defmodule FyrletWeb.SubscriptionChannel do
  use Phoenix.Channel, log_join: false, log_handle_in: false
  alias Fyrlet.{Error, Runtime, SubscriptionTracker}
  @recent_invalidation_limit 64

  @impl true
  def join(
        "subscription:" <> identifier,
        %{"protocol_version" => 1, "name" => name, "params" => parameters},
        socket
      ) do
    with {:ok, _uuid} <- Ecto.UUID.cast(identifier),
         {:ok, subscription} <-
           Runtime.prepare_subscription(socket.assigns.actor, name, parameters),
         :ok <- SubscriptionTracker.claim(socket.transport_pid, self()) do
      Phoenix.PubSub.subscribe(Fyrlet.PubSub, subscription.scope)

      case Runtime.snapshot_with_metadata(socket.assigns.actor, subscription) do
        {:ok, snapshot} ->
          remaining =
            max(
              DateTime.diff(socket.assigns.actor.expires_at, Fyrlet.Auth.now(), :millisecond),
              1
            )

          socket =
            assign(socket,
              subscription: subscription,
              subscription_id: identifier,
              generation: Ecto.UUID.generate(),
              seq: 1,
              pending: false,
              scheduled: false,
              recent_invalidations: [],
              force_refresh: false,
              snapshot_fingerprint: snapshot.fingerprint,
              awaiting: 1,
              ack_timer: ack_timer(1),
              reconcile_timer: reconcile_timer(),
              expiry_timer: Process.send_after(self(), :expired, remaining)
            )

          {:ok, envelope(socket, snapshot), socket}

        {:error, error} ->
          {:error, %{"error" => Error.to_map(error)}}
      end
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
  def handle_in("ack", %{"generation" => generation, "seq" => sequence}, socket) do
    if generation == socket.assigns.generation and sequence == socket.assigns.awaiting do
      Process.cancel_timer(socket.assigns.ack_timer)
      socket = assign(socket, awaiting: nil)
      {:reply, {:ok, %{}}, if(socket.assigns.pending, do: schedule(socket), else: socket)}
    else
      {:reply, {:ok, %{}}, socket}
    end
  end

  def handle_in("refresh", _parameters, socket),
    do: {:reply, {:ok, %{"accepted" => true}}, schedule(assign(socket, :force_refresh, true))}

  def handle_in(_event, _parameters, socket),
    do: {:reply, {:error, %{"error" => Error.to_map(Error.not_found())}}, socket}

  @impl true
  def handle_info({:invalidated, identifier}, socket) when is_integer(identifier) do
    if identifier in socket.assigns.recent_invalidations do
      {:noreply, socket}
    else
      recent = [
        identifier
        | Enum.take(socket.assigns.recent_invalidations, @recent_invalidation_limit - 1)
      ]

      bounded_schedule(assign(socket, :recent_invalidations, recent))
    end
  end

  def handle_info(:invalidated, socket), do: bounded_schedule(socket)

  def handle_info(:reconcile, socket) do
    bounded_schedule(assign(socket, :reconcile_timer, reconcile_timer()))
  end

  def handle_info(:refresh, socket) do
    socket = assign(socket, scheduled: false)

    if socket.assigns.awaiting do
      {:noreply, assign(socket, pending: true)}
    else
      case Runtime.snapshot_with_metadata(socket.assigns.actor, socket.assigns.subscription) do
        {:ok, snapshot}
        when snapshot.fingerprint == socket.assigns.snapshot_fingerprint and
               not socket.assigns.force_refresh ->
          {:noreply, assign(socket, pending: false)}

        {:ok, snapshot} ->
          sequence = socket.assigns.seq + 1

          socket =
            assign(socket,
              seq: sequence,
              pending: false,
              force_refresh: false,
              snapshot_fingerprint: snapshot.fingerprint,
              awaiting: sequence,
              ack_timer: ack_timer(sequence)
            )

          push(socket, "snapshot", envelope(socket, snapshot))
          {:noreply, socket}

        {:error, error} ->
          stop(socket, error)
      end
    end
  end

  def handle_info({:ack_timeout, sequence}, socket) do
    if sequence == socket.assigns.awaiting do
      stop(socket, Error.new("LIMIT_EXCEEDED", "The snapshot was not acknowledged in time"))
    else
      {:noreply, socket}
    end
  end

  def handle_info(:expired, socket), do: stop(socket, Error.unauthorized())
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    for key <- [:ack_timer, :reconcile_timer, :expiry_timer],
        reference = socket.assigns[key],
        is_reference(reference) do
      Process.cancel_timer(reference)
    end

    :ok
  end

  defp bounded_schedule(socket) do
    {:message_queue_len, length} = Process.info(self(), :message_queue_len)

    if length > Application.fetch_env!(:fyrlet, :max_channel_queue) do
      stop(socket, Error.new("LIMIT_EXCEEDED", "The subscription is overloaded; subscribe again"))
    else
      {:noreply, schedule(socket)}
    end
  end

  defp schedule(socket) do
    cond do
      socket.assigns.awaiting ->
        assign(socket, pending: true)

      socket.assigns.scheduled ->
        socket

      true ->
        send(self(), :refresh)
        assign(socket, scheduled: true)
    end
  end

  defp stop(socket, error) do
    push(socket, "status", %{"state" => "closed", "error" => Error.to_map(error)})
    {:stop, :normal, socket}
  end

  defp envelope(socket, snapshot) do
    :telemetry.execute(
      [:fyrlet, :subscription, :snapshot],
      %{bytes: snapshot.bytes},
      %{name: socket.assigns.subscription.name}
    )

    %{
      "protocol_version" => 1,
      "subscription_id" => socket.assigns.subscription_id,
      "generation" => socket.assigns.generation,
      "seq" => socket.assigns.seq,
      "project_id" => socket.assigns.actor.project_id,
      "subject_id" => socket.assigns.actor.subject_id,
      "data" => snapshot.data
    }
  end

  defp ack_timer(sequence),
    do:
      Process.send_after(
        self(),
        {:ack_timeout, sequence},
        Application.fetch_env!(:fyrlet, :snapshot_ack_timeout)
      )

  defp reconcile_timer,
    do:
      Process.send_after(
        self(),
        :reconcile,
        Application.fetch_env!(:fyrlet, :reconciliation_interval)
      )
end
