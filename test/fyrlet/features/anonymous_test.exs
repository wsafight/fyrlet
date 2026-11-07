defmodule Fyrlet.AnonymousTest do
  use Fyrlet.RunsCase
  import Phoenix.ChannelTest, except: [join: 2]
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]
  @endpoint FyrletWeb.Endpoint

  setup do
    Process.flag(:trap_exit, true)
    project = project()

    Application.put_env(:fyrlet, :anonymous, %{
      project.project.id => %{ttl: 600, per_minute: 5, max_active: 4}
    })

    on_exit(fn -> Application.delete_env(:fyrlet, :anonymous) end)
    {:ok, session} = Fyrlet.Features.Anonymous.issue(project.project.id)
    {:ok, actor} = Fyrlet.Auth.authenticate(session["token"], project.project.id)
    %{project: project, alice: user(project, "alice"), session: session, anon: actor}
  end

  defp join_as(actor, name, options) do
    socket(FyrletWeb.UserSocket, "sessions:" <> actor.session_id, %{actor: actor})
    |> subscribe_and_join(
      "subscription:" <> Ecto.UUID.generate(),
      Map.merge(%{"name" => name, "params" => %{}}, options)
    )
  end

  @anonymous_read %{"protocol_version" => 1, "capabilities" => %{"anonymous_read" => 1}}

  test "an anonymous session is a fresh, restricted, short-lived subject", %{
    session: session,
    anon: anon,
    project: project
  } do
    assert anon.kind == "anonymous" and anon.project_id == project.project.id
    assert {:ok, other} = Fyrlet.Features.Anonymous.issue(project.project.id)
    assert other["subject_id"] != session["subject_id"]

    assert DateTime.diff(
             DateTime.from_iso8601(session["expires_at"]) |> elem(1),
             DateTime.utc_now()
           ) in 590..601

    subject = Repo.get!(Fyrlet.Subject, session["subject_id"])
    assert subject.issuer == "anonymous"
    assert Repo.get!(Fyrlet.Session, session["session_id"]).service_key_id == nil
  end

  test "users keep kind user and cannot become anonymous by any input", %{
    alice: alice,
    project: project
  } do
    assert alice.actor.kind == "user"

    assert {:error, %Error{code: "VALIDATION_FAILED"}} =
             Fyrlet.Auth.issue_session(project.service_key, %{
               "external_subject" => "x",
               "kind" => "anonymous"
             })

    # The issuer name belongs to the public entry; a backend cannot take it.
    assert {:error, %Error{code: "VALIDATION_FAILED", message: message}} =
             Fyrlet.Auth.issue_session(project.service_key, %{
               "external_subject" => "x",
               "issuer" => "anonymous"
             })

    assert message =~ "reserved"
  end

  test "it reads only what the contract marks public", %{anon: anon} do
    assert {:ok, "public:anonymous"} = Fyrlet.Runtime.call(anon, "test.public_read", %{})

    for name <- ["test.echo", "test.public_write", "test.revoke", "inbox.history", "inbox.add"] do
      assert {:error, %Error{code: "FORBIDDEN"}} = Fyrlet.Runtime.call(anon, name, %{}, key()),
             name
    end

    assert {:ok, _} = Fyrlet.Runtime.prepare_subscription(anon, "test.public_feed", %{})

    for name <- ["test.private_feed", "inbox.recent", "fyrlet.runs.recent"] do
      assert {:error, %Error{code: "FORBIDDEN"}} =
               Fyrlet.Runtime.prepare_subscription(anon, name, %{}),
             name
    end

    # The same private reads work for a real user.
    assert {:ok, _} =
             Fyrlet.Runtime.prepare_subscription(
               user(project(), "u").actor,
               "test.private_feed",
               %{}
             )
  end

  test "it cannot start, view, signal or cancel runs", %{anon: anon, alice: alice} do
    id = start_run!(alice)

    assert {:error, %Error{code: "FORBIDDEN"}} =
             Fyrlet.Runtime.call(anon, "runs.demo", %{}, key(), capabilities: caps())

    assert {:error, %Error{code: "FORBIDDEN"}} = Runs.get(anon, id)
    assert {:error, %Error{code: "FORBIDDEN"}} = Runs.cancel(anon, id)

    assert {:error, %Error{code: "FORBIDDEN"}} =
             Runs.signal(anon, id, %{
               "wait_id" => Ecto.UUID.generate(),
               "name" => "x",
               "idempotency_key" => "k"
             })

    assert status(id) == "pending"
  end

  test "it connects only as a v2 client that negotiated anonymous_read", %{anon: anon} do
    assert {:ok, snapshot, socket} = join_as(anon, "test.public_feed", @anonymous_read)
    assert snapshot["data"] == "feed" and snapshot["capabilities"] == %{"anonymous_read" => 1}
    leave(socket)

    for options <- [
          %{"protocol_version" => 1},
          %{"protocol_version" => 1, "capabilities" => %{"other" => 1}}
        ] do
      assert {:error, %{"error" => %{"code" => "UNSUPPORTED_CAPABILITY"}}} =
               join_as(anon, "test.public_feed", options)
    end

    assert {:error, %{"error" => %{"code" => "FORBIDDEN"}}} =
             join_as(anon, "test.private_feed", @anonymous_read)

    socket = socket(FyrletWeb.UserSocket, "sessions:" <> anon.session_id, %{actor: anon})

    assert {:error, %{"error" => %{"code" => "UNSUPPORTED_CAPABILITY"}}} =
             subscribe_and_join(socket, "operations", %{"protocol_version" => 1})

    assert {:ok, _, _} = subscribe_and_join(socket, "operations", @anonymous_read)
  end

  test "it has its own, lower, subscription limit", %{anon: anon} do
    Application.put_env(:fyrlet, :anonymous_max_subscriptions, 2)
    on_exit(fn -> Application.delete_env(:fyrlet, :anonymous_max_subscriptions) end)
    socket = socket(FyrletWeb.UserSocket, "sessions:" <> anon.session_id, %{actor: anon})

    transport = spawn(fn -> Process.sleep(:infinity) end)
    socket = %{socket | transport_pid: transport}

    join = fn ->
      subscribe_and_join(
        socket,
        "subscription:" <> Ecto.UUID.generate(),
        Map.merge(%{"name" => "test.public_feed", "params" => %{}}, @anonymous_read)
      )
    end

    assert {:ok, _, _} = join.()
    assert {:ok, _, _} = join.()
    assert {:error, %{"error" => %{"code" => "LIMIT_EXCEEDED"}}} = join.()
  end

  test "an expired or revoked anonymous session stops working", %{anon: anon, session: session} do
    Repo.update_all(from(s in Fyrlet.Session, where: s.id == ^session["session_id"]),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert {:error, %Error{code: "UNAUTHENTICATED"}} =
             Fyrlet.Runtime.call(anon, "test.public_read", %{})

    assert {:error, %Error{code: "UNAUTHENTICATED"}} =
             Fyrlet.Auth.authenticate(session["token"], anon.project_id)
  end

  test "issuing is limited per minute and by total active sessions", %{project: project} do
    id = project.project.id
    Application.put_env(:fyrlet, :anonymous, %{id => %{per_minute: 100, max_active: 3}})
    for _ <- 1..2, do: assert({:ok, _} = Fyrlet.Features.Anonymous.issue(id))

    assert {:error, %Error{code: "LIMIT_EXCEEDED", retryable: true}} =
             Fyrlet.Features.Anonymous.issue(id)

    Application.put_env(:fyrlet, :anonymous, %{id => %{per_minute: 3, max_active: 1000}})
    assert {:error, %Error{code: "LIMIT_EXCEEDED"}} = Fyrlet.Features.Anonymous.issue(id)
  end

  test "the public entry is off unless the project enables it and the capability is on", %{
    project: project
  } do
    other = project()
    assert {:error, %Error{code: "NOT_FOUND"}} = Fyrlet.Features.Anonymous.issue(other.project.id)
    assert {:error, %Error{code: "NOT_FOUND"}} = Fyrlet.Features.Anonymous.issue("not-a-uuid")
    assert {:error, %Error{code: "NOT_FOUND"}} = Fyrlet.Features.Anonymous.issue(nil)

    previous = Application.fetch_env!(:fyrlet, :capabilities)
    Application.put_env(:fyrlet, :capabilities, Map.delete(previous, "anonymous_read"))
    on_exit(fn -> Application.put_env(:fyrlet, :capabilities, previous) end)

    assert {:error, %Error{code: "NOT_FOUND"}} =
             Fyrlet.Features.Anonymous.issue(project.project.id)
  end

  test "over HTTP: sessions are issued without credentials, the contract stays closed", %{
    project: project
  } do
    issued =
      build_conn()
      |> post("/api/v1/anonymous/sessions", %{"project_id" => project.project.id})
      |> json_response(200)

    token = issued["data"]["token"]

    api = fn ->
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("x-project-id", project.project.id)
    end

    assert json_response(api.() |> get("/api/v1/contract"), 403)["error"]["code"] == "FORBIDDEN"

    assert json_response(
             api.()
             |> put_req_header("idempotency-key", "k")
             |> post("/api/v1/operations/test.public_write", %{"input" => %{}}),
             403
           )["error"]["code"] == "FORBIDDEN"

    assert json_response(
             api.()
             |> put_req_header("idempotency-key", "k")
             |> post("/api/v1/operations/test.public_read", %{"input" => %{}}),
             200
           )["data"] == "public:anonymous"

    assert json_response(
             build_conn()
             |> post("/api/v1/anonymous/sessions", %{"project_id" => project().project.id}),
             404
           )

    assert json_response(build_conn() |> post("/api/v1/anonymous/sessions", %{}), 404)
  end

  test "business authorize still decides, and sees the caller is anonymous", %{anon: anon} do
    assert anon.kind == "anonymous"

    assert {:error, %Error{code: "FORBIDDEN"}} =
             Fyrlet.Runtime.prepare_subscription(anon, "test.denied_sub", %{})
  end

  test "expired anonymous subjects are cleaned up and active ones kept", %{
    project: project,
    session: session
  } do
    long_ago = DateTime.add(DateTime.utc_now(), -3 * 86_400, :second)
    {:ok, old} = Fyrlet.Features.Anonymous.issue(project.project.id)

    Repo.update_all(from(s in Fyrlet.Session, where: s.id == ^old["session_id"]),
      set: [expires_at: long_ago]
    )

    assert {1, _} =
             Fyrlet.Features.Anonymous.prune(DateTime.add(DateTime.utc_now(), -86_400, :second))

    assert Repo.get(Fyrlet.Subject, old["subject_id"]) == nil
    assert Repo.get(Fyrlet.Subject, session["subject_id"])
    assert Repo.get(Fyrlet.Subject, user(project, "keep").actor.subject_id)
  end
end
