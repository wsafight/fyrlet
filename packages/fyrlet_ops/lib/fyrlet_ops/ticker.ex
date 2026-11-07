defmodule FyrletOps.Ticker do
  @moduledoc """
  Evaluates alerts on a timer (`config :fyrlet_ops, interval_ms: 30_000`; `false` disables the
  timer, for tests that call `FyrletOps.Status.evaluate/0` themselves). A failed evaluation is
  logged and tried again at the next tick.
  """
  use GenServer
  require Logger

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(_options) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    try do
      FyrletOps.Status.evaluate()
    rescue
      exception -> Logger.error("Ops evaluation failed: #{inspect(exception.__struct__)}")
    end

    schedule()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule do
    case Application.get_env(:fyrlet_ops, :interval_ms, 30_000) do
      interval when is_integer(interval) and interval > 0 ->
        Process.send_after(self(), :tick, interval)

      _disabled ->
        :ok
    end
  end
end
