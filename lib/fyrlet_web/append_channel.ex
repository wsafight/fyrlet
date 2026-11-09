defmodule FyrletWeb.AppendChannel do
  @moduledoc """
  Delivers `mode: "append"` subscriptions: an initial snapshot of the newest
  `max_items` items, then batches of new items, each tied to the cursor it continues from.

  Events (all need the `append` capability):

    * join reply and `snapshot` - `{protocol_version, subscription_id, generation, seq, cursor,
      max_items, data, ...}`. A `snapshot` after the join, with the same generation and a higher
      `seq`, replaces the whole view and the cursor;
    * `append` - `{g, s, base_cursor, cursor, items}`: apply `items` only if `base_cursor` is
      the cursor you hold; then your cursor is `cursor`;
    * client `ack` - `{g, s, c}`: everything up to `s` was applied and `c` is the cursor at `s`.
      Cumulative; the server checks that all three agree. `refresh` asks for a new snapshot.

  A subscriber may be ahead of its acknowledgements by `window_batches` batches or
  `window_bytes` bytes; past that, or when its cursor can no longer be continued (stream
  rewritten, history trimmed), it is sent a new snapshot instead of an unbounded backlog. A
  subscriber that stops acknowledging is closed after `snapshot_ack_timeout`.

  Every member sees the same items; per-member filtering is not offered. Authorization and the
  session are checked before each send.
  """
  use Phoenix.Channel,
    log_join: false,
    log_handle_in: false,
    hibernate_after: Application.compile_env(:fyrlet, :channel_hibernate_after, 15_000)

  alias Fyrlet.{Auth, Capabilities, Error, Runtime}
  alias Fyrlet.Features.Stream
  import FyrletWeb.ChannelSupport

  @max_syncs_per_turn 10

  @impl true
  def join(
        "append:" <> identifier,
        %{"protocol_version" => 1, "name" => name, "params" => parameters} = options,
        socket
      ) do
    actor = socket.assigns.actor

    with {:ok, _uuid} <- identifier(identifier),
         {:ok, capabilities} <- Capabilities.negotiate(options["capabilities"]),
         :ok <- Capabilities.require(capabilities, "append"),
         :ok <- anonymous_entry(actor, capabilities),
         {:ok, subscription} <- Runtime.prepare_subscription(actor, name, parameters),
         :ok <- append_mode(subscription),
         {:ok, stream} <- resolve_stream(actor, subscription),
         :ok <- claim(socket, actor),
         # Listen first, then read: a change committed in between is picked up by the next sync.
         :ok <- Phoenix.PubSub.subscribe(Fyrlet.PubSub, subscription.scope),
         {:ok, window} <- read_window(actor, stream, subscription),
         # Nothing is sent on the strength of a check made before the data was read.
         {:ok, _actor} <- Auth.revalidate(actor) do
      socket =
        assign(socket,
          subscription: subscription,
          subscription_id: identifier,
          capabilities: capabilities,
          stream: stream,
          generation: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
          seq: 1,
          cursor: window.cursor,
          sent: [],
          sent_bytes: 0,
          snapshot_seq: 1,
          dirty: false,
          sync_queued: false,
          ack_timer: nil,
          expiry_timer: expiry_timer(actor),
          reconcile_timer: reconcile_timer()
        )
        |> track(1, window.cursor, window.bytes, :snapshot)

      {:ok, snapshot_envelope(socket, window), socket}
    else
      {:error, error} -> reject(error)
    end
  end

  def join(_topic, _parameters, _socket), do: unsupported()

  defp append_mode(%{specification: %{"mode" => "append"}}), do: :ok

  defp append_mode(_subscription),
    do:
      {:error, Error.new("VALIDATION_FAILED", "This subscription is not an append subscription")}

  defp resolve_stream(actor, subscription) do
    # `prepare_subscription` has just checked the session and authorized this actor.
    with {:ok, stream} <-
           subscription.module.stream(subscription.name, actor, subscription.parameters),
         true <- Stream.valid_name?(stream) do
      {:ok, stream}
    else
      {:error, %Error{} = error} -> {:error, error}
      _invalid -> {:error, Error.new("INTERNAL_ERROR", "The stream could not be resolved")}
    end
  end

  # ---- client events ---------------------------------------------------------------------

  @impl true
  def handle_in("ack", %{"g" => generation, "s" => sequence, "c" => cursor}, socket)
      when is_integer(sequence) and is_binary(cursor) do
    if generation == socket.assigns.generation and acknowledged?(socket, sequence, cursor) do
      {sent, sent_bytes} =
        Enum.reduce(socket.assigns.sent, {[], socket.assigns.sent_bytes}, fn entry,
                                                                             {kept, bytes} ->
          if entry.seq <= sequence,
            do: {kept, bytes - entry.bytes},
            else: {[entry | kept], bytes}
        end)

      snapshot_seq = socket.assigns.snapshot_seq

      socket =
        assign(socket,
          sent: Enum.reverse(sent),
          sent_bytes: sent_bytes,
          snapshot_seq: if(snapshot_seq && snapshot_seq <= sequence, do: nil, else: snapshot_seq)
        )

      if socket.assigns.dirty and is_nil(socket.assigns.snapshot_seq),
        do: sync(socket),
        else: {:noreply, socket}
    else
      # An ack that does not match what was sent changes nothing; the timeout deals with a
      # client that never sends a valid one.
      {:noreply, socket}
    end
  end

  def handle_in("refresh", %{"confirmation_id" => identifier}, socket) do
    with {:ok, identifier} <- confirmation(identifier, socket.assigns.capabilities) do
      case reset(socket, "confirmation", identifier) do
        {:stop, _reason, _socket} = stopped -> stopped
        socket -> {:reply, {:ok, %{"accepted" => true}}, socket}
      end
    else
      {:error, error} -> {:reply, reject(error), socket}
    end
  end

  def handle_in("refresh", _parameters, socket) do
    # A snapshot is already on its way; one more would only repeat it.
    case if(socket.assigns.snapshot_seq, do: socket, else: reset(socket, "refresh")) do
      {:stop, _reason, _socket} = stopped -> stopped
      socket -> {:reply, {:ok, %{"accepted" => true}}, socket}
    end
  end

  def handle_in(_event, _parameters, socket),
    do: {:reply, reject(Error.not_found()), socket}

  defp acknowledged?(socket, sequence, cursor),
    do: Enum.any?(socket.assigns.sent, &(&1.seq == sequence and &1.cursor == cursor))

  # ---- server events ---------------------------------------------------------------------

  @impl true
  def handle_info(message, socket)
      when message == :invalidated or
             (is_tuple(message) and elem(message, 0) == :invalidated) do
    {:noreply, queue_sync(socket)}
  end

  def handle_info(:sync, socket), do: sync(assign(socket, sync_queued: false))

  def handle_info(:reconcile, socket) do
    socket = assign(socket, reconcile_timer: reconcile_timer())
    sync(socket)
  end

  def handle_info(:ack_check, socket) do
    socket = assign(socket, ack_timer: nil)

    case socket.assigns.sent do
      [] ->
        {:noreply, socket}

      sent ->
        deadline = Enum.min_by(sent, & &1.at).at + ack_timeout()

        if deadline <= System.monotonic_time(:millisecond),
          do: stop(socket, Error.new("LIMIT_EXCEEDED", "Updates were not acknowledged in time")),
          else: {:noreply, arm_ack_timer(socket, :ack_check, deadline)}
    end
  end

  def handle_info(:expired, socket), do: stop(socket, Error.unauthorized())
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket),
    do: cancel_timers(socket, [:ack_timer, :expiry_timer, :reconcile_timer])

  # Coalesces bursts of invalidations into one read.
  defp queue_sync(%{assigns: %{sync_queued: true}} = socket), do: socket

  defp queue_sync(socket) do
    send(self(), :sync)
    assign(socket, sync_queued: true)
  end

  # ---- syncing ---------------------------------------------------------------------------

  defp sync(socket, rounds \\ @max_syncs_per_turn)

  # Nothing is sent on top of an unacknowledged snapshot: the client has no base to apply to.
  defp sync(%{assigns: %{snapshot_seq: sequence}} = socket, _rounds) when not is_nil(sequence),
    do: {:noreply, assign(socket, dirty: true)}

  defp sync(socket, rounds) do
    case permitted(socket) do
      :ok -> next_batch(socket, rounds)
      {:error, error} -> stop(socket, error)
    end
  end

  defp next_batch(socket, rounds) do
    a = socket.assigns

    case Stream.after_cursor_shared(a.actor.project_id, a.stream, a.cursor) do
      :none ->
        {:noreply, assign(socket, dirty: false)}

      :reset ->
        socket |> reset("gap") |> continue()

      {:ok, base, cursor, %{json: encoded, count: count}, more?} when base == a.cursor ->
        bytes = byte_size(encoded)

        if overflow?(a, bytes) do
          socket |> reset("overflow") |> continue()
        else
          sequence = a.seq + 1

          push(socket, "append", %{
            "g" => a.generation,
            "s" => sequence,
            "base_cursor" => base,
            "cursor" => cursor,
            "items" => fragment(socket, encoded)
          })

          :telemetry.execute(
            [:fyrlet, :subscription, :append],
            %{bytes: bytes, items: count},
            %{
              name: a.subscription.name
            }
          )

          socket =
            socket
            |> assign(seq: sequence, cursor: cursor)
            |> track(sequence, cursor, bytes, :append)

          cond do
            # Reached the head that was read: nothing else to look for. The next append
            # announces itself with its own notification.
            not more? ->
              {:noreply, assign(socket, dirty: false)}

            rounds > 1 ->
              sync(socket, rounds - 1)

            true ->
              # More may be waiting; yield so other messages (acks, invalidations) get a turn.
              {:noreply, queue_sync(assign(socket, dirty: true))}
          end
        end
    end
  end

  defp continue({:stop, _reason, _socket} = stopped), do: stopped
  defp continue(socket), do: {:noreply, socket}

  defp overflow?(assigns, bytes) do
    length(assigns.sent) + 1 > Stream.limit(:window_batches) or
      assigns.sent_bytes + bytes > Stream.limit(:window_bytes)
  end

  # Replaces the client's view with a fresh snapshot: same generation, higher seq.
  defp reset(socket, reason, confirmation_id \\ nil) do
    a = socket.assigns

    with :ok <- permitted(socket),
         {:ok, window} <- read_window(a.actor, a.stream, a.subscription),
         {:ok, _actor} <- Auth.revalidate(a.actor) do
      sequence = a.seq + 1

      socket =
        assign(socket,
          seq: sequence,
          cursor: window.cursor,
          sent: [],
          sent_bytes: 0,
          snapshot_seq: sequence,
          dirty: false
        )

      socket = track(socket, sequence, window.cursor, window.bytes, :snapshot)

      :telemetry.execute([:fyrlet, :delta, :snapshot_fallback], %{count: 1}, %{
        name: a.subscription.name,
        reason: reason
      })

      payload = snapshot_envelope(socket, window)

      payload =
        if confirmation_id, do: Map.put(payload, "confirmed", [confirmation_id]), else: payload

      push(socket, "snapshot", payload)
      socket
    else
      {:error, error} -> stop(socket, error)
    end
  end

  defp permitted(socket) do
    a = socket.assigns

    with {:ok, actor} <- Auth.revalidate(a.actor) do
      a.subscription.module.authorize(a.subscription.name, actor, a.subscription.parameters)
    end
  end

  defp read_window(actor, stream, subscription) do
    with {:ok, window} <-
           Stream.snapshot_shared(
             actor.project_id,
             stream,
             subscription.specification["max_items"]
           ),
         :ok <-
           Fyrlet.Subscriptions.Limits.check_snapshot(window.bytes, subscription.specification),
         do: {:ok, window}
  end

  defp snapshot_envelope(socket, window) do
    snapshot(socket, window.encoded, %{
      "cursor" => window.cursor,
      "mode" => "append",
      "max_items" => socket.assigns.subscription.specification["max_items"]
    })
  end

  # ---- unacknowledged bookkeeping --------------------------------------------------------

  defp track(socket, sequence, cursor, bytes, kind) do
    entry = %{
      seq: sequence,
      cursor: cursor,
      bytes: bytes,
      kind: kind,
      at: System.monotonic_time(:millisecond)
    }

    socket =
      assign(socket,
        sent: socket.assigns.sent ++ [entry],
        sent_bytes: socket.assigns.sent_bytes + bytes
      )

    if socket.assigns.ack_timer,
      do: socket,
      else: arm_ack_timer(socket, :ack_check, entry.at + ack_timeout())
  end

  defp ack_timeout, do: Application.fetch_env!(:fyrlet, :snapshot_ack_timeout)
end
