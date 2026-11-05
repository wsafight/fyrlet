defmodule FyrletWeb.CORS do
  import Plug.Conn
  def init(options), do: options

  def call(conn, _options) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("x-content-type-options", "nosniff")

    case get_req_header(conn, "origin") do
      [] ->
        conn

      [origin] ->
        if origin in Application.get_env(:fyrlet, :cors_origins, []) do
          conn =
            conn
            |> put_resp_header("access-control-allow-origin", origin)
            |> put_resp_header("vary", "origin")
            |> put_resp_header("access-control-allow-methods", "GET, POST, DELETE, OPTIONS")
            |> put_resp_header(
              "access-control-allow-headers",
              "authorization, content-type, x-project-id, idempotency-key, x-request-id"
            )
            |> put_resp_header("access-control-expose-headers", "x-request-id")

          if conn.method == "OPTIONS", do: conn |> send_resp(204, "") |> halt(), else: conn
        else
          conn |> FyrletWeb.Response.error(Fyrlet.Error.forbidden()) |> halt()
        end

      _invalid ->
        conn |> FyrletWeb.Response.error(Fyrlet.Error.forbidden()) |> halt()
    end
  end
end
