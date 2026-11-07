defmodule FyrletWeb.HTTPTest do
  use Fyrlet.DataCase, async: true
  import Plug.Conn
  import Phoenix.ConnTest
  @endpoint FyrletWeb.Endpoint

  test "session exchange, authenticated contract and structured operation results" do
    project = project()

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> project.service_key)
      |> post("/api/v1/sessions", %{"external_subject" => "alice"})

    session = json_response(conn, 200)["data"]
    conn = authorized(session) |> get("/api/v1/contract")
    assert json_response(conn, 200)["data"]["protocol_version"] == 1
    assert json_response(conn, 200)["request_id"]

    conn =
      authorized(session)
      |> put_req_header("idempotency-key", "http-key")
      |> post("/api/v1/operations/records.add", %{"input" => %{"text" => "from http"}})

    assert json_response(conn, 200)["data"]["text"] == "from http"
    assert json_response(conn, 200)["outcome"] == "committed"
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    conn =
      authorized(session)
      |> post("/api/v1/operations/records.add", %{"input" => %{"text" => "missing key"}})

    assert json_response(conn, 422)["error"]["code"] == "VALIDATION_FAILED"
    conn = build_conn() |> get("/api/v1/contract")
    assert json_response(conn, 401)["error"]["code"] == "UNAUTHENTICATED"
  end

  test "HTTP recovery returns a receipt without replaying and respects ownership" do
    project = project()
    alice = user(project, "alice")
    bob = user(project, "bob")
    session = %{"token" => alice.token, "project_id" => project.project.id}
    input = %{"input" => %{"text" => "recover"}}

    written =
      authorized(session)
      |> put_req_header("idempotency-key", "recover")
      |> post("/api/v1/operations/records.add", input)
      |> json_response(200)

    recovered =
      authorized(session)
      |> put_req_header("idempotency-key", "recover")
      |> post("/api/v1/operations/records.add/recover", input)
      |> json_response(200)

    assert recovered["outcome"] == "committed"
    assert recovered["data"] == written["data"]
    assert recovered["request_id"]

    unknown =
      authorized(%{"token" => bob.token, "project_id" => project.project.id})
      |> put_req_header("idempotency-key", "recover")
      |> post("/api/v1/operations/records.add/recover", input)
      |> json_response(200)

    assert unknown["outcome"] == "unknown"
    assert unknown["data"] == nil
    assert Repo.aggregate(TestRecord, :count) == 1

    conn = authorized(session) |> post("/api/v1/operations/records.add/recover", input)
    assert json_response(conn, 422)["error"]["code"] == "VALIDATION_FAILED"
    conn = build_conn() |> post("/api/v1/operations/records.add/recover", input)
    assert json_response(conn, 401)["error"]["code"] == "UNAUTHENTICATED"
  end

  test "malformed JSON, excessive bodies and disallowed origins are rejected" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/sessions", "{")

    assert json_response(conn, 400)["error"]["code"] == "VALIDATION_FAILED"

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(
        "/api/v1/sessions",
        Jason.encode!(%{"external_subject" => String.duplicate("x", 70_000)})
      )

    assert json_response(conn, 413)["error"]["code"] == "LIMIT_EXCEEDED"
    conn = build_conn() |> put_req_header("origin", "https://untrusted.example") |> get("/health")
    assert json_response(conn, 403)["error"]["code"] == "FORBIDDEN"

    conn =
      build_conn()
      |> put_req_header("origin", "http://localhost:5173")
      |> options("/api/v1/sessions")

    assert conn.status == 204
    assert get_resp_header(conn, "access-control-allow-origin") == ["http://localhost:5173"]
  end

  defp authorized(session) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> session["token"])
    |> put_req_header("x-project-id", session["project_id"])
  end
end
