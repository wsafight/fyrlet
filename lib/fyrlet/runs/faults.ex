defmodule Fyrlet.Runs.Faults do
  @moduledoc """
  Fault-injection seam. Production leaves `:run_faults` unset, so `check/1` is a no-op.

  Tests set it to a one-argument function that is called with the injection point and may
  raise, exit, sleep or send a message to simulate a crash or a race at that exact place.
  Points: `:after_claim`, `:before_commit`, `:after_commit`, `:before_wake_insert`.
  """
  def check(point) do
    case Application.get_env(:fyrlet, :run_faults) do
      nil -> :ok
      hook when is_function(hook, 1) -> hook.(point)
    end
  end
end
