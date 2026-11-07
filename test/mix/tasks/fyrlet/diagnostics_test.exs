defmodule Mix.Tasks.Fyrlet.DiagnosticsTest do
  use Fyrlet.RunsCase

  alias Fyrlet.Effects.Effect
  alias Mix.Tasks.Fyrlet.Effects, as: EffectsTask
  alias Mix.Tasks.Fyrlet.Plugins, as: PluginsTask
  alias Mix.Tasks.Fyrlet.Runs, as: RunsTask

  setup do
    previous_shell = Mix.shell()
    previous_plugins = Application.fetch_env!(:fyrlet, :plugins)
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
      Application.put_env(:fyrlet, :plugins, previous_plugins)
    end)

    %{alice: user(project())}
  end

  describe "fyrlet.runs" do
    test "reports an empty result" do
      RunsTask.run([])

      assert_received {:mix_shell, :info, ["0 stuck run(s)"]}
      refute_received {:mix_shell, :info, _}
    end

    test "lists stale unfinished runs with their current step and excludes recent and terminal runs",
         %{alice: alice} do
      pending = start_run!(alice, "runs.demo", %{"source" => "private-input"})
      waiting = start_run!(alice)
      assert drive(waiting) == "waiting"
      finished = start_run!(alice)
      assert {:ok, _result} = Runs.cancel(alice.actor, finished)
      start_run!(alice)
      age(pending, 900)
      age(waiting, 600)
      age(finished, 1_200)

      RunsTask.run([])

      pending_row = shell_json()
      assert pending_row["run_id"] == pending
      assert pending_row["project_id"] == alice.actor.project_id
      assert pending_row["operation"] == "runs.demo"
      assert pending_row["status"] == "pending"
      assert pending_row["idle_seconds"] >= 900
      assert pending_row["expires_at"] == DateTime.to_iso8601(run(pending).expires_at)

      assert pending_row["step"] == %{
               "name" => "prepare",
               "type" => "step",
               "status" => "pending",
               "attempt" => 0
             }

      refute Map.has_key?(pending_row, "input")
      refute Jason.encode!(pending_row) =~ "private-input"

      waiting_row = shell_json()
      assert waiting_row["run_id"] == waiting
      assert waiting_row["status"] == "waiting"
      assert waiting_row["wait_reason"] == "signal"
      assert waiting_row["step"]["name"] == "approval"
      assert_received {:mix_shell, :info, ["2 stuck run(s)"]}
      refute_received {:mix_shell, :info, _}
    end

    test "limits results to the oldest run", %{alice: alice} do
      newer = start_run!(alice)
      oldest = start_run!(alice)
      age(newer, 600)
      age(oldest, 1_200)

      RunsTask.run(["--limit", "1"])

      assert shell_json()["run_id"] == oldest
      assert_received {:mix_shell, :info, ["1 stuck run(s)"]}
      refute_received {:mix_shell, :info, _}
    end

    test "uses the requested inactivity threshold", %{alice: alice} do
      recent = start_run!(alice)
      old = start_run!(alice)
      age(recent, 600)
      age(old, 3_600)

      RunsTask.run(["--stuck-after", "1800"])

      assert shell_json()["run_id"] == old
      assert_received {:mix_shell, :info, ["1 stuck run(s)"]}
      refute_received {:mix_shell, :info, _}
    end
  end

  describe "fyrlet.effects" do
    setup do
      Application.put_env(:fyrlet, :run_plans, %{
        "runs.demo" => fn _, _ ->
          {:ok, steps: [%{type: :step, name: "send", input: %{}}]}
        end
      })

      Application.put_env(:fyrlet, :run_steps, %{
        "send" => fn _, _ ->
          {:effect,
           %{adapter: "idem", key: "mail", payload: %{"secret" => "private-provider-payload"}}}
        end
      })

      :ok
    end

    test "reports an empty result" do
      EffectsTask.run([])

      assert_received {:mix_shell, :info, ["0 effect(s) need attention"]}
      refute_received {:mix_shell, :info, _}
    end

    test "lists unknown, unresolved and overdue effects without exposing their payloads", %{
      alice: alice
    } do
      past = DateTime.add(Auth.now(), -600, :second)
      future = DateTime.add(Auth.now(), 600, :second)

      expected = [
        effect(alice, status: "unknown", next_attempt_at: future),
        effect(alice, resolution_required: true, next_attempt_at: future),
        effect(alice, next_attempt_at: past),
        effect(alice, status: "claimed", lease_expires_at: past)
      ]

      effect(alice, next_attempt_at: future)
      effect(alice, status: "succeeded", next_attempt_at: past)

      EffectsTask.run([])

      rows = for _effect <- expected, do: shell_json()
      assert MapSet.new(rows, & &1["effect_id"]) == MapSet.new(expected, & &1.id)

      for row <- rows do
        assert row["adapter"] == "idem"
        assert row["policy"] == "idempotent"
        assert row["attempts"] == 0
        assert is_binary(row["run_id"])
        assert is_binary(row["since"])
        refute Map.has_key?(row, "payload")
        refute Jason.encode!(row) =~ "private-provider-payload"
      end

      assert Enum.any?(rows, & &1["resolution_required"])
      assert_received {:mix_shell, :info, ["4 effect(s) need attention"]}
      refute_received {:mix_shell, :info, _}
    end

    test "uses the requested overdue threshold", %{alice: alice} do
      effect(alice, next_attempt_at: DateTime.add(Auth.now(), -600, :second))
      old = effect(alice, next_attempt_at: DateTime.add(Auth.now(), -7_200, :second))

      EffectsTask.run(["--overdue-after", "3600"])

      assert shell_json()["effect_id"] == old.id
      assert_received {:mix_shell, :info, ["1 effect(s) need attention"]}
      refute_received {:mix_shell, :info, _}
    end
  end

  describe "fyrlet.plugins" do
    test "reports when no plugins are configured" do
      Application.put_env(:fyrlet, :plugins, [])

      PluginsTask.run([])

      assert_received {:mix_shell, :info, ["No plugins configured."]}
      refute_received {:mix_shell, :info, _}
    end

    test "reports active plugins and degraded optional plugins" do
      PluginsTask.run([])

      assert_received {:mix_shell, :info, [counter]}
      assert counter =~ "counter 1.2.0  active"
      assert counter =~ "capabilities=[counter]"
      assert counter =~ "migration_dirs=1"
      assert_received {:mix_shell, :info, [mirror]}
      assert mirror =~ "mirror 0.1.0  active"
      assert_received {:mix_shell, :info, [broken]}
      assert broken =~ "broken 0.0.1  degraded (optional, entry closed)"
      assert broken =~ "does_not_exist"
      refute_received {:mix_shell, :info, _}
    end

    test "reports required failures and missing modules without crashing" do
      missing = Module.concat(__MODULE__, MissingPlugin)

      Application.put_env(:fyrlet, :plugins, [
        Fyrlet.TestPlugins.Broken,
        {missing, required: false}
      ])

      PluginsTask.run([])

      assert_received {:mix_shell, :info, [required]}
      assert required =~ "FAILED (required)"
      assert required =~ "does_not_exist"
      assert_received {:mix_shell, :info, [optional]}
      assert optional =~ inspect(missing)
      assert optional =~ "?  degraded (optional, entry closed)"
      assert optional =~ "capabilities=[]  migration_dirs=0"
      refute_received {:mix_shell, :info, _}
    end
  end

  defp shell_json do
    assert_received {:mix_shell, :info, [json]}
    Jason.decode!(json)
  end

  defp effect(alice, fields) do
    id = start_run!(alice)
    assert drive(id) == "waiting"

    Repo.one!(from(entry in Effect, where: entry.run_id == ^id))
    |> Ecto.Changeset.change(fields)
    |> Repo.update!()
  end
end
