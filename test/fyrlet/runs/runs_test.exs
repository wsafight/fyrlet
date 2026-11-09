defmodule Fyrlet.RunsTest do
  use Fyrlet.RunsCase

  setup do
    project = project()
    %{alice: user(project, "alice"), bob: user(project, "bob"), project: project}
  end

  describe "accepting a run (R02)" do
    test "records the run, its grant and nodes, and a wake-up in one transaction", %{alice: alice} do
      assert {:ok, %{"run_id" => id, "status" => "pending", "existing" => false}} =
               start_run(alice, "runs.demo", %{"source" => "a"})

      run = run(id)
      assert run.status == "pending" and run.subject_id == alice.actor.subject_id

      assert run.definition_module == "Fyrlet.RunsTestDefinition" and
               run.definition_version == "1"

      assert [{"prepare", "pending"}, {"approval", "pending"}, {"publish", "pending"}] =
               step_statuses(id)

      grant = Repo.get!(Grant, run.execution_grant_id)
      assert grant.initiator_subject_id == alice.actor.subject_id and is_nil(grant.revoked_at)
      assert DateTime.compare(grant.expires_at, run.expires_at) in [:lt, :eq]

      assert_enqueued worker: Fyrlet.Runs.Worker, args: %{"run_id" => id}
      assert event_types(id) == ["run.created"]
    end

    test "static steps are inserted in one statement with ids, timestamps and encrypted inputs",
         %{
           alice: alice
         } do
      handler = "run-step-inserts-#{Ecto.UUID.generate()}"
      owner = self()

      :telemetry.attach(
        handler,
        [:fyrlet, :repo, :query],
        fn _, _, %{query: query}, owner ->
          if query =~ ~s(INSERT INTO "fyrlet_run_steps"), do: send(owner, :step_insert)
        end,
        owner
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      for count <- [1, 10, 50] do
        Application.put_env(:fyrlet, :run_plans, %{
          "runs.demo" => fn _, _ ->
            {:ok,
             steps:
               for(
                 index <- 1..count,
                 do: %{type: :step, name: "s#{index}", input: %{"index" => index}}
               )}
          end
        })

        id = start_run!(alice)
        assert_receive :step_insert
        refute_receive :step_insert, 20
        rows = steps(id)
        assert length(rows) == count
        assert Enum.map(rows, & &1.seq) == Enum.to_list(0..(count - 1))
        expected = for(index <- 1..count, do: %{"index" => index})
        assert Enum.map(rows, & &1.input) == expected
        assert rows |> Enum.map(& &1.id) |> Enum.uniq() |> length() == count

        assert Enum.all?(rows, fn step ->
                 step.current_attempt == 0 and
                   step.max_attempts == Fyrlet.Runs.Limits.get(:max_attempts) and
                   match?(%DateTime{}, step.inserted_at) and match?(%DateTime{}, step.updated_at)
               end)
      end
    end

    test "the same key and input return the same run; different input conflicts", %{alice: alice} do
      key = key()
      assert {:ok, %{"run_id" => id}} = start_run(alice, "runs.demo", %{"source" => "a"}, key)
      assert {:ok, %{"run_id" => ^id}} = start_run(alice, "runs.demo", %{"source" => "a"}, key)

      assert {:error, %Error{code: "CONFLICT"}} =
               start_run(alice, "runs.demo", %{"source" => "b"}, key)

      assert Repo.aggregate(Run, :count) == 1
      assert Repo.aggregate(Oban.Job, :count) == 2
    end

    test "a run needs the negotiated capability and an idempotency key", %{alice: alice} do
      assert {:error, %Error{code: "UNSUPPORTED_CAPABILITY"}} =
               Fyrlet.Runtime.call(alice.actor, "runs.demo", %{}, key(), capabilities: %{})

      assert {:error, %Error{code: "UNSUPPORTED_CAPABILITY"}} =
               Fyrlet.Runtime.call(alice.actor, "runs.demo", %{}, key())

      assert {:error, %Error{code: "VALIDATION_FAILED"}} =
               Fyrlet.Runtime.call(alice.actor, "runs.demo", %{}, nil, capabilities: caps())

      assert Repo.aggregate(Run, :count) == 0
    end

    test "business keys: return_existing never creates a second run, even once finished", %{
      alice: alice
    } do
      first = start_run!(alice, "runs.demo", %{"key" => "order-1"})

      assert {:ok, %{"run_id" => ^first, "existing" => true}} =
               start_run(alice, "runs.demo", %{"key" => "order-1"})

      {:ok, _} = Runs.cancel(alice.actor, first)
      assert status(first) == "cancelled"

      # a different request key, and the request-level idempotency record is irrelevant
      Repo.delete_all(Fyrlet.Idempotency)

      assert {:ok, %{"run_id" => ^first, "existing" => true}} =
               start_run(alice, "runs.demo", %{"key" => "order-1"})

      assert Repo.aggregate(Run, :count) == 1
    end

    test "business keys: reject_if_active conflicts while active and allows a new run after", %{
      alice: alice
    } do
      first = start_run!(alice, "runs.exclusive", %{"key" => "k"})

      assert {:error, %Error{code: "CONFLICT"}} =
               start_run(alice, "runs.exclusive", %{"key" => "k"})

      {:ok, _} = Runs.cancel(alice.actor, first)

      assert {:ok, %{"run_id" => second, "existing" => false}} =
               start_run(alice, "runs.exclusive", %{"key" => "k"})

      assert second != first
    end

    test "the pending queue per project is bounded", %{alice: alice} do
      put_runs(max_pending_per_project: 2)
      start_run!(alice)
      start_run!(alice)
      assert {:error, %Error{code: "LIMIT_EXCEEDED"}} = start_run(alice)
      assert Repo.aggregate(Run, :count) == 2
    end
  end

  describe "plan validation (R21)" do
    defp plan(steps_fun) do
      Application.put_env(:fyrlet, :run_plans, %{
        "runs.demo" => fn _actor, _input -> {:ok, steps_fun.()} end
      })
    end

    test "invalid plans are refused and leave nothing behind", %{alice: alice} do
      step = fn name -> %{type: :step, name: name, input: %{}} end

      bad = [
        [steps: []],
        [steps: Enum.map(1..51, &step.("s#{&1}"))],
        [steps: [%{type: :step, name: "Bad Name", input: %{}}]],
        [steps: [%{type: :step, name: "ok", input: %{"big" => String.duplicate("x", 70_000)}}]],
        [steps: [%{type: :wait, name: "w", signal: "go"}]],
        [steps: [%{type: :wait, name: "w", signal: "go", timeout_ms: 0}]],
        [steps: [%{type: :wait, name: "w", signal: "go", timeout_ms: 10, on_timeout: :explode}]],
        [steps: [%{type: :step, name: "ok", input: %{}, max_attempts: 99}]],
        [steps: [step.("a")], ttl_seconds: 0],
        [steps: [step.("a")], business_key: String.duplicate("k", 201)],
        [steps: [%{type: :other, name: "x"}]],
        [no: :steps]
      ]

      for options <- bad do
        plan(fn -> options end)
        assert {:error, %Error{code: "VALIDATION_FAILED"}} = start_run(alice), inspect(options)
      end

      assert Repo.aggregate(Run, :count) == 0
      assert Repo.aggregate(Step, :count) == 0
      assert Repo.aggregate(Grant, :count) == 0
      assert Repo.aggregate(Fyrlet.Idempotency, :count) == 0
    end

    test "a plan whose waits outlast the execution authority is refused", %{alice: alice} do
      put_runs(grant_cap: 10)
      plan(fn -> [steps: [%{type: :wait, name: "w", signal: "go", timeout_ms: 60_000}]] end)
      assert {:error, %Error{code: "VALIDATION_FAILED", message: message}} = start_run(alice)
      assert message =~ "authority"
    end

    test "a failing run/3 and a missing capability policy are honoured", %{alice: alice} do
      Application.put_env(:fyrlet, :run_plans, %{
        "runs.demo" => fn _, _ -> {:error, Error.forbidden()} end
      })

      assert {:error, %Error{code: "FORBIDDEN"}} = start_run(alice)
      Application.put_env(:fyrlet, :run_plans, %{"runs.demo" => fn _, _ -> :nonsense end})
      assert {:error, %Error{code: "VALIDATION_FAILED"}} = start_run(alice)
    end
  end

  describe "running steps (R03)" do
    test "a sequential plan advances through waits with outputs passed on", %{alice: alice} do
      test = self()

      Application.put_env(:fyrlet, :run_steps, %{
        "prepare" => fn input, ctx ->
          send(test, {:prepare, input, ctx})
          {:ok, %{"prepared" => input["source"]}}
        end,
        "publish" => fn _input, ctx ->
          send(test, {:publish, ctx.outputs})
          {:ok, %{"published" => true}}
        end
      })

      id = start_run!(alice, "runs.demo", %{"source" => "doc"})
      assert drive(id) == "waiting"
      assert run(id).wait_reason == "signal"

      assert [{"prepare", "succeeded"}, {"approval", "waiting"}, {"publish", "pending"}] =
               step_statuses(id)

      assert_received {:prepare, %{"source" => "doc"}, context}
      assert context.attempt == 1 and context.operation == "runs.demo"
      assert context.operation_id == "#{id}:0"
      assert context.initiator_subject_id == alice.actor.subject_id

      assert {:ok, %{"status" => "consumed"}} =
               signal(alice.actor, id, "user_approval", %{"approved" => true})

      assert drive(id) == "completed"

      assert_received {:publish, outputs}

      assert [
               %{name: "prepare", output: %{"prepared" => "doc"}},
               %{name: "approval", output: %{"signal" => "user_approval"}}
             ] = outputs

      assert run(id).output == %{"published" => true}
      assert is_struct(run(id).finished_at, DateTime)

      assert Enum.all?(attempts(id), &(&1.status == "succeeded"))
      seqs = Enum.map(events(id), & &1.seq)
      assert seqs == Enum.to_list(1..length(seqs))
    end

    test "every committed step makes the next one available atomically", %{alice: alice} do
      Application.put_env(:fyrlet, :run_plans, %{
        "runs.demo" => fn _, _ ->
          {:ok,
           steps: [%{type: :step, name: "a", input: %{}}, %{type: :step, name: "b", input: %{}}]}
        end
      })

      id = start_run!(alice)
      Repo.delete_all(Oban.Job)
      assert Engine.run_once(id) == :succeeded
      assert run(id).current_step_seq == 1
      assert_enqueued worker: Fyrlet.Runs.Worker, args: %{"run_id" => id}
      assert Engine.run_once(id) == :succeeded
      assert status(id) == "completed"
    end

    test "declared step and signal contracts are enforced", %{alice: alice} do
      id = start_run!(alice, "runs.strict", %{"source" => "x"})

      Application.put_env(:fyrlet, :run_steps, %{
        "prepare" => fn _, _ -> {:ok, %{"ok" => "not a boolean"}} end
      })

      assert drive(id) == "failed"
      assert run(id).error["code"] == "INVALID_STEP_OUTPUT"

      Application.put_env(:fyrlet, :run_steps, %{})
      ok = start_run!(alice, "runs.strict", %{"source" => "x"})

      Application.put_env(:fyrlet, :run_steps, %{
        "prepare" => fn _, _ -> {:ok, %{"ok" => true}} end
      })

      assert drive(ok) == "waiting"

      assert {:error, %Error{code: "VALIDATION_FAILED"}} =
               signal(alice.actor, ok, "user_approval", %{"approved" => "yes"})

      assert {:ok, %{"status" => "consumed"}} =
               signal(alice.actor, ok, "user_approval", %{"approved" => true})
    end

    test "a non-map step result and an oversized output fail the run", %{alice: alice} do
      Application.put_env(:fyrlet, :run_steps, %{"prepare" => fn _, _ -> {:ok, "text"} end})
      id = start_run!(alice)
      assert drive(id) == "failed"
      assert run(id).error["code"] == "INVALID_STEP_RESULT"

      Application.put_env(:fyrlet, :run_steps, %{
        "prepare" => fn _, _ -> {:ok, %{"big" => String.duplicate("x", 70_000)}} end
      })

      id = start_run!(alice)
      assert drive(id) == "failed"
      assert run(id).error["code"] == "INVALID_STEP_OUTPUT"
    end
  end

  describe "retries" do
    test "a retryable error is retried until it succeeds, counting only business attempts", %{
      alice: alice
    } do
      counter = :counters.new(1, [])

      Application.put_env(:fyrlet, :run_steps, %{
        "prepare" => fn _, _ ->
          :counters.add(counter, 1, 1)

          if :counters.get(counter, 1) < 3,
            do: {:error, Error.new("UPSTREAM", "busy", %{}, true)},
            else: {:ok, %{"ok" => true}}
        end
      })

      id = start_run!(alice)
      assert drive(id) == "waiting"
      assert :counters.get(counter, 1) == 3
      [prepare | _] = steps(id)
      assert prepare.status == "succeeded" and prepare.current_attempt == 3
      assert Enum.map(attempts(id), & &1.status) == ["failed", "failed", "succeeded"]
      assert "step.retry_scheduled" in event_types(id)
    end

    test "a permanent error fails the run immediately and cancels the rest", %{alice: alice} do
      Application.put_env(:fyrlet, :run_steps, %{
        "prepare" => fn _, _ -> {:error, Error.new("BAD", "no", %{}, false)} end
      })

      id = start_run!(alice)
      assert drive(id) == "failed"
      assert run(id).error["code"] == "BAD"

      assert [{"prepare", "failed"}, {"approval", "cancelled"}, {"publish", "cancelled"}] =
               step_statuses(id)

      assert length(attempts(id)) == 1
    end

    test "attempts are exhausted after the step's maximum", %{alice: alice} do
      Application.put_env(:fyrlet, :run_plans, %{
        "runs.demo" => fn _, _ ->
          {:ok, steps: [%{type: :step, name: "flaky", input: %{}, max_attempts: 2}]}
        end
      })

      Application.put_env(:fyrlet, :run_steps, %{
        "flaky" => fn _, _ -> {:error, Error.new("UPSTREAM", "x", %{}, true)} end
      })

      id = start_run!(alice)
      assert drive(id) == "failed"
      assert run(id).error["code"] == "UPSTREAM"
      assert length(attempts(id)) == 2
    end

    test "an exception in a step is a retryable crash, and its message is not stored", %{
      alice: alice
    } do
      counter = :counters.new(1, [])

      Application.put_env(:fyrlet, :run_steps, %{
        "prepare" => fn _, _ ->
          :counters.add(counter, 1, 1)

          if :counters.get(counter, 1) == 1,
            do: raise("secret token abc123"),
            else: {:ok, %{"ok" => true}}
        end
      })

      id = start_run!(alice)
      assert drive(id) == "waiting"
      refute inspect(Repo.all(Event)) =~ "abc123"
      [first | _] = attempts(id)
      assert first.status == "failed" and first.error["code"] == "STEP_CRASHED"
    end
  end

  describe "local chaining" do
    test "several short steps run in one wake-up, each still leased and committed alone", %{
      alice: alice
    } do
      Application.put_env(:fyrlet, :run_plans, %{
        "runs.demo" => fn _, _ ->
          {:ok, steps: for(n <- ["a", "b", "c"], do: %{type: :step, name: n, input: %{}})}
        end
      })

      put_runs(local_chain: 5)
      id = start_run!(alice)
      assert :ok = Fyrlet.Runs.Worker.perform(%Oban.Job{args: %{"run_id" => id}})
      assert status(id) == "completed"
      assert length(attempts(id)) == 3 and Enum.all?(attempts(id), &(&1.status == "succeeded"))
      assert Enum.map(attempts(id), & &1.execution_epoch) == [1, 2, 3]
    end

    test "the chain is bounded and never loops on a blocked run", %{alice: alice} do
      put_runs(local_chain: 2)
      id = start_run!(alice)
      Fyrlet.Runs.Worker.perform(%Oban.Job{args: %{"run_id" => id}})

      assert [{"prepare", "succeeded"}, {"approval", "waiting"}, {"publish", "pending"}] =
               step_statuses(id)

      assert length(attempts(id)) == 1

      put_runs(local_chain: 1)
      two = start_run!(alice)
      Fyrlet.Runs.Worker.perform(%Oban.Job{args: %{"run_id" => two}})
      assert length(attempts(two)) == 1
    end
  end
end
