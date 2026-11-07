defmodule Target do
  use Plug.Router
  plug(:match)
  plug(:dispatch)

  post "/hook" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    send(
      Application.get_env(:flow_example, :test_pid),
      {:called, Plug.Conn.get_req_header(conn, "idempotency-key"), body}
    )

    send_resp(conn, Application.get_env(:flow_example, :status, 200), "{}")
  end
end

defmodule FlowExampleTest do
  @moduledoc "A second domain on the same public API: no tables, no private modules, no core changes."
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Fyrlet.Repo
  alias Fyrlet.{Repo, Runs}
  alias Fyrlet.Testing

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)

    {:ok, server} =
      Bandit.start_link(plug: Target, port: 0, ip: {127, 0, 0, 1}, startup_log: false)

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    Application.put_env(:flow_example, :test_pid, self())
    Application.put_env(:flow_example, :status, 200)
    Application.put_env(:flow_example, :url, "http://127.0.0.1:#{port}/hook")

    for {k, v} <- [allowed_hosts: ["127.0.0.1"], allow_http: true, timeout_ms: 500],
        do: Application.put_env(:fyrlet_effect_http, k, v)

    Application.put_env(:fyrlet, :effects, retry_base_seconds: 0, reconcile_delay_seconds: 0)
    {:ok, project} = Fyrlet.Auth.create_project("flow")

    {:ok, session} =
      Fyrlet.Auth.issue_session(project.service_key, %{"external_subject" => "alice"})

    {:ok, actor} = Fyrlet.Auth.authenticate(session["token"], project.project.id)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)

      for k <- [:allowed_hosts, :allow_http, :timeout_ms],
          do: Application.delete_env(:fyrlet_effect_http, k)

      Application.delete_env(:fyrlet, :effects)
    end)

    %{actor: actor}
  end

  defp start(actor, nodes, flow \\ "f1"),
    do:
      Fyrlet.Runtime.call(
        actor,
        "flow.start",
        %{"flow_id" => flow, "nodes" => nodes},
        "k-" <> flow <> inspect(:erlang.phash2(nodes)),
        capabilities: %{"runs" => 1}
      )

  defp http(name, body \\ "{}"),
    do: %{
      "type" => "http",
      "name" => name,
      "url" => Application.get_env(:flow_example, :url),
      "body" => body
    }

  defp wait(name, signal, extra \\ %{}),
    do:
      Map.merge(
        %{"type" => "wait", "name" => name, "signal" => signal, "timeout_seconds" => 60},
        extra
      )

  defp pump(id), do: Testing.drive(id, effects: true)

  test "http, wait for an event, http", %{actor: actor} do
    {:ok, %{"run_id" => id}} =
      start(actor, [
        http("first", ~s({"n":1})),
        wait("approval", "go"),
        http("second", ~s({"n":2}))
      ])

    assert pump(id) == "waiting"
    assert_received {:called, [_], ~s({"n":1})}
    refute_received {:called, _, _}

    wait_id = Testing.wait_step(id).id

    assert {:ok, %{"status" => "consumed"}} =
             Runs.signal(actor, id, %{
               "wait_id" => wait_id,
               "name" => "ngo",
               "idempotency_key" => "s1"
             })

    assert pump(id) == "completed"
    assert_received {:called, [_], ~s({"n":2})}
    assert {:ok, %{"steps" => steps, "effects" => effects}} = Runs.get(actor, id)
    assert Enum.map(steps, & &1["status"]) == ["succeeded", "satisfied", "succeeded"]
    assert Enum.all?(effects, &(&1["status"] == "succeeded"))
  end

  test "a wait that times out can continue the flow", %{actor: actor} do
    {:ok, %{"run_id" => id}} =
      start(actor, [wait("optional", "never", %{"continue_on_timeout" => true}), http("after")])

    assert pump(id) == "waiting"
    Testing.expire_wait(id)
    assert pump(id) == "completed"
    assert_received {:called, _, _}
  end

  test "a refused call fails the flow and later nodes never run", %{actor: actor} do
    Application.put_env(:flow_example, :status, 422)
    {:ok, %{"run_id" => id}} = start(actor, [http("bad"), http("never")])
    assert pump(id) == "failed"
    assert_received {:called, _, _}
    refute_received {:called, _, _}
  end

  test "a flow can be cancelled while waiting, and a finished flow id can be run again", %{
    actor: actor
  } do
    {:ok, %{"run_id" => id}} = start(actor, [wait("hold", "x")], "f2")
    pump(id)

    assert {:error, %Fyrlet.Error{code: "CONFLICT"}} =
             Fyrlet.Runtime.call(
               actor,
               "flow.start",
               %{"flow_id" => "f2", "nodes" => [wait("hold", "y")]},
               "other-key",
               capabilities: %{"runs" => 1}
             )

    assert {:ok, %{"status" => "cancelled"}} = Runs.cancel(actor, id)

    assert {:ok, %{"run_id" => again, "existing" => false}} =
             Fyrlet.Runtime.call(
               actor,
               "flow.start",
               %{"flow_id" => "f2", "nodes" => [wait("hold", "y")]},
               "third-key",
               capabilities: %{"runs" => 1}
             )

    assert again != id
  end

  test "malformed nodes are rejected before anything is stored", %{actor: actor} do
    assert {:error, %Fyrlet.Error{code: "VALIDATION_FAILED"}} =
             start(actor, [%{"type" => "http", "name" => "nourl"}], "bad1")

    assert {:error, %Fyrlet.Error{code: "VALIDATION_FAILED"}} =
             start(actor, [%{"type" => "wait", "name" => "nosignal"}], "bad2")

    assert {:error, %Fyrlet.Error{code: "VALIDATION_FAILED"}} =
             start(actor, [%{"type" => "shell", "name" => "x"}], "bad3")

    assert {:error, %Fyrlet.Error{code: "VALIDATION_FAILED"}} =
             start(actor, [], "bad4")

    for body <- ["{", "[]", "null", "42"] do
      assert {:error, %Fyrlet.Error{code: "VALIDATION_FAILED"}} =
               start(actor, [http("invalid", body)], "bad-body-" <> body)

      assert {:error, %Fyrlet.Error{code: "VALIDATION_FAILED"}} =
               Fyrlet.Runtime.call(
                 actor,
                 "flow.save",
                 %{"flow_id" => "invalid", "nodes" => [http("invalid", body)]},
                 "save-bad-" <> body
               )
    end

    assert Testing.run_count() == 0
  end
end
