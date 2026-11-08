defmodule Fyrlet.Application do
  use Application

  @impl true
  def start(_type, _arguments) do
    Fyrlet.Plugins.validate!()
    Fyrlet.Registry.validate!()
    Fyrlet.Quota.validate!()
    Fyrlet.Retention.validate!()
    Fyrlet.Pruning.validate!()
    Fyrlet.Vault.validate!()
    Fyrlet.Metrics.validate!()
    Fyrlet.Subscriptions.Tracker.validate!()

    children =
      cluster() ++
        [
          Fyrlet.Repo,
          Fyrlet.Subscriptions.SessionChecks,
          {Phoenix.PubSub, name: Fyrlet.PubSub},
          {Registry, keys: :unique, name: Fyrlet.ObserverRegistry},
          {DynamicSupervisor,
           strategy: :one_for_one,
           name: Fyrlet.ObserverSupervisor,
           max_children: Application.fetch_env!(:fyrlet, :max_observers)},
          Fyrlet.Subscriptions.Tracker,
          Fyrlet.Quota
        ] ++
        Fyrlet.Metrics.child_specs() ++
        Fyrlet.InvalidationNotifications.child_specs() ++
        presence() ++
        [
          {Oban, oban_config()}
        ] ++
        stream_readers() ++ recovery() ++ Fyrlet.Plugins.children() ++ [FyrletWeb.Endpoint]

    Supervisor.start_link(children, strategy: :one_for_one, name: Fyrlet.Supervisor)
  end

  defp presence, do: if(Fyrlet.Capabilities.enabled?("presence"), do: [Fyrlet.Presence], else: [])

  defp cluster do
    case Application.get_env(:fyrlet, :cluster_nodes, []) do
      [] -> []
      peers -> [{Fyrlet.Cluster, peers}]
    end
  end

  # Plugins add queues for their own workers; they cannot change the core ones.
  defp oban_config do
    config = Application.fetch_env!(:fyrlet, Oban)

    case config[:queues] do
      queues when is_list(queues) ->
        Keyword.put(config, :queues, Keyword.merge(Fyrlet.Plugins.queues(), queues))

      _disabled ->
        config
    end
  end

  # Shared reads for append subscriptions; only there when the capability is on.
  defp stream_readers do
    if Fyrlet.Capabilities.enabled?("append"),
      do: [Fyrlet.Features.Stream.Reader.Supervisor],
      else: []
  end

  defp recovery do
    if Fyrlet.Capabilities.enabled?("runs") and Application.get_env(:fyrlet, :run_recovery, true),
      do: [Fyrlet.Runs.Recovery],
      else: []
  end

  @impl true
  def config_change(changed, _new, removed) do
    FyrletWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
