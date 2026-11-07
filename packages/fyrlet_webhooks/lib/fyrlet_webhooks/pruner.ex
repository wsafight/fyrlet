defmodule FyrletWebhooks.Pruner do
  @moduledoc "Forgets event IDs older than `retention_seconds`, once an hour."
  use GenServer
  require Logger

  @interval :timer.hours(1)

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(_options) do
    Process.send_after(self(), :prune, @interval)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:prune, state) do
    try do
      prune()
    rescue
      exception -> Logger.error("Webhook pruning failed: #{inspect(exception.__struct__)}")
    end

    Process.send_after(self(), :prune, @interval)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc "Removes event IDs received more than `retention_seconds` ago. Returns the count."
  def prune do
    cutoff = DateTime.add(Fyrlet.Auth.now(), -retention(), :second)
    {count, _} = FyrletWebhooks.Receiver.prune(cutoff)
    count
  end

  defp retention, do: Application.get_env(:fyrlet_webhooks, :retention_seconds, 604_800)
end
