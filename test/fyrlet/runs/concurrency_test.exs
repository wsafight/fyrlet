defmodule Fyrlet.RunsConcurrencyTest do
  @moduledoc """
  Real concurrency: no sandbox, every transaction commits on its own connection, so row
  locks and advisory locks are actually contended. Data is removed afterwards.
  """
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Fyrlet.Repo
  import Ecto.Query
  import Fyrlet.Fixtures
  import Fyrlet.RunsCase, except: [start_run: 4]
  alias Fyrlet.Repo
  alias Fyrlet.Runs
  alias Fyrlet.Runs.{Attempt, Engine, Run, Signal, Step}

  setup_all do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)
    :ok
  end

  setup do
    previous = Application.get_env(:fyrlet, :runs, [])
    Application.put_env(:fyrlet, :runs, retry_base_seconds: 0, retry_max_seconds: 0)
    project = project()
    alice = user(project, "alice")

    on_exit(fn ->
      Application.put_env(:fyrlet, :runs, previous)
      for key <- [:run_plans, :run_steps, :run_faults], do: Application.delete_env(:fyrlet, key)
      id = project.project.id
      Repo.delete_all(from(r in Run, where: r.project_id == ^id))
      Repo.delete_all(from(g in Fyrlet.Runs.Grant, where: g.project_id == ^id))
      Repo.delete_all(from(p in Fyrlet.Project, where: p.id == ^id))

      Repo.delete_all(
        from(j in Oban.Job,
          where: j.worker in ["Fyrlet.Runs.Worker", "Fyrlet.InvalidationWorker"]
        )
      )
    end)

    %{alice: alice}
  end

  defp start(alice, op \\ "runs.demo", input \\ %{}, request_key \\ nil) do
    Fyrlet.Runtime.call(alice.actor, op, input, request_key || key(), capabilities: caps())
  end

  defp parallel(count, fun),
    do:
      1..count
      |> Task.async_stream(fun, max_concurrency: count, timeout: 20_000)
      |> Enum.map(fn {:ok, r} -> r end)

  defp count(schema, run_id),
    do: Repo.aggregate(from(r in schema, where: r.run_id == ^run_id), :count)

  test "simultaneous starts with one idempotency key create one run and one wake-up", %{
    alice: alice
  } do
    request_key = key()
    results = parallel(12, fn _ -> start(alice, "runs.demo", %{"source" => "a"}, request_key) end)

    ids = for {:ok, %{"run_id" => id}} <- results, uniq: true, do: id
    assert length(ids) == 1, inspect(results)

    assert Repo.aggregate(from(r in Run, where: r.project_id == ^alice.actor.project_id), :count) ==
             1

    assert length(all_enqueued(worker: Fyrlet.Runs.Worker)) == 1
  end

  test "simultaneous starts with one business key and different request keys create one run", %{
    alice: alice
  } do
    results = parallel(12, fn _ -> start(alice, "runs.demo", %{"key" => "order-1"}) end)
    ids = for {:ok, %{"run_id" => id}} <- results, uniq: true, do: id
    assert length(ids) == 1, inspect(results)

    assert Repo.aggregate(from(r in Run, where: r.project_id == ^alice.actor.project_id), :count) ==
             1
  end

  test "workers racing for one run execute every step exactly once", %{alice: alice} do
    counters = %{
      "a" => :counters.new(1, []),
      "b" => :counters.new(1, []),
      "c" => :counters.new(1, [])
    }

    Application.put_env(:fyrlet, :run_plans, %{
      "runs.demo" => fn _, _ ->
        {:ok, steps: for(n <- ["a", "b", "c"], do: %{type: :step, name: n, input: %{}})}
      end
    })

    Application.put_env(
      :fyrlet,
      :run_steps,
      Map.new(counters, fn {name, c} ->
        {name,
         fn _, _ ->
           :counters.add(c, 1, 1)
           Process.sleep(15)
           {:ok, %{name => true}}
         end}
      end)
    )

    {:ok, %{"run_id" => id}} = start(alice)

    parallel(10, fn _ ->
      Enum.reduce_while(1..40, nil, fn _, _ ->
        Engine.run_once(id)
        if Repo.get!(Run, id).status == "completed", do: {:halt, :done}, else: {:cont, nil}
      end)
    end)

    assert Repo.get!(Run, id).status == "completed"

    for {name, counter} <- counters,
        do:
          assert(
            :counters.get(counter, 1) == 1,
            "step #{name} ran #{:counters.get(counter, 1)} times"
          )

    assert count(Attempt, id) == 3

    assert Repo.all(from(a in Attempt, where: a.run_id == ^id, select: a.status)) |> Enum.uniq() ==
             ["succeeded"]
  end

  test "runs of one project claimed at once never hold more leases than the project limit", %{
    alice: alice
  } do
    limit = 2

    Application.put_env(:fyrlet, :runs,
      retry_base_seconds: 0,
      retry_max_seconds: 0,
      max_concurrent_per_project: limit
    )

    Application.put_env(:fyrlet, :run_plans, %{
      "runs.demo" => fn _, _ -> {:ok, steps: [%{type: :step, name: "a", input: %{}}]} end
    })

    # Many rounds: the race window is small, and a single clean round proves little.
    for _round <- 1..12 do
      ids = for _ <- 1..10, do: elem(start(alice), 1)["run_id"]
      parallel(10, fn index -> Engine.claim(Enum.at(ids, index - 1)) end)

      held =
        Repo.aggregate(
          from(a in Attempt,
            where: a.project_id == ^alice.actor.project_id and a.status == "leased"
          ),
          :count
        )

      assert held <= limit, "#{held} leases are held with a limit of #{limit}"

      # Clear the leases so the next round starts from nothing.
      Repo.update_all(from(a in Attempt, where: a.project_id == ^alice.actor.project_id),
        set: [status: "abandoned"]
      )
    end
  end

  test "a signal racing its timeout produces exactly one outcome, every time", %{alice: alice} do
    Application.put_env(:fyrlet, :run_plans, %{
      "runs.demo" => fn _, _ ->
        {:ok,
         steps: [%{type: :wait, name: "w", signal: "go", timeout_ms: 60_000, on_timeout: :fail}]}
      end
    })

    outcomes =
      for _ <- 1..15 do
        {:ok, %{"run_id" => id}} = start(alice)
        assert drive(id) == "waiting"
        wait = wait_step(id)
        past = DateTime.add(Fyrlet.Auth.now(), -1, :second)
        Repo.update_all(from(s in Step, where: s.id == ^wait.id), set: [wait_deadline: past])

        parallel(2, fn
          1 ->
            Runs.signal(alice.actor, id, %{
              "wait_id" => wait.id,
              "name" => "go",
              "idempotency_key" => key()
            })

          2 ->
            Engine.expire_wait(id, wait.id)
        end)

        final = Repo.get!(Step, wait.id).status
        run = Repo.get!(Run, id)
        # Whoever got the lock first decided; the other must not have changed it afterwards.
        assert {final, run.status} in [{"satisfied", "completed"}, {"timed_out", "failed"}]
        final
      end

    assert Enum.all?(outcomes, &(&1 in ["satisfied", "timed_out"]))
  end

  test "duplicate signals sent at once are stored and consumed once", %{alice: alice} do
    Application.put_env(:fyrlet, :run_plans, %{
      "runs.demo" => fn _, _ ->
        {:ok, steps: [%{type: :wait, name: "w", signal: "go", timeout_ms: 60_000}]}
      end
    })

    {:ok, %{"run_id" => id}} = start(alice)
    drive(id)
    wait = wait_step(id)

    params = %{
      "wait_id" => wait.id,
      "name" => "go",
      "payload" => %{"n" => 1},
      "idempotency_key" => "same"
    }

    results = parallel(8, fn _ -> Runs.signal(alice.actor, id, params) end)
    receipts = for {:ok, receipt} <- results, do: receipt["signal_id"]

    assert Enum.uniq(receipts) |> length() == 1, inspect(results)
    assert count(Signal, id) == 1
    assert Repo.get!(Run, id).status == "completed"
  end

  test "a cancel racing the final step ends in exactly one terminal state", %{alice: alice} do
    Application.put_env(:fyrlet, :run_plans, %{
      "runs.demo" => fn _, _ -> {:ok, steps: [%{type: :step, name: "a", input: %{}}]} end
    })

    Application.put_env(:fyrlet, :run_steps, %{
      "a" => fn _, _ ->
        Process.sleep(10)
        {:ok, %{"done" => true}}
      end
    })

    states =
      for _ <- 1..12 do
        {:ok, %{"run_id" => id}} = start(alice)

        parallel(2, fn
          1 ->
            Engine.run_once(id)
            :ran

          2 ->
            Runs.cancel(alice.actor, id)
            :cancelled
        end)

        # A run that was cancelling when the executor returned needs no further driving.
        drive(id)
        run = Repo.get!(Run, id)
        assert run.status in ["completed", "cancelled"], "ended #{run.status}"
        assert is_struct(run.finished_at, DateTime)
        # The two outcomes are mutually exclusive.
        assert run.status == "completed" == is_nil(run.cancellation_outcome)
        run.status
      end

    assert Enum.all?(states, &(&1 in ["completed", "cancelled"]))
  end
end
