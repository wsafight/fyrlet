defmodule Fyrlet.HTTP do
  @moduledoc "Public JSON response helpers for host routers and Fyrlet plugins."
  defdelegate result(conn, result), to: FyrletWeb.Response
  defdelegate success(conn, data), to: FyrletWeb.Response
  defdelegate error(conn, error), to: FyrletWeb.Response
  defdelegate error(conn, error, status), to: FyrletWeb.Response

  @doc "Dispatches unmatched routes to the host's configured Plug router, or returns 404."
  def fallback(conn) do
    case Application.get_env(:fyrlet, :host_router) do
      nil -> error(conn, Fyrlet.Error.not_found())
      router when is_atom(router) -> router.call(conn, router.init([]))
    end
  end
end
