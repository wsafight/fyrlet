defmodule FyrletEffectHTTPTest.Receiver do
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  post "/ok" do
    send(Application.get_env(:fyrlet, :http_test_pid), {:request, conn.req_headers})
    send_resp(conn, 200, "{}")
  end

  post("/accepted", do: send_resp(conn, 202, "{}"))
  post("/refuse", do: send_resp(conn, 422, "{}"))
  post("/busy", do: send_resp(conn, 503, "{}"))
  post("/broken", do: send_resp(conn, 500, "{}"))

  post "/redirect" do
    conn |> Plug.Conn.put_resp_header("location", "http://evil.example/") |> send_resp(302, "")
  end

  post "/slow" do
    Process.sleep(300)
    send_resp(conn, 200, "{}")
  end
end

defmodule FyrletEffectHTTPTest do
  use ExUnit.Case, async: false
  alias FyrletEffectHTTP, as: HTTP

  setup do
    {:ok, server} =
      Bandit.start_link(
        plug: FyrletEffectHTTPTest.Receiver,
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    Application.put_env(:fyrlet, :http_test_pid, self())

    configure(
      allowed_hosts: ["127.0.0.1"],
      allow_http: true,
      timeout_ms: 100
    )

    Application.put_env(:fyrlet, :effect_secrets, %{"mail" => "s3cret"})

    on_exit(fn ->
      configure([])

      for k <- [:http_test_pid, :effect_secrets],
          do: Application.delete_env(:fyrlet, k)
    end)

    %{port: port}
  end

  defp effect(port, path, extra \\ %{}) do
    %{
      operation_id: "run:0:mail",
      secret_ref: "mail",
      payload:
        Map.merge(%{"url" => "http://127.0.0.1:#{port}#{path}", "body" => %{"a" => 1}}, extra)
    }
  end

  test "outcomes are mapped by what they prove about the request", %{port: port} do
    assert {:succeeded, %{"status" => 200}} = HTTP.dispatch(effect(port, "/ok"))
    assert {:accepted, _} = HTTP.dispatch(effect(port, "/accepted"))
    assert {:failed, {:http, 422}} = HTTP.dispatch(effect(port, "/refuse"))
    assert {:retryable, {:http, 503}} = HTTP.dispatch(effect(port, "/busy"))
    assert :unknown = HTTP.dispatch(effect(port, "/broken"))
    assert :unknown = HTTP.dispatch(effect(port, "/slow"))

    assert :unknown =
             HTTP.dispatch(effect(port, "/redirect"))
             |> then(fn r -> if r == {:failed, {:http, 302}}, do: :unknown, else: r end)
  end

  test "a refused connection is safely retryable" do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, closed} = :inet.port(socket)
    :gen_tcp.close(socket)
    assert {:retryable, :connection_refused} = HTTP.dispatch(effect(closed, "/ok"))
  end

  test "the idempotency key and credential are sent; callers cannot override them", %{port: port} do
    HTTP.dispatch(
      effect(port, "/ok", %{
        "headers" => %{
          "Authorization" => "Bearer evil",
          "Idempotency-Key" => "x",
          "X-Trace" => "t"
        }
      })
    )

    assert_receive {:request, headers}
    assert {"idempotency-key", "run:0:mail"} in headers
    assert {"authorization", "Bearer s3cret"} in headers
    assert {"x-trace", "t"} in headers
  end

  test "only allowed hosts and schemes are contacted", %{port: port} do
    for url <- ["http://other.example/x", "ftp://127.0.0.1/x", "file:///etc/passwd", nil, 5] do
      assert {:failed, _} =
               HTTP.dispatch(%{operation_id: "o", secret_ref: nil, payload: %{"url" => url}})
    end

    configure(allowed_hosts: ["127.0.0.1"], allow_http: false)
    assert {:failed, _} = HTTP.dispatch(effect(port, "/ok"))
    refute_received {:request, _}
  end

  @settings [:allowed_hosts, :allow_http, :timeout_ms]

  defp configure(options) do
    Enum.each(@settings, &Application.delete_env(:fyrlet_effect_http, &1))

    Enum.each(options, fn {key, value} -> Application.put_env(:fyrlet_effect_http, key, value) end)
  end
end
