defmodule FyrletWeb.Response do
  import Plug.Conn

  def result(conn, {:ok, data}), do: success(conn, data)
  def result(conn, {:error, error}), do: error(conn, error)

  def success(conn, data) do
    send_json(conn, 200, %{"request_id" => request_id(conn), "data" => data})
  end

  def error(conn, error, status \\ nil) do
    send_json(conn, status || Fyrlet.Error.status(error), %{
      "request_id" => request_id(conn),
      "error" => Fyrlet.Error.to_map(error)
    })
  end

  defp request_id(conn),
    do: List.first(get_resp_header(conn, "x-request-id")) || Ecto.UUID.generate()

  defp send_json(conn, status, data),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(data))
end
