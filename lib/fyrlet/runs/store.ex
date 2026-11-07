defmodule Fyrlet.Runs.Store do
  @moduledoc """
  The only place run, step and attempt rows change state. Every change is checked against
  `Fyrlet.Runs.StateMachine` and must happen inside a transaction that holds the run's row
  lock (`lock_run/1`). An illegal transition raises: it is a bug, not a runtime condition.
  """
  import Ecto.Query
  alias Fyrlet.{Auth, Repo}
  alias Fyrlet.Runs.{Attempt, Notify, Run, StateMachine, Step}

  def lock_run(id), do: Repo.one(from(run in Run, where: run.id == ^id, lock: "FOR UPDATE"))

  def lock_step(run_id, seq) do
    Repo.one(
      from(step in Step, where: step.run_id == ^run_id and step.seq == ^seq, lock: "FOR UPDATE")
    )
  end

  def steps(run_id),
    do: Repo.all(from(step in Step, where: step.run_id == ^run_id, order_by: step.seq))

  # ---- runs ---------------------------------------------------------------------------

  def move_run(%Run{} = run, to, attrs \\ []) do
    guard!(StateMachine.run(run.status, to))
    updated = update_run_row(run, Keyword.merge([status: to], attrs), run.status)
    event(updated.id, "run." <> to, nil, %{"from" => run.status})
    Notify.mark(updated)

    if StateMachine.terminal?(to) do
      started = updated.inserted_at
      duration = DateTime.diff(updated.finished_at || Auth.now(), started, :millisecond)

      Notify.emit(
        [:fyrlet, :run, :stop],
        %{duration_ms: duration, steps: length(updated.plan["nodes"])},
        %{
          operation: updated.operation,
          status: to,
          project_id: updated.project_id
        }
      )
    end

    updated
  end

  @doc "Changes fields without changing the status."
  def update_run(%Run{} = run, attrs) do
    updated = update_run_row(run, attrs, run.status)
    Notify.mark(updated)
    updated
  end

  defp update_run_row(run, attrs, expected_status) do
    now = Auth.now()

    query = from(r in Run, where: r.id == ^run.id and r.status == ^expected_status, select: r)

    case Repo.update_all(query, set: Keyword.put(attrs, :updated_at, now), inc: [version: 1]) do
      {1, [updated]} -> updated
      {0, []} -> raise "run #{run.id} changed concurrently while its lock was held"
    end
  end

  @doc """
  Ends a run in a terminal state: abandons live attempts, invalidates the execution
  epoch so a straggling executor cannot commit, and cancels unfinished nodes.
  """
  def close_run(%Run{} = run, to, attrs \\ []) do
    abandoned = abandon_leases(run.id)
    cancel_open_steps(run.id)
    # Effects never sent are withdrawn; ones already out keep going and are recorded as they land.
    Fyrlet.Effects.cancel_open(run.id)
    now = Auth.now()

    run =
      if abandoned > 0, do: update_run(run, execution_epoch: run.execution_epoch + 1), else: run

    move_run(run, to, Keyword.merge([finished_at: now], attrs))
  end

  # ---- steps --------------------------------------------------------------------------

  def move_step(%Step{} = step, to, attrs \\ []) do
    guard!(StateMachine.step(step.type, step.status, to))
    now = Auth.now()
    query = from(s in Step, where: s.id == ^step.id and s.status == ^step.status, select: s)

    case Repo.update_all(query, set: Keyword.merge([status: to, updated_at: now], attrs)) do
      {1, [updated]} -> updated
      {0, []} -> raise "step #{step.id} changed concurrently while the run lock was held"
    end
  end

  defp cancel_open_steps(run_id) do
    for step <-
          Repo.all(
            from(s in Step,
              where:
                s.run_id == ^run_id and
                  s.status in ["pending", "waiting", "running", "awaiting_effect"]
            )
          ) do
      move_step(step, "cancelled", finished_at: Auth.now())
      event(run_id, "step.cancelled", step.id, %{})
    end

    :ok
  end

  # ---- attempts -----------------------------------------------------------------------

  def leased_attempts(run_id) do
    Repo.all(from(a in Attempt, where: a.run_id == ^run_id and a.status == "leased"))
  end

  def move_attempt(%Attempt{} = attempt, to, attrs \\ []) do
    guard!(StateMachine.attempt(attempt.status, to))
    now = Auth.now()

    query =
      from(a in Attempt, where: a.id == ^attempt.id and a.status == ^attempt.status, select: a)

    case Repo.update_all(query,
           set: Keyword.merge([status: to, finished_at: now, updated_at: now], attrs)
         ) do
      {1, [updated]} -> updated
      {0, []} -> raise "attempt #{attempt.id} changed concurrently while the run lock was held"
    end
  end

  def abandon_leases(run_id) do
    attempts = leased_attempts(run_id)
    for attempt <- attempts, do: move_attempt(attempt, "abandoned")
    length(attempts)
  end

  # ---- events -------------------------------------------------------------------------

  # Taking the next sequence number and writing the event are one statement: the UPDATE takes
  # (or already holds) the run's row lock and the INSERT uses the number it returned, in the
  # same transaction. Two statements meant two round trips for every event, and a step emits
  # several.
  @event_sql """
  WITH next AS (
    UPDATE fyrlet_runs SET event_seq = event_seq + 1 WHERE id = $1 RETURNING event_seq
  )
  INSERT INTO fyrlet_run_events (id, run_id, step_id, type, payload, seq, created_at)
  SELECT $2::uuid, $1::uuid, $3::uuid, $4::text, $5::jsonb, next.event_seq, $6::timestamp FROM next
  """

  @doc "Appends an audit event; the sequence number is allocated under the run's lock."
  def event(run_id, type, step_id, payload) do
    %{num_rows: 1} =
      Repo.query!(@event_sql, [
        Ecto.UUID.dump!(run_id),
        Ecto.UUID.bingenerate(),
        step_id && Ecto.UUID.dump!(step_id),
        type,
        payload,
        DateTime.to_naive(Auth.now())
      ])

    :ok
  end

  defp guard!(:ok), do: :ok

  defp guard!({:error, reason}),
    do: raise(ArgumentError, "illegal state change: #{inspect(reason)}")
end
