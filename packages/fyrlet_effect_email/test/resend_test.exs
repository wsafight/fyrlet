defmodule ResendTest.Receiver do
  @behaviour Plug
  def init(options), do: options

  def call(conn, _options) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    send(
      Application.fetch_env!(:fyrlet_effect_email, :test_pid),
      {:request, conn.method, conn.request_path, conn.req_headers, body}
    )

    {status, response} = Application.fetch_env!(:fyrlet_effect_email, :test_response)
    Plug.Conn.send_resp(conn, status, response)
  end
end

defmodule ResendTest do
  use ExUnit.Case, async: false
  alias FyrletEffectEmail.Resend
  @context %{secret: "test-api-key", idempotency_key: "stable-operation"}

  setup do
    {:ok, server} =
      Bandit.start_link(
        plug: ResendTest.Receiver,
        port: 0,
        ip: {127, 0, 0, 1},
        startup_log: false
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    previous = Application.get_all_env(:fyrlet_effect_email)
    Application.put_env(:fyrlet_effect_email, :test_pid, self())
    Application.put_env(:fyrlet_effect_email, :resend_url, "http://127.0.0.1:#{port}")
    Application.put_env(:fyrlet_effect_email, :allow_http, true)

    on_exit(fn ->
      for {key, _value} <- Application.get_all_env(:fyrlet_effect_email),
          do: Application.delete_env(:fyrlet_effect_email, key)

      for {key, value} <- previous, do: Application.put_env(:fyrlet_effect_email, key, value)
    end)

    :ok
  end

  defp respond(status, body),
    do: Application.put_env(:fyrlet_effect_email, :test_response, {status, body})

  test "acceptance preserves the stable key and never claims delivery" do
    respond(200, ~s({"id":"email-1"}))

    assert {:accepted, "email-1"} =
             Resend.deliver(%{"to" => ["alice@example.com"], "subject" => "Hello"}, @context)

    assert_received {:request, "POST", "/emails", headers, body}
    assert {"authorization", "Bearer test-api-key"} in headers
    assert {"idempotency-key", "stable-operation"} in headers
    assert Jason.decode!(body)["subject"] == "Hello"
    assert Resend.capabilities()["idempotency"]["window_seconds"] == 86_400
  end

  test "delivery and bounce are reconciled separately from acceptance" do
    for {event, expected} <- [
          {"sent", :pending},
          {"delivered", {:delivered, "delivered"}},
          {"bounced", {:bounced, "bounced"}}
        ] do
      respond(200, Jason.encode!(%{"last_event" => event}))
      assert Resend.status("email-1", @context) == expected
    end

    respond(404, "{}")
    assert Resend.status("missing", @context) == :not_found
  end

  test "ambiguous failures stay unknown and rejected requests never expose provider bodies" do
    respond(429, "{}")
    assert {:transient, "resend rate limit"} = Resend.deliver(%{}, @context)
    respond(422, ~s({"message":"private@example.com"}))
    assert {:rejected, "resend HTTP 422"} = Resend.deliver(%{}, @context)

    for {status, body} <- [{500, "{}"}, {408, "{}"}, {200, "not json"}, {200, "{}"}] do
      respond(status, body)
      assert :unknown = Resend.deliver(%{}, @context)
    end

    assert :unknown = Resend.deliver(%{}, %{secret: nil, idempotency_key: "key"})
    Application.put_env(:fyrlet_effect_email, :allow_http, false)
    assert :unknown = Resend.deliver(%{}, @context)
  end
end
