defmodule Fyrlet.RuntimeTest do
  use Fyrlet.DataCase, async: true
  use Oban.Testing, repo: Fyrlet.Repo

  setup do
    project = project()
    %{project: project, alice: user(project), bob: user(project, "bob")}
  end

  test "write, idempotent replay, defaults and durable notification commit together", %{
    alice: alice
  } do
    key = Ecto.UUID.generate()
    assert {:ok, item} = Runtime.call(alice.actor, "inbox.add", %{"text" => "hello"}, key)
    assert item["version"] == 1
    assert item["content_type"] == "text"

    assert {:ok, ^item} =
             Runtime.call(
               alice.actor,
               "inbox.add",
               %{"content_type" => "text", "text" => "hello"},
               key
             )

    assert Repo.aggregate(InboxItem, :count) == 1
    assert Repo.aggregate(Fyrlet.Idempotency, :count) == 1

    assert_enqueued worker: Fyrlet.InvalidationWorker,
                    args: %{project_id: alice.actor.project_id}

    assert Repo.aggregate(Oban.Job, :count) == 1

    assert {:error, %Error{code: "CONFLICT"}} =
             Runtime.call(alice.actor, "inbox.add", %{"text" => "different"}, key)
  end

  test "missing keys, schema violations, unknown operations and denied operations have no writes",
       %{alice: alice} do
    assert {:error, %Error{code: "VALIDATION_FAILED"}} =
             Runtime.call(alice.actor, "inbox.add", %{"text" => "hello"})

    for input <- [
          %{},
          %{"text" => ""},
          %{"text" => "hello", "subject_id" => alice.actor.subject_id}
        ] do
      assert {:error, %Error{code: "VALIDATION_FAILED"}} =
               Runtime.call(alice.actor, "inbox.add", input, "key")
    end

    assert {:error, %Error{code: "NOT_FOUND"}} = Runtime.call(alice.actor, "unknown.op", %{})

    assert {:error, %Error{code: "FORBIDDEN"}} =
             Runtime.call(alice.actor, "test.denied", %{}, "denied")

    assert Repo.aggregate(InboxItem, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "output validation rolls back business changes, idempotency and outbox", %{alice: alice} do
    assert {:error, %Error{code: "INTERNAL_ERROR"}} =
             Runtime.call(alice.actor, "test.bad_output", %{}, "bad")

    assert Repo.aggregate(InboxItem, :count) == 0
    assert Repo.aggregate(Fyrlet.Idempotency, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "project and subject filters protect reads, mutations and snapshots", %{
    project: project,
    alice: alice,
    bob: bob
  } do
    other = user(project())
    {:ok, item} = add(alice.actor)
    {:ok, _item} = add(bob.actor, "private bob")
    {:ok, _item} = add(other.actor, "other project")
    {:ok, result} = Runtime.call(alice.actor, "inbox.history", %{})
    assert result["items"] == [item]
    {:ok, subscription} = Runtime.prepare_subscription(alice.actor, "inbox.recent", %{})
    assert {:ok, [^item]} = Runtime.snapshot(alice.actor, subscription)
    refute subscription.scope == Fyrlet.Example.Inbox.scope("inbox.recent", bob.actor, %{})
    assert project.project.id == alice.actor.project_id

    assert {:error, %Error{code: "NOT_FOUND"}} =
             Runtime.call(
               bob.actor,
               "inbox.update",
               %{"id" => item["id"], "text" => "hacked", "expected_version" => 1},
               "foreign"
             )

    assert {:error, %Error{code: "NOT_FOUND"}} =
             Runtime.call(
               other.actor,
               "inbox.delete",
               %{"id" => item["id"], "expected_version" => 1},
               "foreign"
             )
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

  test "expired idempotency windows may execute again", %{alice: alice} do
    {:ok, first} = Runtime.call(alice.actor, "inbox.add", %{"text" => "again"}, "expired")

    Repo.update_all(Fyrlet.Idempotency,
      set: [expires_at: DateTime.add(Auth.now(), -1, :second)]
    )

    {:ok, second} = Runtime.call(alice.actor, "inbox.add", %{"text" => "again"}, "expired")
    refute first["id"] == second["id"]
  end

  test "idempotency keys are scoped by subject and operation", %{
    alice: alice,
    bob: bob
  } do
    key = "shared-key"

    assert {:ok, alice_item} = Runtime.call(alice.actor, "inbox.add", %{"text" => "a"}, key)

    assert {:ok, bob_item} =
             Runtime.call(bob.actor, "inbox.add", %{"text" => "b"}, key)

    assert {:ok, other_item} =
             Runtime.call(alice.actor, "inbox.add", %{"text" => "a"}, "another-key")

    assert length(Enum.uniq([alice_item["id"], bob_item["id"], other_item["id"]])) == 3
    assert Repo.aggregate(InboxItem, :count) == 3
    assert Repo.aggregate(Fyrlet.Idempotency, :count) == 3
  end

  test "write idempotency keys must be short non-empty strings", %{alice: alice} do
    for key <- [nil, "", String.duplicate("k", 201), :atom, 123] do
      assert {:error, %Error{code: "VALIDATION_FAILED"}} =
               Runtime.call(alice.actor, "inbox.add", %{"text" => "x"}, key)
    end

    assert Repo.aggregate(InboxItem, :count) == 0
    assert Repo.aggregate(Fyrlet.Idempotency, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "prepare_subscription normalizes parameters and scopes by the current actor", %{
    alice: alice
  } do
    assert {:ok, subscription} =
             Runtime.prepare_subscription(alice.actor, "inbox.recent", %{})

    assert subscription.name == "inbox.recent"
    assert subscription.parameters == %{"limit" => 50, "include_archived" => false}
    assert subscription.module == Fyrlet.Example.Inbox
    assert subscription.scope == Fyrlet.Example.Inbox.scope("inbox.recent", alice.actor, %{})

    assert {:error, %Error{code: "NOT_FOUND"}} =
             Runtime.prepare_subscription(alice.actor, "inbox.unknown", %{})

    for parameters <- [%{"limit" => 0}, %{"limit" => 101}, %{"unexpected" => 1}] do
      assert {:error, %Error{code: "VALIDATION_FAILED"}} =
               Runtime.prepare_subscription(alice.actor, "inbox.recent", parameters)
    end

    assert {:error, %Error{code: "FORBIDDEN"}} =
             Runtime.prepare_subscription(alice.actor, "test.denied_sub", %{})
  end

  test "snapshots revalidate the session before returning data", %{alice: alice} do
    {:ok, item} = add(alice.actor)
    assert {:ok, subscription} = Runtime.prepare_subscription(alice.actor, "inbox.recent", %{})
    assert {:ok, [^item]} = Runtime.snapshot(alice.actor, subscription)

    {:ok, _revoked} = Auth.revoke_own_session(alice.actor)

    assert {:error, %Error{code: "UNAUTHENTICATED"}} =
             Runtime.snapshot(alice.actor, subscription)
  end

  test "read operations revalidate after execution and can be revoked mid-flight", %{
    alice: alice
  } do
    assert {:ok, "ok"} = Runtime.call(alice.actor, "test.echo", %{})
    assert {:error, %Error{code: "UNAUTHENTICATED"}} = Runtime.call(alice.actor, "test.revoke", %{})
    assert {:error, %Error{code: "UNAUTHENTICATED"}} = Runtime.call(alice.actor, "test.echo", %{})
  end

  test "business exceptions are converted to INTERNAL_ERROR and rolled back", %{alice: alice} do
    assert {:error, %Error{code: "INTERNAL_ERROR"}} =
             Runtime.call(alice.actor, "test.raise", %{}, "raising")

    assert Repo.aggregate(InboxItem, :count) == 0
    assert Repo.aggregate(Fyrlet.Idempotency, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
  end
end
