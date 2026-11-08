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

  This module is the public entry point; the work lives in `Engine.Claim` (leases and
  admission), `Engine.Execute` (running steps, committing results, effect outcomes),
  `Engine.Wait` (signals and deadlines), `Engine.Advance` (next-node planning) and
  `Engine.Cancel`. The helpers at the bottom are shared by those modules.
  """
  alias Fyrlet.Runs.{Store, Worker}
  alias Fyrlet.Runs.Engine.{Cancel, Claim, Execute, Wait}

  # ---- driving ------------------------------------------------------------------------

  def run_once(run_id) do
    case Claim.claim(run_id) do
      {:execute, context} -> Execute.execute(context)
      other -> other
    end
  end

  defdelegate transact(fun), to: Fyrlet.Transaction, as: :run

  # ---- the public surface, unchanged ---------------------------------------------------

  defdelegate claim(run_id), to: Claim
  defdelegate claim_external(executor, queues), to: Claim
  defdelegate fail_for_grant(run), to: Claim
  defdelegate project_busy_for_test?(run, now), to: Claim

  defdelegate commit_result(claimed, result), to: Execute
  defdelegate effect_resolved(run, effect, outcome), to: Execute

  defdelegate consume_signal(run, step, signal, now), to: Wait
  defdelegate expire_wait(run_id, step_id), to: Wait

  defdelegate request_cancel(run_id), to: Cancel

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

  # ---- shared helpers -----------------------------------------------------------------

  def error_map(code, message), do: %{"code" => code, "message" => message}

  @doc false
  def future?(nil, _now), do: false
  def future?(time, now), do: DateTime.compare(time, now) == :gt
end
