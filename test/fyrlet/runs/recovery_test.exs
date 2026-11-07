defmodule Fyrlet.RunsRecoveryTest do
  use Fyrlet.RunsCase

  setup do
    project = project()
    %{alice: user(project, "alice")}
  end

  defp two_steps do
    Application.put_env(:fyrlet, :run_plans, %{
      "runs.demo" => fn _, _ ->
        {:ok,
         steps: [%{type: :step, name: "a", input: %{}}, %{type: :step, name: "b", input: %{}}]}
      end
    })
  end

  defp counting_steps do
    counters = %{"a" => :counters.new(1, []), "b" => :counters.new(1, [])}

    Application.put_env(
      :fyrlet,
      :run_steps,
      Map.new(counters, fn {name, counter} ->
        {name,
         fn _, _ ->
           :counters.add(counter, 1, 1)
           {:ok, %{name => true}}
         end}
      end)
    )

    fn name -> :counters.get(counters[name], 1) end
  end

  describe "cancelling (R05)" do
    test "a run that has not started is cancelled at once and never claimed", %{alice: alice} do
      id = start_run!(alice)

      assert {:ok, %{"status" => "cancelled", "cancellation_outcome" => "confirmed"}} =
               Runs.cancel(alice.actor, id)

      assert [{"prepare", "cancelled"}, {"approval", "cancelled"}, {"publish", "cancelled"}] =
               step_statuses(id)

      assert Engine.run_once(id) == :noop
      assert attempts(id) == []
      assert event_types(id) |> Enum.take(-3) |> Enum.member?("run.cancelled")
      assert is_struct(run(id).finished_at, DateTime)
    end

    test "a waiting run is cancelled and its wait closed", %{alice: alice} do
      id = start_run!(alice)
      assert drive(id) == "waiting"
      assert {:ok, %{"status" => "cancelled"}} = Runs.cancel(alice.actor, id)

      assert [{"prepare", "succeeded"}, {"approval", "cancelled"}, {"publish", "cancelled"}] =
               step_statuses(id)
    end

    test "cancelling is idempotent and a finished run is returned as it is", %{alice: alice} do
      id = start_run!(alice)
      assert {:ok, first} = Runs.cancel(alice.actor, id)
      assert {:ok, ^first} = Runs.cancel(alice.actor, id)

      Application.put_env(:fyrlet, :run_plans, %{
        "runs.demo" => fn _, _ -> {:ok, steps: [%{type: :step, name: "a", input: %{}}]} end
      })

      done = start_run!(alice)
      assert drive(done) == "completed"
      assert {:ok, %{"status" => "completed"}} = Runs.cancel(alice.actor, done)
    end

    test "only an authorized caller can cancel", %{alice: alice} do
      bob = user(project(), "bob")
      id = start_run!(alice)
      assert {:error, %Error{code: "NOT_FOUND"}} = Runs.cancel(bob.actor, id)
      assert {:error, %Error{code: "NOT_FOUND"}} = Runs.cancel(alice.actor, Ecto.UUID.generate())
      assert status(id) == "pending"
    end

    test "cancelling during execution waits for the executor, then records its result only as audit",
         %{alice: alice} do
      two_steps()
      id = start_run!(alice)
      pause_at(:before_commit)

      executor = spawn_executor(fn -> Engine.run_once(id) end)
      assert_receive {:paused, pid, :before_commit}

      assert {:ok, %{"status" => "cancelling", "cancel_deadline" => deadline}} =
               Runs.cancel(alice.actor, id)

      assert is_binary(deadline)
      assert [{"a", "running"}, {"b", "cancelled"}] = step_statuses(id)

      send(pid, :continue)
      assert {:ok, :cancelled} = await_executor(executor)

      assert status(id) == "cancelled" and run(id).cancellation_outcome == "confirmed"
      assert [{"a", "cancelled"}, {"b", "cancelled"}] = step_statuses(id)
      assert "attempt.late_result" in event_types(id)
      assert Engine.run_once(id) == :noop
      assert [%{status: "succeeded"}] = attempts(id)
    end

    test "an executor that never answers ends the cancel as fenced, not confirmed", %{
      alice: alice
    } do
      two_steps()
      id = start_run!(alice)
      pause_at(:before_commit)
      executor = spawn_executor(fn -> Engine.run_once(id) end)
      assert_receive {:paused, pid, :before_commit}

      {:ok, _} = Runs.cancel(alice.actor, id)
      assert Recovery.scan().cancel_fenced == 0

      set_run(id, cancel_deadline: DateTime.add(Fyrlet.Auth.now(), -1, :second))
      assert Recovery.scan().cancel_fenced == 1
      assert status(id) == "cancelled" and run(id).cancellation_outcome == "fenced_timeout"
      assert [%{status: "abandoned"}] = attempts(id)

      # The straggler wakes up later; it cannot change anything.
      send(pid, :continue)
      assert {:ok, :stale} = await_executor(executor)
      assert status(id) == "cancelled"
      assert "attempt.late_result" in event_types(id)
    end

    test "a cancel that races a completing step leaves exactly one terminal state", %{
      alice: alice
    } do
      Application.put_env(:fyrlet, :run_plans, %{
        "runs.demo" => fn _, _ -> {:ok, steps: [%{type: :step, name: "a", input: %{}}]} end
      })

      for order <- [:cancel_then_commit, :commit_then_cancel] do
        id = start_run!(alice)
        pause_at(:before_commit)
        executor = spawn_executor(fn -> Engine.run_once(id) end)
        assert_receive {:paused, pid, :before_commit}

        if order == :cancel_then_commit do
          {:ok, _} = Runs.cancel(alice.actor, id)
          send(pid, :continue)
          await_executor(executor)
          assert status(id) == "cancelled"
        else
          send(pid, :continue)
          await_executor(executor)
          assert status(id) == "completed"
          assert {:ok, %{"status" => "completed"}} = Runs.cancel(alice.actor, id)
          assert status(id) == "completed"
        end
      end
    end
  end

  describe "crash recovery (R06)" do
    test "a crash after claiming leaves a lease that recovery abandons and re-wakes", %{
      alice: alice
    } do
      two_steps()
      calls = counting_steps()
      id = start_run!(alice)

      inject(fn
        :after_claim -> exit(:simulated_crash)
        _ -> :ok
      end)

      executor = spawn_executor(fn -> Engine.run_once(id) end)
      assert {:crashed, :simulated_crash} = await_executor(executor)
      Application.delete_env(:fyrlet, :run_faults)

      assert status(id) == "running"
      assert [%{status: "leased"}] = attempts(id)
      assert calls.("a") == 0
      assert Engine.run_once(id) == :noop

      stats = Recovery.scan()
      assert stats.expired_leases == 0

      expire_leases(id)
      assert Recovery.scan().expired_leases == 1
      assert [%{status: "abandoned"}] = attempts(id)
      assert_enqueued worker: Fyrlet.Runs.Worker, args: %{"run_id" => id}

      assert drive(id) == "completed"
      assert calls.("a") == 1 and calls.("b") == 1
      assert Enum.map(attempts(id), & &1.status) == ["abandoned", "succeeded", "succeeded"]
    end

    test "completed steps are never run again after a later crash", %{alice: alice} do
      two_steps()
      calls = counting_steps()
      id = start_run!(alice)
      assert Engine.run_once(id) == :succeeded
      assert calls.("a") == 1

      inject(fn
        :after_claim -> exit(:simulated_crash)
        _ -> :ok
      end)

      assert {:crashed, _} = await_executor(spawn_executor(fn -> Engine.run_once(id) end))
      Application.delete_env(:fyrlet, :run_faults)
      expire_leases(id)
      Recovery.scan()

      assert drive(id) == "completed"
      assert calls.("a") == 1
      assert calls.("b") == 1
    end

    test "a crash after the result committed does not repeat the step", %{alice: alice} do
      two_steps()
      calls = counting_steps()
      id = start_run!(alice)

      inject(fn
        :after_commit -> exit(:crash_before_notify)
        _ -> :ok
      end)

      assert {:crashed, _} = await_executor(spawn_executor(fn -> Engine.run_once(id) end))
      Application.delete_env(:fyrlet, :run_faults)

      assert [{"a", "succeeded"}, {"b", "pending"}] = step_statuses(id)
      assert drive(id) == "completed"
      assert calls.("a") == 1
    end

    test "a stale executor cannot overwrite the executor that took over", %{alice: alice} do
      two_steps()
      id = start_run!(alice)
      pause_at(:before_commit)
      slow = spawn_executor(fn -> Engine.run_once(id) end)
      assert_receive {:paused, slow_pid, :before_commit}

      # The lease expires and the work is handed to a second executor, which finishes it.
      expire_leases(id)
      assert Recovery.scan().expired_leases == 1
      Application.delete_env(:fyrlet, :run_faults)
      assert Engine.run_once(id) == :succeeded
      assert [{"a", "succeeded"}, {"b", "pending"}] = step_statuses(id)
      epoch = run(id).execution_epoch

      send(slow_pid, :continue)
      assert {:ok, :stale} = await_executor(slow)

      assert [{"a", "succeeded"}, {"b", "pending"}] = step_statuses(id)
      assert run(id).execution_epoch == epoch and run(id).status == "running"
      assert "attempt.late_result" in event_types(id)
      assert Enum.map(attempts(id), & &1.status) == ["abandoned", "succeeded"]
    end

    test "each ownership check rejects a stale result on its own", %{alice: alice} do
      two_steps()

      for tamper <- [:epoch_moved_on, :attempt_not_leased] do
        id = start_run!(alice)
        pause_at(:before_commit)
        executor = spawn_executor(fn -> Engine.run_once(id) end)
        assert_receive {:paused, pid, :before_commit}

        case tamper do
          # The lease still looks live, but ownership moved to a newer epoch.
          :epoch_moved_on ->
            set_run(id, execution_epoch: run(id).execution_epoch + 1)

          # The epoch is unchanged, but the attempt is no longer the leased one.
          :attempt_not_leased ->
            Repo.update_all(from(a in Attempt, where: a.run_id == ^id),
              set: [status: "abandoned"]
            )
        end

        before = step_statuses(id)
        send(pid, :continue)
        assert {:ok, :stale} = await_executor(executor), "#{tamper} must reject the result"
        assert step_statuses(id) == before
        assert "attempt.late_result" in event_types(id)
        Application.delete_env(:fyrlet, :run_faults)
      end
    end

    test "every takeover moves the execution epoch forward", %{alice: alice} do
      two_steps()
      id = start_run!(alice)
      pause_at(:before_commit)
      slow = spawn_executor(fn -> Engine.run_once(id) end)
      assert_receive {:paused, pid, :before_commit}
      claimed = run(id).execution_epoch
      assert claimed == 1

      expire_leases(id)
      Recovery.scan()
      assert run(id).execution_epoch > claimed, "abandoning a lease must invalidate its epoch"

      Application.delete_env(:fyrlet, :run_faults)
      assert Engine.run_once(id) == :succeeded
      assert run(id).execution_epoch > claimed + 1

      send(pid, :continue)
      assert {:ok, :stale} = await_executor(slow)
    end

    test "closing a run with a live lease invalidates that lease's epoch", %{alice: alice} do
      two_steps()
      id = start_run!(alice)
      pause_at(:before_commit)
      executor = spawn_executor(fn -> Engine.run_once(id) end)
      assert_receive {:paused, pid, :before_commit}
      claimed = run(id).execution_epoch

      :ok = Runs.revoke_grant(alice.actor.project_id, id)
      assert status(id) == "failed"
      assert run(id).execution_epoch > claimed

      send(pid, :continue)
      assert {:ok, :stale} = await_executor(executor)
      assert status(id) == "failed"
    end

    test "attempt exhaustion through lost leases fails the run", %{alice: alice} do
      Application.put_env(:fyrlet, :run_plans, %{
        "runs.demo" => fn _, _ ->
          {:ok, steps: [%{type: :step, name: "a", input: %{}, max_attempts: 2}]}
        end
      })

      id = start_run!(alice)

      for _ <- 1..2 do
        inject(fn
          :after_claim -> exit(:crash)
          _ -> :ok
        end)

        await_executor(spawn_executor(fn -> Engine.run_once(id) end))
        Application.delete_env(:fyrlet, :run_faults)
        expire_leases(id)
        Recovery.scan()
      end

      assert status(id) == "failed" and run(id).error["code"] == "ATTEMPTS_EXHAUSTED"
    end

    test "a lost wake-up is repaired from the tables", %{alice: alice} do
      two_steps()
      id = start_run!(alice)
      Repo.delete_all(Oban.Job)
      refute_enqueued worker: Fyrlet.Runs.Worker

      assert Recovery.scan().rescheduled == 0
      age(id, 120)
      assert Recovery.scan().rescheduled == 1
      assert_enqueued worker: Fyrlet.Runs.Worker, args: %{"run_id" => id}
    end

    test "a crash between committing a step and waking the next one is repaired", %{alice: alice} do
      two_steps()
      id = start_run!(alice)

      inject(fn
        :before_wake_insert -> exit(:crash_before_wake)
        _ -> :ok
      end)

      assert {:crashed, _} = await_executor(spawn_executor(fn -> Engine.run_once(id) end))
      Application.delete_env(:fyrlet, :run_faults)

      # The whole commit rolled back: nothing half-applied, so the step simply runs again.
      assert [{"a", "running"}, {"b", "pending"}] = step_statuses(id)
      expire_leases(id)
      Recovery.scan()
      assert drive(id) == "completed"
    end
  end

  describe "lifetime, authority and versions (R18, R19, R23)" do
    test "a run past its deadline expires and its work is fenced off", %{alice: alice} do
      two_steps()
      id = start_run!(alice)
      assert Engine.run_once(id) == :succeeded
      set_run(id, expires_at: DateTime.add(Fyrlet.Auth.now(), -1, :second))

      assert Recovery.scan().expired_runs == 1
      assert status(id) == "expired" and run(id).error["code"] == "RUN_EXPIRED"
      assert Engine.run_once(id) == :noop
    end

    test "a deadline that passes during a cancel ends expired with a fenced outcome", %{
      alice: alice
    } do
      two_steps()
      id = start_run!(alice)
      pause_at(:before_commit)
      executor = spawn_executor(fn -> Engine.run_once(id) end)
      assert_receive {:paused, pid, :before_commit}

      {:ok, _} = Runs.cancel(alice.actor, id)
      assert status(id) == "cancelling"
      set_run(id, expires_at: DateTime.add(Fyrlet.Auth.now(), -1, :second))

      assert Recovery.scan().expired_runs == 1
      assert status(id) == "expired" and run(id).cancellation_outcome == "fenced_timeout"
      send(pid, :continue)
      assert {:ok, :stale} = await_executor(executor)
    end

    test "the user's session expiring does not stop an accepted run (R19)", %{alice: alice} do
      two_steps()
      id = start_run!(alice)

      Repo.update_all(from(s in Fyrlet.Session),
        set: [expires_at: DateTime.add(Fyrlet.Auth.now(), -1, :second)]
      )

      assert drive(id) == "completed"
      assert {:error, %Error{code: "UNAUTHENTICATED"}} = Runs.get(alice.actor, id)
    end

    test "revoking the execution authority refuses new work and fails the run", %{alice: alice} do
      two_steps()
      id = start_run!(alice)
      assert Engine.run_once(id) == :succeeded

      assert :ok = Runs.revoke_grant(alice.actor.project_id, id)
      assert status(id) == "failed" and run(id).error["code"] == "EXECUTION_GRANT_REVOKED"
      assert Engine.run_once(id) == :noop
      assert [{"a", "succeeded"}, {"b", "cancelled"}] = step_statuses(id)
    end

    test "the grant is checked when work is claimed, not only when it is revoked", %{alice: alice} do
      two_steps()
      id = start_run!(alice)
      # Tampering directly with the row: no revoke_grant/2, no scan.
      Repo.update_all(from(g in Grant), set: [revoked_at: Fyrlet.Auth.now()])

      assert Engine.run_once(id) == :noop
      assert status(id) == "failed" and run(id).error["code"] == "EXECUTION_GRANT_REVOKED"
      assert attempts(id) == []

      other = start_run!(alice)

      Repo.update_all(from(g in Grant, where: is_nil(g.revoked_at)),
        set: [expires_at: DateTime.add(Fyrlet.Auth.now(), -1, :second)]
      )

      assert Engine.run_once(other) == :noop
      assert run(other).error["code"] == "EXECUTION_GRANT_REVOKED"
    end

    test "an expired or revoked grant is also found by the scan", %{alice: alice} do
      two_steps()
      id = start_run!(alice)
      Repo.update_all(from(g in Grant), set: [revoked_at: Fyrlet.Auth.now()])
      assert Recovery.scan().grants == 1
      assert run(id).error["code"] == "EXECUTION_GRANT_REVOKED"
    end

    test "a run whose pinned version is gone pauses, resumes, or fails (R18)", %{alice: alice} do
      two_steps()
      calls = counting_steps()
      id = start_run!(alice)
      assert run(id).definition_version == "1"

      Application.put_env(:fyrlet, :run_test_version, "2")
      Application.put_env(:fyrlet, :run_test_impls, %{})
      assert drive(id) == "waiting"
      assert run(id).wait_reason == "definition_unavailable"
      assert calls.("a") == 0 and attempts(id) == []

      # Still unavailable: stays paused. Available again: resumes with the pinned version.
      assert Recovery.scan().definitions == 0
      Application.put_env(:fyrlet, :run_test_impls, %{"1" => Fyrlet.RunsTestDefinition})
      assert Recovery.scan().definitions == 1
      assert drive(id) == "completed"
      assert calls.("a") == 1
    end

    test "an unavailable definition that stays gone fails the run after its grace period", %{
      alice: alice
    } do
      two_steps()
      id = start_run!(alice)
      Application.put_env(:fyrlet, :run_test_version, "9")
      assert drive(id) == "waiting"

      age(id, Fyrlet.Runs.Limits.get(:definition_unavailable_ttl) + 60)
      assert Recovery.scan().definitions == 1
      assert status(id) == "failed" and run(id).error["code"] == "DEFINITION_UNAVAILABLE"
    end

    test "a run keeps using the implementation it was accepted under, never a newer one", %{
      alice: alice
    } do
      defmodule OldImpl do
        def step(name, _input, _context), do: {:ok, %{"impl" => "v1", "step" => name}}
      end

      Application.put_env(:fyrlet, :run_test_impls, %{"1" => OldImpl})
      id = start_run!(alice)
      Application.put_env(:fyrlet, :run_test_version, "2")
      assert drive(id) == "waiting"

      assert %{output: %{"impl" => "v1"}} =
               hd(Repo.all(from(s in Step, where: s.run_id == ^id and s.seq == 0)))

      assert run(id).definition_version == "1"
    end
  end

  describe "retention and observability (R21)" do
    test "pruning removes only old finished runs and never active ones or their facts", %{
      alice: alice
    } do
      two_steps()
      old_done = start_run!(alice)
      {:ok, _} = Runs.cancel(alice.actor, old_done)
      active = start_run!(alice)
      waiting = start_run!(alice)

      Application.put_env(:fyrlet, :run_plans, %{
        "runs.demo" => fn _, _ ->
          {:ok, steps: [%{type: :wait, name: "w", signal: "go", timeout_ms: 60_000}]}
        end
      })

      parked = start_run!(alice)
      drive(parked)
      {:ok, _} = signal(alice.actor, parked, "go", %{}, "early-key")

      long_ago = DateTime.add(Fyrlet.Auth.now(), -400 * 86_400, :second)
      set_run(old_done, finished_at: long_ago)
      set_run(active, inserted_at: long_ago, updated_at: long_ago)
      Repo.update_all(from(s in Signal), set: [received_at: long_ago])

      assert :ok = Fyrlet.PruneWorker.perform(%Oban.Job{})

      assert Repo.get(Run, old_done) == nil
      assert Repo.all(from(s in Step, where: s.run_id == ^old_done)) == []
      assert Repo.get(Run, active) && Repo.get(Run, waiting) && Repo.get(Run, parked)
      assert length(steps(active)) == 2

      # A signal of a finished run goes after its retention, but an active run keeps all of its own.
      assert Repo.aggregate(
               from(g in Grant, where: g.id == ^run(active).execution_grant_id),
               :count
             ) == 1

      assert Repo.aggregate(Grant, :count) == 3
    end

    test "run completion and steps emit telemetry only once committed", %{alice: alice} do
      test = self()
      handler = "run-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler,
        [
          [:fyrlet, :run, :stop],
          [:fyrlet, :run, :step],
          [:fyrlet, :run, :recovery],
          [:fyrlet, :run, :queue],
          [:fyrlet, :run, :wait],
          [:fyrlet, :run, :cancel],
          [:fyrlet, :run, :signal]
        ],
        fn event, measurements, metadata, _ ->
          send(test, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      Application.put_env(:fyrlet, :run_plans, %{
        "runs.demo" => fn _, _ -> {:ok, steps: [%{type: :step, name: "a", input: %{}}]} end
      })

      id = start_run!(alice)
      assert drive(id) == "completed"

      assert_received {:telemetry, [:fyrlet, :run, :step], %{duration_ms: _},
                       %{name: "a", status: "succeeded", attempt: 1}}

      assert_received {:telemetry, [:fyrlet, :run, :stop], %{duration_ms: _, steps: 1},
                       %{status: "completed", operation: "runs.demo"}}

      Recovery.scan()
      assert_received {:telemetry, [:fyrlet, :run, :recovery], %{expired_leases: 0}, _}
      assert_received {:telemetry, [:fyrlet, :run, :queue], %{pending: 0, oldest_age_ms: 0}, _}
      assert_received {:telemetry, [:fyrlet, :run, :wait], %{overdue: 0}, _}

      # A rolled-back transaction must not leak events.
      flush_telemetry()
      failing = start_run!(alice)

      Engine.transact(fn ->
        Fyrlet.Runs.Store.move_run(Fyrlet.Runs.Store.lock_run(failing), "failed", error: %{})
        Repo.rollback(:undo)
      end)

      refute_received {:telemetry, [:fyrlet, :run, :stop], _, _}
    end
  end

  defp flush_telemetry do
    receive do
      {:telemetry, _, _, _} -> flush_telemetry()
    after
      0 -> :ok
    end
  end
end
