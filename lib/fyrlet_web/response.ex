defmodule FyrletWeb.Response do
  import Plug.Conn

  def result(conn, {:ok, data}), do: success(conn, data)
  def result(conn, {:error, error}), do: error(conn, error)

  def operation(conn, {:ok, envelope}),
    do: send_json(conn, 200, Map.put(envelope, "request_id", request_id(conn)))

  def operation(conn, {:error, error}), do: error(conn, error)

  def success(conn, data) do
    send_json(conn, 200, %{"request_id" => request_id(conn), "data" => data})
  end

  def error(conn, error, status \\ nil) do
    conn
    |> retry_after(error)
    |> send_json(status || Fyrlet.Error.status(error), %{
      "request_id" => request_id(conn),
      "error" => Fyrlet.Error.to_map(error)
    })
  end

  # Whole seconds, rounded up, as the Retry-After header requires.
  defp retry_after(conn, %{details: %{"retry_after_ms" => ms}}) when is_integer(ms),
    do: put_resp_header(conn, "retry-after", Integer.to_string(max(div(ms + 999, 1000), 1)))

  defp retry_after(conn, _error), do: conn

  defp request_id(conn),
    do: List.first(get_resp_header(conn, "x-request-id")) || Ecto.UUID.generate()

  defp send_json(conn, status, data),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(data))
end
