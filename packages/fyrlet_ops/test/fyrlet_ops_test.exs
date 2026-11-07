defmodule FyrletOpsTest.Handler do
  @behaviour FyrletOps.AlertHandler
  def handle_alert(kind, alert),
    do: send(Application.fetch_env!(:fyrlet, :ops_test_pid), {kind, alert})
end

defmodule FyrletOpsTest.Crashing do
  @behaviour FyrletOps.AlertHandler
  def handle_alert(_kind, _alert), do: raise("handler down")
end

defmodule FyrletOpsTest do
  use FyrletOps.Case
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]
  alias Fyrlet.Effects.Effect
  alias FyrletOps.Status
  @endpoint FyrletWeb.Endpoint

  setup do
    Application.put_env(:fyrlet, :ops_test_pid, self())
    Status.reset()

    on_exit(fn ->
      Application.delete_env(:fyrlet, :ops_test_pid)

      for key <- [:thresholds, :alert_handlers, :stuck_after_seconds],
          do: Application.delete_env(:fyrlet_ops, key)

      Status.reset()
    end)

    a = project()
    b = project()
    %{a: a, b: b, alice: user(a, "alice"), bob: user(b, "bob")}
  end

  defp put_ops(options),
    do: Enum.each(options, fn {key, value} -> Application.put_env(:fyrlet_ops, key, value) end)

  defp backdate(run_id, seconds) do
    past = DateTime.add(Fyrlet.Auth.now(), -seconds, :second)

    Repo.update_all(from(r in Run, where: r.id == ^run_id),
      set: [updated_at: past, inserted_at: past]
    )
  end

  defp unknown_effect(run_id, project_id) do
    step = hd(steps(run_id))

    Repo.insert!(%Effect{
      project_id: project_id,
      run_id: run_id,
      step_id: step.id,
      effect_key: "mail",
      operation_id: "#{run_id}:0:mail",
      adapter: "idem",
      adapter_version: "1",
      delivery_policy: "manual",
      payload: %{},
      payload_hash: <<0>>,
      status: "unknown",
      resolution_required: true
    })
  end

  test "a healthy installation reports no alerts", %{alice: alice} do
    id = start_run!(alice)
    drive(id)
    status = Status.status()
    assert status["runs"]["by_status"]["waiting"] == 1
    assert status["runs"]["stuck"] == 0
    assert Status.alerts(status) == []
  end

  test "stuck runs and unresolved effects fire alerts that carry no identifiers", %{
    a: a,
    alice: alice
  } do
    id = start_run!(alice)
    drive(id)
    backdate(id, 3_600)
    unknown_effect(id, a.project.id)

    alerts = Status.alerts(Status.status()) |> Map.new(&{&1["name"], &1})
    assert alerts["runs.stuck"]["value"] == 1

    assert alerts["effects.unresolved"] |> Map.take(["severity", "value"]) ==
             %{"severity" => "critical", "value" => 1}

    refute inspect(alerts) =~ id
  end

  test "a project sees only its own numbers", %{a: a, b: b, alice: alice, bob: bob} do
    for owner <- [alice, alice, bob], do: drive(start_run!(owner))
    assert Status.status(a.project.id)["runs"]["by_status"] == %{"waiting" => 2}
    assert Status.status(b.project.id)["runs"]["by_status"] == %{"waiting" => 1}
    assert Status.status(a.project.id)["limits"]["concurrent"] == 2
    assert Status.status(a.project.id)["plugins"] == %{}
    assert Status.status(:all)["runs"]["by_status"] == %{"waiting" => 3}
  end

  test "thresholds are configurable and invalid ones fall back to the default", %{alice: alice} do
    id = start_run!(alice)
    backdate(id, 600)
    assert Status.alerts(Status.status()) |> Enum.any?(&(&1["name"] == "queue.age_seconds"))

    put_ops(thresholds: %{"queue.age_seconds" => 100_000})
    refute Status.alerts(Status.status()) |> Enum.any?(&(&1["name"] == "queue.age_seconds"))

    put_ops(thresholds: %{"queue.age_seconds" => -5})
    assert Status.alerts(Status.status()) |> Enum.any?(&(&1["name"] == "queue.age_seconds"))
  end

  test "handlers hear about transitions once, not on every evaluation", %{alice: alice} do
    put_ops(alert_handlers: [FyrletOpsTest.Crashing, FyrletOpsTest.Handler])
    id = start_run!(alice)
    drive(id)
    assert {:ok, []} = Status.evaluate()
    refute_received {:firing, _}

    backdate(id, 3_600)
    assert {:ok, [%{"name" => "runs.stuck"}]} = Status.evaluate()
    assert_received {:firing, %{"name" => "runs.stuck"}}

    Status.evaluate()
    refute_received {:firing, _}

    Repo.update_all(from(r in Run, where: r.id == ^id), set: [updated_at: Fyrlet.Auth.now()])
    assert {:ok, []} = Status.evaluate()
    assert_received {:resolved, %{"name" => "runs.stuck"}}
    Status.evaluate()
    refute_received {:resolved, _}
  end

  test "alert transitions and status are emitted as telemetry", %{alice: alice} do
    parent = self()
    id = {:ops, make_ref()}

    :telemetry.attach_many(
      id,
      [[:fyrlet, :ops, :alert], [:fyrlet, :ops, :status]],
      fn event, measurements, metadata, _ ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    run = start_run!(alice)
    drive(run)
    backdate(run, 3_600)
    Status.evaluate()

    assert_received {:telemetry, [:fyrlet, :ops, :alert], %{firing: 1},
                     %{name: "runs.stuck", severity: "warning"}}

    assert_received {:telemetry, [:fyrlet, :ops, :status], %{alerts: 1, stuck_runs: 1}, _}
  end

  test "the ticker evaluates alerts on its own", %{alice: alice} do
    put_ops(alert_handlers: [FyrletOpsTest.Handler])
    id = start_run!(alice)
    drive(id)
    backdate(id, 3_600)
    send(FyrletOps.Ticker, :tick)
    # A synchronous call returns only after the :tick above has been handled.
    :sys.get_state(FyrletOps.Ticker)
    assert_received {:firing, %{"name" => "runs.stuck"}}
  end

  test "the plugin passes the conformance suite" do
    assert Fyrlet.Conformance.Plugin.failures(FyrletOps) == []
  end

  describe "GET /api/v1/plugins/ops/status" do
    test "needs a service key and is confined to its project", %{
      a: a,
      b: b,
      alice: alice,
      bob: bob
    } do
      drive(start_run!(alice))
      drive(start_run!(bob))
      stuck = start_run!(bob)
      drive(stuck)
      backdate(stuck, 3_600)

      fetch = fn key ->
        build_conn()
        |> put_req_header("authorization", "Bearer " <> key)
        |> get("/api/v1/plugins/ops/status")
      end

      assert %{"data" => %{"status" => status, "alerts" => []}} =
               json_response(fetch.(a.service_key), 200)

      assert status["runs"]["by_status"] == %{"waiting" => 1}

      assert %{"data" => %{"alerts" => [%{"name" => "runs.stuck", "value" => 1}]}} =
               json_response(fetch.(b.service_key), 200)

      assert json_response(fetch.("rtk_unknown"), 401)
      assert json_response(fetch.(alice.token), 401)
      assert json_response(build_conn() |> get("/api/v1/plugins/ops/status"), 401)
    end
  end
end
