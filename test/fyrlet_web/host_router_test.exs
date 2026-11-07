defmodule FyrletWeb.HostRouterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn

  @endpoint FyrletWeb.Endpoint

  defmodule HostRouter do
    use Plug.Router

    plug :match
    plug :dispatch

    get "/host/status" do
      Fyrlet.HTTP.success(conn, %{"host" => true, "query" => conn.query_string})
    end

    get "/host/fail" do
      raise "private host credentials at #{conn.request_path}"
    end

    match _ do
      Fyrlet.HTTP.error(conn, Fyrlet.Error.not_found())
    end
  end

  import Phoenix.ConnTest

  setup do
    previous = Application.fetch_env(:fyrlet, :host_router)
    Application.put_env(:fyrlet, :host_router, HostRouter)

    on_exit(fn ->
      case previous do
        {:ok, router} -> Application.put_env(:fyrlet, :host_router, router)
        :error -> Application.delete_env(:fyrlet, :host_router)
      end
    end)

    :ok
  end

  test "unmatched routes reach the host router with their path and query intact" do
    conn = build_conn() |> get("/host/status?value=one%20two")

    assert %{
             "data" => %{"host" => true, "query" => "value=one%20two"},
             "request_id" => request_id
           } =
             json_response(conn, 200)

    assert get_resp_header(conn, "x-request-id") == [request_id]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "core routes still take precedence over the host fallback" do
    conn = build_conn() |> get("/health")
    assert json_response(conn, 200)["data"] == %{"status" => "ok"}
  end

  test "missing host routes and an absent host router return structured errors" do
    conn = build_conn() |> get("/host/missing")
    assert json_response(conn, 404)["error"]["code"] == "NOT_FOUND"
    Application.delete_env(:fyrlet, :host_router)
    conn = build_conn() |> get("/host/status")
    assert json_response(conn, 404)["error"]["code"] == "NOT_FOUND"
  end

  test "host exceptions become structured internal errors without leaking exception details" do
    log =
      capture_log(fn ->
        conn = build_conn() |> get("/host/fail")

        assert %{"error" => %{"code" => "INTERNAL_ERROR"}, "request_id" => request_id} =
                 json_response(conn, 500)

        assert get_resp_header(conn, "x-request-id") == [request_id]
        refute conn.resp_body =~ "private host credentials"
      end)

    assert log =~ "HTTP request failed"
    refute log =~ "private host credentials"
  end

  test "unsupported request media types are rejected before reaching the host" do
    conn =
      build_conn()
      |> put_req_header("content-type", "text/plain")
      |> post("/host/status", "plain text")

    assert json_response(conn, 415)["error"]["code"] == "VALIDATION_FAILED"
  end

  test "invalid UTF-8 JSON is rejected with a structured parser error" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/host/status", <<123, 34, 120, 34, 58, 34, 255, 34, 125>>)

    assert json_response(conn, 400)["error"]["code"] == "VALIDATION_FAILED"
  end
end
