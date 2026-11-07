defmodule InboxExample.DomainTest do
  use InboxExample.DataCase, async: true

  setup do
    %{alice: user(project())}
  end

  test "optimistic updates, archive and delete change the bounded list", %{alice: alice} do
    {:ok, item} = add(alice.actor)

    {:ok, updated} =
      Runtime.call(
        alice.actor,
        "inbox.update",
        %{"id" => item["id"], "expected_version" => 1, "text" => "edited"},
        "update"
      )

    assert updated["version"] == 2

    assert {:error, %Error{code: "CONFLICT"}} =
             Runtime.call(
               alice.actor,
               "inbox.archive",
               %{"id" => item["id"], "expected_version" => 1},
               "stale"
             )

    assert {:ok, %{"archived" => true, "version" => 3}} =
             Runtime.call(
               alice.actor,
               "inbox.archive",
               %{"id" => item["id"], "expected_version" => 2},
               "archive"
             )

    assert {:ok, %{"items" => []}} = Runtime.call(alice.actor, "inbox.history", %{})

    assert {:ok, %{"items" => [_item]}} =
             Runtime.call(alice.actor, "inbox.history", %{"include_archived" => true})

    assert {:ok, %{"deleted" => true}} =
             Runtime.call(
               alice.actor,
               "inbox.delete",
               %{"id" => item["id"], "expected_version" => 3},
               "delete"
             )

    assert Repo.aggregate(InboxItem, :count) == 0
  end

  test "keyset history has no duplicate records even with identical timestamps", %{alice: alice} do
    for index <- 1..5, do: add(alice.actor, "item #{index}")
    time = Auth.now()
    Repo.update_all(InboxItem, set: [inserted_at: time])
    {:ok, first} = Runtime.call(alice.actor, "inbox.history", %{"limit" => 2})

    {:ok, second} =
      Runtime.call(alice.actor, "inbox.history", %{"limit" => 2, "cursor" => first["next_cursor"]})

    {:ok, third} =
      Runtime.call(alice.actor, "inbox.history", %{
        "limit" => 2,
        "cursor" => second["next_cursor"]
      })

    identifiers = Enum.map(first["items"] ++ second["items"] ++ third["items"], & &1["id"])
    assert length(Enum.uniq(identifiers)) == 5
    assert third["next_cursor"] == nil

    assert {:error, %Error{code: "VALIDATION_FAILED"}} =
             Runtime.call(alice.actor, "inbox.history", %{"cursor" => "invalid"})

    malformed =
      Jason.encode!(%{"time" => 123, "id" => Ecto.UUID.generate()})
      |> Base.url_encode64(padding: false)

    assert {:error, %Error{code: "VALIDATION_FAILED"}} =
             Runtime.call(alice.actor, "inbox.history", %{"cursor" => malformed})
  end
end
