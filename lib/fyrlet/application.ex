defmodule Fyrlet.Application do
  use Application

  @impl true
  def start(_type, _arguments) do
    Fyrlet.Registry.validate!()

    children = [
      Fyrlet.Repo,
      {Phoenix.PubSub, name: Fyrlet.PubSub},
      Fyrlet.SubscriptionTracker,
      {Oban, Application.fetch_env!(:fyrlet, Oban)},
      FyrletWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Fyrlet.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    FyrletWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
