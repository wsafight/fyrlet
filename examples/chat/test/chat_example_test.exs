defmodule ChatExampleTest do
  use ExUnit.Case, async: false
  alias Fyrlet.{Runtime, Testing}

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Fyrlet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    project = Testing.project()

    %{
      alice: Testing.user(project, "alice"),
      bob: Testing.user(project, "bob"),
      outsider: Testing.user(Testing.project(), "eve")
    }
  end

  defp call(user, name, input), do: Runtime.call(user.actor, name, input, Ecto.UUID.generate())

  test "invitation, assignment, human handoff and leaving preserve membership boundaries",
       users do
    {:ok, room} = call(users.alice, "chat.create", %{"title" => "Support"})
    reference = %{"room_id" => room["id"]}
    assert {:error, %Fyrlet.Error{code: "FORBIDDEN"}} = call(users.bob, "chat.get", reference)

    assert {:error, %Fyrlet.Error{code: "NOT_FOUND"}} =
             call(users.outsider, "chat.join", %{"code" => room["code"]})

    assert {:ok, _room} = call(users.bob, "chat.join", %{"code" => room["code"]})

    assert {:ok, %{"assigned_subject_id" => assigned}} =
             call(
               users.alice,
               "chat.assign",
               Map.put(reference, "subject_id", users.bob.actor.subject_id)
             )

    assert assigned == users.bob.actor.subject_id
    assert {:ok, %{"status" => "human"}} = call(users.bob, "chat.handoff", reference)
    assert {:ok, _left} = call(users.bob, "chat.leave", reference)

    assert {:error, %Fyrlet.Error{code: "FORBIDDEN"}} =
             call(users.bob, "chat.post", Map.put(reference, "text", "forbidden"))
  end

  test "history pagination has no duplicates and closed conversations refuse writes", %{
    alice: alice
  } do
    {:ok, room} = call(alice, "chat.create", %{"title" => "History"})
    reference = %{"room_id" => room["id"]}

    for index <- 1..5,
        do: call(alice, "chat.post", Map.put(reference, "text", "message #{index}"))

    {:ok, page} = call(alice, "chat.history", Map.put(reference, "limit", 3))
    assert Enum.map(page["items"], & &1["text"]) == ["message 3", "message 4", "message 5"]

    {:ok, older} =
      call(
        alice,
        "chat.history",
        Map.merge(reference, %{"limit" => 3, "cursor" => page["next_cursor"]})
      )

    assert Enum.map(older["items"], & &1["text"]) == ["message 1", "message 2"]
    assert older["next_cursor"] == nil
    assert {:ok, _closed} = call(alice, "chat.close", reference)

    assert {:error, %Fyrlet.Error{code: "CONFLICT"}} =
             call(alice, "chat.post", Map.put(reference, "text", "late"))
  end
end
