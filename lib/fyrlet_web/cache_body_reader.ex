defmodule FyrletWeb.CacheBodyReader do
  @moduledoc """
  Keeps the raw request body for plugin paths. A signature covers the exact bytes that were
  sent, which the JSON parser would otherwise consume and re-encode.

  Anything other than a complete read (an oversized or failed body) is handed back untouched,
  so the parser keeps producing its own 413 and error responses.
  """
  def read_body(conn, options) do
    case Plug.Conn.read_body(conn, options) do
      {:ok, body, conn} ->
        if String.starts_with?(conn.request_path, "/api/v1/plugins/"),
          do: {:ok, body, Plug.Conn.assign(conn, :raw_body, body)},
          else: {:ok, body, conn}

      other ->
        other
    end
  end
end
