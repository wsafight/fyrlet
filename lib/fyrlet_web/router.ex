defmodule FyrletWeb.Router do
  use Plug.Router
  alias Fyrlet.{Auth, Error, Registry, Runtime, Schema}
  alias FyrletWeb.Response

  plug :match
  plug :dispatch

  get "/health" do
    Response.success(conn, %{"status" => "ok"})
  end

  post "/api/v1/sessions" do
    Response.result(conn, Auth.issue_session(bearer(conn), conn.body_params))
  end

  delete "/api/v1/sessions/:id" do
    Response.result(conn, Auth.revoke_session(bearer(conn), id))
  end

  delete "/api/v1/session" do
    result = with {:ok, actor} <- actor(conn), do: Auth.revoke_own_session(actor)
    Response.result(conn, result)
  end

  get "/api/v1/contract" do
    result = with {:ok, _actor} <- actor(conn), do: {:ok, Registry.export()}
    Response.result(conn, result)
  end

  get "/api/v1/identity" do
    result =
      with {:ok, actor} <- actor(conn),
           do: {:ok, %{"project_id" => actor.project_id, "subject_id" => actor.subject_id}}

    Response.result(conn, result)
  end

  post "/api/v1/operations/:name" do
    envelope = Schema.object(%{"input" => %{"type" => "object"}}, ["input"])

    result =
      with {:ok, actor} <- actor(conn),
           {:ok, body} <- Schema.validate(envelope, conn.body_params) do
        Runtime.call(
          actor,
          name,
          body["input"],
          List.first(get_req_header(conn, "idempotency-key"))
        )
      end

    Response.result(conn, result)
  end

  match _ do
    Response.error(conn, Error.not_found())
  end

  defp actor(conn),
    do: Auth.authenticate(bearer(conn), List.first(get_req_header(conn, "x-project-id")))

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _missing -> nil
    end
  end
end
