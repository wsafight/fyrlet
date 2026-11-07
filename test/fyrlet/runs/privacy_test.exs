defmodule Fyrlet.RunsPrivacyTest do
  use Fyrlet.RunsCase
  import ExUnit.CaptureLog
  alias Fyrlet.{Effects, Vault}
  alias Fyrlet.Effects.Effect
  alias Fyrlet.Runs.Privacy

  @k1 :crypto.strong_rand_bytes(32)
  @k2 :crypto.strong_rand_bytes(32)

  setup do
    %{alice: user(project(), "alice"), bob: user(project(), "bob")}
  end

  defp raw(sql, params), do: Repo.query!(sql, params).rows

  describe "encryption at rest" do
    test "values are stored as ciphertext, read back transparently, and keep working end to end",
         %{alice: alice} do
      Application.put_env(:fyrlet, :vault, keys: %{"k1" => @k1}, current: "k1")

      Application.put_env(:fyrlet, :run_steps, %{
        "prepare" => fn input, _ -> {:ok, %{"echo" => input["source"], "token" => "tok-777"}} end
      })

      id = start_run!(alice, "runs.demo", %{"source" => "plain-secret-42"})
      assert drive(id) == "waiting"

      [[input, output]] =
        raw(
          "SELECT r.input::text, s.output::text FROM fyrlet_runs r JOIN fyrlet_run_steps s ON s.run_id = r.id WHERE r.id = $1 AND s.seq = 0",
          [Ecto.UUID.dump!(id)]
        )

      for stored <- [input, output],
          do: refute(stored =~ "plain-secret-42" or stored =~ "tok-777")

      assert input =~ "__enc"

      assert run(id).input == %{"source" => "plain-secret-42"}
      assert hd(steps(id)).output == %{"echo" => "plain-secret-42", "token" => "tok-777"}

      {:ok, _} = signal(alice.actor, id, "user_approval", %{"approved" => "ssn-123"})
      assert drive(id) == "completed"

      [[payload]] =
        raw("SELECT payload::text FROM fyrlet_run_signals WHERE run_id = $1", [
          Ecto.UUID.dump!(id)
        ])

      refute payload =~ "ssn-123"
    end

    test "effect payloads and results are encrypted but dedupe hashes still work", %{alice: alice} do
      Application.put_env(:fyrlet, :vault, keys: %{"k1" => @k1}, current: "k1")

      Application.put_env(:fyrlet, :run_plans, %{
        "runs.demo" => fn _, _ -> {:ok, steps: [%{type: :step, name: "send", input: %{}}]} end
      })

      Application.put_env(:fyrlet, :run_steps, %{
        "send" => fn _, _ ->
          {:effect, %{adapter: "idem", key: "k", payload: %{"to" => "ceo@example.com"}}}
        end
      })

      Application.put_env(:fyrlet, :effect_handlers, %{
        dispatch: fn effect ->
          send(Process.whereis(:effect_probe) || self(), {:saw, effect.payload})
          {:succeeded, %{"id" => "msg-9"}}
        end
      })

      id = start_run!(alice)
      drive(id)
      effect = Repo.one!(Effect)

      [[payload]] =
        raw("SELECT payload::text FROM fyrlet_effects WHERE id = $1", [Ecto.UUID.dump!(effect.id)])

      refute payload =~ "ceo@example.com"

      assert Effects.dispatch(effect.id) == :succeeded
      assert_received {:saw, %{"to" => "ceo@example.com"}}
      assert Repo.get!(Effect, effect.id).result == %{"id" => "msg-9"}
      assert byte_size(effect.payload_hash) == 32
      on_exit(fn -> Application.delete_env(:fyrlet, :effect_handlers) end)
    end

    test "old keys still read old data after rotation; a vanished key fails loudly" do
      Application.put_env(:fyrlet, :vault, keys: %{"old" => @k1}, current: "old")
      old = Vault.encrypt(%{"a" => 1})
      Application.put_env(:fyrlet, :vault, keys: %{"old" => @k1, "new" => @k2}, current: "new")
      fresh = Vault.encrypt(%{"a" => 2})

      assert old["k"] == "old" and fresh["k"] == "new"
      assert {:ok, %{"a" => 1}} = Vault.decrypt(old)
      assert {:ok, %{"a" => 2}} = Vault.decrypt(fresh)

      Application.put_env(:fyrlet, :vault, keys: %{"new" => @k2}, current: "new")
      assert :error = Vault.decrypt(old)

      assert :error =
               Vault.decrypt(%{fresh | "d" => Base.encode64(:crypto.strong_rand_bytes(60))})
    end

    test "tampered ciphertext is rejected, and no vault means plain storage" do
      Application.put_env(:fyrlet, :vault, keys: %{"k" => @k1}, current: "k")
      sealed = Vault.encrypt(%{"x" => 1})
      <<head::binary-20, byte, rest::binary>> = Base.decode64!(sealed["d"])
      tampered = %{sealed | "d" => Base.encode64(head <> <<Bitwise.bxor(byte, 1)>> <> rest)}
      assert :error = Vault.decrypt(tampered)

      Application.delete_env(:fyrlet, :vault)
      refute Vault.enabled?()
      assert Vault.encrypt(%{"x" => 1}) == %{"x" => 1}
      assert {:ok, %{"x" => 1}} = Vault.decrypt(%{"x" => 1})

      Application.put_env(:fyrlet, :vault, keys: %{"short" => "tiny"}, current: "short")
      refute Vault.enabled?()
    end
  end

  describe "redaction" do
    test "sensitive keys are hidden at any depth wherever a run is presented", %{alice: alice} do
      Application.put_env(:fyrlet, :run_plans, %{
        "runs.private" => fn _, _ -> {:ok, steps: [%{type: :step, name: "a", input: %{}}]} end
      })

      Application.put_env(:fyrlet, :run_steps, %{
        "a" => fn _, _ ->
          {:ok,
           %{
             "secret" => "hunter2",
             "ok" => 1,
             "nested" => %{"source" => "deep", "keep" => 2},
             "list" => [%{"secret" => "x"}]
           }}
        end
      })

      id = start_run!(alice, "runs.private")
      drive(id)

      {:ok, view} = Runs.get(alice.actor, id)

      assert Jason.decode!(view["output_json"]) == %{
               "secret" => "[redacted]",
               "ok" => 1,
               "nested" => %{"source" => "[redacted]", "keep" => 2},
               "list" => [%{"secret" => "[redacted]"}]
             }

      refute inspect(view) =~ "hunter2"
      assert run(id).output["secret"] == "hunter2"
    end
  end

  describe "purging" do
    defp finished(alice, input \\ %{"source" => "keepsake"}) do
      Application.put_env(:fyrlet, :run_plans, %{
        "runs.demo" => fn _, _ ->
          {:ok,
           steps: [
             %{type: :step, name: "a", input: %{"private" => "x"}},
             %{type: :wait, name: "w", signal: "go", timeout_ms: 60_000}
           ]}
        end
      })

      Application.put_env(:fyrlet, :run_steps, %{
        "a" => fn _, _ -> {:ok, %{"result" => "private-output"}} end
      })

      id = start_run!(alice, "runs.demo", input)
      drive(id)
      {:ok, _} = signal(alice.actor, id, "go", %{"pii" => "ssn"}, "purge-key")
      drive(id)
      assert status(id) == "completed"
      id
    end

    test "a person's finished runs lose their content but keep their facts", %{
      alice: alice,
      bob: bob
    } do
      mine = finished(alice)
      theirs = finished(bob)
      before_events = length(events(mine))

      key =
        Repo.one!(
          from(s in Signal, where: s.run_id == ^mine, select: {s.idempotency_key, s.input_hash})
        )

      assert %{purged: 1, still_active: 0, held: 0} =
               Privacy.purge_subject(alice.actor.project_id, alice.actor.subject_id)

      run = run(mine)

      assert run.input == %{"purged" => true} and run.output == %{"purged" => true} and
               run.purged_at

      assert hd(run.plan["nodes"])["input"] == %{}
      assert Enum.all?(steps(mine), &(&1.input == %{"purged" => true} or is_nil(&1.input)))

      assert Repo.one!(from(s in Signal, where: s.run_id == ^mine, select: s.payload)) == %{
               "purged" => true
             }

      # What identifies and audits the run is untouched.
      assert run.status == "completed" and run.operation == "runs.demo" and run.id == mine

      assert Repo.one!(
               from(s in Signal,
                 where: s.run_id == ^mine,
                 select: {s.idempotency_key, s.input_hash}
               )
             ) == key

      assert length(events(mine)) == before_events + 1 and "run.purged" in event_types(mine)

      # Another person's run is untouched.
      assert run(theirs).input == %{"source" => "keepsake"} and is_nil(run(theirs).purged_at)
    end

    test "active runs are cancelled first; one still held by an executor is reported, not purged",
         %{alice: alice} do
      parked = start_run!(alice)
      drive(parked)

      assert %{purged: 1, still_active: 0} =
               Privacy.purge_subject(alice.actor.project_id, alice.actor.subject_id)

      assert status(parked) == "cancelled" and run(parked).input == %{"purged" => true}

      running = start_run!(alice)
      pause_at(:before_commit)
      executor = spawn_executor(fn -> Engine.run_once(running) end)
      assert_receive {:paused, pid, :before_commit}

      assert %{still_active: 1} =
               Privacy.purge_subject(alice.actor.project_id, alice.actor.subject_id)

      assert run(running).purged_at == nil
      send(pid, :continue)
      await_executor(executor)
      assert %{purged: 1} = Privacy.purge_subject(alice.actor.project_id, alice.actor.subject_id)
    end

    test "a run with an unresolved external effect is held, because its payload is still needed",
         %{alice: alice} do
      Application.put_env(:fyrlet, :run_plans, %{
        "runs.demo" => fn _, _ -> {:ok, steps: [%{type: :step, name: "send", input: %{}}]} end
      })

      Application.put_env(:fyrlet, :run_steps, %{
        "send" => fn _, _ ->
          {:effect, %{adapter: "manual", key: "k", payload: %{"to" => "x"}}}
        end
      })

      id = start_run!(alice)
      drive(id)
      Application.put_env(:fyrlet, :effect_handlers, %{dispatch: fn _ -> :unknown end})
      on_exit(fn -> Application.delete_env(:fyrlet, :effect_handlers) end)
      Effects.dispatch(Repo.one!(Effect).id)

      {:ok, _} = Runs.cancel(alice.actor, id)

      assert %{held: 1, purged: 0} =
               Privacy.purge_subject(alice.actor.project_id, alice.actor.subject_id)

      assert Repo.one!(Effect).payload == %{"to" => "x"}
    end

    test "payload retention purges old finished runs only", %{alice: alice} do
      old = finished(alice)
      recent = finished(alice, %{"source" => "recent"})
      put_runs(payload_retention: 3_600)
      set_run(old, finished_at: DateTime.add(Fyrlet.Auth.now(), -7_200, :second))

      assert Privacy.purge_expired(Fyrlet.Auth.now()) == 1
      assert run(old).purged_at && is_nil(run(recent).purged_at)

      put_runs(payload_retention: nil)
      assert Privacy.purge_expired(Fyrlet.Auth.now()) == 0
    end

    test "de-duplication survives a purge: the business key and idempotency record still answer",
         %{alice: alice} do
      key = key()

      Application.put_env(:fyrlet, :run_plans, %{
        "runs.demo" => fn _, _ ->
          {:ok, steps: [%{type: :step, name: "a", input: %{}}], business_key: "once"}
        end
      })

      assert {:ok, %{"run_id" => id}} = start_run(alice, "runs.demo", %{}, key)
      drive(id)
      Privacy.purge_subject(alice.actor.project_id, alice.actor.subject_id)
      assert {:ok, %{"run_id" => ^id}} = start_run(alice, "runs.demo", %{}, key)

      assert {:ok, %{"run_id" => ^id, "existing" => true}} =
               start_run(alice, "runs.demo", %{}, key())
    end
  end

  test "logs carry no payload data even when steps, effects and plans fail", %{alice: alice} do
    Application.put_env(:fyrlet, :run_steps, %{
      "prepare" => fn _, _ -> raise "boom hunter2-secret" end
    })

    Application.put_env(:fyrlet, :run_advance, fn _, _ -> raise "advance hunter2-secret" end)

    log =
      capture_log(fn ->
        id = start_run!(alice, "runs.demo", %{"source" => "hunter2-secret"})
        drive(id)
        # Planning fails at creation: the run is refused and nothing is stored.
        assert {:error, _} = start_run(alice, "runs.dynamic", %{})
      end)

    refute log =~ "hunter2-secret"
  end
end
