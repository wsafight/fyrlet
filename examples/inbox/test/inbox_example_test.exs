defmodule InboxExampleTest do
  @moduledoc """
  Acceptance for a host application: a separate Mix project that depends on Fyrlet
  through its public entry points only (config, migrations, Definition behaviour,
  Fyrlet.Auth / Fyrlet.Runtime, the HTTP endpoint and the exported contract).
  """
  use ExUnit.Case, async: false
  import Plug.Test, only: [conn: 2, conn: 3]
  import Plug.Conn

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Fyrlet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    {:ok, project} = Fyrlet.Auth.create_project("example")

    {:ok, session} =
      Fyrlet.Auth.issue_session(project.service_key, %{"external_subject" => "alice"})

    {:ok, actor} = Fyrlet.Auth.authenticate(session["token"], project.project.id)
    %{project: project, session: session, actor: actor}
  end

  test "Fyrlet is running as a dependency with this application's definition" do
    assert Application.fetch_env!(:fyrlet, :definitions) == [InboxExample.Inbox]
    assert Fyrlet.Migrator.paths() |> length() == 2
    assert %{"operations" => operations} = Fyrlet.Registry.export()
    assert Map.has_key?(operations, "inbox.add")
  end

  test "a write is validated, idempotent and visible through the subscription", %{actor: actor} do
    input = %{"text" => "hello", "content_type" => "text"}

    assert {:ok, %{"text" => "hello", "version" => 1} = item} =
             Fyrlet.Runtime.call(actor, "inbox.add", input, "key-1")

    assert {:ok, ^item} = Fyrlet.Runtime.call(actor, "inbox.add", input, "key-1")

    assert {:error, %Fyrlet.Error{code: "CONFLICT"}} =
             Fyrlet.Runtime.call(actor, "inbox.add", %{"text" => "other"}, "key-1")

    assert {:ok, subscription} = Fyrlet.Runtime.prepare_subscription(actor, "inbox.recent", %{})
    assert {:ok, view} = Fyrlet.Runtime.view(actor, subscription)
    assert Fyrlet.Subscriptions.View.data(view) == [item]
    assert Fyrlet.Repo.aggregate(InboxExample.Item, :count) == 1
  end

  test "the HTTP endpoint serves the host's contract and operations", %{
    session: session,
    project: project
  } do
    health = conn(:get, "/health") |> FyrletWeb.Endpoint.call([])
    assert health.status == 200

    authorized = fn conn ->
      conn
      |> put_req_header("authorization", "Bearer " <> session["token"])
      |> put_req_header("x-project-id", project.project.id)
    end

    contract = conn(:get, "/api/v1/contract") |> authorized.() |> FyrletWeb.Endpoint.call([])
    assert contract.status == 200
    assert %{"data" => %{"protocol_version" => 1}} = Jason.decode!(contract.resp_body)

    call =
      conn(:post, "/api/v1/operations/inbox.add", Jason.encode!(%{"input" => %{"text" => "x"}}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("idempotency-key", "http-1")
      |> authorized.()
      |> FyrletWeb.Endpoint.call([])

    assert call.status == 200
    assert %{"data" => %{"text" => "x"}} = Jason.decode!(call.resp_body)
  end
end
