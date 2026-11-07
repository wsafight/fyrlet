defmodule Fyrlet.Runs.ConcurrencyLimitTest do
  @moduledoc """
  `max_concurrent_per_project`: a project may hold only so many leases at once, counted from
  its own attempts. Another project's leases never count, and a blocked step is not claimed but
  woken again later.
  """
  use Fyrlet.RunsCase

  setup do
    Application.put_env(:fyrlet, :run_plans, %{
      "runs.demo" => fn _, _ -> {:ok, steps: [%{type: :step, name: "a", input: %{}}]} end
    })

    Application.put_env(:fyrlet, :run_steps, %{"a" => fn _, _ -> {:ok, %{}} end})
    %{a: user(project(), "alice"), b: user(project(), "bob")}
  end

  defp claim(run_id), do: Fyrlet.Runs.Engine.claim(run_id)
  defp leased(run_id), do: Enum.filter(attempts(run_id), &(&1.status == "leased"))

  test "every attempt records the project of its run", %{a: a} do
    id = start_run!(a)
    assert {:execute, _} = claim(id)
    assert [%{project_id: project_id}] = attempts(id)
    assert project_id == run(id).project_id
  end

  test "a project at its limit cannot claim another step; the step stays unclaimed", %{a: a} do
    put_runs(max_concurrent_per_project: 1)
    first = start_run!(a)
    second = start_run!(a)

    assert {:execute, _} = claim(first)
    assert claim(second) == :noop
    assert attempts(second) == []
    assert [%{status: "pending"}] = steps(second)
    # It will be tried again; nothing was lost.
    assert_enqueued(worker: Fyrlet.Runs.Worker, args: %{"run_id" => second})
  end

  test "the limit counts the project's own leases, not anyone else's", %{a: a, b: b} do
    put_runs(max_concurrent_per_project: 1)
    a1 = start_run!(a)
    a2 = start_run!(a)
    b1 = start_run!(b)
    b2 = start_run!(b)

    assert {:execute, _} = claim(a1)
    assert claim(a2) == :noop
    # B is unaffected by A holding its only lease...
    assert {:execute, _} = claim(b1)
    # ...and is held back by its own.
    assert claim(b2) == :noop
    assert length(leased(a1)) == 1 and length(leased(b1)) == 1
  end

  test "an expired lease no longer counts", %{a: a} do
    put_runs(max_concurrent_per_project: 1)
    first = start_run!(a)
    second = start_run!(a)
    assert {:execute, _} = claim(first)
    assert claim(second) == :noop

    past = DateTime.add(Fyrlet.Auth.now(), -5, :second)

    Repo.update_all(from(at in Attempt, where: at.run_id == ^first),
      set: [lease_expires_at: past]
    )

    assert {:execute, _} = claim(second)
  end

  test "a finished attempt no longer counts", %{a: a} do
    put_runs(max_concurrent_per_project: 1)
    first = start_run!(a)
    second = start_run!(a)
    assert {:execute, _} = claim(first)
    assert claim(second) == :noop

    Repo.update_all(from(at in Attempt, where: at.run_id == ^first), set: [status: "succeeded"])
    assert {:execute, _} = claim(second)
  end

  test "a run's own lease is not counted against itself", %{a: a} do
    put_runs(max_concurrent_per_project: 1)
    id = start_run!(a)
    assert {:execute, _} = claim(id)
    # Re-checking for the same run (a retry, a recovery pass) must not see its own lease as load.
    refute Fyrlet.Runs.Engine.project_busy_for_test?(run(id), Fyrlet.Auth.now())
  end
end
