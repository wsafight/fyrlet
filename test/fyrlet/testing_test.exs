defmodule Fyrlet.TestingTest do
  use Fyrlet.RunsCase

  alias Fyrlet.Testing

  setup do
    %{alice: Testing.user(Testing.project())}
  end

  test "fixtures produce usable credentials with distinct projects and stable subject identity" do
    first = Testing.project()
    second = Testing.project()
    alice = Testing.user(first)
    renewed = Testing.user(first, "alice")
    other = Testing.user(second, "alice")

    assert first.project.id != second.project.id
    assert first.service_key != second.service_key
    assert alice.actor.project_id == first.project.id
    assert alice.actor.subject_id == renewed.actor.subject_id
    assert alice.actor.session_id != renewed.actor.session_id
    assert alice.actor.subject_id != other.actor.subject_id
    assert alice.token == alice.session["token"]
    assert {:ok, actor} = Auth.authenticate(alice.token, first.project.id)
    assert actor == alice.actor
  end

  test "snapshots apply input defaults and return only the actor's records", %{alice: alice} do
    assert {:ok, record} = add(alice.actor, "visible")
    assert {:ok, _} = add(Testing.user(Testing.project()).actor, "other project")

    assert {:ok, [^record]} = Testing.snapshot(alice.actor, "records.recent")
    assert {:ok, [^record]} = Testing.snapshot(alice.actor, "records.recent", %{"limit" => 1})
  end

  test "snapshot preparation propagates authorization and validation errors", %{alice: alice} do
    assert {:error, %Error{code: "NOT_FOUND"}} = Testing.snapshot(alice.actor, "missing")
    assert {:error, %Error{code: "FORBIDDEN"}} = Testing.snapshot(alice.actor, "test.denied_sub")

    assert {:error, %Error{code: "VALIDATION_FAILED"}} =
             Testing.snapshot(alice.actor, "records.recent", %{"limit" => 0})

    assert {:ok, _} = Auth.revoke_own_session(alice.actor)

    assert {:error, %Error{code: "UNAUTHENTICATED"}} =
             Testing.snapshot(alice.actor, "records.recent")
  end

  test "run lookup and counts reflect persisted runs", %{alice: alice} do
    assert Testing.run_count() == 0
    id = start_run!(alice)
    assert %Run{id: ^id, status: "pending"} = Testing.run(id)
    assert Testing.run_count() == 1
    assert_raise Ecto.NoResultsError, fn -> Testing.run(Ecto.UUID.generate()) end
  end

  test "step advances only one node and drive stops at a signal wait", %{alice: alice} do
    id = start_run!(alice)
    assert Testing.wait_step(id).name == "approval"
    Testing.step(id)

    assert step_statuses(id) == [
             {"prepare", "succeeded"},
             {"approval", "pending"},
             {"publish", "pending"}
           ]

    assert Testing.drive(id) == "waiting"
    assert Testing.wait_step(id).status == "waiting"
    version = Testing.run(id).version
    assert Testing.drive(id) == "waiting"
    assert Testing.run(id).version == version
  end

  test "drive accepts integer and keyword limits without running additional nodes", %{
    alice: alice
  } do
    first = start_run!(alice)
    second = start_run!(alice)
    assert Testing.drive(first, 1) == "running"
    assert Testing.drive(second, limit: 1) == "running"
    assert step_statuses(first) == step_statuses(second)
    assert Testing.wait_step(first).status == "pending"
    assert Testing.drive(first) == "waiting"
  end

  test "drive leaves terminal runs unchanged", %{alice: alice} do
    id = start_run!(alice)
    assert {:ok, _} = Runs.cancel(alice.actor, id)
    before = Testing.run(id)
    assert Testing.drive(id) == "cancelled"
    assert Testing.run(id) == before
    assert Testing.effects(id) == []
  end

  test "expiring a wait applies its configured timeout", %{alice: alice} do
    id = start_run!(alice)
    assert Testing.drive(id) == "waiting"
    Testing.expire_wait(id)
    assert Testing.run(id).status == "failed"
    assert Testing.run(id).error["code"] == "WAIT_TIMEOUT"
    assert DateTime.compare(Testing.wait_step(id).wait_deadline, Auth.now()) == :lt
  end

  test "lease expiration is scoped to one run and recovery repairs it", %{alice: alice} do
    id = start_run!(alice)
    sibling = start_run!(alice)
    assert {:execute, _} = Engine.claim(id)
    assert {:execute, _} = Engine.claim(sibling)
    [sibling_attempt] = attempts(sibling)

    Testing.expire_leases(id)
    assert DateTime.compare(hd(attempts(id)).lease_expires_at, Auth.now()) == :lt
    assert attempts(sibling) == [sibling_attempt]
    assert Testing.recover().expired_leases == 1
    assert Testing.drive(id) == "waiting"
    assert length(attempts(id)) == 2
    assert hd(attempts(id)).status == "abandoned"
  end

  test "drive dispatches effects only when requested and resumes the run", %{alice: alice} do
    Application.put_env(:fyrlet, :run_plans, %{
      "runs.demo" => fn _, _ -> {:ok, steps: [%{type: :step, name: "send", input: %{}}]} end
    })

    Application.put_env(:fyrlet, :run_steps, %{
      "send" => fn _, _ -> {:effect, %{adapter: "idem", key: "mail", payload: %{}}} end
    })

    id = start_run!(alice)
    assert Testing.wait_step(id) == nil
    assert Testing.drive(id) == "waiting"
    assert [%{run_id: ^id, status: "pending"}] = Testing.effects(id)
    assert Testing.drive(id, effects: true) == "completed"
    assert [%{run_id: ^id, status: "succeeded", result: %{"sent" => true}}] = Testing.effects(id)
  end
end
