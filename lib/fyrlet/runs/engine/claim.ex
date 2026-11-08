defmodule Fyrlet.Runs.Engine.Claim do
  @moduledoc """
  Claims work for in-process workers and external executors. A claim persists a lease and
  increments the run's `execution_epoch`, all in one transaction holding the run's row lock,
  so claims are serialised against commits, signals, timeouts and cancels.

  Per-project concurrency is admitted under a project advisory lock held to the end of the
  claim's transaction, so two runs of one project cannot count the same free lease slot.
  """
  import Ecto.Query
  import Fyrlet.Runs.Engine, only: [error_map: 2, future?: 2, transact: 1]
  alias Fyrlet.{Auth, Repo}
  alias Fyrlet.Runs.{Attempt, Grant, Limits, Resolver, Run, Step, Store, Worker}
  alias Fyrlet.Runs.Engine.Wait

  @terminal ~w(completed failed cancelled expired)

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
        Wait.enter_wait(run, step, now)

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
      case Fyrlet.Runs.Engine.abandon_expired(run, step, now) do
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
end
