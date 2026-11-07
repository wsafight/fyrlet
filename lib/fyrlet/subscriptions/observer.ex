defmodule Fyrlet.Subscriptions.Observer do
  use GenServer, restart: :temporary
  alias Fyrlet.Error
  alias Fyrlet.Subscriptions.Observation

  def start_link({key, actor, subscription}) do
    GenServer.start_link(__MODULE__, {actor, subscription},
      name: {:via, Registry, {Fyrlet.ObserverRegistry, key}},
      hibernate_after: Application.fetch_env!(:fyrlet, :observer_hibernate_after)
    )
  end

  def attach(actor, subscription, delivery), do: attach(actor, subscription, delivery, 1)

  defp attach(actor, subscription, delivery, retries) do
    key = observer_key(actor, subscription)

    with {:ok, observer} <- ensure_started(key, actor, subscription),
         {:ok, revision, encoded} <-
           GenServer.call(observer, {:attach, self(), delivery, actor}, 15_000) do
      {:ok, observer, revision, encoded}
    end
  catch
    :exit, _reason ->
      if retries > 0,
        do: attach(actor, subscription, delivery, retries - 1),
        else: {:error, Error.new("INTERNAL_ERROR", "The observer is unavailable", %{}, true)}
  end

  # Who may share one Observer. A private subscription never shares. `shared` shares only for
  # the same actor. `identical` shares across members, so the key must pin everything the
  # result depends on: project, query, scope, the projection and the authorization policy.
  defp observer_key(actor, %{specification: %{"sharing" => "identical"}} = subscription) do
    {:identical, subscription.module, actor.project_id, subscription.name,
     subscription.parameters, subscription.scope,
     Fyrlet.Definition.current_version(subscription.module, subscription.name),
     policy_version(subscription)}
  end

  defp observer_key(actor, %{specification: %{"shared" => true}} = subscription),
    do: {actor, subscription}

  defp observer_key(_actor, _subscription), do: {self(), make_ref()}

  defp policy_version(%{module: module, name: name}) do
    Code.ensure_loaded(module)

    if function_exported?(module, :policy_version, 1),
      do: to_string(module.policy_version(name)),
      else: "1"
  end

  def ready(observer, revision), do: GenServer.cast(observer, {:ready, self(), revision})
  def refresh(observer), do: GenServer.cast(observer, {:refresh, self()})
  def invalidate(observer, message), do: send(observer, message)

  defp ensure_started(key, actor, subscription) do
    case Registry.lookup(Fyrlet.ObserverRegistry, key) do
      [{observer, _value}] ->
        {:ok, observer}

      [] ->
        case DynamicSupervisor.start_child(
               Fyrlet.ObserverSupervisor,
               {__MODULE__, {key, actor, subscription}}
             ) do
          {:ok, observer} ->
            {:ok, observer}

          {:error, {:already_started, observer}} ->
            {:ok, observer}

          {:error, %Error{} = error} ->
            {:error, error}

          {:error, :max_children} ->
            {:error, Error.new("LIMIT_EXCEEDED", "The node has reached its observer limit")}

          {:error, _reason} ->
            {:error, Error.new("INTERNAL_ERROR", "The observer could not start", %{}, true)}
        end
    end
  end

  @impl true
  def init({actor, subscription}), do: Observation.init({actor, subscription, false})

  @impl true
  defdelegate handle_call(message, from, state), to: Observation

  @impl true
  defdelegate handle_cast(message, state), to: Observation

  @impl true
  defdelegate handle_info(message, state), to: Observation

  @impl true
  defdelegate terminate(reason, state), to: Observation
end
