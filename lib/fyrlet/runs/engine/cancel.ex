defmodule Fyrlet.Runs.Engine.Cancel do
  @moduledoc """
  Cooperative cancellation: the run moves to `cancelling`, unstarted steps are cancelled at
  once, and the run closes as `cancelled` either immediately or when the last live attempt
  reports back (or its lease is recovered).
  """
  import Ecto.Query
  import Fyrlet.Runs.Engine, only: [transact: 1]
  alias Fyrlet.{Auth, Repo}
  alias Fyrlet.Runs.{Limits, Run, Step, Store}

  @terminal ~w(completed failed cancelled expired)

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
end
