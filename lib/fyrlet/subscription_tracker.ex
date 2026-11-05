defmodule Fyrlet.SubscriptionTracker do
  use GenServer

  def start_link(_options),
    do: GenServer.start_link(__MODULE__, %{counts: %{}, monitors: %{}}, name: __MODULE__)

  def claim(transport, channel), do: GenServer.call(__MODULE__, {:claim, transport, channel})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:claim, transport, channel}, _from, state) do
    count = Map.get(state.counts, transport, 0)

    if count < Application.fetch_env!(:fyrlet, :max_subscriptions) do
      reference = Process.monitor(channel)

      state = %{
        counts: Map.put(state.counts, transport, count + 1),
        monitors: Map.put(state.monitors, reference, transport)
      }

      report(state)
      {:reply, :ok, state}
    else
      {:reply,
       {:error, Fyrlet.Error.new("LIMIT_EXCEEDED", "Too many subscriptions on this connection")},
       state}
    end
  end

  @impl true
  def handle_info({:DOWN, reference, :process, _process, _reason}, state) do
    case Map.pop(state.monitors, reference) do
      {nil, _monitors} ->
        {:noreply, state}

      {transport, monitors} ->
        count = Map.fetch!(state.counts, transport)

        counts =
          if count == 1,
            do: Map.delete(state.counts, transport),
            else: Map.put(state.counts, transport, count - 1)

        state = %{counts: counts, monitors: monitors}
        report(state)
        {:noreply, state}
    end
  end

  defp report(state),
    do:
      :telemetry.execute(
        [:fyrlet, :subscription, :count],
        %{active: map_size(state.monitors)},
        %{}
      )
end
