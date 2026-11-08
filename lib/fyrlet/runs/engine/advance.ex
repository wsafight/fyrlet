defmodule Fyrlet.Runs.Engine.Advance do
  @moduledoc """
  Moves a run to its next node once the current step has an outcome. The next node is
  decided and persisted in the caller's transaction (which holds the run lock), so a crash
  can never leave a decision made but not recorded, and recovery never decides twice.
  """
  alias Fyrlet.Auth
  alias Fyrlet.Runs.{Faults, Store, Worker}

  @doc false
  def advance(run, output, event) do
    run =
      if run.status == "waiting", do: Store.move_run(run, "running", wait_reason: nil), else: run

    if run.plan["mode"] == "dynamic",
      do: advance_dynamic(run, event),
      else: advance_planned(run, output)
  end

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
end
