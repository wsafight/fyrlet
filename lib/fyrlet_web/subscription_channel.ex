defmodule FyrletWeb.SubscriptionChannel do
  use Phoenix.Channel,
    log_join: false,
    log_handle_in: false,
    hibernate_after: Application.compile_env(:fyrlet, :channel_hibernate_after, 15_000)

  alias Fyrlet.{Auth, Capabilities, Error, Runtime}
  alias Fyrlet.Subscriptions.Observer
  alias Fyrlet.Subscriptions.Observation
  import FyrletWeb.ChannelSupport

  @impl true
  def join(
        "subscription:" <> identifier,
        %{"protocol_version" => 1, "name" => name, "params" => parameters} = options,
        socket
      ) do
    delivery = if options["delivery"] == "delta-v1", do: "delta-v1", else: "snapshot"

    with {:ok, _uuid} <- identifier(identifier),
         {:ok, capabilities} <- Capabilities.negotiate(options["capabilities"]),
         :ok <- anonymous_entry(socket.assigns.actor, capabilities),
         {:ok, subscription} <-
           Runtime.prepare_subscription(socket.assigns.actor, name, parameters),
         :ok <- require_capability(subscription, capabilities),
         :ok <- not_append(subscription),
         :ok <- claim(socket, socket.assigns.actor),
         {:ok, observer, revision, encoded, observation} <-
           attach(socket.assigns.actor, subscription, delivery) do
      socket =
        socket
        |> assign(
          subscription: subscription,
          subscription_id: identifier,
          capabilities: capabilities,
          delivery: delivery,
          generation: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
          observer: observer,
          observation: observation,
          observer_monitor: if(observer != self(), do: Process.monitor(observer)),
          revision: revision,
          seq: 1,
          awaiting: 1,
          confirmations: MapSet.new(),
          ack_timer: nil,
          expiry_timer: expiry_timer(socket.assigns.actor)
        )
        |> awaiting(1)

      {:ok, envelope(socket, encoded), socket}
    else
      {:error, error} -> reject(error)
    end
  end

  def join(_topic, _parameters, _socket), do: unsupported()

  defp require_capability(%{specification: %{"capability" => name}}, capabilities),
    do: Capabilities.require(capabilities, name)

  defp require_capability(_subscription, _capabilities), do: :ok

  # Append-mode subscriptions have their own channel (`append:<id>`) and protocol events.
  defp not_append(%{specification: %{"mode" => "append"}}),
    do:
      {:error,
       Error.new("VALIDATION_FAILED", "This is an append subscription; join append:<id> instead")}

  defp not_append(_subscription), do: :ok

  defp attach(actor, subscription, delivery) do
    if subscription.specification["shared"] == true or
         subscription.specification["sharing"] == "identical" do
      with {:ok, observer, revision, encoded} <- Observer.attach(actor, subscription, delivery),
           do: {:ok, observer, revision, encoded, nil}
    else
      Observation.attach_local(actor, subscription, delivery)
    end
  end

  defp observation_cast(%{assigns: %{observation: nil}} = socket, message) do
    GenServer.cast(socket.assigns.observer, message)
    socket
  end

  defp observation_cast(socket, message) do
    {:noreply, observation} = Observation.handle_cast(message, socket.assigns.observation)
    assign(socket, observation: observation)
  end

  @impl true
  def handle_in("ack", %{"g" => generation, "s" => sequence}, socket) do
    if is_integer(sequence) and sequence > 0 and generation == socket.assigns.generation and
         sequence == socket.assigns.awaiting do
      {:noreply,
       socket
       |> observation_cast({:ready, self(), socket.assigns.revision})
       |> assign(awaiting: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_in("refresh", %{"confirmation_id" => identifier}, socket) do
    with {:ok, identifier} <- confirmation(identifier, socket.assigns.capabilities),
         true <- MapSet.size(socket.assigns.confirmations) < 32 do
      socket =
        socket
        |> assign(confirmations: MapSet.put(socket.assigns.confirmations, identifier))
        |> observation_cast({:confirm, self(), identifier})

      {:reply, {:ok, %{"accepted" => true}}, socket}
    else
      {:error, error} ->
        {:reply, reject(error), socket}

      false ->
        {:reply, reject(Error.new("LIMIT_EXCEEDED", "Too many pending confirmations")), socket}
    end
  end

  def handle_in("refresh", _parameters, socket) do
    {:reply, {:ok, %{"accepted" => true}}, observation_cast(socket, {:refresh, self()})}
  end

  def handle_in(_event, _parameters, socket),
    do: {:reply, reject(Error.not_found()), socket}

  @impl true
  def handle_info(
        {:observer_update, observer, revision, event, encoded},
        %{assigns: %{observer: observer}} = socket
      ) do
    case Auth.validate_session(socket.assigns.actor, socket.assigns.actor.expires_at, nil) do
      {:ok, _actor} ->
        sequence = socket.assigns.seq + 1

        {event, payload} =
          case event do
            :delta ->
              :telemetry.execute(
                [:fyrlet, :subscription, :delta],
                %{bytes: byte_size(encoded)},
                %{name: socket.assigns.subscription.name}
              )

              {"delta",
               %{
                 "g" => socket.assigns.generation,
                 "b" => socket.assigns.seq,
                 "s" => sequence,
                 "p" => fragment(socket, encoded)
               }}

            :snapshot ->
              {"snapshot", envelope(assign(socket, seq: sequence), encoded)}

            {:snapshot, identifiers} ->
              {"snapshot",
               envelope(assign(socket, seq: sequence), encoded)
               |> Map.put("confirmed", identifiers)}
          end

        push(socket, event, payload)

        confirmations =
          MapSet.difference(socket.assigns.confirmations, MapSet.new(payload["confirmed"] || []))

        {:noreply,
         socket
         |> assign(seq: sequence, revision: revision, confirmations: confirmations)
         |> awaiting(sequence)}

      {:error, error} ->
        stop(socket, error)
    end
  end

  def handle_info({:observer_error, observer, error}, %{assigns: %{observer: observer}} = socket),
    do: stop(socket, error)

  def handle_info(
        {:DOWN, monitor, :process, observer, _reason},
        %{assigns: %{observer_monitor: monitor, observer: observer}} = socket
      ),
      do:
        stop(
          socket,
          Error.new("INTERNAL_ERROR", "The observer stopped; reconnect to recover", %{}, true)
        )

  def handle_info(:ack_timeout, socket) do
    socket = assign(socket, ack_timer: nil)

    cond do
      socket.assigns.awaiting == nil ->
        {:noreply, socket}

      socket.assigns.ack_deadline <= System.monotonic_time(:millisecond) ->
        stop(socket, Error.new("LIMIT_EXCEEDED", "The snapshot was not acknowledged in time"))

      true ->
        {:noreply, arm_ack_timer(socket, :ack_timeout, socket.assigns.ack_deadline)}
    end
  end

  def handle_info(:expired, socket), do: stop(socket, Error.unauthorized())

  def handle_info(message, socket) when message in [:invalidated, :reconcile, :refresh],
    do: observation_message(message, socket)

  def handle_info({:invalidated, _identifier} = message, socket) do
    observation_message(message, socket)
  end

  def handle_info({:invalidated, _identifier, _change} = message, socket) do
    observation_message(message, socket)
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp observation_message(message, %{assigns: %{observation: nil}} = socket) do
    Observer.invalidate(socket.assigns.observer, message)
    {:noreply, socket}
  end

  defp observation_message(message, socket) do
    case Observation.handle_info(message, socket.assigns.observation) do
      {:noreply, observation} ->
        {:noreply, assign(socket, observation: observation)}

      {:stop, %Error{} = error, observation} ->
        stop(assign(socket, observation: observation), error)

      {:stop, reason, observation} ->
        {:stop, reason, assign(socket, observation: observation)}
    end
  end

  @impl true
  def terminate(_reason, socket) do
    cancel_timers(socket, [:ack_timer, :expiry_timer])

    if socket.assigns[:observation],
      do: Observation.terminate(:normal, socket.assigns.observation)

    :ok
  end

  defp awaiting(socket, sequence) do
    socket =
      assign(socket,
        awaiting: sequence,
        ack_deadline:
          System.monotonic_time(:millisecond) +
            Application.fetch_env!(:fyrlet, :snapshot_ack_timeout)
      )

    if socket.assigns.ack_timer,
      do: socket,
      else: arm_ack_timer(socket, :ack_timeout, socket.assigns.ack_deadline)
  end

  defp envelope(socket, encoded),
    do: snapshot(socket, encoded, %{"delivery" => socket.assigns.delivery})
end
