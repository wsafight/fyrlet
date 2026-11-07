defmodule Fyrlet.Runs.Worker do
  @moduledoc """
  Oban only wakes the engine; the run tables decide whether anything runs. A duplicate,
  late or redelivered job finds nothing to claim and exits, and Oban's own retries never
  consume the run's business retry budget (that is counted in the attempt rows).
  """
  use Oban.Worker, queue: :fyrlet, max_attempts: 5
  alias Fyrlet.Runs.Engine

  @impl true
  def perform(%Oban.Job{
        args: %{"kind" => "wait_timeout", "run_id" => run_id, "step_id" => step_id}
      }) do
    Engine.expire_wait(run_id, step_id)
    :ok
  end

  # `:local` strategy: several short steps in one wake-up. Each step is still claimed, leased
  # and committed on its own, so a crash between them loses nothing and a stale result is
  # still refused; the chain only saves the round trip through the queue.
  def perform(%Oban.Job{args: %{"run_id" => run_id}}) do
    chain(run_id, Fyrlet.Runs.Limits.get(:local_chain))
    :ok
  end

  defp chain(_run_id, 0), do: :ok

  defp chain(run_id, remaining) do
    case Engine.run_once(run_id) do
      :succeeded -> chain(run_id, remaining - 1)
      _other -> :ok
    end
  end

  @doc "Schedules a wake-up; call inside the transaction that made work available."
  def wake(run_id, options \\ []) do
    %{"kind" => "wake", "run_id" => run_id}
    |> new(Keyword.merge([unique: [period: 30, states: [:available, :retryable]]], options))
    |> Oban.insert!()
  end

  def wait_timeout(run_id, step_id, deadline) do
    %{"kind" => "wait_timeout", "run_id" => run_id, "step_id" => step_id}
    |> new(scheduled_at: deadline)
    |> Oban.insert!()
  end
end
