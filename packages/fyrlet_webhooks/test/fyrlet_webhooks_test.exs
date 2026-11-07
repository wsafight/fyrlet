defmodule FyrletWebhooksTest do
  use FyrletWebhooks.Case
  alias FyrletWebhooks.Receiver, as: Webhooks
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]
  @endpoint FyrletWeb.Endpoint

  @secret "0123456789abcdef-secret"

  setup do
    project = project()
    alice = user(project, "alice")

    Application.put_env(:fyrlet_webhooks, :sources, %{
      "billing" => %{
        project_id: project.project.id,
        secret: @secret,
        handler: FyrletWebhooks.TestHandler
      },
      "blank" => %{
        project_id: project.project.id,
        secret: "",
        handler: FyrletWebhooks.TestHandler
      },
      "short" => %{
        project_id: project.project.id,
        secret: "tiny",
        handler: FyrletWebhooks.TestHandler
      }
    })

    on_exit(fn -> Application.delete_env(:fyrlet_webhooks, :sources) end)

    id = start_run!(alice)
    assert drive(id) == "waiting"
    %{project: project, alice: alice, run_id: id, wait_id: wait_step(id).id}
  end

  defp body(event, ctx, extra \\ %{}),
    do:
      Jason.encode!(
        Map.merge(
          %{
            "event" => event,
            "run" => ctx.run_id,
            "wait" => ctx.wait_id,
            "name" => "paid",
            "data" => %{"amount" => 5}
          },
          extra
        )
      )

  defp signed(source, raw, secret \\ @secret, at \\ System.os_time(:second)),
    do: Webhooks.receive_event(source, Webhooks.sign(secret, at, raw), raw)

  test "a verified event becomes a signal and resumes the run", ctx do
    assert {:ok, %{"status" => "accepted", "outcome" => "consumed"}} =
             signed("billing", body("evt-1", ctx))

    assert drive(ctx.run_id) == "completed"

    assert [%{payload: %{"amount" => 5}, idempotency_key: "webhook:billing:evt-1"}] =
             Repo.all(Signal)
  end

  test "a redelivered event is recognised and not applied twice", ctx do
    raw = body("evt-2", ctx)
    assert {:ok, %{"status" => "accepted"}} = signed("billing", raw)
    assert {:ok, %{"status" => "duplicate", "outcome" => "consumed"}} = signed("billing", raw)

    assert {:ok, %{"status" => "duplicate"}} =
             signed("billing", body("evt-2", ctx, %{"data" => %{"amount" => 999}}))

    assert Repo.aggregate(Signal, :count) == 1
    assert Repo.aggregate(FyrletWebhooks.Receiver.Event, :count) == 1
  end

  test "a wrong, missing, malformed or foreign signature is refused", ctx do
    raw = body("evt-3", ctx)
    now = System.os_time(:second)

    for header <- [
          Webhooks.sign("another-secret-value", now, raw),
          Webhooks.sign(@secret, now, raw <> " "),
          nil,
          "",
          "garbage",
          "t=#{now}",
          "v1=abc",
          "t=x,v1=abc"
        ] do
      assert {:error, %Error{code: "UNAUTHENTICATED"}} =
               Webhooks.receive_event("billing", header, raw),
             inspect(header)
    end

    assert Repo.aggregate(Signal, :count) == 0
    assert status(ctx.run_id) == "waiting"
  end

  test "a request outside the tolerance window is refused even with a valid signature", ctx do
    raw = body("evt-4", ctx)

    assert {:error, %Error{code: "UNAUTHENTICATED"}} =
             signed("billing", raw, @secret, System.os_time(:second) - 301)

    assert {:error, %Error{code: "UNAUTHENTICATED"}} =
             signed("billing", raw, @secret, System.os_time(:second) + 301)

    assert {:ok, _} = signed("billing", raw, @secret, System.os_time(:second) - 250)
  end

  test "it fails closed: unknown, blank or weak sources do nothing",
       ctx do
    raw = body("evt-5", ctx)

    for source <- ["nope", "blank", "short"] do
      assert {:error, %Error{code: "NOT_FOUND"}} = signed(source, raw, "")
      assert {:error, %Error{code: "NOT_FOUND"}} = signed(source, raw, @secret)
    end

    assert status(ctx.run_id) == "waiting"
  end

  test "a payload that cannot be translated or targets the wrong thing is refused and not recorded",
       ctx do
    assert {:error, %Error{code: "VALIDATION_FAILED"}} = signed("billing", ~s({"unknown":true}))
    assert {:error, %Error{code: "VALIDATION_FAILED"}} = signed("billing", "[1,2]")
    assert {:error, %Error{code: "VALIDATION_FAILED"}} = signed("billing", "not json")

    assert {:error, %Error{code: "VALIDATION_FAILED"}} =
             signed("billing", body("evt-6", ctx, %{"name" => "other"}))

    assert {:error, %Error{code: "NOT_FOUND"}} =
             signed("billing", body("evt-7", ctx, %{"run" => Ecto.UUID.generate()}))

    assert Repo.aggregate(FyrletWebhooks.Receiver.Event, :count) == 0

    # A failed event may be sent again once it is right.
    assert {:ok, %{"status" => "accepted"}} = signed("billing", body("evt-6", ctx))
  end

  test "the principal is restricted to its own project", ctx do
    other = project()
    other_alice = user(other, "zed")
    foreign = start_run!(other_alice)
    drive(foreign)
    foreign_wait = wait_step(foreign) || %{id: Ecto.UUID.generate()}

    assert {:error, %Error{code: "NOT_FOUND"}} =
             signed("billing", body("evt-8", ctx, %{"run" => foreign, "wait" => foreign_wait.id}))

    assert status(foreign) in ["waiting", "running", "pending"]
  end

  test "over HTTP the exact raw bytes are what is signed", ctx do
    raw = body("evt-9", ctx)
    header = Webhooks.sign(@secret, System.os_time(:second), raw)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-fyrlet-signature", header)
      |> post("/api/v1/plugins/webhooks/billing", raw)

    assert json_response(conn, 200)["data"]["status"] == "accepted"

    # Whitespace changes the bytes, so the same JSON re-serialised no longer verifies.
    reformatted = Jason.encode!(Jason.decode!(body("evt-10", ctx)), pretty: true)

    bad =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header(
        "x-fyrlet-signature",
        Webhooks.sign(@secret, System.os_time(:second), body("evt-10", ctx))
      )
      |> post("/api/v1/plugins/webhooks/billing", reformatted)

    assert json_response(bad, 401)["error"]["code"] == "UNAUTHENTICATED"

    none =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/plugins/webhooks/billing", raw)

    assert json_response(none, 401)

    assert json_response(
             build_conn()
             |> put_req_header("content-type", "application/json")
             |> post("/api/v1/plugins/webhooks/missing", raw),
             404
           )
  end

  test "only POST to a source is served, and the plugin passes the conformance suite" do
    conn = build_conn() |> get("/api/v1/plugins/webhooks/billing")
    assert json_response(conn, 404)
    assert Fyrlet.Conformance.Plugin.failures(FyrletWebhooks) == []
  end

  test "event IDs are forgotten after the retention period", ctx do
    assert {:ok, _} = signed("billing", body("evt-old", ctx))
    old = DateTime.add(Fyrlet.Auth.now(), -2_000_000, :second)
    Repo.update_all(Webhooks.Event, set: [received_at: old])
    Application.put_env(:fyrlet_webhooks, :retention_seconds, 604_800)
    on_exit(fn -> Application.delete_env(:fyrlet_webhooks, :retention_seconds) end)

    assert FyrletWebhooks.Pruner.prune() == 1
    assert Repo.aggregate(Webhooks.Event, :count) == 0
  end
end
