defmodule Fyrlet.EffectsTest do
  use Fyrlet.RunsCase
  alias Fyrlet.Effects
  alias Fyrlet.Effects.{Effect, Event}

  setup do
    Application.put_env(:fyrlet, :effect_test_pid, self())
    project = project()

    on_exit(fn ->
      Application.delete_env(:fyrlet, :effect_test_pid)
      Application.delete_env(:fyrlet, :effect_handlers)
    end)

    %{alice: user(project, "alice")}
  end

  defp send_run(alice, adapter, extra \\ %{}) do
    Application.put_env(:fyrlet, :run_plans, %{
      "runs.demo" => fn _, _ ->
        {:ok,
         steps: [
           %{type: :step, name: "send", input: %{}},
           %{type: :step, name: "after", input: %{}}
         ]}
      end
    })

    Application.put_env(:fyrlet, :run_steps, %{
      "send" => fn _, _ ->
        {:effect,
         Map.merge(%{adapter: adapter, key: "mail", payload: %{"to" => "a@example.com"}}, extra)}
      end
    })

    id = start_run!(alice)
    assert drive(id) == "waiting"
    id
  end

  defp effect(run_id), do: Repo.one!(from(e in Effect, where: e.run_id == ^run_id))
  defp handler(map), do: Application.put_env(:fyrlet, :effect_handlers, map)

  defp etypes(e),
    do:
      Repo.all(from(ev in Event, where: ev.effect_id == ^e.id, order_by: ev.seq, select: ev.type))

  test "intent is stored with the step; delivery resumes the run", %{alice: alice} do
    id = send_run(alice, "idem")
    e = effect(id)
    assert run(id).wait_reason == "effect"
    assert [{"send", "awaiting_effect"}, {"after", "pending"}] = step_statuses(id)
    assert e.status == "pending" and e.delivery_policy == "idempotent"
    assert e.operation_id == "#{id}:0:mail"
    refute_received {:adapter, :dispatch, _}

    assert Effects.dispatch(e.id) == :succeeded
    assert_received {:adapter, :dispatch, %{operation_id: op}}
    assert op == e.operation_id
    assert effect(id).status == "succeeded"
    assert drive(id) == "completed"
    assert Effects.dispatch(e.id) == :noop
  end

  test "a retryable failure is resent with the same operation id", %{alice: alice} do
    id = send_run(alice, "idem")
    e = effect(id)
    counter = :counters.new(1, [])

    handler(%{
      dispatch: fn _ ->
        :counters.add(counter, 1, 1)
        if :counters.get(counter, 1) == 1, do: {:retryable, :busy}, else: {:succeeded, %{}}
      end
    })

    assert Effects.dispatch(e.id) == :retry
    assert Effects.dispatch(e.id) == :succeeded
    assert_received {:adapter, :dispatch, %{operation_id: a, attempt: 1}}
    assert_received {:adapter, :dispatch, %{operation_id: b, attempt: 2}}
    assert a == b
  end

  test "exhausted retries fail the effect and the run", %{alice: alice} do
    id = send_run(alice, "idem", %{max_attempts: 1})
    handler(%{dispatch: fn _ -> {:retryable, :busy} end})
    assert Effects.dispatch(effect(id).id) == :failed
    assert status(id) == "failed"
  end

  test "a definite failure fails the run", %{alice: alice} do
    id = send_run(alice, "idem")
    handler(%{dispatch: fn _ -> {:failed, "rejected"} end})
    assert Effects.dispatch(effect(id).id) == :failed
    assert status(id) == "failed" and run(id).error["code"] == "EFFECT_FAILED"
  end

  test "a lost response within an idempotency window is resent with the same key", %{alice: alice} do
    id = send_run(alice, "idem")
    e = effect(id)
    counter = :counters.new(1, [])

    handler(%{
      dispatch: fn _ ->
        :counters.add(counter, 1, 1)
        if :counters.get(counter, 1) == 1, do: :unknown, else: {:succeeded, %{}}
      end
    })

    assert Effects.dispatch(e.id) == :retry
    assert effect(id).status == "pending"
    assert Effects.dispatch(e.id) == :succeeded
    assert_received {:adapter, :dispatch, %{operation_id: a}}
    assert_received {:adapter, :dispatch, %{operation_id: b}}
    assert a == b
  end

  test "an adapter that raises leaves the outcome unknown, never failed", %{alice: alice} do
    id = send_run(alice, "query")
    handler(%{dispatch: fn _ -> raise "boom secret-xyz" end})
    assert Effects.dispatch(effect(id).id) == :unknown
    e = effect(id)
    assert e.status == "unknown" and e.delivery_policy == "query_only"
    refute inspect(Repo.all(Event)) =~ "secret-xyz"
    assert status(id) == "waiting"
  end

  test "query-only: not_found never causes a resend; a found result resolves", %{alice: alice} do
    id = send_run(alice, "query")
    e = effect(id)
    handler(%{dispatch: fn _ -> :unknown end, query: fn _ -> :not_found end})
    Effects.dispatch(e.id)
    assert Effects.reconcile(e.id) == :unresolved
    assert Effects.reconcile(e.id) == :unresolved
    assert effect(id).status == "unknown"

    assert Enum.count(
             Process.info(self(), :messages) |> elem(1),
             &match?({:adapter, :dispatch, _}, &1)
           ) == 1

    handler(%{query: fn _ -> {:succeeded, %{"seen" => true}} end})
    assert Effects.reconcile(e.id) == :succeeded
    assert effect(id).status == "succeeded"
    assert drive(id) == "completed"
  end

  test "an outcome that stays unknown past the reconcile window needs a person, not a failure", %{
    alice: alice
  } do
    id = send_run(alice, "query")
    e = effect(id)
    handler(%{dispatch: fn _ -> :unknown end})
    Effects.dispatch(e.id)

    Application.put_env(:fyrlet, :effects,
      retry_base_seconds: 0,
      retry_max_seconds: 0,
      reconcile_delay_seconds: 0,
      reconcile_ttl_seconds: 0
    )

    on_exit(fn ->
      Application.put_env(:fyrlet, :effects,
        retry_base_seconds: 0,
        retry_max_seconds: 0,
        reconcile_delay_seconds: 0
      )
    end)

    assert Effects.recover(Fyrlet.Auth.now()).escalated == 1
    e = effect(id)
    assert e.status == "unknown" and e.resolution_required
    assert status(id) == "waiting"
    assert {:error, %{code: "EFFECT_UNKNOWN"}} = Effects.ensure_known(e.id)
  end

  test "manual policy pauses; resolution is audited and resend needs acknowledgement", %{
    alice: alice
  } do
    id = send_run(alice, "manual")
    e = effect(id)
    handler(%{dispatch: fn _ -> :unknown end})
    assert Effects.dispatch(e.id) == :unknown
    assert effect(id).resolution_required

    assert {:error, %{code: "VALIDATION_FAILED"}} = Effects.resolve(e.id, "succeeded", "", "x")
    assert {:error, %{code: "CONFLICT"}} = Effects.resolve(e.id, "resend", "ops", "checked")
    assert effect(id).status == "unknown"

    assert {:ok, _} =
             Effects.resolve(e.id, "resend", "ops", "provider has no record",
               acknowledge_duplicates: true
             )

    handler(%{dispatch: fn _ -> {:succeeded, %{}} end})
    assert Effects.dispatch(e.id) == :succeeded
    types = etypes(e)
    assert "effect.unknown" in types and "effect.resolved" in types and "effect.claimed" in types
    assert Enum.count(types, &(&1 == "effect.claimed")) == 2
  end

  test "a person can mark an unknown effect succeeded, failed or abandoned", %{alice: alice} do
    for {decision, run_status} <- [
          {"succeeded", "running"},
          {"failed", "failed"},
          {"abandon", "failed"}
        ] do
      id = send_run(alice, "manual")
      e = effect(id)
      handler(%{dispatch: fn _ -> :unknown end})
      Effects.dispatch(e.id)
      assert {:ok, _} = Effects.resolve(e.id, decision, "ops", "evidence")
      assert status(id) == run_status
      assert {:error, %{code: "CONFLICT"}} = Effects.resolve(e.id, decision, "ops", "again")
    end
  end

  test "cancelling the run withdraws an unsent effect and records one already in flight", %{
    alice: alice
  } do
    id = send_run(alice, "idem")
    e = effect(id)
    {:ok, _} = Runs.cancel(alice.actor, id)
    assert effect(id).status == "cancelled"
    assert Effects.dispatch(e.id) == :noop
    refute_received {:adapter, :dispatch, _}

    id2 = send_run(alice, "idem")
    e2 = effect(id2)
    test = self()

    handler(%{
      dispatch: fn _ ->
        send(test, :in_flight)
        receive do: (:go -> {:succeeded, %{"late" => true}})
      end
    })

    task = Task.async(fn -> Effects.dispatch(e2.id) end)
    assert_receive :in_flight
    {:ok, _} = Runs.cancel(alice.actor, id2)
    assert status(id2) == "cancelled"
    send(task.pid, :go)
    assert Task.await(task) == :succeeded
    assert effect(id2).status == "succeeded"
    assert status(id2) == "cancelled"
    assert Enum.map(steps(id2), & &1.status) == ["cancelled", "cancelled"]
  end

  test "receipts are idempotent and a contradicting one is recorded, not applied", %{alice: alice} do
    id = send_run(alice, "query")
    e = effect(id)
    handler(%{dispatch: fn _ -> {:accepted, "ext-1"} end})
    assert Effects.dispatch(e.id) == :accepted
    assert effect(id).external_ref == "ext-1"

    assert {:ok, %{"status" => "applied"}} =
             Effects.receipt(e.id, "r1", "succeeded", %{"delivered" => true})

    assert {:ok, %{"status" => "duplicate"}} = Effects.receipt(e.id, "r1", "succeeded")
    assert {:error, %{code: "CONFLICT"}} = Effects.receipt(e.id, "r2", "failed", "x")
    assert effect(id).status == "succeeded"
    assert "effect.receipt_conflict" in etypes(e)
    assert drive(id) == "completed"

    assert {:error, %{code: "NOT_FOUND"}} =
             Effects.receipt(Ecto.UUID.generate(), "r", "succeeded")
  end

  test "a dispatcher that died after claiming is treated as unknown, and its late result is ignored",
       %{alice: alice} do
    id = send_run(alice, "manual")
    e = effect(id)
    test = self()

    handler(%{
      dispatch: fn _ ->
        send(test, :sent)
        receive do: (:go -> {:succeeded, %{}})
      end
    })

    task = Task.async(fn -> Effects.dispatch(e.id) end)
    assert_receive :sent

    Repo.update_all(from(x in Effect, where: x.id == ^e.id),
      set: [lease_expires_at: DateTime.add(Fyrlet.Auth.now(), -5, :second)]
    )

    assert Effects.recover(Fyrlet.Auth.now()).lost_claims == 1
    assert effect(id).status == "unknown"

    send(task.pid, :go)
    assert Task.await(task) == :stale
    assert effect(id).status == "unknown"
    assert "effect.late_result" in etypes(e)
  end

  test "the same effect key with a different request conflicts; the same request is reused", %{
    alice: alice
  } do
    id = send_run(alice, "idem")
    run = run(id)
    step = hd(steps(id))
    now = Fyrlet.Auth.now()
    spec = %{adapter: "idem", key: "mail", payload: %{"to" => "a@example.com"}}
    assert {:ok, same} = Effects.create(run, step, spec, now)
    assert same.id == effect(id).id

    assert {:error, %{code: "EFFECT_CONFLICT"}} =
             Effects.create(run, step, %{spec | payload: %{"to" => "b@example.com"}}, now)

    assert {:error, %{code: "VALIDATION_FAILED"}} =
             Effects.create(run, step, %{spec | adapter: "nope"}, now)

    assert {:error, %{code: "VALIDATION_FAILED"}} =
             Effects.create(run, step, %{spec | key: "Bad Key"}, now)
  end

  test "the run view shows effects", %{alice: alice} do
    id = send_run(alice, "idem")

    assert {:ok,
            %{
              "effects" => [
                %{"status" => "pending", "adapter" => "idem", "policy" => "idempotent"}
              ]
            }} = Runs.get(alice.actor, id)
  end

  test "once the receiver's idempotency window has passed an unknown outcome is no longer resent",
       %{alice: alice} do
    id = send_run(alice, "idem")
    e = effect(id)
    handler(%{dispatch: fn _ -> :unknown end})
    # First send happened long ago, beyond the adapter's 3600 s window.
    Repo.update_all(from(x in Effect, where: x.id == ^e.id),
      set: [first_dispatched_at: DateTime.add(Fyrlet.Auth.now(), -7_200, :second)]
    )

    assert Effects.dispatch(e.id) == :unknown
    assert effect(id).status == "unknown"

    assert Enum.count(
             Process.info(self(), :messages) |> elem(1),
             &match?({:adapter, :dispatch, _}, &1)
           ) == 1
  end
end
