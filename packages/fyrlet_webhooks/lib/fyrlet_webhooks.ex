defmodule FyrletWebhooks do
  @moduledoc """
  Inbound webhooks as a Fyrlet plugin: a verified, de-duplicated event becomes a signal for
  one wait node of a run in the source's project.

      # mix.exs
      {:fyrlet_webhooks, path: "..."}

      # config
      config :fyrlet, plugins: [FyrletWebhooks]

      config :fyrlet_webhooks,
        sources: %{"billing" => %{project_id: "...", secret: "<16+ bytes>", handler: MyApp.Billing}},
        tolerance_seconds: 300,        # accepted clock difference
        retention_seconds: 604_800     # how long event IDs are remembered

  Senders `POST /api/v1/plugins/webhooks/<source>` with
  `x-fyrlet-signature: t=<unix seconds>,v1=<hex>`, where `v1 = HMAC-SHA256(secret,
  "<t>.<raw body>")`. See `FyrletWebhooks.Receiver` for the handler contract and the
  guarantees. The plugin is fail-closed: an unknown source, a short secret, a bad or stale
  signature all refuse the request.
  """
  @behaviour Fyrlet.Plugin
  alias Fyrlet.Error
  alias FyrletWebhooks.Receiver
  alias Fyrlet.HTTP, as: Response

  @impl true
  def name, do: "webhooks"
  @impl true
  def version, do: "0.1.0"
  @impl true
  def capabilities, do: %{"webhooks" => 1}
  @impl true
  def children(_config), do: [FyrletWebhooks.Pruner]
  @impl true
  def migrations, do: [Application.app_dir(:fyrlet_webhooks, "priv/migrations")]

  @impl true
  def call(%Plug.Conn{method: "POST"} = conn, [source]) do
    signature = List.first(Plug.Conn.get_req_header(conn, "x-fyrlet-signature"))
    Response.result(conn, Receiver.receive_event(source, signature, conn.assigns[:raw_body]))
  end

  def call(conn, _path), do: Response.error(conn, Error.not_found())

  defdelegate sign(secret, timestamp, body), to: Receiver
end
