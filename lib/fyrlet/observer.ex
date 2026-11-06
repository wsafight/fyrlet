defmodule Fyrlet.Observer do
  use GenServer, restart: :temporary
  alias Fyrlet.{Auth, Error, Runtime, View}
  @recent_limit 64

  def start_link({key, actor, subscription}) do
    GenServer.start_link(__MODULE__, {actor, subscription},
      name: {:via, Registry, {Fyrlet.ObserverRegistry, key}},
      hibernate_after: Application.fetch_env!(:fyrlet, :observer_hibernate_after)
    )
  end

  def attach(actor, subscription, delivery), do: attach(actor, subscription, delivery, 1)

  defp attach(actor, subscription, delivery, retries) do
    key =
      if subscription.specification["shared"] == true,
        do: {actor, subscription},
        else: {self(), make_ref()}

    with {:ok, observer} <- ensure_started(key, actor, subscription),
         {:ok, revision, encoded} <- GenServer.call(observer, {:attach, self(), delivery}, 15_000) do
      {:ok, observer, revision, encoded}
    end
  catch
    :exit, _reason ->
      if retries > 0,
        do: attach(actor, subscription, delivery, retries - 1),
        else: {:error, Error.new("INTERNAL_ERROR", "The observer is unavailable", %{}, true)}
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
  def init({actor, subscription}) do
    Phoenix.PubSub.subscribe(Fyrlet.PubSub, subscription.scope)
    Process.send_after(self(), :idle, 5_000)

    {:ok,
     %{
       actor: actor,
       subscription: subscription,
       view: nil,
       revision: 1,
       encoded: nil,
       clients: %{},
       recent: [],
       scheduled: false,
       change: nil,
       reconcile_timer: reconcile_timer()
     }}
  end

  @impl true
  def handle_call({:attach, channel, delivery}, _from, state) do
    with {:ok, state} <- load_initial(state),
         {:ok, actor} <- Auth.revalidate(state.actor),
         :ok <-
           state.subscription.module.authorize(
             state.subscription.name,
             actor,
             state.subscription.parameters
           ),
         {:ok, _actor} <- Auth.revalidate(actor),
         :ok <- snapshot_size(state.view.bytes) do
      client = %{
        monitor: Process.monitor(channel),
        revision: state.revision,
        ready: false,
        force: false,
        delivery: delivery
      }

      state = encode_snapshot(%{state | clients: Map.put(state.clients, channel, client)})
      {:reply, {:ok, state.revision, state.encoded}, state}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  defp load_initial(%{view: nil} = state) do
    with {:ok, view} <- Runtime.view(state.actor, state.subscription),
         do: {:ok, %{state | view: view}}
  end

  defp load_initial(state), do: {:ok, state}

  @impl true
  def handle_cast({:ready, channel, revision}, state) do
    case Map.get(state.clients, channel) do
      %{revision: ^revision} = client ->
        state = %{state | clients: Map.put(state.clients, channel, %{client | ready: true})}

        state =
          if client.force or revision != state.revision, do: schedule(state, nil), else: state

        {:noreply, state}

      _missing ->
        {:noreply, state}
    end
  end

  def handle_cast({:refresh, channel}, state) do
    case Map.get(state.clients, channel) do
      nil ->
        {:noreply, state}

      client ->
        state = %{state | clients: Map.put(state.clients, channel, %{client | force: true})}
        {:noreply, schedule(state, nil)}
    end
  end

  @impl true
  def handle_info({:invalidated, identifier, change}, state) when is_integer(identifier),
    do: invalidated(identifier, change, state)

  def handle_info({:invalidated, identifier}, state) when is_integer(identifier),
    do: invalidated(identifier, nil, state)

  def handle_info(:invalidated, state), do: {:noreply, schedule(state, nil)}

  def handle_info(:reconcile, state) do
    Process.cancel_timer(state.reconcile_timer)
    {:noreply, schedule(%{state | reconcile_timer: reconcile_timer()}, nil)}
  end

  def handle_info(:refresh, state) do
    {:message_queue_len, queued} = Process.info(self(), :message_queue_len)

    result =
      if queued > Application.fetch_env!(:fyrlet, :max_channel_queue),
        do: {:error, Error.new("LIMIT_EXCEEDED", "The observer is overloaded; subscribe again")},
        else: Runtime.view(state.actor, state.subscription, state.view, state.change)

    case result do
      {:ok, view} ->
        previous_revision = state.revision
        changed = not view.unchanged

        state = %{
          state
          | view: view,
            revision: state.revision + if(changed, do: 1, else: 0),
            encoded: if(changed, do: nil, else: state.encoded),
            scheduled: false,
            change: nil
        }

        {:noreply, deliver(state, previous_revision, changed)}

      {:error, error} ->
        for {channel, _client} <- state.clients,
            do: send(channel, {:observer_error, self(), error})

        {:stop, :normal, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, channel, _reason}, state) do
    case Map.get(state.clients, channel) do
      %{monitor: ^monitor} ->
        state = %{state | clients: Map.delete(state.clients, channel)}
        if map_size(state.clients) == 0, do: {:stop, :normal, state}, else: {:noreply, state}

      _missing ->
        {:noreply, state}
    end
  end

  def handle_info(:idle, %{clients: clients} = state) when map_size(clients) == 0,
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Process.cancel_timer(state.reconcile_timer)
    :ok
  end

  defp invalidated(identifier, change, state) do
    if identifier in state.recent do
      {:noreply, state}
    else
      recent = [identifier | Enum.take(state.recent, @recent_limit - 1)]
      {:noreply, schedule(%{state | recent: recent}, change)}
    end
  end

  defp schedule(%{scheduled: true} = state, _change), do: %{state | change: nil}

  defp schedule(state, change) do
    send(self(), :refresh)
    %{state | scheduled: true, change: change}
  end

  defp deliver(state, previous_revision, changed) do
    patch = if changed and state.view.patch != nil, do: Jason.encode!(state.view.patch)
    patch = if patch && byte_size(patch) + 96 < state.view.bytes, do: patch

    Enum.reduce(state.clients, state, fn {channel, client}, current ->
      if client.ready and (client.force or client.revision != current.revision) do
        delta =
          not is_nil(patch) and not client.force and client.delivery == "delta-v1" and
            client.revision == previous_revision

        current = if delta, do: current, else: encode_snapshot(current)
        {event, body} = if delta, do: {:delta, patch}, else: {:snapshot, current.encoded}
        send(channel, {:observer_update, self(), current.revision, event, body})
        client = %{client | ready: false, force: false, revision: current.revision}
        %{current | clients: Map.put(current.clients, channel, client)}
      else
        current
      end
    end)
  end

  defp encode_snapshot(%{encoded: nil} = state),
    do: %{state | encoded: Jason.encode!(View.data(state.view))}

  defp encode_snapshot(state), do: state

  defp snapshot_size(bytes) do
    if bytes <= Application.fetch_env!(:fyrlet, :max_snapshot_bytes),
      do: :ok,
      else: {:error, Error.new("LIMIT_EXCEEDED", "The snapshot exceeds the response size limit")}
  end

  defp reconcile_timer,
    do:
      Process.send_after(
        self(),
        :reconcile,
        Application.fetch_env!(:fyrlet, :reconciliation_interval)
      )
end
