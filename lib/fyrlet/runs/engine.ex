defmodule Fyrlet.Runs.Engine do
  @moduledoc """
  Advances runs. Every function that changes state does so in one transaction that holds
  the run's row lock, so claiming, committing a result, consuming a signal, timing out a
  wait and cancelling are serialised against each other.

  Execution ownership: claiming a step persists a lease and increments the run's
  `execution_epoch`. A result is only accepted while its attempt is still `leased` and its
  epoch equals the run's current epoch; anything else is recorded as a late result and
  never advances the run. The framework does not promise that code outside the database
  never runs twice - only that a stale executor cannot change state.
  """
  import Ecto.Query
  require Logger
  alias Fyrlet.{Auth, Effects, Error, Repo}

  alias Fyrlet.Runs.{
    Attempt,
    Faults,
    Grant,
    Limits,
    Notify,
    Plan,
    Resolver,
    Run,
    Signal,
    Step,
    Store,
    Worker
  }

  @terminal ~w(completed failed cancelled expired)

  # ---- driving ------------------------------------------------------------------------

  def run_once(run_id) do
    case claim(run_id) do
      {:execute, context} -> execute(context)
      other -> other
    end
  end

  defdelegate transact(fun), to: Fyrlet.Transaction, as: :run

  # ---- claim --------------------------------------------------------------------------

  def claim(run_id), do: transact(fn -> claim_locked(run_id) end)

  defp claim_locked(run_id, mode \\ :internal) do
    case Store.lock_run(run_id) do
      nil -> :noop
      %Run{status: status} when status in @terminal or status == "cancelling" -> :noop
      run -> claim_active(run, Auth.now(), mode)
    end
  end

  defp claim_active(run, now, mode) do
    cond do
      not future?(run.expires_at, now) ->
        Store.close_run(run, "expired",
          error: error_map("RUN_EXPIRED", "The run reached its deadline")
        )

        :noop

      grant_unusable?(run, now) ->
        fail_for_grant(run)
        :noop

      true ->
        claim_step(run, now, mode)
    end
  end

  defp claim_step(run, now, mode) do
    case Store.lock_step(run.id, run.current_step_seq) do
      nil ->
        :noop

      %Step{type: "wait", status: "pending"} = step ->
        enter_wait(run, step, now)

      %Step{type: "step", status: "pending"} = step ->
        cond do
          # `not_before` holds a retry back until its backoff has passed.
          future?(step.not_before, now) -> :noop
          not runnable_here?(step, mode) -> :noop
          true -> claim_work(run, step, now, mode)
        end

      %Step{type: "step", status: "running"} = step ->
        recover_stuck_step(run, step, now, mode)

      _other ->
        :noop
    end
  end

  defp recover_stuck_step(run, step, now, mode) do
    live? =
      run.id
      |> Store.leased_attempts()
      |> Enum.any?(&(&1.step_id == step.id and future?(&1.lease_expires_at, now)))

    if live? do
      :noop
    else
      case abandon_expired(run, step, now) do
        {:ok, run, step} ->
          if runnable_here?(step, mode), do: claim_work(run, step, now, mode), else: :noop

        :failed ->
          :noop
      end
    end
  end

  # In-process workers take unqueued steps; an executor takes only its own queues.
  defp runnable_here?(step, :internal), do: is_nil(step.queue)
  defp runnable_here?(step, {:external, executor}), do: step.queue in executor.queues

  defp claim_work(run, step, now, {:external, executor}) do
    lock_project!(run.project_id)

    if project_busy?(run, now) do
      Worker.wake(run.id, schedule_in: 5)
      :noop
    else
      start_attempt(run, step, nil, now, executor.id)
    end
  end

  defp claim_work(run, step, now, :internal) do
    case Resolver.implementation(run) do
      nil ->
        pause_unavailable(run)
        :noop

      impl ->
        lock_project!(run.project_id)

        if project_busy?(run, now) do
          Worker.wake(run.id, schedule_in: 5)
          :noop
        else
          start_attempt(run, step, impl, now)
        end
    end
  end

  defp start_attempt(run, step, impl, now, executor_id \\ nil) do
    run =
      if run.status in ["pending", "waiting"],
        do: Store.move_run(run, "running", wait_reason: nil, started_at: run.started_at || now),
        else: run

    run = Store.update_run(run, execution_epoch: run.execution_epoch + 1)
    attempt_number = step.current_attempt + 1

    attempt =
      Repo.insert!(%Attempt{
        run_id: run.id,
        project_id: run.project_id,
        step_id: step.id,
        attempt: attempt_number,
        execution_epoch: run.execution_epoch,
        lease_id: Ecto.UUID.generate(),
        lease_expires_at: DateTime.add(now, Limits.get(:lease_seconds), :second),
        executor_id: executor_id,
        status: "leased",
        started_at: now
      })

    step =
      Store.move_step(step, "running",
        current_attempt: attempt_number,
        started_at: step.started_at || now,
        not_before: nil
      )

    Store.event(run.id, "attempt.leased", step.id, %{
      "attempt" => attempt_number,
      "epoch" => run.execution_epoch
    })

    {:execute, %{run: run, step: step, attempt: attempt, impl: impl}}
  end

  # Counting a project's leases and creating one is a read followed by a write, and the claims of
  # two runs lock only their own rows, so without more both can count the same free slot. This
  # lock is per project and lasts until the claim's transaction commits - after the new lease is
  # visible - so the next claim of that project counts it. Different projects do not wait for each
  # other. Outside a transaction the lock would be released at once and protect nothing, so that
  # is refused rather than silently allowed.
  defp lock_project!(project_id) do
    unless Repo.in_transaction?(),
      do: raise("A project lease slot must be claimed inside the claim's transaction")

    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "fyrlet.runs.project:" <> project_id
    ])
  end

  @doc false
  def project_busy_for_test?(run, now), do: project_busy?(run, now)

  defp project_busy?(run, now) do
    held =
      Repo.one(
        from(a in Attempt,
          where:
            a.project_id == ^run.project_id and a.status == "leased" and
              a.lease_expires_at > ^now and a.run_id != ^run.id,
          select: count(a.id)
        )
      )

    held >= Limits.get(:max_concurrent_per_project)
  end

  defp pause_unavailable(run) do
    unless run.status == "waiting" and run.wait_reason == "definition_unavailable" do
      run = if run.status == "pending", do: Store.move_run(run, "running"), else: run
      Store.move_run(run, "waiting", wait_reason: "definition_unavailable")
    end

    :ok
  end

  # ---- waits --------------------------------------------------------------------------

  defp enter_wait(run, step, now) do
    run =
      if run.status == "pending", do: Store.move_run(run, "running", started_at: now), else: run

    deadline = DateTime.add(now, wait_timeout_ms(run, step), :millisecond)
    step = Store.move_step(step, "waiting", wait_deadline: deadline, started_at: now)
    Store.event(run.id, "wait.entered", step.id, %{"signal" => step.signal_name})

    signal =
      Repo.one(
        from(s in Signal,
          where: s.run_id == ^run.id and s.wait_id == ^step.id and s.status == "received",
          order_by: [asc: s.received_at],
          limit: 1,
          lock: "FOR UPDATE"
        )
      )

    if signal do
      consume_signal(run, step, signal, now)
      :noop
    else
      Store.move_run(run, "waiting", wait_reason: "signal")
      Worker.wait_timeout(run.id, step.id, deadline)
      :noop
    end
  end

  defp wait_timeout_ms(run, step) do
    node = Enum.find(run.plan["nodes"], &(&1["seq"] == step.seq))
    node["timeout_ms"]
  end

  @doc "Consumes a signal for a waiting node and advances the run. Caller holds the run lock."
  def consume_signal(run, step, signal, now) do
    Repo.update_all(from(s in Signal, where: s.id == ^signal.id),
      set: [status: "consumed", consumed_at: now]
    )

    output = %{"signal" => signal.name, "payload" => signal.payload}
    step = Store.move_step(step, "satisfied", output: output, finished_at: now)
    Store.event(run.id, "wait.satisfied", step.id, %{"signal" => signal.name})

    run =
      if run.status == "waiting", do: Store.move_run(run, "running", wait_reason: nil), else: run

    advance(run, output, {:wait_satisfied, step.name, signal.payload})
  end

  @doc "Handles a wait deadline. Races with a signal for the same run lock."
  def expire_wait(run_id, step_id) do
    transact(fn ->
      now = Auth.now()

      with %Run{status: status} = run when status not in @terminal and status != "cancelling" <-
             Store.lock_run(run_id),
           %Step{type: "wait", status: "waiting"} = step <-
             Store.lock_step(run_id, run.current_step_seq),
           true <- step.id == step_id,
           false <- future?(step.wait_deadline, now) do
        timeout_wait(run, step, now)
      else
        _other -> :noop
      end
    end)
  end

  defp timeout_wait(run, %Step{wait_timeout_action: "continue"} = step, now) do
    output = %{"timeout" => true}
    step = Store.move_step(step, "timed_out", output: output, finished_at: now)
    Store.event(run.id, "wait.timed_out", step.id, %{"action" => "continue"})

    run =
      if run.status == "waiting", do: Store.move_run(run, "running", wait_reason: nil), else: run

    advance(run, output, {:wait_timed_out, step.name})
    :continued
  end

  defp timeout_wait(run, step, now) do
    error = error_map("WAIT_TIMEOUT", "The awaited signal did not arrive in time")
    Store.move_step(step, "timed_out", error: error, finished_at: now)
    Store.event(run.id, "wait.timed_out", step.id, %{"action" => "fail"})
    Store.close_run(run, "failed", error: error)
    :failed
  end

  # ---- execution ----------------------------------------------------------------------

  defp execute(%{run: run, step: step, attempt: attempt, impl: impl} = claimed) do
    Faults.check(:after_claim)

    context = %{
      run_id: run.id,
      step_id: step.id,
      step_seq: step.seq,
      attempt: attempt.attempt,
      execution_epoch: attempt.execution_epoch,
      operation: run.operation,
      project_id: run.project_id,
      initiator_subject_id: run.subject_id,
      # Stable across retries and lease takeovers: use it as an external idempotency key.
      operation_id: "#{run.id}:#{step.seq}",
      outputs: outputs(run.id)
    }

    result = safe_step(impl, step, context)
    Faults.check(:before_commit)
    outcome = commit_result(claimed, result)
    Faults.check(:after_commit)
    outcome
  end

  defp outputs(run_id) do
    Repo.all(
      from(s in Step,
        where: s.run_id == ^run_id and s.status in ["succeeded", "satisfied", "timed_out"],
        order_by: s.seq,
        select: %{name: s.name, output: s.output}
      )
    )
  end

  defp safe_step(impl, step, context) do
    case impl.step(step.name, step.input, context) do
      {:ok, output} when is_map(output) ->
        {:ok, output}

      # A managed commit: business writes that must be atomic with the step's result.
      {:ok, output, options} when is_map(output) and is_list(options) ->
        {:ok, output, Keyword.get(options, :commit)}

      {:effect, spec} ->
        {:effect, spec}

      {:ok, nil} ->
        {:ok, %{}}

      {:error, %Error{} = error} ->
        {:error, error}

      other ->
        {:error,
         Error.new(
           "INVALID_STEP_RESULT",
           "step/3 returned #{inspect(summary(other))}",
           %{},
           false
         )}
    end
  rescue
    exception ->
      Logger.error("Run step raised #{inspect(exception.__struct__)}")
      {:error, Error.new("STEP_CRASHED", "The step raised an exception", %{}, true)}
  catch
    kind, _reason ->
      Logger.error("Run step ended abnormally (#{kind})")
      {:error, Error.new("STEP_CRASHED", "The step ended abnormally", %{}, true)}
  end

  defp summary({tag, _}) when is_atom(tag), do: tag
  defp summary(other) when is_atom(other), do: other
  defp summary(_other), do: :unexpected

  # ---- commit -------------------------------------------------------------------------

  def commit_result(
        %{run: claimed_run, step: claimed_step, attempt: claimed_attempt} = claimed,
        result
      ) do
    outcome =
      do_commit_result(
        claimed_run,
        claimed_step,
        claimed_attempt,
        result,
        claimed[:result_hash],
        claimed[:enforce_lease] == true
      )

    case outcome do
      # The step's own writes failed: nothing of that commit survived, so record the failure.
      {:error, {:commit_failed, error}} -> commit_result(claimed, {:error, error})
      other -> other
    end
  end

  # `enforce_lease`: the report comes from an external executor, whose lease is only good until
  # `lease_expires_at`. In-process steps run under the same lease record but are not interrupted
  # when it passes (they do not heartbeat), so for them it is recovery's job, as before.
  defp lease_over?(attempt), do: DateTime.compare(attempt.lease_expires_at, Auth.now()) != :gt

  defp do_commit_result(claimed_run, claimed_step, claimed_attempt, result, hash, enforce_lease) do
    transact(fn ->
      run = Store.lock_run(claimed_run.id)

      attempt =
        Repo.one(from(a in Attempt, where: a.id == ^claimed_attempt.id, lock: "FOR UPDATE"))

      if attempt.status != "leased" or attempt.execution_epoch != run.execution_epoch or
           run.status in @terminal or (enforce_lease and lease_over?(attempt)) do
        Store.event(run.id, "attempt.late_result", claimed_step.id, %{
          "attempt" => attempt.attempt,
          "epoch" => attempt.execution_epoch,
          "outcome" => outcome_label(result)
        })

        :stale
      else
        # An executor's report is remembered with its commit, so a repeat can be recognised.
        if hash,
          do:
            Repo.update_all(from(a in Attempt, where: a.id == ^attempt.id),
              set: [result_hash: hash]
            )

        apply_result(run, claimed_step.seq, attempt, result)
      end
    end)
  end

  @doc """
  Claims one step for an external executor from the queues it may serve. Returns
  `{:ok, work}` or `:none`.
  """
  def claim_external(executor, queues) do
    queues = Enum.filter(queues, &(&1 in executor.queues))

    candidates =
      Repo.all(
        from(s in Step,
          join: r in Run,
          on: r.id == s.run_id and r.current_step_seq == s.seq,
          where:
            r.project_id == ^executor.project_id and s.queue in ^queues and
              s.status in ["pending", "running"] and r.status in ["pending", "running", "waiting"],
          order_by: [asc: s.inserted_at],
          select: s.run_id,
          limit: 10
        )
      )

    Enum.find_value(candidates, :none, fn run_id ->
      case transact(fn -> claim_locked(run_id, {:external, executor}) end) do
        {:execute, claimed} -> {:ok, work(claimed)}
        _other -> nil
      end
    end)
  end

  defp work(%{run: run, step: step, attempt: attempt}) do
    %{
      "run_id" => run.id,
      "operation" => run.operation,
      "step_id" => step.id,
      "step" => step.name,
      "queue" => step.queue,
      "input" => step.input,
      "definition_version" => run.definition_version,
      "attempt_id" => attempt.id,
      "attempt" => attempt.attempt,
      "lease_id" => attempt.lease_id,
      "execution_epoch" => attempt.execution_epoch,
      "lease_expires_at" => DateTime.to_iso8601(attempt.lease_expires_at)
    }
  end

  defp apply_result(run, seq, attempt, result) do
    step = Store.lock_step(run.id, seq)
    now = Auth.now()

    cond do
      run.status == "cancelling" ->
        Store.move_attempt(attempt, attempt_status(result), error: attempt_error(result))

        Store.event(run.id, "attempt.late_result", step.id, %{
          "attempt" => attempt.attempt,
          "outcome" => outcome_label(result)
        })

        Store.close_run(run, "cancelled", cancellation_outcome: "confirmed")
        :cancelled

      match?({:effect, _}, result) ->
        start_effect(run, step, attempt, elem(result, 1), now)

      true ->
        {plain, commit} =
          case result do
            {:ok, output, commit} -> {{:ok, output}, commit}
            other -> {other, nil}
          end

        case validate_output(run, step, plain) do
          {:ok, output} -> succeed(run, step, attempt, output, now, commit)
          {:error, error} -> fail_attempt(run, step, attempt, error, now)
        end
    end
  end

  defp start_effect(run, step, attempt, spec, now) do
    case Effects.create(run, step, spec, now) do
      {:ok, effect} ->
        # The attempt is over; the effect owns delivery from here, with its own lease.
        Store.move_attempt(attempt, "succeeded")
        Store.move_step(step, "awaiting_effect")
        Store.event(run.id, "step.awaiting_effect", step.id, %{"effect" => effect.id})
        Store.move_run(run, "waiting", wait_reason: "effect")
        :awaiting_effect

      {:error, error} ->
        fail_attempt(run, step, attempt, %{error | retryable: false}, now)
    end
  end

  @doc """
  An effect reached a final state. Called with the run locked. A run that is already over
  (or cancelling) only has the outcome recorded; a waiting step is completed or failed.
  """
  def effect_resolved(run, effect, outcome) do
    step = Repo.one(from(s in Step, where: s.id == ^effect.step_id, lock: "FOR UPDATE"))

    cond do
      run.status in @terminal or run.status == "cancelling" ->
        :recorded

      is_nil(step) or step.status != "awaiting_effect" ->
        :recorded

      outcome == :succeeded ->
        output = %{"effect" => %{"key" => effect.effect_key, "result" => effect.result || %{}}}
        Store.move_step(step, "succeeded", output: output, finished_at: Auth.now())
        Store.event(run.id, "step.succeeded", step.id, %{"effect" => effect.id})
        advance(run, output, {:step_succeeded, step.name, output})
        :resumed

      true ->
        error = effect.last_error || error_map("EFFECT_FAILED", "The external effect failed")
        Store.move_step(step, "failed", error: error, finished_at: Auth.now())
        Store.event(run.id, "step.failed", step.id, %{"effect" => effect.id})
        Store.close_run(run, "failed", error: error)
        :failed
    end
  end

  defp validate_output(run, step, {:ok, output}) do
    with {:ok, output} <- Plan.payload(output, "output of #{step.name}") |> wrap(),
         {:ok, output} <- output_contract(run, step, output) do
      {:ok, output}
    end
  end

  defp validate_output(_run, _step, {:error, %Error{} = error}), do: {:error, error}

  defp wrap({:ok, value}), do: {:ok, value}

  defp wrap({:error, %Error{message: message}}),
    do: {:error, Error.new("INVALID_STEP_OUTPUT", message, %{}, false)}

  defp output_contract(run, step, output) do
    with {:ok, _module, specification} <- Fyrlet.Registry.fetch("operations", run.operation),
         {:error, _} = invalid <-
           Plan.contract(
             specification,
             ["steps", step.name, "output"],
             output,
             "output of #{step.name}"
           ) do
      _ = invalid

      {:error,
       Error.new("INVALID_STEP_OUTPUT", "The output of #{step.name} does not match its contract")}
    else
      {:ok, value} -> {:ok, value}
      _unknown_operation -> {:ok, output}
    end
  end

  defp succeed(run, step, attempt, output, now, commit) do
    run_commit(commit)
    Store.move_attempt(attempt, "succeeded")
    Store.move_step(step, "succeeded", output: output, finished_at: now)
    Store.event(run.id, "step.succeeded", step.id, %{"attempt" => attempt.attempt})
    step_telemetry(run, step, attempt, "succeeded", now)
    advance(run, output, {:step_succeeded, step.name, output})
    :succeeded
  end

  # Runs inside the commit transaction, so its writes are atomic with the step's result.
  defp run_commit(nil), do: :ok

  defp run_commit(commit) when is_function(commit, 0) do
    case commit.() do
      {:error, %Error{} = error} -> Repo.rollback({:commit_failed, error})
      _ok -> :ok
    end
  rescue
    exception ->
      Logger.error("Step commit raised #{inspect(exception.__struct__)}")

      Repo.rollback(
        {:commit_failed,
         Error.new("STEP_COMMIT_FAILED", "The step's own writes failed", %{}, true)}
      )
  end

  defp fail_attempt(run, step, attempt, error, now) do
    Store.move_attempt(attempt, "failed", error: Error.to_map(error))

    if error.retryable and step.current_attempt < step.max_attempts do
      delay = backoff(step.current_attempt)
      next = DateTime.add(now, delay, :second)
      Store.move_step(step, "pending", not_before: next, error: Error.to_map(error))

      Store.event(run.id, "step.retry_scheduled", step.id, %{
        "attempt" => attempt.attempt,
        "delay_s" => delay
      })

      Store.update_run(run, [])
      Worker.wake(run.id, schedule_in: delay)
      step_telemetry(run, step, attempt, "retry", now)
      :retry
    else
      Store.move_step(step, "failed", error: Error.to_map(error), finished_at: now)

      Store.event(run.id, "step.failed", step.id, %{
        "attempt" => attempt.attempt,
        "code" => error.code
      })

      Store.close_run(run, "failed", error: Error.to_map(error))
      step_telemetry(run, step, attempt, "failed", now)
      :failed
    end
  end

  defp step_telemetry(run, step, attempt, status, now) do
    Notify.emit(
      [:fyrlet, :run, :step],
      %{duration_ms: DateTime.diff(now, attempt.started_at, :millisecond)},
      %{operation: run.operation, name: step.name, status: status, attempt: attempt.attempt}
    )
  end

  defp backoff(attempt) do
    base = Limits.get(:retry_base_seconds)
    min(base * Integer.pow(2, max(attempt - 1, 0)), Limits.get(:retry_max_seconds))
  end

  defp attempt_status({:ok, _}), do: "succeeded"
  defp attempt_status({:ok, _, _}), do: "succeeded"
  defp attempt_status({:effect, _}), do: "succeeded"
  defp attempt_status(_other), do: "failed"
  defp attempt_error({:error, %Error{} = error}), do: Error.to_map(error)
  defp attempt_error(_other), do: nil
  defp outcome_label({:ok, _}), do: "ok"
  defp outcome_label({:ok, _, _}), do: "ok"
  defp outcome_label({:effect, _}), do: "effect"
  defp outcome_label({:error, %Error{code: code}}), do: code
  defp outcome_label(_other), do: "unknown"

  # ---- advancing ----------------------------------------------------------------------

  defp advance(run, output, event) do
    run =
      if run.status == "waiting", do: Store.move_run(run, "running", wait_reason: nil), else: run

    if run.plan["mode"] == "dynamic",
      do: advance_dynamic(run, event),
      else: advance_planned(run, output)
  end

  # The next node is decided by the definition and persisted in this transaction, so a crash
  # can never leave a decision made but not recorded, and recovery never decides twice.
  defp advance_dynamic(run, event) do
    case Fyrlet.Runs.Dynamic.decide(run, event) do
      {:node, node} ->
        next = run.current_step_seq + 1
        Fyrlet.Runs.insert_step(run.id, Map.put(node, "seq", next))

        Store.event(run.id, "plan.advanced", nil, %{
          "next" => node["name"],
          "type" => node["type"]
        })

        run = Store.update_run(run, current_step_seq: next)
        Faults.check(:before_wake_insert)
        Worker.wake(run.id)
        run

      {:done, output} ->
        Store.move_run(run, "completed", output: output, finished_at: Auth.now())

      {:error, error} ->
        Store.close_run(run, "failed", error: error)
    end
  end

  defp advance_planned(run, output) do
    next = run.current_step_seq + 1

    case Store.lock_step(run.id, next) do
      nil ->
        Store.move_run(run, "completed", output: output, finished_at: Auth.now())

      _step ->
        run = Store.update_run(run, current_step_seq: next)
        Faults.check(:before_wake_insert)
        Worker.wake(run.id)
        run
    end
  end

  # ---- cancel -------------------------------------------------------------------------

  @doc "Accepts a cancellation. Idempotent. Returns the run."
  def request_cancel(run_id) do
    transact(fn ->
      case Store.lock_run(run_id) do
        nil ->
          Repo.rollback(:not_found)

        %Run{status: status} = run when status in @terminal or status == "cancelling" ->
          run

        run ->
          now = Auth.now()
          deadline = DateTime.add(now, Limits.get(:cancel_deadline_seconds), :second)
          run = Store.move_run(run, "cancelling", cancel_deadline: deadline)
          cancel_unstarted(run)

          if Store.leased_attempts(run.id) == [] do
            Store.close_run(run, "cancelled", cancellation_outcome: "confirmed")
          else
            run
          end
      end
    end)
  end

  defp cancel_unstarted(run) do
    for step <-
          Repo.all(
            from(s in Step, where: s.run_id == ^run.id and s.status in ["pending", "waiting"])
          ) do
      Store.move_step(step, "cancelled", finished_at: Auth.now())
      Store.event(run.id, "step.cancelled", step.id, %{})
    end
  end

  # ---- recovery primitives ------------------------------------------------------------

  @doc "Abandons expired leases of a running step; retries it or fails the run."
  def abandon_expired(run, step, now) do
    attempts = run.id |> Store.leased_attempts() |> Enum.filter(&(&1.step_id == step.id))

    for attempt <- attempts do
      Store.move_attempt(attempt, "abandoned")
      Store.event(run.id, "attempt.abandoned", step.id, %{"attempt" => attempt.attempt})
    end

    run = Store.update_run(run, execution_epoch: run.execution_epoch + 1)

    if step.current_attempt >= step.max_attempts do
      error = error_map("ATTEMPTS_EXHAUSTED", "The step did not complete within its attempts")
      Store.move_step(step, "failed", error: error, finished_at: now)
      Store.close_run(run, "failed", error: error)
      :failed
    else
      step = Store.move_step(step, "pending")
      Worker.wake(run.id)
      {:ok, run, step}
    end
  end

  def fail_for_grant(run) do
    Store.close_run(run, "failed",
      error:
        error_map("EXECUTION_GRANT_REVOKED", "The execution authority was revoked or expired")
    )
  end

  defp grant_unusable?(run, now) do
    case Repo.get(Grant, run.execution_grant_id) do
      nil -> true
      %Grant{revoked_at: revoked} when not is_nil(revoked) -> true
      %Grant{expires_at: expires} -> not future?(expires, now)
    end
  end

  def error_map(code, message), do: %{"code" => code, "message" => message}

  defp future?(nil, _now), do: false
  defp future?(time, now), do: DateTime.compare(time, now) == :gt
end
