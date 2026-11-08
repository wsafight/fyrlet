defmodule Fyrlet.Runs.Engine.Wait do
  @moduledoc """
  Wait nodes: entering a wait, consuming its signal and handling its deadline. All entry
  points run inside the caller's transaction (or open their own) holding the run's row
  lock, so a signal and a timeout for the same wait race on that lock.
  """
  import Ecto.Query
  import Fyrlet.Runs.Engine, only: [error_map: 2, future?: 2, transact: 1]
  alias Fyrlet.{Auth, Repo}
  alias Fyrlet.Runs.{Run, Signal, Step, Store, Worker}
  alias Fyrlet.Runs.Engine.Advance

  @terminal ~w(completed failed cancelled expired)

  @doc false
  def enter_wait(run, step, now) do
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

    Advance.advance(run, output, {:wait_satisfied, step.name, signal.payload})
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

    Advance.advance(run, output, {:wait_timed_out, step.name})
    :continued
  end

  defp timeout_wait(run, step, now) do
    error = error_map("WAIT_TIMEOUT", "The awaited signal did not arrive in time")
    Store.move_step(step, "timed_out", error: error, finished_at: now)
    Store.event(run.id, "wait.timed_out", step.id, %{"action" => "fail"})
    Store.close_run(run, "failed", error: error)
    :failed
  end
end
