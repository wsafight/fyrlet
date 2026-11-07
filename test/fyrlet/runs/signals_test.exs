defmodule Fyrlet.RunsSignalsTest do
  use Fyrlet.RunsCase

  setup do
    project = project()
    %{alice: user(project, "alice"), bob: user(project, "bob")}
  end

  defp waiting_run(alice, options \\ []) do
    timeout = options[:timeout_ms] || 60_000
    action = options[:on_timeout] || :fail

    Application.put_env(:fyrlet, :run_plans, %{
      "runs.demo" => fn _, _ ->
        {:ok,
         steps: [
           %{type: :step, name: "prepare", input: %{}},
           %{
             type: :wait,
             name: "approval",
             signal: "user_approval",
             timeout_ms: timeout,
             on_timeout: action
           },
           %{type: :step, name: "publish", input: %{}}
         ]}
      end
    })

    id = start_run!(alice)
    assert drive(id) == "waiting"
    id
  end

  defp expire_wait(id) do
    wait = wait_step(id)
    past = DateTime.add(Fyrlet.Auth.now(), -1, :second)
    Repo.update_all(from(s in Step, where: s.id == ^wait.id), set: [wait_deadline: past])
    wait
  end

  describe "signals (R04)" do
    test "a signal for a waiting node is consumed and the run resumes", %{alice: alice} do
      id = waiting_run(alice)

      assert {:ok, %{"status" => "consumed", "signal_id" => signal_id}} =
               signal(alice.actor, id, "user_approval", %{"approved" => true})

      assert status(id) == "running"

      assert [{"prepare", "succeeded"}, {"approval", "satisfied"}, {"publish", "pending"}] =
               step_statuses(id)

      assert Repo.get!(Signal, signal_id).status == "consumed"
      assert drive(id) == "completed"
    end

    test "a signal that arrives before the run reaches the wait is stored and consumed on arrival",
         %{alice: alice} do
      Application.put_env(:fyrlet, :run_plans, %{
        "runs.demo" => fn _, _ ->
          {:ok,
           steps: [
             %{type: :step, name: "slow", input: %{}},
             %{type: :wait, name: "approval", signal: "user_approval", timeout_ms: 60_000},
             %{type: :step, name: "publish", input: %{}}
           ]}
        end
      })

      id = start_run!(alice)
      wait = wait_step(id)

      assert {:ok, %{"status" => "accepted"}} =
               Runs.signal(alice.actor, id, %{
                 "wait_id" => wait.id,
                 "name" => "user_approval",
                 "payload" => %{},
                 "idempotency_key" => "early"
               })

      assert status(id) == "pending"
      assert Repo.get_by!(Signal, idempotency_key: "early").status == "received"

      assert drive(id) == "completed"
      assert Repo.get_by!(Signal, idempotency_key: "early").status == "consumed"

      assert [{"slow", "succeeded"}, {"approval", "satisfied"}, {"publish", "succeeded"}] =
               step_statuses(id)
    end

    test "replaying a receipt does not consume or advance again; a different payload conflicts",
         %{alice: alice} do
      id = waiting_run(alice)

      assert {:ok, %{"status" => "consumed"} = first} =
               signal(alice.actor, id, "user_approval", %{"x" => 1}, "k1")

      version = run(id).version

      assert {:ok, ^first} = signal(alice.actor, id, "user_approval", %{"x" => 1}, "k1")
      assert run(id).version == version
      assert Repo.aggregate(Signal, :count) == 1

      assert {:error, %Error{code: "CONFLICT"}} =
               signal(alice.actor, id, "user_approval", %{"x" => 2}, "k1")
    end

    test "wrong names, unknown waits and closed waits are rejected", %{alice: alice} do
      id = waiting_run(alice)
      wait = wait_step(id)

      send = fn wait_id, name, key ->
        Runs.signal(alice.actor, id, %{
          "wait_id" => wait_id,
          "name" => name,
          "idempotency_key" => key
        })
      end

      assert {:error, %Error{code: "VALIDATION_FAILED"}} = send.(wait.id, "something_else", "a")

      assert {:error, %Error{code: "VALIDATION_FAILED"}} =
               send.(Ecto.UUID.generate(), "user_approval", "b")

      assert {:error, %Error{code: "VALIDATION_FAILED"}} =
               send.(hd(steps(id)).id, "user_approval", "c")

      assert {:ok, _} = send.(wait.id, "user_approval", "d")
      assert {:error, %Error{code: "CONFLICT"}} = send.(wait.id, "user_approval", "e")
      assert Repo.aggregate(Signal, :count) == 1
    end

    test "terminal and cancelling runs accept no signals", %{alice: alice} do
      id = waiting_run(alice)
      wait = wait_step(id)
      {:ok, _} = Runs.cancel(alice.actor, id)
      assert status(id) == "cancelled"

      assert {:error, %Error{code: "CONFLICT"}} =
               Runs.signal(alice.actor, id, %{
                 "wait_id" => wait.id,
                 "name" => "user_approval",
                 "idempotency_key" => "late"
               })

      assert Repo.aggregate(Signal, :count) == 0
    end

    test "only an authorized caller may signal; other projects see nothing", %{
      alice: alice,
      bob: bob
    } do
      id = waiting_run(alice)
      wait = wait_step(id)
      params = %{"wait_id" => wait.id, "name" => "user_approval", "idempotency_key" => "k"}

      assert {:error, %Error{code: "FORBIDDEN"}} = Runs.signal(bob.actor, id, params)

      stranger = user(project(), "mallory")
      assert {:error, %Error{code: "NOT_FOUND"}} = Runs.signal(stranger.actor, id, params)

      Application.put_env(:fyrlet, :run_authorize, fn _, action, actor, _ref ->
        if action == :signal and actor.subject_id == bob.actor.subject_id,
          do: :ok,
          else: {:error, Error.forbidden()}
      end)

      assert {:ok, %{"status" => "consumed"}} = Runs.signal(bob.actor, id, params)
    end

    test "inbox size and rate are bounded", %{alice: alice} do
      put_runs(signal_inbox: 2)

      Application.put_env(:fyrlet, :run_plans, %{
        "runs.demo" => fn _, _ ->
          {:ok,
           steps: [
             %{type: :step, name: "slow", input: %{}},
             %{type: :wait, name: "approval", signal: "go", timeout_ms: 60_000}
           ]}
        end
      })

      id = start_run!(alice)
      wait = wait_step(id)

      send = fn key ->
        Runs.signal(alice.actor, id, %{
          "wait_id" => wait.id,
          "name" => "go",
          "idempotency_key" => key
        })
      end

      assert {:ok, _} = send.("1")
      assert {:ok, _} = send.("2")
      assert {:error, %Error{code: "LIMIT_EXCEEDED"}} = send.("3")

      put_runs(signal_inbox: 50, signals_per_minute: 2)
      assert {:error, %Error{code: "LIMIT_EXCEEDED", retryable: true}} = send.("4")
    end

    test "bad parameters are validation errors", %{alice: alice} do
      id = waiting_run(alice)

      assert {:error, %Error{code: "VALIDATION_FAILED"}} =
               Runs.signal(alice.actor, id, %{"name" => "x"})

      assert {:error, %Error{code: "NOT_FOUND"}} = Runs.signal(alice.actor, "not-a-uuid", %{})

      wait = wait_step(id)

      assert {:error, %Error{code: "VALIDATION_FAILED"}} =
               Runs.signal(alice.actor, id, %{
                 "wait_id" => wait.id,
                 "name" => "user_approval",
                 "payload" => "text",
                 "idempotency_key" => "k"
               })

      assert {:error, %Error{code: "NOT_FOUND"}} =
               Runs.signal(alice.actor, Ecto.UUID.generate(), %{
                 "wait_id" => wait.id,
                 "name" => "user_approval",
                 "idempotency_key" => "k"
               })
    end
  end

  describe "wait timeouts (R23)" do
    test "on_timeout :fail fails the run and closes the wait", %{alice: alice} do
      id = waiting_run(alice, on_timeout: :fail)
      expire_wait(id)
      assert Engine.expire_wait(id, wait_step(id).id) == :failed

      assert status(id) == "failed"
      assert run(id).error["code"] == "WAIT_TIMEOUT"

      assert [{"prepare", "succeeded"}, {"approval", "timed_out"}, {"publish", "cancelled"}] =
               step_statuses(id)
    end

    test "on_timeout :continue resumes with a timeout marker", %{alice: alice} do
      test = self()
      id = waiting_run(alice, on_timeout: :continue)

      Application.put_env(:fyrlet, :run_steps, %{
        "publish" => fn _, ctx ->
          send(test, {:outputs, ctx.outputs})
          {:ok, %{}}
        end
      })

      expire_wait(id)
      assert Engine.expire_wait(id, wait_step(id).id) == :continued
      assert drive(id) == "completed"
      assert_received {:outputs, outputs}

      assert %{name: "approval", output: %{"timeout" => true}} =
               Enum.find(outputs, &(&1.name == "approval"))
    end

    test "a late signal cannot revive a timed-out wait", %{alice: alice} do
      id = waiting_run(alice, on_timeout: :continue)
      wait = expire_wait(id)
      Engine.expire_wait(id, wait.id)

      assert {:error, %Error{code: "CONFLICT"}} =
               Runs.signal(alice.actor, id, %{
                 "wait_id" => wait.id,
                 "name" => "user_approval",
                 "idempotency_key" => "late"
               })
    end

    test "a timeout that fires before the deadline is a no-op", %{alice: alice} do
      id = waiting_run(alice)
      assert Engine.expire_wait(id, wait_step(id).id) == :noop
      assert status(id) == "waiting"
    end

    test "a signal and a timeout racing for the same wait resolve to exactly one outcome", %{
      alice: alice
    } do
      for order <- [:signal_first, :timeout_first] do
        id = waiting_run(alice, on_timeout: :fail)
        wait = expire_wait(id)

        run_signal = fn ->
          Runs.signal(alice.actor, id, %{
            "wait_id" => wait.id,
            "name" => "user_approval",
            "idempotency_key" => key()
          })
        end

        run_timeout = fn -> Engine.expire_wait(id, wait.id) end

        {first, second} =
          if order == :signal_first,
            do: {run_signal, run_timeout},
            else: {run_timeout, run_signal}

        first.()
        second.()

        outcomes = for s <- steps(id), s.type == "wait", do: s.status
        assert outcomes in [["satisfied"], ["timed_out"]]

        case order do
          :signal_first -> assert outcomes == ["satisfied"] and status(id) == "running"
          :timeout_first -> assert outcomes == ["timed_out"] and status(id) == "failed"
        end
      end
    end

    test "concurrent signal and timeout never both win", %{alice: alice} do
      id = waiting_run(alice, on_timeout: :fail)
      wait = expire_wait(id)

      tasks = [
        Task.async(fn ->
          Runs.signal(alice.actor, id, %{
            "wait_id" => wait.id,
            "name" => "user_approval",
            "idempotency_key" => key()
          })
        end),
        Task.async(fn -> Engine.expire_wait(id, wait.id) end)
      ]

      Task.await_many(tasks)
      [wait_after] = Enum.filter(steps(id), &(&1.type == "wait"))
      assert wait_after.status in ["satisfied", "timed_out"]
      assert status(id) == "failed" == (wait_after.status == "timed_out")
    end
  end
end
