defmodule Fyrlet.Subscriptions.Observation do
  @moduledoc false
  alias Fyrlet.{Auth, Error, Runtime}
  alias Fyrlet.Subscriptions.View
  @recent_limit 64

  def attach_local(actor, subscription, delivery) do
    {:ok, state} = init({actor, subscription, true})

    case handle_call({:attach, self(), delivery, actor}, nil, state) do
      {:reply, {:ok, revision, encoded}, state} ->
        {:ok, self(), revision, encoded, state}

      {:reply, {:error, error}, state} ->
        terminate(:normal, state)
        Phoenix.PubSub.unsubscribe(Fyrlet.PubSub, subscription.scope)
        {:error, error}
    end
  end

  def init({actor, subscription, local}) do
    Phoenix.PubSub.subscribe(Fyrlet.PubSub, subscription.scope)
    unless local, do: Process.send_after(self(), :idle, 5_000)

    identical? = subscription.specification["sharing"] == "identical"

    {:ok,
     %{
       # An identical observer holds no actor: its data cannot depend on one.
       actor: if(identical?, do: nil, else: actor),
       local: local,
       mode: if(identical?, do: :identical, else: :private),
       shared_context: %{project_id: actor.project_id, scope: subscription.scope},
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

  def handle_call({:attach, channel, delivery, attaching}, _from, state) do
    actor = if state.mode == :identical, do: attaching, else: state.actor

    # A warm cache grants nothing: every member is checked before it sees anything. The order
    # is: session, authorization and membership first (so the application's query never runs
    # for someone who may not read), then the data, then the session once more - nothing is
    # sent on the strength of a check made before the data was read.
    with {:ok, actor} <- Auth.revalidate(actor),
         :ok <-
           state.subscription.module.authorize(
             state.subscription.name,
             actor,
             state.subscription.parameters
           ),
         :ok <- member?(state, actor),
         {:ok, state} <- load_initial(state, actor),
         {:ok, _actor} <- Auth.revalidate(actor),
         :ok <-
           Fyrlet.Subscriptions.Limits.check_snapshot(
             state.view.bytes,
             state.subscription.specification
           ) do
      client = %{
        monitor: if(channel != self(), do: Process.monitor(channel)),
        revision: state.revision,
        ready: false,
        force: false,
        confirmations: [],
        delivery: delivery,
        actor: if(state.mode == :identical, do: actor)
      }

      state = encode_snapshot(%{state | clients: Map.put(state.clients, channel, client)})
      {:reply, {:ok, state.revision, state.encoded}, release_encoded(state)}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  # The caller has just checked the session and authorization for `actor` and checks the
  # session again afterwards, so the load does not repeat either.
  defp load_initial(%{view: nil, mode: :identical} = state, _actor) do
    with {:ok, view} <- load_view(state, nil, nil), do: {:ok, %{state | view: view}}
  end

  defp load_initial(%{view: nil} = state, actor) do
    with {:ok, view} <- Runtime.load_view(actor, state.subscription),
         do: {:ok, %{state | view: view}}
  end

  defp load_initial(state, _actor), do: {:ok, state}

  defp load_view(%{mode: :identical} = state, previous, _change),
    do: Runtime.shared_view(state.subscription, state.shared_context, previous)

  defp load_view(state, previous, change),
    do: Runtime.view(state.actor, state.subscription, previous, change)

  defp member?(%{mode: :private}, _actor), do: :ok

  defp member?(%{subscription: subscription}, actor) do
    case subscription.module.membership(subscription.name, actor, subscription.parameters) do
      :member -> :ok
      _not_a_member -> {:error, Error.forbidden()}
    end
  end

  # Before data goes to a member of an identical observer: session, authorization, membership.
  # `session` is the member's session check when the caller already made it together with the
  # other members' (see `sessions/2`); nil means the check is made here.
  defp permitted(%{mode: :private}, _client, _session), do: :ok

  defp permitted(state, %{actor: actor}, session) do
    subscription = state.subscription

    with {:ok, actor} <- session || Auth.revalidate(actor),
         :ok <- subscription.module.authorize(subscription.name, actor, subscription.parameters),
         :ok <- member?(state, actor) do
      :ok
    end
  end

  # One batched session check for the members about to be checked, so that a room of N members
  # costs a handful of queries instead of N sequential ones. Private observers hold one member
  # whose session the surrounding code already checked.
  defp sessions(%{mode: :private}, _members), do: %{}

  defp sessions(_state, members) do
    channels = Enum.map(members, &elem(&1, 0))
    results = Auth.revalidate_many(Enum.map(members, fn {_channel, client} -> client.actor end))
    channels |> Enum.zip(results) |> Map.new()
  end

  # Ends the subscription of every member that no longer passes. Returns the surviving state.
  defp recheck_clients(%{mode: :private} = state), do: state

  defp recheck_clients(state) do
    members = Map.to_list(state.clients)
    checked = sessions(state, members)

    Enum.reduce(members, state, fn {channel, client}, current ->
      case permitted(current, client, checked[channel]) do
        :ok -> current
        {:error, error} -> drop_client(current, channel, client, error)
      end
    end)
  end

  defp drop_client(state, channel, client, error) do
    send(channel, {:observer_error, self(), error})
    Process.demonitor(client.monitor, [:flush])
    state = %{state | clients: Map.delete(state.clients, channel)}
    if map_size(state.clients) == 0, do: send(self(), :idle)
    state
  end

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

  def handle_cast({:confirm, channel, identifier}, state) do
    case Map.get(state.clients, channel) do
      nil ->
        {:noreply, state}

      client ->
        client = %{
          client
          | force: true,
            confirmations: Enum.uniq(client.confirmations ++ [identifier])
        }

        {:noreply, schedule(%{state | clients: Map.put(state.clients, channel, client)}, nil)}
    end
  end

  def handle_info({:invalidated, identifier, change}, state) when is_integer(identifier),
    do: invalidated(identifier, change, state)

  def handle_info({:invalidated, identifier}, state) when is_integer(identifier),
    do: invalidated(identifier, nil, state)

  def handle_info(:invalidated, state), do: {:noreply, schedule(state, nil)}

  def handle_info(:reconcile, state) do
    Process.cancel_timer(state.reconcile_timer)
    state = recheck_clients(state)
    {:noreply, schedule(%{state | reconcile_timer: reconcile_timer()}, nil)}
  end

  # Membership or policy changed: look at every member now rather than at the next tick.
  def handle_info(:membership_changed, state), do: {:noreply, recheck_clients(state)}

  def handle_info(:refresh, state) do
    {:message_queue_len, queued} = Process.info(self(), :message_queue_len)
    confirming = Enum.any?(state.clients, fn {_channel, client} -> client.confirmations != [] end)

    result =
      if queued > Application.fetch_env!(:fyrlet, :max_channel_queue),
        do: {:error, Error.new("LIMIT_EXCEEDED", "The observer is overloaded; subscribe again")},
        else: load_view(state, if(confirming, do: nil, else: state.view), state.change)

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

        {:noreply, state |> deliver(previous_revision, changed) |> release_encoded()}

      {:error, error} ->
        if state.local do
          {:stop, error, state}
        else
          for {channel, _client} <- state.clients,
              do: send(channel, {:observer_error, self(), error})

          {:stop, :normal, state}
        end
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
    # The diff is only worth its CPU when at least one member can consume a delta.
    patch =
      if changed and
           Enum.any?(state.clients, fn {_channel, client} ->
             client.delivery == "delta-v1"
           end) do
        case View.patch(state.view) do
          nil ->
            nil

          patch ->
            encoded = Jason.encode!(patch)
            if byte_size(encoded) + 96 < state.view.bytes, do: encoded
        end
      end

    :telemetry.execute([:fyrlet, :scope, :shared], %{members: map_size(state.clients)}, %{
      name: state.subscription.name,
      mode: state.mode
    })

    checked = sessions(state, state.clients)

    Enum.reduce(state.clients, state, fn {channel, client}, current ->
      deliver_checked(current, channel, client, patch, previous_revision, checked[channel])
    end)
  end

  defp deliver_checked(current, channel, client, patch, previous_revision, session) do
    case permitted(current, client, session) do
      {:error, error} ->
        drop_client(current, channel, client, error)

      :ok when not client.ready or (not client.force and client.revision == current.revision) ->
        current

      :ok ->
        delta =
          not is_nil(patch) and not client.force and client.delivery == "delta-v1" and
            client.revision == previous_revision

        current = if delta, do: current, else: encode_snapshot(current)
        {event, body} = if delta, do: {:delta, patch}, else: {:snapshot, current.encoded}
        event = if client.confirmations == [], do: event, else: {:snapshot, client.confirmations}
        send(channel, {:observer_update, self(), current.revision, event, body})

        client = %{
          client
          | ready: false,
            force: false,
            confirmations: [],
            revision: current.revision
        }

        %{current | clients: Map.put(current.clients, channel, client)}
    end
  end

  defp encode_snapshot(%{encoded: nil} = state) do
    started = System.monotonic_time()
    encoded = View.encode(state.view)

    :telemetry.execute(
      [:fyrlet, :subscription, :serialize],
      %{duration: System.monotonic_time() - started, bytes: byte_size(encoded)},
      %{name: state.subscription.name, mode: state.mode}
    )

    %{state | encoded: encoded}
  end

  defp encode_snapshot(state), do: state

  defp release_encoded(%{local: true} = state), do: %{state | encoded: nil}
  defp release_encoded(state), do: state

  defp reconcile_timer,
    do:
      Process.send_after(
        self(),
        :reconcile,
        Application.fetch_env!(:fyrlet, :reconciliation_interval)
      )
end
