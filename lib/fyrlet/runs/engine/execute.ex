defmodule Fyrlet.Runs.Engine.Execute do
  @moduledoc """
  Runs a claimed step and commits its result. A result is only accepted while its attempt
  is still `leased` and its epoch equals the run's current epoch; anything else is recorded
  as a late result and never advances the run. External executor reports additionally die
  with their lease; in-process steps are recovered instead of interrupted.

  Also converges effects: a step that returns `{:effect, spec}` waits for delivery, and
  `effect_resolved/3` turns the final delivery into the step's outcome.
  """
  import Ecto.Query
  import Fyrlet.Runs.Engine, only: [error_map: 2, future?: 2, transact: 1]
  require Logger
  alias Fyrlet.{Auth, Effects, Error, Repo}
  alias Fyrlet.Runs.{Attempt, Faults, Limits, Notify, Plan, Step, Store, Worker}
  alias Fyrlet.Runs.Engine.Advance

  @terminal ~w(completed failed cancelled expired)

  @doc false
  def execute(%{run: run, step: step, attempt: attempt, impl: impl} = claimed) do
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
  defp lease_over?(attempt), do: not future?(attempt.lease_expires_at, Auth.now())

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
        Advance.advance(run, output, {:step_succeeded, step.name, output})
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
    Advance.advance(run, output, {:step_succeeded, step.name, output})
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
end
