defmodule AgentExampleTest do
  use ExUnit.Case, async: false
  alias Fyrlet.{Runtime, Runs, Testing}

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Fyrlet.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    project = Testing.project()
    %{alice: Testing.user(project, "alice"), bob: Testing.user(project, "bob")}
  end

  defp start(actor, tool \\ "word_count") do
    Runtime.call(
      actor,
      "agent.start",
      %{"goal" => "review this text", "tool" => tool},
      Ecto.UUID.generate(),
      capabilities: %{"runs" => 1}
    )
  end

  test "only the owner approves the result, and rejection remains a business result", %{
    alice: alice,
    bob: bob
  } do
    for approved <- [true, false] do
      {:ok, %{"run_id" => id}} = start(alice.actor)
      assert Testing.drive(id) == "waiting"
      wait = Testing.wait_step(id)

      signal = %{
        "wait_id" => wait.id,
        "name" => "approval",
        "payload" => %{"approved" => approved},
        "idempotency_key" => Ecto.UUID.generate()
      }

      assert {:error, %Fyrlet.Error{code: "FORBIDDEN"}} = Runs.signal(bob.actor, id, signal)
      assert {:ok, _receipt} = Runs.signal(alice.actor, id, signal)
      assert Testing.drive(id) == "completed"
      {:ok, rows} = Testing.snapshot(alice.actor, "agent.tasks")
      assert hd(rows)["status"] == if(approved, do: "approved", else: "rejected")
      assert Jason.decode!(hd(rows)["result_json"])["words"] == 3
    end

    assert {:ok, []} = Testing.snapshot(bob.actor, "agent.tasks")
  end

  test "unknown tools refuse admission and cancellation prevents final approval", %{alice: alice} do
    assert {:error, %Fyrlet.Error{code: "VALIDATION_FAILED"}} = start(alice.actor, "shell")
    {:ok, %{"run_id" => id}} = start(alice.actor, "excerpt")
    Testing.drive(id)
    assert {:ok, _receipt} = Runs.cancel(alice.actor, id)
    assert Testing.drive(id) == "cancelled"
    assert {:ok, [%{"status" => "cancelled"}]} = Testing.snapshot(alice.actor, "agent.tasks")
  end
end
