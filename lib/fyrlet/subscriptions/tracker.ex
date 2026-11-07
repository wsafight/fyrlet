defmodule Fyrlet.Subscriptions.Tracker do
  use GenServer

  def start_link(_options),
    do:
      GenServer.start_link(__MODULE__, %{counts: %{}, projects: %{}, monitors: %{}},
        name: __MODULE__
      )

  # `project_id` adds the project's cap (`Fyrlet.Quota.max_subscriptions/1`) to the
  # per-connection one; without it only the connection is limited.
  def claim(transport, channel, limit \\ nil, project_id \\ nil),
    do: GenServer.call(__MODULE__, {:claim, transport, channel, limit, project_id})

  def validate! do
    limit = Application.get_env(:fyrlet, :max_subscriptions_per_node, 10_000)

    unless is_integer(limit) and limit > 0,
      do: raise(ArgumentError, "max_subscriptions_per_node must be a positive integer")

    :ok
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:claim, transport, channel, limit, project_id}, _from, state) do
    count = Map.get(state.counts, transport, 0)
    project_count = Map.get(state.projects, project_id, 0)
    project_limit = project_id && Fyrlet.Quota.max_subscriptions(project_id)
    node_limit = Application.get_env(:fyrlet, :max_subscriptions_per_node, 10_000)

    cond do
      map_size(state.monitors) >= node_limit ->
        {:reply,
         {:error,
          Fyrlet.Error.new("LIMIT_EXCEEDED", "Too many subscriptions on this node", %{
            "scope" => "node",
            "limit" => node_limit
          })}, state}

      count >= (limit || Application.fetch_env!(:fyrlet, :max_subscriptions)) ->
        {:reply,
         {:error,
          Fyrlet.Error.new("LIMIT_EXCEEDED", "Too many subscriptions on this connection")}, state}

      project_limit && project_count >= project_limit ->
        {:reply,
         {:error,
          Fyrlet.Error.new("LIMIT_EXCEEDED", "Too many subscriptions for this project", %{
            "scope" => "project",
            "limit" => project_limit
          })}, state}

      true ->
        reference = Process.monitor(channel)

        state = %{
          counts: Map.put(state.counts, transport, count + 1),
          projects:
            if(project_id,
              do: Map.put(state.projects, project_id, project_count + 1),
              else: state.projects
            ),
          monitors: Map.put(state.monitors, reference, {transport, project_id})
        }

        report(state)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:DOWN, reference, :process, _process, _reason}, state) do
    case Map.pop(state.monitors, reference) do
      {nil, _monitors} ->
        {:noreply, state}

      {{transport, project_id}, monitors} ->
        state = %{
          counts: decrement(state.counts, transport),
          projects:
            if(project_id, do: decrement(state.projects, project_id), else: state.projects),
          monitors: monitors
        }

        report(state)
        {:noreply, state}
    end
  end

  defp decrement(counts, key) do
    case Map.fetch!(counts, key) do
      1 -> Map.delete(counts, key)
      count -> Map.put(counts, key, count - 1)
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
