defmodule Fyrlet.RunsDynamicTest do
  use Fyrlet.RunsCase

  setup do
    %{alice: user(project(), "alice")}
  end

  defp advance(fun), do: Application.put_env(:fyrlet, :run_advance, fun)

  test "the next node is chosen from the previous node's output", %{alice: alice} do
    Application.put_env(:fyrlet, :run_steps, %{
      "check" => fn _, _ -> {:ok, %{"score" => 90}} end,
      "approve" => fn _, _ -> {:ok, %{"approved" => true}} end,
      "review" => fn _, _ -> {:ok, %{"reviewed" => true}} end
    })

    advance(fn
      _state, :start ->
        {:step, "check", %{}}

      _state, {:step_succeeded, "check", %{"score" => s}} when s >= 80 ->
        {:step, "approve", %{}}

      _state, {:step_succeeded, "check", _} ->
        {:step, "review", %{}}

      state, {:step_succeeded, "approve", _} ->
        {:done, %{"path" => Enum.map(state.outputs, & &1.name)}}
    end)

    id = start_run!(alice, "runs.dynamic", %{})
    assert [{"check", "pending"}] = step_statuses(id)
    assert drive(id) == "completed"
    assert [{"check", "succeeded"}, {"approve", "succeeded"}] = step_statuses(id)
    assert run(id).output == %{"path" => ["check", "approve"]}
    assert "plan.advanced" in event_types(id)
  end

  test "a decision can loop until a condition holds", %{alice: alice} do
    counter = :counters.new(1, [])

    Application.put_env(:fyrlet, :run_steps, %{
      "poll" => fn _, _ ->
        :counters.add(counter, 1, 1)
        {:ok, %{"ready" => :counters.get(counter, 1) >= 3}}
      end
    })

    advance(fn
      _s, :start -> {:step, "poll", %{}}
      _s, {:step_succeeded, "poll", %{"ready" => true}} -> {:done, %{"polls" => 3}}
      _s, {:step_succeeded, "poll", _} -> {:step, "poll", %{}}
    end)

    id = start_run!(alice, "runs.dynamic")
    assert drive(id) == "completed"
    assert length(steps(id)) == 3 and run(id).output == %{"polls" => 3}
  end

  test "it can wait for an event and decide on what arrived", %{alice: alice} do
    advance(fn
      _s, :start -> {:wait, %{name: "decision", signal: "verdict", timeout_ms: 60_000}}
      _s, {:wait_satisfied, "decision", %{"ok" => true}} -> {:step, "ship", %{}}
      _s, {:wait_satisfied, "decision", _} -> {:done, %{"shipped" => false}}
      _s, {:step_succeeded, "ship", _} -> {:done, %{"shipped" => true}}
    end)

    id = start_run!(alice, "runs.dynamic")
    assert drive(id) == "waiting"
    {:ok, _} = signal(alice.actor, id, "verdict", %{"ok" => true})
    assert drive(id) == "completed"
    assert [{"decision", "satisfied"}, {"ship", "succeeded"}] = step_statuses(id)

    other = start_run!(alice, "runs.dynamic")
    drive(other)
    {:ok, _} = signal(alice.actor, other, "verdict", %{"ok" => false})
    assert status(other) == "completed" and run(other).output == %{"shipped" => false}
  end

  test "a timed-out wait that continues is reported as such", %{alice: alice} do
    test = self()

    advance(fn
      _s, :start ->
        {:wait, %{name: "w", signal: "x", timeout_ms: 1_000, on_timeout: :continue}}

      _s, event ->
        send(test, {:event, event})
        {:done, %{}}
    end)

    id = start_run!(alice, "runs.dynamic")
    drive(id)
    wait = wait_step(id)

    Repo.update_all(from(s in Step, where: s.id == ^wait.id),
      set: [wait_deadline: DateTime.add(Fyrlet.Auth.now(), -1, :second)]
    )

    Engine.expire_wait(id, wait.id)
    assert status(id) == "completed"
    assert_received {:event, {:wait_timed_out, "w"}}
  end

  test "bad decisions fail the run with a clear code and never stall it", %{alice: alice} do
    for {decision, code} <- [
          {{:step, "Bad Name", %{}}, "VALIDATION_FAILED"},
          {{:step, "x", %{"big" => String.duplicate("a", 70_000)}}, "VALIDATION_FAILED"},
          {{:wait, %{name: "w", signal: "s"}}, "VALIDATION_FAILED"},
          {{:done, "text"}, "INVALID_ADVANCE"},
          {:nonsense, "VALIDATION_FAILED"},
          {{:error, Error.new("DENIED", "no", %{}, false)}, "DENIED"}
        ] do
      advance(fn
        _s, :start -> {:step, "first", %{}}
        _s, _event -> decision
      end)

      id = start_run!(alice, "runs.dynamic")
      assert drive(id) == "failed", inspect(decision)
      assert run(id).error["code"] == code, inspect(decision)
    end
  end

  test "an advance/3 that raises fails the run without leaking its message", %{alice: alice} do
    advance(fn
      _s, :start -> {:step, "first", %{}}
      _s, _event -> raise "internal secret"
    end)

    id = start_run!(alice, "runs.dynamic")
    assert drive(id) == "failed"
    assert run(id).error["code"] == "ADVANCE_CRASHED"
    refute inspect(run(id).error) =~ "secret"
  end

  test "the node count is bounded", %{alice: alice} do
    put_runs(max_nodes: 4)
    Application.put_env(:fyrlet, :run_steps, %{"again" => fn _, _ -> {:ok, %{}} end})
    advance(fn _s, _e -> {:step, "again", %{}} end)

    id = start_run!(alice, "runs.dynamic")
    assert drive(id) == "failed"
    assert run(id).error["code"] == "TOO_MANY_NODES"
    assert length(steps(id)) == 4
  end

  test "the first decision must be a node, and creation errors leave nothing behind", %{
    alice: alice
  } do
    advance(fn _s, :start -> {:done, %{}} end)
    assert {:error, %Error{code: "VALIDATION_FAILED"}} = start_run(alice, "runs.dynamic")
    advance(fn _s, :start -> raise "boom" end)
    assert {:error, %Error{code: "VALIDATION_FAILED"}} = start_run(alice, "runs.dynamic")
    assert Repo.aggregate(Run, :count) == 0
  end

  test "business keys work for dynamic runs too", %{alice: alice} do
    advance(fn
      _s, :start -> {:step, "first", %{}}
      _s, _e -> {:done, %{}}
    end)

    first = start_run!(alice, "runs.dynamic", %{"key" => "k1"})

    assert {:ok, %{"run_id" => ^first, "existing" => true}} =
             start_run(alice, "runs.dynamic", %{"key" => "k1"})
  end

  test "a crash after deciding is recovered without deciding twice", %{alice: alice} do
    calls = :counters.new(1, [])

    advance(fn
      _s, :start ->
        {:step, "a", %{}}

      _s, {:step_succeeded, "a", _} ->
        :counters.add(calls, 1, 1)
        {:step, "b", %{}}

      _s, {:step_succeeded, "b", _} ->
        {:done, %{}}
    end)

    id = start_run!(alice, "runs.dynamic")

    inject(fn
      :before_wake_insert -> exit(:crash)
      _ -> :ok
    end)

    assert {:crashed, _} = await_executor(spawn_executor(fn -> Engine.run_once(id) end))
    Application.delete_env(:fyrlet, :run_faults)

    # The decision and its wake-up are one commit: the crash rolled both back together.
    assert [{"a", "running"}] = step_statuses(id)
    expire_leases(id)
    Recovery.scan()
    assert drive(id) == "completed"
    assert [{"a", "succeeded"}, {"b", "succeeded"}] = step_statuses(id)
    assert :counters.get(calls, 1) == 2
  end

  test "an operation uses exactly one planning mode" do
    contract = %{
      "operations" => %{
        "x.run" => Fyrlet.Runs.operation(Fyrlet.Schema.object(%{}), planning: :dynamic)
      },
      "subscriptions" => %{}
    }

    defmodule StaticOnly do
      @behaviour Fyrlet.Definition
      def contract, do: Application.fetch_env!(:fyrlet, :registry_test_contract)
      def authorize(_, _, _), do: :ok
      def execute(_, _, _), do: {:ok, %{}, []}
      def scope(_, _, _), do: "t"
      def run(_, _, _), do: {:ok, steps: []}
      def step(_, _, _), do: {:ok, %{}}
    end

    previous = Application.fetch_env!(:fyrlet, :definitions)
    Application.put_env(:fyrlet, :registry_test_contract, contract)
    Application.put_env(:fyrlet, :definitions, [StaticOnly])

    on_exit(fn ->
      Application.put_env(:fyrlet, :definitions, previous)
      Application.delete_env(:fyrlet, :registry_test_contract)
    end)

    assert_raise RuntimeError, ~r/needs advance\/3/, fn -> Fyrlet.Registry.validate!() end

    Application.put_env(
      :fyrlet,
      :registry_test_contract,
      put_in(contract, ["operations", "x.run", "planning"], "psychic")
    )

    assert_raise RuntimeError, ~r/unknown planning/, fn -> Fyrlet.Registry.validate!() end
  end
end
