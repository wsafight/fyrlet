defmodule FyrletWeb.PresenceChannel do
  @moduledoc """
  Presence rooms: who is here, and short-lived state such as "typing".

  Join `presence:<uuid>` with `protocol_version: 1`, the `presence` capability, a `name` from the
  contract's `presence` section, its `params`, and optionally `meta` (validated by the entry's
  `meta` schema and capped in size). The reply carries the current `state`; afterwards the
  server pushes `diff` events, and the client may send `update` to change its own `meta`.

  Members are keyed by `subject_id`, so one person on two devices is one key with two metas.
  Identity is never taken from the client. Every meta entry has a `ref` that is unique to it;
  clients apply `diff` by ref, which makes a repeated diff harmless.

  Like a subscription, a presence member is re-checked: the session and `authorize/3` run again
  on every reconciliation interval, and the channel closes when either fails.
  """
  use Phoenix.Channel,
    log_join: false,
    log_handle_in: false,
    hibernate_after: Application.compile_env(:fyrlet, :channel_hibernate_after, 15_000)

  alias Fyrlet.{Auth, Capabilities, Error, Presence, Registry, Schema}
  import FyrletWeb.ChannelSupport

  @no_meta %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  @impl true
  def join(
        "presence:" <> identifier,
        %{"protocol_version" => 1, "name" => name, "params" => parameters} = options,
        socket
      )
      when is_binary(name) do
    actor = socket.assigns.actor

    with {:ok, _uuid} <- identifier(identifier, "presence"),
         {:ok, capabilities} <- Capabilities.negotiate(options["capabilities"]),
         :ok <- Capabilities.require(capabilities, "presence"),
         :ok <- not_anonymous(actor),
         {:ok, module, specification} <- Registry.fetch("presence", name),
         {:ok, normalized} <- Schema.validate(specification["input"], parameters),
         {:ok, data} <- validate_data(specification, Map.get(options, "meta", %{})),
         {:ok, current} <- Auth.revalidate(actor),
         :ok <- module.authorize(name, current, normalized),
         topic = room_topic(current, module.scope(name, current, normalized)),
         :ok <- claim(socket, current),
         :ok <- Phoenix.PubSub.subscribe(Fyrlet.PubSub, topic),
         :ok <- room_capacity(topic, current.subject_id),
         joined_at = DateTime.to_iso8601(Auth.now()),
         {:ok, _ref} <-
           Presence.track(self(), topic, current.subject_id, meta(data, joined_at)),
         {:ok, _actor} <- Auth.revalidate(current) do
      socket =
        assign(socket,
          actor: current,
          module: module,
          presence_name: name,
          presence_specification: specification,
          presence_parameters: normalized,
          topic_key: topic,
          joined_at: joined_at,
          update_window: {0, 0},
          expiry_timer: expiry_timer(current),
          recheck_timer: reconcile_timer(:recheck)
        )

      {:ok,
       %{
         "protocol_version" => Capabilities.protocol_version(),
         "name" => name,
         "capabilities" => capabilities,
         "self" => current.subject_id,
         "state" => wire(Presence.list(topic))
       }, socket}
    else
      {:error, error} -> reject(error)
    end
  end

  def join(_topic, _parameters, _socket), do: unsupported()

  @impl true
  def handle_in("update", %{"meta" => raw}, socket) do
    with :ok <- within_update_rate(socket.assigns.update_window),
         {:ok, data} <- validate_data(socket.assigns.presence_specification, raw),
         {:ok, _ref} <-
           Presence.update(
             self(),
             socket.assigns.topic_key,
             socket.assigns.actor.subject_id,
             meta(data, socket.assigns.joined_at)
           ) do
      {:reply, {:ok, %{}}, assign(socket, update_window: bump(socket.assigns.update_window))}
    else
      {:error, %Error{} = error} ->
        {:reply, reject(error), assign(socket, update_window: bump(socket.assigns.update_window))}

      {:error, _presence} ->
        {:reply, reject(Error.not_found()), socket}
    end
  end

  def handle_in(_event, _parameters, socket),
    do: {:reply, reject(Error.not_found()), socket}

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", payload: diff}, socket) do
    push(socket, "diff", %{"joins" => wire(diff.joins), "leaves" => wire(diff.leaves)})
    {:noreply, socket}
  end

  def handle_info(:expired, socket), do: stop(socket, Error.unauthorized())

  def handle_info(:recheck, socket) do
    assigns = socket.assigns

    with {:ok, actor} <- Auth.revalidate(assigns.actor),
         :ok <-
           assigns.module.authorize(assigns.presence_name, actor, assigns.presence_parameters) do
      {:noreply, assign(socket, recheck_timer: reconcile_timer(:recheck))}
    else
      {:error, error} -> stop(socket, error)
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket), do: cancel_timers(socket, [:expiry_timer, :recheck_timer])

  # ---- helpers --------------------------------------------------------------------------

  defp not_anonymous(actor),
    do:
      if(Fyrlet.Features.Anonymous.anonymous?(actor), do: {:error, Error.forbidden()}, else: :ok)

  # The project is part of the room, whatever the application's scope string contains.
  defp room_topic(actor, scope), do: "presence:" <> actor.project_id <> ":" <> scope

  defp validate_data(specification, raw) do
    with {:ok, data} <- Schema.validate(specification["meta"] || @no_meta, raw) do
      if byte_size(Jason.encode!(data)) <=
           Application.fetch_env!(:fyrlet, :presence_max_meta_bytes),
         do: {:ok, data},
         else: {:error, Error.new("LIMIT_EXCEEDED", "The presence meta is too large")}
    end
  end

  defp room_capacity(topic, key) do
    members = Presence.list(topic)

    if is_map_key(members, key) or
         map_size(members) < Application.fetch_env!(:fyrlet, :presence_max_members),
       do: :ok,
       else: {:error, Error.new("LIMIT_EXCEEDED", "The presence room is full")}
  end

  defp meta(data, joined_at), do: %{data: data, joined_at: joined_at}

  # `%{key => %{metas: [...]}}` to `%{key => [%{"ref", "data", "joined_at"}]}`.
  defp wire(entries) do
    Map.new(entries, fn {key, %{metas: metas}} ->
      {key,
       Enum.map(metas, fn meta ->
         %{
           "ref" => meta.phx_ref,
           "data" => Map.get(meta, :data, %{}),
           "joined_at" => Map.get(meta, :joined_at)
         }
       end)}
    end)
  end

  # A channel may change its state a few times a second, not on every keystroke.
  defp within_update_rate({second, count}) do
    now = System.monotonic_time(:second)

    if second != now or count < Application.fetch_env!(:fyrlet, :presence_updates_per_second),
      do: :ok,
      else: {:error, Error.new("LIMIT_EXCEEDED", "Presence updates are too frequent", %{}, true)}
  end

  defp bump({second, count}) do
    now = System.monotonic_time(:second)
    if second == now, do: {now, count + 1}, else: {now, 1}
  end
end
