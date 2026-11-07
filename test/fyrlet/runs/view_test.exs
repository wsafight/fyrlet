defmodule Fyrlet.Runs.ViewTest do
  use Fyrlet.RunsCase
  alias Fyrlet.Runs.View

  setup do
    Application.put_env(:fyrlet, :effect_test_pid, self())
    on_exit(fn -> Application.delete_env(:fyrlet, :effect_test_pid) end)
    %{alice: user(project(), "alice")}
  end

  defp run_with_effect(alice) do
    Application.put_env(:fyrlet, :run_plans, %{
      "runs.demo" => fn _, _ ->
        {:ok,
         steps: [
           %{type: :step, name: "prepare", input: %{"blob" => String.duplicate("i", 5_000)}},
           %{type: :step, name: "send", input: %{}}
         ]}
      end
    })

    Application.put_env(:fyrlet, :run_steps, %{
      "prepare" => fn _, _ -> {:ok, %{"blob" => String.duplicate("o", 5_000)}} end,
      "send" => fn _, _ ->
        {:effect, %{adapter: "idem", key: "mail", payload: %{"to" => "secret@example.com"}}}
      end
    })

    id = start_run!(alice)
    drive(id)
    [effect] = Repo.all(Fyrlet.Effects.Effect)

    Application.put_env(:fyrlet, :effect_handlers, %{
      dispatch: fn _ -> {:succeeded, %{"token" => "private-result"}} end
    })

    on_exit(fn -> Application.delete_env(:fyrlet, :effect_handlers) end)
    Fyrlet.Effects.dispatch(effect.id)
    drive(id)
    id
  end

  test "the view shows step and effect summaries", %{alice: alice} do
    id = run_with_effect(alice)
    view = View.build(run(id))

    assert [
             %{
               "name" => "prepare",
               "type" => "step",
               "status" => "succeeded",
               "seq" => 0,
               "attempt" => 1
             },
             %{"name" => "send", "status" => "succeeded"}
           ] =
             Enum.map(view["steps"], &Map.take(&1, ["name", "type", "status", "seq", "attempt"]))

    assert [
             %{
               "key" => "mail",
               "adapter" => "idem",
               "status" => "succeeded",
               "policy" => "idempotent",
               "attempts" => 1,
               "resolution_required" => false
             }
           ] = Enum.map(view["effects"], &Map.delete(&1, "id"))

    # The step and effect summaries carry no bodies. (The run's own output is a separate
    # field and, as before, includes what its last step produced.)
    refute inspect(view["effects"]) =~ "secret@example.com"
    refute inspect(view["effects"]) =~ "private-result"
    refute inspect(view["steps"]) =~ String.duplicate("o", 100)
    refute inspect(view["steps"]) =~ String.duplicate("i", 100)
  end

  test "the queries do not read step bodies or effect payloads", %{alice: alice} do
    id = run_with_effect(alice)
    run = run(id)
    test = self()
    handler = {:view_sql, make_ref()}

    :telemetry.attach(
      handler,
      [:fyrlet, :repo, :query],
      fn _, _, meta, _ -> send(test, {:sql, meta.query}) end,
      nil
    )

    View.build(run)
    :telemetry.detach(handler)

    queries = drain([])
    steps = Enum.find(queries, &(&1 =~ ~s(FROM "fyrlet_run_steps")))
    effects = Enum.find(queries, &(&1 =~ ~s(FROM "fyrlet_effects")))

    for column <- ~w("input" "output" "signal_name" "wait_id"),
        do: refute(steps =~ column, "steps read #{column}")

    for column <- ~w("payload" "result" "payload_hash" "last_error"),
        do: refute(effects =~ column, "effects read #{column}")

    assert steps =~ ~s("name") and steps =~ ~s("status")
    assert effects =~ ~s("effect_key") and effects =~ ~s("status")
  end

  defp drain(acc),
    do: receive(do: ({:sql, q} -> drain([q | acc])), after: (0 -> Enum.reverse(acc)))
end
