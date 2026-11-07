defmodule FyrletWeb.ChannelSupport do
  @moduledoc false
  import Phoenix.Channel, only: [push: 3]
  import Phoenix.Socket, only: [assign: 2]
  alias Fyrlet.{Auth, Capabilities, Error}
  alias Fyrlet.Features.Anonymous
  alias Fyrlet.Subscriptions.Tracker

  def reject(error), do: {:error, %{"error" => Error.to_map(error)}}

  def unsupported,
    do: reject(Error.new("UNSUPPORTED_VERSION", "Expected protocol_version 1, name and params"))

  def identifier(value, kind \\ "subscription") do
    case Ecto.UUID.cast(value) do
      {:ok, identifier} -> {:ok, identifier}
      :error -> {:error, Error.new("VALIDATION_FAILED", "Invalid #{kind} identifier")}
    end
  end

  def anonymous_entry(actor, capabilities) do
    if Anonymous.anonymous?(actor),
      do: Capabilities.require(capabilities, Anonymous.capability()),
      else: :ok
  end

  def claim(socket, actor) do
    limit = if Anonymous.anonymous?(actor), do: Anonymous.max_subscriptions()
    Tracker.claim(socket.transport_pid, self(), limit, actor.project_id)
  end

  def expiry_timer(actor) do
    remaining = max(DateTime.diff(actor.expires_at, Auth.now(), :millisecond), 1)
    Process.send_after(self(), :expired, remaining)
  end

  def reconcile_timer(event \\ :reconcile),
    do:
      Process.send_after(self(), event, Application.fetch_env!(:fyrlet, :reconciliation_interval))

  def cancel_timers(socket, keys) do
    for key <- keys,
        reference = socket.assigns[key],
        is_reference(reference),
        do: Process.cancel_timer(reference)

    :ok
  end

  def arm_ack_timer(socket, event, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 1)
    assign(socket, ack_timer: Process.send_after(self(), event, remaining))
  end

  def stop(socket, error) do
    push(socket, "status", %{"state" => "closed", "error" => Error.to_map(error)})
    {:stop, :normal, socket}
  end

  def snapshot(socket, encoded, extra) do
    assigns = socket.assigns

    :telemetry.execute([:fyrlet, :subscription, :snapshot], %{bytes: byte_size(encoded)}, %{
      name: assigns.subscription.name
    })

    Map.merge(
      %{
        "protocol_version" => Capabilities.protocol_version(),
        "capabilities" => assigns.capabilities,
        "subscription_id" => assigns.subscription_id,
        "generation" => assigns.generation,
        "seq" => assigns.seq,
        "project_id" => assigns.actor.project_id,
        "subject_id" => assigns.actor.subject_id,
        "data" => fragment(socket, encoded)
      },
      extra
    )
  end

  def fragment(socket, encoded) do
    if socket.serializer == Phoenix.Socket.V2.JSONSerializer and Phoenix.json_library() == Jason,
      do: Jason.Fragment.new(encoded),
      else: Jason.decode!(encoded)
  end
end
