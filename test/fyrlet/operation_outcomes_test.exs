defmodule Fyrlet.OperationOutcomesTest do
  use Fyrlet.RunsCase
  alias Fyrlet.Idempotency

  setup do
    project = project()
    %{alice: user(project, "alice"), bob: user(project, "bob")}
  end

  test "reads complete while writes commit", %{alice: alice} do
    assert {:ok, %{"outcome" => "completed", "data" => "ok"}} =
             Runtime.call_with_outcome(alice.actor, "test.echo", %{}, nil)

    assert {:ok, %{"outcome" => "committed", "data" => record}} =
             Runtime.call_with_outcome(alice.actor, "records.add", %{"text" => "saved"}, "write")

    assert record["text"] == "saved"
  end

  test "recovery returns the committed result without executing again", %{alice: alice} do
    input = %{"text" => "saved"}
    assert {:ok, receipt} = Runtime.call_with_outcome(alice.actor, "records.add", input, "write")
    assert {:ok, ^receipt} = Runtime.recover(alice.actor, "records.add", input, "write")
    assert {:ok, ^receipt} = Runtime.recover(alice.actor, "records.add", input, "write")
    assert Repo.aggregate(TestRecord, :count) == 1
    assert Repo.aggregate(Idempotency, :count) == 1
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "recovery applies the same schema defaults and canonical input hash", %{alice: alice} do
    assert {:ok, receipt} =
             Runtime.call_with_outcome(alice.actor, "records.add", %{"text" => "saved"}, "write")

    assert {:ok, ^receipt} =
             Runtime.recover(
               alice.actor,
               "records.add",
               %{"content_type" => "text", "text" => "saved"},
               "write"
             )
  end

  test "a run is accepted rather than completed and recovery creates no second run", %{
    alice: alice
  } do
    assert {:ok, %{"outcome" => "accepted", "data" => %{"run_id" => id}} = receipt} =
             Runtime.call_with_outcome(alice.actor, "runs.demo", %{}, "run", capabilities: caps())

    assert {:ok, ^receipt} =
             Runtime.recover(alice.actor, "runs.demo", %{}, "run", capabilities: caps())

    assert status(id) == "pending"
    assert Repo.aggregate(Run, :count) == 1
  end

  test "ingest is accepted and has no operation-level recovery", %{alice: alice} do
    input = %{"items" => [%{"key" => "one", "data" => %{"n" => 1, "text" => "saved"}}]}

    assert {:ok, %{"outcome" => "accepted", "data" => %{"accepted" => 1}}} =
             Runtime.call_with_outcome(alice.actor, "events.ingest", input, "batch",
               capabilities: %{"ingest" => 1}
             )

    assert {:error, %Error{code: "UNSUPPORTED_CAPABILITY"}} =
             Runtime.recover(alice.actor, "events.ingest", input, "batch",
               capabilities: %{"ingest" => 1}
             )

    assert Repo.aggregate(Fyrlet.Features.Ingest.Batch, :count) == 1
    assert Repo.aggregate(TestRecord, :count) == 0
  end

  test "an absent receipt stays unknown and creates nothing", %{alice: alice} do
    assert {:ok, %{"outcome" => "unknown", "data" => nil}} =
             Runtime.recover(alice.actor, "records.add", %{"text" => "unsent"}, "absent")

    assert Repo.aggregate(TestRecord, :count) == 0
    assert Repo.aggregate(Idempotency, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "expired receipts remain unknown without deletion or reexecution", %{alice: alice} do
    input = %{"text" => "saved"}
    assert {:ok, _receipt} = Runtime.call_with_outcome(alice.actor, "records.add", input, "write")
    Repo.update_all(Idempotency, set: [expires_at: DateTime.add(Auth.now(), -1, :second)])

    assert {:ok, %{"outcome" => "unknown"}} =
             Runtime.recover(alice.actor, "records.add", input, "write")

    assert Repo.aggregate(Idempotency, :count) == 1
    assert Repo.aggregate(TestRecord, :count) == 1
  end

  test "different input conflicts without changing the original result", %{alice: alice} do
    assert {:ok, _receipt} =
             Runtime.call_with_outcome(alice.actor, "records.add", %{"text" => "saved"}, "write")

    assert {:error, %Error{code: "CONFLICT"}} =
             Runtime.recover(alice.actor, "records.add", %{"text" => "changed"}, "write")

    assert Repo.aggregate(TestRecord, :count) == 1
  end

  test "receipts are isolated by project, subject and operation", %{alice: alice, bob: bob} do
    input = %{"text" => "secret"}
    assert {:ok, _receipt} = Runtime.call_with_outcome(alice.actor, "records.add", input, "write")
    stranger = user(project(), "alice")

    for actor <- [bob.actor, stranger.actor] do
      assert {:ok, %{"outcome" => "unknown"}} =
               Runtime.recover(actor, "records.add", input, "write")
    end

    assert {:ok, %{"outcome" => "unknown"}} =
             Runtime.recover(alice.actor, "test.public_write", %{}, "write")
  end

  test "revoked sessions cannot recover stored results", %{alice: alice} do
    input = %{"text" => "secret"}
    assert {:ok, _receipt} = Runtime.call_with_outcome(alice.actor, "records.add", input, "write")
    assert {:ok, _revoked} = Auth.revoke_own_session(alice.actor)

    assert {:error, %Error{code: "UNAUTHENTICATED"}} =
             Runtime.recover(alice.actor, "records.add", input, "write")
  end

  test "current business authorization is required", %{alice: alice} do
    Repo.insert!(%Idempotency{
      project_id: alice.actor.project_id,
      subject_id: alice.actor.subject_id,
      operation: "test.denied",
      key: "write",
      input_hash: Auth.hash("{}"),
      result: %{"data" => "secret"},
      expires_at: DateTime.add(Auth.now(), 60, :second)
    })

    assert {:error, %Error{code: "FORBIDDEN"}} =
             Runtime.recover(alice.actor, "test.denied", %{}, "write")
  end

  test "read operations and unnegotiated run recovery are refused", %{alice: alice} do
    assert {:error, %Error{code: "UNSUPPORTED_CAPABILITY"}} =
             Runtime.recover(alice.actor, "test.echo", %{}, "read")

    assert {:error, %Error{code: "UNSUPPORTED_CAPABILITY"}} =
             Runtime.recover(alice.actor, "runs.demo", %{}, "run")
  end

  test "invalid keys and inputs never execute business code", %{alice: alice} do
    for key <- [nil, "", String.duplicate("a", 201), 123] do
      assert {:error, %Error{code: "VALIDATION_FAILED"}} =
               Runtime.recover(alice.actor, "records.add", %{"text" => "saved"}, key)
    end

    assert {:error, %Error{code: "VALIDATION_FAILED"}} =
             Runtime.recover(alice.actor, "records.add", %{}, "write")

    assert Repo.aggregate(TestRecord, :count) == 0
  end

  test "rolled-back writes have no recoverable receipt", %{alice: alice} do
    assert {:error, %Error{code: "INTERNAL_ERROR"}} =
             Runtime.call_with_outcome(alice.actor, "test.bad_output", %{}, "bad")

    assert {:ok, %{"outcome" => "unknown"}} =
             Runtime.recover(alice.actor, "test.bad_output", %{}, "bad")

    assert Repo.aggregate(TestRecord, :count) == 0
  end
end
