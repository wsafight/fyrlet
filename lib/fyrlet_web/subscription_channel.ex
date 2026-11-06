defmodule FyrletWeb.SubscriptionChannel do
  use Phoenix.Channel,
    log_join: false,
    log_handle_in: false,
    hibernate_after: Application.compile_env(:fyrlet, :channel_hibernate_after, 15_000)

  alias Fyrlet.{Auth, Error, Observer, Runtime, SubscriptionTracker}

  @impl true
  def join(
        "subscription:" <> identifier,
        %{"protocol_version" => 1, "name" => name, "params" => parameters} = options,
        socket
      ) do
    delivery = if options["delivery"] == "delta-v1", do: "delta-v1", else: "snapshot"

    with {:ok, _uuid} <- Ecto.UUID.cast(identifier),
         {:ok, subscription} <-
           Runtime.prepare_subscription(socket.assigns.actor, name, parameters),
         :ok <- SubscriptionTracker.claim(socket.transport_pid, self()),
         {:ok, observer, revision, encoded} <-
           Observer.attach(socket.assigns.actor, subscription, delivery) do
      remaining = max(DateTime.diff(socket.assigns.actor.expires_at, Auth.now(), :millisecond), 1)

      socket =
        socket
        |> assign(
          subscription: subscription,
          subscription_id: identifier,
          delivery: delivery,
          generation: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
          observer: observer,
          observer_monitor: Process.monitor(observer),
          revision: revision,
          seq: 1,
          awaiting: 1,
          ack_timer: nil,
          expiry_timer: Process.send_after(self(), :expired, remaining)
        )
        |> awaiting(1)

      {:ok, envelope(socket, encoded), socket}
    else
      :error ->
        {:error,
         %{
           "error" =>
             Error.to_map(Error.new("VALIDATION_FAILED", "Invalid subscription identifier"))
         }}

      {:error, error} ->
        {:error, %{"error" => Error.to_map(error)}}
    end
  end

  def join(_topic, _parameters, _socket) do
    {:error,
     %{
       "error" =>
         Error.to_map(
           Error.new("UNSUPPORTED_VERSION", "Expected protocol_version 1, name and params")
         )
     }}
  end

  @impl true
  def handle_in("ack", %{"g" => generation, "s" => sequence}, socket) do
    if is_integer(sequence) and sequence > 0 and generation == socket.assigns.generation and
         sequence == socket.assigns.awaiting do
      Observer.ready(socket.assigns.observer, socket.assigns.revision)
      {:noreply, assign(socket, awaiting: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_in("refresh", _parameters, socket) do
    Observer.refresh(socket.assigns.observer)
    {:reply, {:ok, %{"accepted" => true}}, socket}
  end

  def handle_in(_event, _parameters, socket),
    do: {:reply, {:error, %{"error" => Error.to_map(Error.not_found())}}, socket}

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
          end

        push(socket, event, payload)
        {:noreply, socket |> assign(seq: sequence, revision: revision) |> awaiting(sequence)}

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
        {:noreply, arm_ack_timer(socket)}
    end
  end

  def handle_info(:expired, socket), do: stop(socket, Error.unauthorized())

  def handle_info(message, socket) when message in [:invalidated, :reconcile] do
    Observer.invalidate(socket.assigns.observer, message)
    {:noreply, socket}
  end

  def handle_info({:invalidated, _identifier} = message, socket) do
    Observer.invalidate(socket.assigns.observer, message)
    {:noreply, socket}
  end

  def handle_info({:invalidated, _identifier, _change} = message, socket) do
    Observer.invalidate(socket.assigns.observer, message)
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    for key <- [:ack_timer, :expiry_timer],
        reference = socket.assigns[key],
        is_reference(reference),
        do: Process.cancel_timer(reference)

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

    if socket.assigns.ack_timer, do: socket, else: arm_ack_timer(socket)
  end

  defp arm_ack_timer(socket) do
    remaining = max(socket.assigns.ack_deadline - System.monotonic_time(:millisecond), 1)
    assign(socket, ack_timer: Process.send_after(self(), :ack_timeout, remaining))
  end

  defp stop(socket, error) do
    push(socket, "status", %{"state" => "closed", "error" => Error.to_map(error)})
    {:stop, :normal, socket}
  end

  defp envelope(socket, encoded) do
    :telemetry.execute([:fyrlet, :subscription, :snapshot], %{bytes: byte_size(encoded)}, %{
      name: socket.assigns.subscription.name
    })

    %{
      "protocol_version" => 1,
      "subscription_id" => socket.assigns.subscription_id,
      "generation" => socket.assigns.generation,
      "seq" => socket.assigns.seq,
      "project_id" => socket.assigns.actor.project_id,
      "subject_id" => socket.assigns.actor.subject_id,
      "delivery" => socket.assigns.delivery,
      "data" => fragment(socket, encoded)
    }
  end

  defp fragment(socket, encoded) do
    if socket.serializer == Phoenix.Socket.V2.JSONSerializer and Phoenix.json_library() == Jason,
      do: Jason.Fragment.new(encoded),
      else: Jason.decode!(encoded)
  end
end
