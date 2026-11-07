defmodule FyrletWeb.CORSTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  alias FyrletWeb.CORS

  @allowed ["https://app.example", "https://other.example"]

  setup do
    previous = Application.get_env(:fyrlet, :cors_origins)
    Application.put_env(:fyrlet, :cors_origins, @allowed)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fyrlet, :cors_origins, previous),
        else: Application.delete_env(:fyrlet, :cors_origins)
    end)

    :ok
  end

  defp call(method, origin) do
    conn = conn(method, "/api/v1/sessions")
    conn = if origin, do: put_req_header(conn, "origin", origin), else: conn
    CORS.call(conn, CORS.init([]))
  end

  test "init/1 passes its options through" do
    assert CORS.init(foo: :bar) == [foo: :bar]
    assert CORS.init([]) == []
  end

  test "responses without an Origin still carry the safety headers" do
    conn = call(:get, nil)

    assert conn.state == :unset
    refute conn.halted
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "access-control-allow-origin") == []
  end

  test "an allowed origin gets the CORS headers and passes through" do
    conn = call(:get, "https://app.example")

    refute conn.halted
    assert get_resp_header(conn, "access-control-allow-origin") == ["https://app.example"]
    assert get_resp_header(conn, "vary") == ["origin"]

    assert get_resp_header(conn, "access-control-allow-methods") == [
             "GET, POST, DELETE, OPTIONS"
           ]

    assert [allowed_headers] = get_resp_header(conn, "access-control-allow-headers")
    assert allowed_headers =~ "authorization"
    assert allowed_headers =~ "x-fyrlet-capabilities"

    assert get_resp_header(conn, "access-control-expose-headers") == ["x-request-id"]
  end

  test "a preflight from an allowed origin is answered 204 and halted" do
    conn = call(:options, "https://other.example")

    assert conn.status == 204
    assert conn.halted
    assert conn.resp_body == ""
    assert get_resp_header(conn, "access-control-allow-origin") == ["https://other.example"]
  end

  test "a preflight from an unknown origin is refused, not answered 204" do
    conn = call(:options, "https://evil.example")

    assert conn.status == 403
    assert conn.halted
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "FORBIDDEN"
    assert get_resp_header(conn, "access-control-allow-origin") == []
  end

  test "an unknown origin on a normal request is refused" do
    conn = call(:get, "https://evil.example")

    assert conn.status == 403
    assert conn.halted
  end

  test "more than one Origin header is treated as invalid" do
    conn = %{conn(:get, "/api/v1/sessions") | req_headers: [{"origin", "a"}, {"origin", "b"}]}
    conn = CORS.call(conn, CORS.init([]))

    assert conn.status == 403
    assert conn.halted
  end

  test "same-origin requests work without a cross-origin allowance" do
    Application.put_env(:fyrlet, :cors_origins, [])

    for address <- ["http://localhost:4210", "https://app.example", "http://[::1]:4210"] do
      response =
        conn(:get, address <> "/sdk/index.js")
        |> put_req_header("origin", address)
        |> CORS.call([])

      refute response.halted
      assert get_resp_header(response, "access-control-allow-origin") == [address]
    end
  end

  test "same-origin matching rejects other ports, schemes and malformed origins" do
    Application.put_env(:fyrlet, :cors_origins, [])

    for origin <- [
          "http://localhost:4211",
          "https://localhost:4210",
          "http://user@localhost:4210",
          "http://localhost:4210/path",
          "http://localhost:4210?query",
          "http://localhost:4210#fragment",
          "null"
        ] do
      response =
        conn(:get, "http://localhost:4210/sdk/index.js")
        |> put_req_header("origin", origin)
        |> CORS.call([])

      assert response.halted
      assert response.status == 403
    end
  end

  test "an empty allow-list refuses cross-origin requests" do
    Application.put_env(:fyrlet, :cors_origins, [])

    conn = call(:get, "https://app.example")
    assert conn.status == 403
    assert conn.halted
  end
end
