defmodule Fyrlet.RunsExecutorTest do
  use Fyrlet.RunsCase
  alias Fyrlet.Features.Executors
  alias Fyrlet.Runs.Executor
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]
  @endpoint FyrletWeb.Endpoint

  setup do
    project = project()
    alice = user(project, "alice")

    {:ok, %{executor: gpu, token: gpu_token}} =
      Executors.create(project.project.id, "gpu-1", ["gpu"])

    {:ok, %{executor: cpu, token: cpu_token}} =
      Executors.create(project.project.id, "cpu-1", ["cpu"])

    %{
      project: project,
      alice: alice,
      gpu: gpu,
      gpu_token: gpu_token,
      cpu: cpu,
      cpu_token: cpu_token
    }
  end

  defp plan(steps),
    do:
      Application.put_env(:fyrlet, :run_plans, %{
        "runs.external" => fn _, _ -> {:ok, steps: steps} end
      })

  defp step(name), do: %{type: :step, name: name, input: %{"n" => name}}
  defp lease(work), do: {work["attempt_id"], work["lease_id"], work["execution_epoch"]}

  test "in-process workers leave queued steps alone; the executor takes them with a lease", %{
    alice: alice,
    gpu: gpu
  } do
    plan([step("render"), step("after")])
    id = start_run!(alice, "runs.external")

    assert Engine.run_once(id) == :noop
    assert attempts(id) == []

    assert {:ok, work} = Executor.claim(gpu, ["gpu"])

    assert %{
             "step" => "render",
             "queue" => "gpu",
             "input" => %{"n" => "render"},
             "definition_version" => "1",
             "execution_epoch" => 1
           } = work

    assert status(id) == "running"
    assert [%{status: "leased", executor_id: executor_id}] = attempts(id)

    assert executor_id == gpu.id
    assert {:ok, nil} = Executor.claim(gpu, ["gpu"])
  end

  test "a successful report advances the run exactly like local work", %{alice: alice, gpu: gpu} do
    plan([step("render"), step("after")])
    id = start_run!(alice, "runs.external")
    {:ok, work} = Executor.claim(gpu, ["gpu"])
    {attempt, lease, epoch} = lease(work)

    assert {:ok, %{"status" => "accepted"}} =
             Executor.report(gpu, attempt, lease, epoch, %{
               "status" => "succeeded",
               "output" => %{"frames" => 3}
             })

    assert [{"render", "succeeded"}, {"after", "pending"}] = step_statuses(id)
    assert hd(steps(id)).output == %{"frames" => 3}

    {:ok, second} = Executor.claim(gpu, ["gpu"])
    {a2, l2, e2} = lease(second)
    assert e2 > epoch
    {:ok, _} = Executor.report(gpu, a2, l2, e2, %{"status" => "succeeded", "output" => %{}})
    assert status(id) == "completed"
  end

  test "the same report twice is acknowledged; a different one conflicts", %{
    alice: alice,
    gpu: gpu
  } do
    plan([step("render")])
    id = start_run!(alice, "runs.external")
    {:ok, work} = Executor.claim(gpu, ["gpu"])
    {attempt, lease, epoch} = lease(work)
    report = %{"status" => "succeeded", "output" => %{"b" => 2, "a" => 1}}

    assert {:ok, %{"status" => "accepted"}} = Executor.report(gpu, attempt, lease, epoch, report)

    assert {:ok, %{"status" => "duplicate"}} =
             Executor.report(gpu, attempt, lease, epoch, %{
               "status" => "succeeded",
               "output" => %{"a" => 1, "b" => 2}
             })

    assert {:error, %Error{code: "CONFLICT"}} =
             Executor.report(gpu, attempt, lease, epoch, %{
               "status" => "succeeded",
               "output" => %{"a" => 9}
             })

    assert {:error, %Error{code: "CONFLICT"}} =
             Executor.report(gpu, attempt, lease, epoch, %{
               "status" => "failed",
               "error" => %{"code" => "X", "message" => "y"}
             })

    assert status(id) == "completed" and hd(steps(id)).output == %{"b" => 2, "a" => 1}
  end

  test "failures follow the retry rules, retryable or not", %{alice: alice, gpu: gpu} do
    plan([step("render")])
    id = start_run!(alice, "runs.external")
    {:ok, w1} = Executor.claim(gpu, ["gpu"])
    {a, l, e} = lease(w1)

    {:ok, _} =
      Executor.report(gpu, a, l, e, %{
        "status" => "failed",
        "error" => %{"code" => "OOM", "message" => "out of memory", "retryable" => true}
      })

    assert [{"render", "pending"}] = step_statuses(id)

    {:ok, w2} = Executor.claim(gpu, ["gpu"])
    assert w2["attempt"] == 2
    {a, l, e} = lease(w2)

    {:ok, _} =
      Executor.report(gpu, a, l, e, %{
        "status" => "failed",
        "error" => %{"code" => "BAD_INPUT", "message" => "no", "retryable" => false}
      })

    assert status(id) == "failed" and run(id).error["code"] == "BAD_INPUT"
  end

  test "a lost lease cannot report, and its late result is only audited", %{
    alice: alice,
    gpu: gpu
  } do
    plan([step("render")])
    id = start_run!(alice, "runs.external")
    {:ok, slow} = Executor.claim(gpu, ["gpu"])
    expire_leases(id)
    assert Recovery.scan().expired_leases == 1

    {:ok, fresh} = Executor.claim(gpu, ["gpu"])
    assert fresh["attempt"] == 2 and fresh["execution_epoch"] > slow["execution_epoch"]

    {a, l, e} = lease(slow)

    assert {:error, %Error{code: "LEASE_LOST"}} =
             Executor.report(gpu, a, l, e, %{
               "status" => "succeeded",
               "output" => %{"late" => true}
             })

    assert {:error, %Error{code: "LEASE_LOST"}} = Executor.heartbeat(gpu, a, l, e)
    assert [{"render", "running"}] = step_statuses(id)

    {a, l, e} = lease(fresh)
    assert {:ok, _} = Executor.report(gpu, a, l, e, %{"status" => "succeeded", "output" => %{}})
    assert status(id) == "completed"
  end

  test "an expired lease is refused at once, before recovery has taken it over", %{
    alice: alice,
    gpu: gpu
  } do
    plan([step("render")])
    id = start_run!(alice, "runs.external")
    {:ok, work} = Executor.claim(gpu, ["gpu"])
    {a, l, e} = lease(work)

    # Five seconds past expiry. Nothing has scanned, replaced or cancelled anything.
    Repo.update_all(from(x in Attempt, where: x.id == ^a),
      set: [lease_expires_at: DateTime.add(Auth.now(), -5, :second)]
    )

    expired = Repo.get!(Attempt, a).lease_expires_at

    assert {:error, %Error{code: "LEASE_LOST"}} = Executor.heartbeat(gpu, a, l, e)
    # A status poll does not fail: it tells the executor the lease is gone and to stop.
    assert {:ok, %{"cancel" => true, "lease_valid" => false}} = Executor.status(gpu, a, l, e)

    assert {:error, %Error{code: "LEASE_LOST"}} =
             Executor.report(gpu, a, l, e, %{"status" => "succeeded", "output" => %{"late" => 1}})

    # The lease was not renewed and the report changed nothing but the audit trail.
    assert Repo.get!(Attempt, a).lease_expires_at == expired
    assert [%{status: "leased"}] = attempts(id)
    assert [{"render", "running"}] = step_statuses(id)
    assert status(id) == "running"
    assert Enum.any?(events(id), &(&1.type == "attempt.late_result"))

    # Recovery then takes over as before, and the replacement works.
    assert Recovery.scan().expired_leases == 1
    {:ok, fresh} = Executor.claim(gpu, ["gpu"])
    {a2, l2, e2} = lease(fresh)

    assert {:ok, _} =
             Executor.report(gpu, a2, l2, e2, %{"status" => "succeeded", "output" => %{}})

    assert status(id) == "completed"
  end

  test "a lease that expired while a cancel was pending is refused too", %{
    alice: alice,
    gpu: gpu
  } do
    plan([step("render")])
    id = start_run!(alice, "runs.external")
    {:ok, work} = Executor.claim(gpu, ["gpu"])
    {a, l, e} = lease(work)
    {:ok, %{"status" => "cancelling"}} = Runs.cancel(alice.actor, id)

    Repo.update_all(from(x in Attempt, where: x.id == ^a),
      set: [lease_expires_at: DateTime.add(Auth.now(), -5, :second)]
    )

    assert {:error, %Error{code: "LEASE_LOST"}} = Executor.heartbeat(gpu, a, l, e)
    # A status poll does not fail: it tells the executor the lease is gone and to stop.
    assert {:ok, %{"cancel" => true, "lease_valid" => false}} = Executor.status(gpu, a, l, e)
  end

  test "a wrong lease id or epoch is refused", %{alice: alice, gpu: gpu} do
    plan([step("render")])
    start_run!(alice, "runs.external")
    {:ok, work} = Executor.claim(gpu, ["gpu"])
    {a, l, e} = lease(work)
    ok = %{"status" => "succeeded", "output" => %{}}

    assert {:error, %Error{code: "LEASE_LOST"}} =
             Executor.report(gpu, a, Ecto.UUID.generate(), e, ok)

    assert {:error, %Error{code: "LEASE_LOST"}} = Executor.report(gpu, a, l, e + 1, ok)

    assert {:error, %Error{code: "VALIDATION_FAILED"}} =
             Executor.report(gpu, a, l, e, %{"status" => "maybe"})
  end

  test "heartbeats extend a live lease and stop extending once a cancel is accepted", %{
    alice: alice,
    gpu: gpu
  } do
    plan([step("render")])
    id = start_run!(alice, "runs.external")
    {:ok, work} = Executor.claim(gpu, ["gpu"])
    {a, l, e} = lease(work)
    first = Repo.get!(Attempt, a).lease_expires_at

    Repo.update_all(from(x in Attempt, where: x.id == ^a),
      set: [lease_expires_at: DateTime.add(first, -30, :second)]
    )

    assert {:ok, %{"cancel" => false}} = Executor.heartbeat(gpu, a, l, e)
    extended = Repo.get!(Attempt, a).lease_expires_at
    assert DateTime.compare(extended, DateTime.add(first, -30, :second)) == :gt

    assert {:ok, %{"cancel" => false, "lease_valid" => true}} = Executor.status(gpu, a, l, e)
    {:ok, %{"status" => "cancelling"}} = Runs.cancel(alice.actor, id)
    assert {:ok, %{"cancel" => true, "lease_valid" => true}} = Executor.status(gpu, a, l, e)
    before = Repo.get!(Attempt, a).lease_expires_at
    assert {:ok, %{"cancel" => true}} = Executor.heartbeat(gpu, a, l, e)
    assert Repo.get!(Attempt, a).lease_expires_at == before

    # Reporting after the cancel is audited; the run ends confirmed.
    assert {:ok, _} = Executor.report(gpu, a, l, e, %{"status" => "succeeded", "output" => %{}})
    assert status(id) == "cancelled" and run(id).cancellation_outcome == "confirmed"
    assert {:ok, %{"cancel" => true, "lease_valid" => false}} = Executor.status(gpu, a, l, e)
  end

  test "an executor never reaches other queues, projects or attempts", %{
    alice: alice,
    gpu: gpu,
    cpu: cpu
  } do
    plan([step("render"), %{type: :step, name: "cpu_step", input: %{}}])
    id = start_run!(alice, "runs.external")
    assert {:ok, nil} = Executor.claim(cpu, ["gpu"])
    assert {:ok, nil} = Executor.claim(gpu, ["cpu"])
    assert {:ok, nil} = Executor.claim(cpu, ["cpu", "gpu"])

    {:ok, work} = Executor.claim(gpu, ["gpu"])
    {a, l, e} = lease(work)

    assert {:error, %Error{code: "NOT_FOUND"}} =
             Executor.report(cpu, a, l, e, %{"status" => "succeeded"})

    assert {:error, %Error{code: "NOT_FOUND"}} = Executor.heartbeat(cpu, a, l, e)
    {:ok, _} = Executor.report(gpu, a, l, e, %{"status" => "succeeded", "output" => %{}})

    # The second step is routed to the cpu queue by name.
    assert {:ok, nil} = Executor.claim(gpu, ["gpu"])
    assert {:ok, %{"step" => "cpu_step"}} = Executor.claim(cpu, ["cpu"])
    assert run(id).status == "running"

    foreign = project()
    {:ok, %{executor: stranger}} = Executors.create(foreign.project.id, "x", ["gpu"])
    other = user(foreign, "eve")
    plan([step("render")])
    start_run!(alice, "runs.external")
    assert {:ok, nil} = Executor.claim(stranger, ["gpu"])
    _ = other
  end

  test "credentials are validated and can be revoked on their own", %{
    project: project,
    gpu_token: token,
    gpu: gpu
  } do
    assert {:ok, %{id: id}} = Executors.authenticate(token)
    assert id == gpu.id
    assert {:error, %Error{code: "UNAUTHENTICATED"}} = Executors.authenticate("rtx_nope")
    assert {:error, %Error{code: "UNAUTHENTICATED"}} = Executors.authenticate(project.service_key)
    assert {:error, %Error{code: "UNAUTHENTICATED"}} = Executors.authenticate(nil || "")

    Executors.revoke(gpu.id)
    assert {:error, %Error{code: "UNAUTHENTICATED"}} = Executors.authenticate(token)

    assert {:error, %Error{code: "VALIDATION_FAILED"}} =
             Executors.create(project.project.id, "bad", [])

    assert {:error, %Error{code: "VALIDATION_FAILED"}} =
             Executors.create(project.project.id, "bad", ["Not Valid"])
  end

  describe "over HTTP" do
    defp post_as(token, path, body),
      do: build_conn() |> put_req_header("authorization", "Bearer " <> token) |> post(path, body)

    test "claim, heartbeat, status and result", %{alice: alice, gpu_token: token} do
      plan([step("render")])
      id = start_run!(alice, "runs.external")

      work =
        post_as(token, "/api/v1/executor/claim", %{"queues" => ["gpu"]})
        |> json_response(200)
        |> get_in(["data"])

      assert work["step"] == "render"
      body = %{"lease_id" => work["lease_id"], "epoch" => work["execution_epoch"]}
      path = "/api/v1/executor/attempts/#{work["attempt_id"]}"

      assert json_response(post_as(token, path <> "/heartbeat", body), 200)["data"]["cancel"] ==
               false

      poll =
        build_conn() |> put_req_header("authorization", "Bearer " <> token) |> get(path, body)

      assert json_response(poll, 200)["data"] == %{"cancel" => false, "lease_valid" => true}

      done =
        post_as(
          token,
          path <> "/result",
          Map.merge(body, %{"status" => "succeeded", "output" => %{"ok" => true}})
        )

      assert json_response(done, 200)["data"]["status"] == "accepted"
      assert status(id) == "completed"

      assert json_response(
               post_as(
                 token,
                 path <> "/result",
                 Map.merge(body, %{
                   "status" => "failed",
                   "error" => %{"code" => "A", "message" => "b"}
                 })
               ),
               409
             )["error"]["code"] == "CONFLICT"

      stale = post_as(token, path <> "/heartbeat", body)
      assert json_response(stale, 409)["error"]["code"] == "LEASE_LOST"
    end

    test "tokens, bodies and the capability are checked", %{
      alice: alice,
      gpu_token: token,
      project: project
    } do
      assert json_response(
               post_as(project.service_key, "/api/v1/executor/claim", %{"queues" => ["gpu"]}),
               401
             )

      assert json_response(
               post_as(alice.token, "/api/v1/executor/claim", %{"queues" => ["gpu"]}),
               401
             )

      assert json_response(post_as(token, "/api/v1/executor/claim", %{}), 422)

      assert json_response(
               post_as(token, "/api/v1/executor/attempts/#{Ecto.UUID.generate()}/heartbeat", %{}),
               422
             )

      previous = Application.fetch_env!(:fyrlet, :capabilities)
      Application.put_env(:fyrlet, :capabilities, Map.delete(previous, "executors"))
      on_exit(fn -> Application.put_env(:fyrlet, :capabilities, previous) end)

      assert json_response(post_as(token, "/api/v1/executor/claim", %{"queues" => ["gpu"]}), 404)[
               "error"
             ]["code"] == "NOT_FOUND"
    end
  end
end
