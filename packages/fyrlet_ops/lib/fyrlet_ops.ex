defmodule FyrletOps do
  @moduledoc """
  Operational status and alerts for Fyrlet, as a plugin.

      # mix.exs
      {:fyrlet_ops, path: "..."}

      # config
      config :fyrlet, plugins: [FyrletOps]

  Provides `GET /api/v1/plugins/ops/status` (a project's own status, authenticated with the
  project's service key), a background evaluation that notifies `FyrletOps.AlertHandler`s when
  an alert starts or stops firing, and `mix fyrlet.ops`. See `FyrletOps.Status`.
  """
  @behaviour Fyrlet.Plugin
  alias Fyrlet.{Auth, Error}
  alias Fyrlet.HTTP, as: Response

  @impl true
  def name, do: "ops"
  @impl true
  def version, do: "0.1.0"
  @impl true
  def capabilities, do: %{"ops" => 1}
  @impl true
  def children(_config), do: [FyrletOps.Ticker]

  @impl true
  def call(%Plug.Conn{method: "GET"} = conn, ["status"]) do
    result =
      with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
           {:ok, key} <- Auth.authenticate_key(token) do
        status = FyrletOps.Status.status(key.project_id)
        {:ok, %{"status" => status, "alerts" => FyrletOps.Status.alerts(status)}}
      else
        _unauthenticated -> {:error, Error.unauthorized()}
      end

    Response.result(conn, result)
  end

  def call(conn, _path), do: Response.error(conn, Error.not_found())
end
