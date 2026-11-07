defmodule Fyrlet.Runs.StateMachine do
  @moduledoc """
  The legal state changes of runs, steps and attempts (temp spec §3.3).

  Pure and database-free so it can be verified exhaustively. Every state change in the
  engine goes through these functions; a change that is not listed here is a bug, not a
  condition to handle.
  """

  @run_states ~w(pending running waiting completed failed cancelling cancelled expired)
  @terminal ~w(completed failed cancelled expired)

  @run_transitions %{
    "pending" => ~w(running failed cancelling expired),
    "running" => ~w(waiting completed failed cancelling expired),
    "waiting" => ~w(running failed cancelling expired),
    "cancelling" => ~w(cancelled expired),
    "completed" => [],
    "failed" => [],
    "cancelled" => [],
    "expired" => []
  }

  @work_states ~w(pending running awaiting_effect succeeded failed cancelled)
  @work_transitions %{
    "pending" => ~w(running cancelled),
    # `pending` again is a retry after a failed or abandoned attempt.
    "running" => ~w(pending awaiting_effect succeeded failed cancelled),
    "awaiting_effect" => ~w(running succeeded failed cancelled),
    "succeeded" => [],
    "failed" => [],
    "cancelled" => []
  }

  @wait_states ~w(pending waiting satisfied timed_out cancelled)
  @wait_transitions %{
    "pending" => ~w(waiting cancelled),
    "waiting" => ~w(satisfied timed_out cancelled),
    "satisfied" => [],
    "timed_out" => [],
    "cancelled" => []
  }

  @attempt_states ~w(leased succeeded failed abandoned)
  @attempt_transitions %{
    "leased" => ~w(succeeded failed abandoned),
    "succeeded" => [],
    "failed" => [],
    "abandoned" => []
  }

  def run_states, do: @run_states
  def work_states, do: @work_states
  def wait_states, do: @wait_states
  def attempt_states, do: @attempt_states
  def terminal_states, do: @terminal

  def terminal?(status), do: status in @terminal
  def active?(status), do: status in @run_states and status not in @terminal

  def run(from, to), do: check(@run_transitions, from, to, :run)

  def step("step", from, to), do: check(@work_transitions, from, to, :step)
  def step("wait", from, to), do: check(@wait_transitions, from, to, :wait)

  def attempt(from, to), do: check(@attempt_transitions, from, to, :attempt)

  def allowed(:run, from), do: Map.get(@run_transitions, from, [])
  def allowed(:step, from), do: Map.get(@work_transitions, from, [])
  def allowed(:wait, from), do: Map.get(@wait_transitions, from, [])
  def allowed(:attempt, from), do: Map.get(@attempt_transitions, from, [])

  defp check(table, from, to, kind) do
    if to in Map.get(table, from, []),
      do: :ok,
      else: {:error, {:illegal_transition, kind, from, to}}
  end
end
