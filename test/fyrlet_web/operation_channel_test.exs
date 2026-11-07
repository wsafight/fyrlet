defmodule FyrletWeb.OperationChannelTest do
  use Fyrlet.DataCase, async: false
  import Phoenix.ChannelTest
  @endpoint FyrletWeb.Endpoint

  setup do
    Process.flag(:trap_exit, true)
    project = project()
    alice = user(project)

    socket =
      socket(FyrletWeb.UserSocket, "sessions:" <> alice.actor.session_id, %{actor: alice.actor})

    {:ok, %{"protocol_version" => 1}, socket} =
      subscribe_and_join(socket, "operations", %{"protocol_version" => 1})

    %{project: project, alice: alice, socket: socket}
  end

  test "socket operations keep transactional idempotency and structured errors", %{socket: socket} do
    parameters = %{
      "name" => "records.add",
      "input" => %{"text" => "socket write"},
      "idempotency_key" => "same"
    }

    reference = push(socket, "call", parameters)
    assert_reply reference, :ok, %{"outcome" => "committed", "data" => item}
    reference = push(socket, "call", parameters)
    assert_reply reference, :ok, %{"data" => ^item}
    assert Repo.aggregate(TestRecord, :count) == 1
    assert Repo.aggregate(Oban.Job, :count) == 1
    reference = push(socket, "call", put_in(parameters, ["input", "text"], "different"))
    assert_reply reference, :error, %{"status" => 409, "error" => %{"code" => "CONFLICT"}}
    reference = push(socket, "call", Map.delete(parameters, "idempotency_key"))

    assert_reply reference, :error, %{
      "status" => 422,
      "error" => %{"code" => "VALIDATION_FAILED"}
    }

    leave(socket)
  end

  test "socket recovery returns committed or unknown without replay", %{socket: socket} do
    parameters = %{
      "name" => "records.add",
      "input" => %{"text" => "saved"},
      "idempotency_key" => "recover"
    }

    reference = push(socket, "recover", parameters)
    assert_reply reference, :ok, %{"outcome" => "unknown", "data" => nil}
    assert Repo.aggregate(TestRecord, :count) == 0
    reference = push(socket, "call", parameters)
    assert_reply reference, :ok, %{"outcome" => "committed", "data" => record}
    reference = push(socket, "recover", parameters)
    assert_reply reference, :ok, %{"outcome" => "committed", "data" => ^record}
    assert Repo.aggregate(TestRecord, :count) == 1
    reference = push(socket, "recover", put_in(parameters, ["input", "text"], "different"))
    assert_reply reference, :error, %{"status" => 409, "error" => %{"code" => "CONFLICT"}}
    leave(socket)
  end

  test "socket operations enforce ownership and revalidate credentials on each call", %{
    socket: socket,
    project: project,
    alice: alice
  } do
    bob = user(project, "bob")
    {:ok, private} = add(bob.actor)

    reference =
      push(socket, "call", %{
        "name" => "records.delete",
        "input" => %{"id" => private["id"], "expected_version" => 1},
        "idempotency_key" => "delete"
      })

    assert_reply reference, :error, %{"status" => 404, "error" => %{"code" => "NOT_FOUND"}}

    Repo.update_all(from(session in Fyrlet.Session, where: session.id == ^alice.actor.session_id),
      set: [revoked_at: Auth.now()]
    )

    reference = push(socket, "call", %{"name" => "records.list", "input" => %{}})
    assert_reply reference, :error, %{"status" => 401, "error" => %{"code" => "UNAUTHENTICATED"}}
    leave(socket)
  end

  test "expired operation channels close", %{socket: socket} do
    send(socket.channel_pid, :expired)
    assert_push "status", %{"error" => %{"code" => "UNAUTHENTICATED"}}
  end
end
