defmodule Fyrlet.Runs.StateMachineTest do
  use ExUnit.Case, async: true
  alias Fyrlet.Runs.StateMachine, as: SM

  # The specification's run diagram, written out independently of the implementation.
  @allowed_runs MapSet.new([
                  {"pending", "running"},
                  {"running", "waiting"},
                  {"waiting", "running"},
                  {"running", "completed"},
                  {"pending", "failed"},
                  {"running", "failed"},
                  {"waiting", "failed"},
                  {"pending", "cancelling"},
                  {"running", "cancelling"},
                  {"waiting", "cancelling"},
                  {"cancelling", "cancelled"},
                  {"pending", "expired"},
                  {"running", "expired"},
                  {"waiting", "expired"},
                  {"cancelling", "expired"}
                ])

  test "exactly the specified run transitions are legal" do
    for from <- SM.run_states(), to <- SM.run_states() do
      expected = MapSet.member?(@allowed_runs, {from, to})
      assert SM.run(from, to) == :ok == expected, "run #{from} -> #{to}"
    end
  end

  test "terminal run states are absorbing" do
    for terminal <- SM.terminal_states(), to <- SM.run_states() do
      assert {:error, {:illegal_transition, :run, ^terminal, ^to}} = SM.run(terminal, to)
    end

    assert Enum.all?(SM.terminal_states(), &SM.terminal?/1)
    refute Enum.any?(~w(pending running waiting cancelling), &SM.terminal?/1)
  end

  test "every non-terminal state can reach a terminal one (no stuck states)" do
    reachable = fn start ->
      Stream.iterate(MapSet.new([start]), fn seen ->
        Enum.reduce(seen, seen, fn state, acc ->
          Enum.reduce(SM.allowed(:run, state), acc, &MapSet.put(&2, &1))
        end)
      end)
      |> Enum.take(10)
      |> List.last()
    end

    for state <- SM.run_states(), not SM.terminal?(state) do
      assert Enum.any?(reachable.(state), &SM.terminal?/1), "#{state} cannot finish"
    end
  end

  test "work steps may only retry from running and never leave a final state" do
    assert :ok = SM.step("step", "pending", "running")
    assert :ok = SM.step("step", "running", "pending")
    assert :ok = SM.step("step", "running", "awaiting_effect")
    assert :ok = SM.step("step", "awaiting_effect", "running")
    assert {:error, _} = SM.step("step", "pending", "succeeded")
    assert {:error, _} = SM.step("step", "pending", "pending")

    for final <- ~w(succeeded failed cancelled), to <- SM.work_states() do
      assert {:error, _} = SM.step("step", final, to)
    end
  end

  test "wait nodes are satisfied, timed out or cancelled exactly once" do
    assert :ok = SM.step("wait", "pending", "waiting")
    for to <- ~w(satisfied timed_out cancelled), do: assert(:ok = SM.step("wait", "waiting", to))
    assert {:error, _} = SM.step("wait", "pending", "satisfied")

    for closed <- ~w(satisfied timed_out cancelled), to <- SM.wait_states() do
      assert {:error, _} = SM.step("wait", closed, to), "#{closed} -> #{to} must stay closed"
    end
  end

  test "attempt results cannot be rewritten" do
    for to <- ~w(succeeded failed abandoned), do: assert(:ok = SM.attempt("leased", to))

    for final <- ~w(succeeded failed abandoned), to <- SM.attempt_states() do
      assert {:error, _} = SM.attempt(final, to)
    end

    assert {:error, _} = SM.attempt("leased", "leased")
  end

  test "unknown states are never legal" do
    assert {:error, _} = SM.run("bogus", "running")
    assert {:error, _} = SM.run("running", "bogus")
    assert {:error, _} = SM.step("step", "bogus", "running")
  end

  test "allowed/2 is the single source the transition checks use" do
    for from <- SM.run_states() do
      for to <- SM.allowed(:run, from) do
        assert :ok = SM.run(from, to), "allowed run #{from} -> #{to} must be legal"
      end

      for to <- SM.run_states(), to not in SM.allowed(:run, from) do
        assert {:error, _} = SM.run(from, to), "disallowed run #{from} -> #{to} must be refused"
      end
    end

    assert SM.allowed(:run, "pending") == ["running", "failed", "cancelling", "expired"]
    assert SM.allowed(:run, "completed") == []
    assert SM.allowed(:run, "made_up") == []

    assert SM.allowed(:step, "running") ==
             ["pending", "awaiting_effect", "succeeded", "failed", "cancelled"]

    assert SM.allowed(:wait, "waiting") == ["satisfied", "timed_out", "cancelled"]
    assert SM.allowed(:attempt, "leased") == ["succeeded", "failed", "abandoned"]
    assert SM.allowed(:attempt, "unknown") == []
  end

  test "active?/1 covers every non-terminal state and nothing else" do
    for state <- SM.run_states() do
      assert SM.active?(state) == state not in SM.terminal_states()
    end

    assert SM.active?("pending")
    assert SM.active?("cancelling")
    refute SM.active?("completed")
    refute SM.active?("not-a-state")
  end
end
