defmodule Fyrlet.DiagnosticsTest do
  use Fyrlet.RunsCase

  alias Fyrlet.Diagnostics
  alias Fyrlet.Effects.Effect

  setup do
    previous = Map.new([:plugins, :cluster_nodes], &{&1, Application.fetch_env(:fyrlet, &1)})

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, setting} -> Application.put_env(:fyrlet, key, setting)
          :error -> Application.delete_env(:fyrlet, key)
        end
      end
    end)

    now = Auth.now()
    %{alice: user(project()), other: user(project()), now: now, cutoff: DateTime.add(now, -300)}
  end

  test "empty projects and installations report zero usage", %{
    alice: alice,
    now: now,
    cutoff: cutoff
  } do
    for scope <- [alice.actor.project_id, :all] do
      assert Diagnostics.runs(scope, now, cutoff) == %{
               "by_status" => %{},
               "stuck" => 0,
               "oldest_pending_age_seconds" => 0,
               "waits_overdue" => 0,
               "definition_unavailable" => 0
             }

      assert Diagnostics.effects(scope, now, cutoff) == %{
               "by_status" => %{},
               "unresolved" => 0,
               "overdue" => 0
             }

      assert Diagnostics.limits(scope)["projects_near_limit"] == 0
    end

    assert Diagnostics.limits(alice.actor.project_id)["pending"] == 0
    assert Diagnostics.limits(alice.actor.project_id)["concurrent"] == 0
    refute Map.has_key?(Diagnostics.limits(:all), "pending")
  end

  test "run aggregates isolate projects and combine them only for installation operators",
       context do
    %{alice: alice, other: other, now: now, cutoff: cutoff} = context
    new_run(alice, status: "pending", inserted_at: DateTime.add(now, -120))
    new_run(alice, status: "completed")
    new_run(other, status: "pending", inserted_at: DateTime.add(now, -600))
    new_run(other, status: "failed")

    own = Diagnostics.runs(alice.actor.project_id, now, cutoff)
    assert own["by_status"] == %{"pending" => 1, "completed" => 1}
    assert own["oldest_pending_age_seconds"] == 120

    all = Diagnostics.runs(:all, now, cutoff)
    assert all["by_status"] == %{"pending" => 2, "completed" => 1, "failed" => 1}
    assert all["oldest_pending_age_seconds"] == 600
  end

  test "only active runs strictly older than the cutoff count as stuck", context do
    %{alice: alice, other: other, now: now, cutoff: cutoff} = context
    past = DateTime.add(cutoff, -1)

    for status <- ~w(pending running waiting cancelling),
        do: new_run(alice, status: status, updated_at: past)

    for status <- ~w(completed failed cancelled expired),
        do: new_run(alice, status: status, updated_at: past)

    new_run(alice, updated_at: cutoff)
    new_run(other, updated_at: past)

    assert Diagnostics.runs(alice.actor.project_id, now, cutoff)["stuck"] == 4
    assert Diagnostics.runs(:all, now, cutoff)["stuck"] == 5
  end

  test "overdue waits require a current waiting step in a waiting run", context do
    %{alice: alice, other: other, now: now, cutoff: cutoff} = context
    waiting_run(alice, now)
    waiting_run(alice, DateTime.add(now, -1))
    waiting_run(alice, DateTime.add(now, 1))
    waiting_run(other, DateTime.add(now, -1))
    inactive = waiting_run(alice, DateTime.add(now, -1))
    set_run(inactive, status: "completed")
    previous_step = waiting_run(alice, DateTime.add(now, -1))
    set_run(previous_step, current_step_seq: 2)

    assert Diagnostics.runs(alice.actor.project_id, now, cutoff)["waits_overdue"] == 2
    assert Diagnostics.runs(:all, now, cutoff)["waits_overdue"] == 3
  end

  test "definition availability counts only runs paused for a missing definition", context do
    %{alice: alice, other: other, now: now, cutoff: cutoff} = context
    new_run(alice, status: "waiting", wait_reason: "definition_unavailable")
    new_run(alice, status: "waiting", wait_reason: "signal")
    new_run(alice, status: "failed", wait_reason: "definition_unavailable")
    new_run(other, status: "waiting", wait_reason: "definition_unavailable")

    assert Diagnostics.runs(alice.actor.project_id, now, cutoff)["definition_unavailable"] == 1
    assert Diagnostics.runs(:all, now, cutoff)["definition_unavailable"] == 2
  end

  describe "effect aggregates" do
    setup do
      Application.put_env(:fyrlet, :run_plans, %{
        "runs.demo" => fn _, _ -> {:ok, steps: [%{type: :step, name: "send", input: %{}}]} end
      })

      Application.put_env(:fyrlet, :run_steps, %{
        "send" => fn _, _ ->
          {:effect, %{adapter: "idem", key: "mail", payload: %{"secret" => "private"}}}
        end
      })

      :ok
    end

    test "unresolved effects are scoped and an unknown effect is counted only once", context do
      %{alice: alice, other: other, now: now, cutoff: cutoff} = context
      effect(alice, status: "unknown", resolution_required: true)
      effect(alice, status: "accepted", resolution_required: true)
      effect(alice, status: "succeeded")
      effect(other, status: "unknown")

      own = Diagnostics.effects(alice.actor.project_id, now, cutoff)
      assert own["by_status"] == %{"unknown" => 1, "accepted" => 1, "succeeded" => 1}
      assert own["unresolved"] == 2
      assert Diagnostics.effects(:all, now, cutoff)["unresolved"] == 3
      refute Jason.encode!(own) =~ "private"
    end

    test "overdue effects exclude exact cutoffs, future work and finished deliveries", context do
      %{alice: alice, other: other, now: now, cutoff: cutoff} = context
      effect(alice, next_attempt_at: DateTime.add(cutoff, -1))
      effect(alice, status: "claimed", lease_expires_at: DateTime.add(now, -1))
      effect(alice, next_attempt_at: cutoff)
      effect(alice, next_attempt_at: DateTime.add(now, 60))
      effect(alice, status: "claimed", lease_expires_at: now)
      effect(alice, status: "claimed", lease_expires_at: nil)
      effect(alice, status: "succeeded", next_attempt_at: DateTime.add(cutoff, -1))
      effect(other, next_attempt_at: DateTime.add(cutoff, -1))

      assert Diagnostics.effects(alice.actor.project_id, now, cutoff)["overdue"] == 2
      assert Diagnostics.effects(:all, now, cutoff)["overdue"] == 3
    end
  end

  test "pending and concurrent limits include the eighty percent boundary per project", context do
    %{alice: alice, other: other} = context
    put_runs(max_pending_per_project: 5, max_concurrent_per_project: 5)

    for _index <- 1..4, do: new_run(alice, status: "pending")
    for status <- ~w(running waiting cancelling), do: new_run(alice, status: status)
    for _index <- 1..4, do: new_run(other, status: "running")
    new_run(alice, status: "completed")

    assert Diagnostics.limits(alice.actor.project_id) == %{
             "pending_limit" => 5,
             "concurrent_limit" => 5,
             "projects_near_limit" => 1,
             "pending" => 4,
             "concurrent" => 3
           }

    assert Diagnostics.limits(other.actor.project_id)["concurrent"] == 4
    assert Diagnostics.limits(:all)["projects_near_limit"] == 2
  end

  test "projects below both thresholds are not reported near their limits", %{alice: alice} do
    put_runs(max_pending_per_project: 5, max_concurrent_per_project: 5)
    for status <- ~w(pending running waiting cancelling), do: new_run(alice, status: status)
    assert Diagnostics.limits(alice.actor.project_id)["projects_near_limit"] == 0
  end

  test "plugin failures are visible only to installation operators", %{alice: alice} do
    Application.put_env(:fyrlet, :plugins, [
      Fyrlet.TestPlugins.Counter,
      {Fyrlet.TestPlugins.Broken, required: false}
    ])

    assert Diagnostics.plugins(:all) == %{"degraded" => 1}
    assert Diagnostics.plugins(alice.actor.project_id) == %{}
    Application.put_env(:fyrlet, :plugins, [])
    assert Diagnostics.plugins(:all) == %{"degraded" => 0}
  end

  test "cluster diagnostics distinguish configured peers from connected nodes" do
    Application.put_env(:fyrlet, :cluster_nodes, [:first@localhost, :second@localhost])

    assert Diagnostics.cluster() == %{
             "node" => to_string(node()),
             "configured" => ["first@localhost", "second@localhost"],
             "connected" => Enum.map(Node.list(), &to_string/1)
           }

    Application.delete_env(:fyrlet, :cluster_nodes)
    assert Diagnostics.cluster()["configured"] == []
  end

  defp new_run(alice, fields) do
    id = start_run!(alice)
    set_run(id, fields)
    id
  end

  defp waiting_run(alice, deadline) do
    id = start_run!(alice)
    assert drive(id) == "waiting"
    wait_step(id) |> Ecto.Changeset.change(wait_deadline: deadline) |> Repo.update!()
    id
  end

  defp effect(alice, fields) do
    id = start_run!(alice)
    assert drive(id) == "waiting"

    Repo.one!(from(entry in Effect, where: entry.run_id == ^id))
    |> Ecto.Changeset.change(fields)
    |> Repo.update!()
  end
end
