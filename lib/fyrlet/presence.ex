defmodule Fyrlet.Presence do
  @moduledoc """
  Who is in a presence room, tracked by `Phoenix.Presence` on `Fyrlet.PubSub`.

  Started only when the `presence` capability is enabled. It is a CRDT, so rooms stay
  consistent across the nodes joined by `Fyrlet.Cluster`; a member disappears when its channel
  process ends. Clients use `FyrletWeb.PresenceChannel`, not this module.
  """
  use Phoenix.Presence, otp_app: :fyrlet, pubsub_server: Fyrlet.PubSub
end
