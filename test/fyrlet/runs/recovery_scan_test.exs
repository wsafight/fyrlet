defmodule Fyrlet.RunsRecoveryScanTest do
  use Fyrlet.RunsCase

  import ExUnit.CaptureLog

  setup do
    test_process = self()
    handler = {__MODULE__, test_process}

    :telemetry.attach_many(
      handler,
      [[:fyrlet, :run, :recovery], [:fyrlet, :run, :queue]],
      fn event, measurements, _metadata, _config ->
        send(test_process, {:scan_event, event, measurements})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    %{alice: user(project())}
  end

  test "expiration scans respect the batch limit and eventually repair every project", %{
    alice: alice
  } do
    put_runs(scan_batch: 2)
    other = user(project())
    ids = for actor <- [alice, other, alice, other, alice], do: start_run!(actor)
    past = DateTime.add(Auth.now(), -1, :second)
    Repo.update_all(from(entry in Run, where: entry.id in ^ids), set: [expires_at: past])

    assert for(_index <- 1..4, do: Recovery.scan().expired_runs) == [2, 2, 1, 0]

    for id <- ids do
      assert status(id) == "expired"
      assert Enum.count(event_types(id), &(&1 == "run.expired")) == 1
    end
  end

  test "wait timeout batches make progress without consuming or recording a timeout twice", %{
    alice: alice
  } do
    put_runs(scan_batch: 2)

    ids =
      for _index <- 1..5 do
        id = start_run!(alice)
        assert drive(id) == "waiting"
        wait = wait_step(id)

        Repo.update_all(from(entry in Step, where: entry.id == ^wait.id),
          set: [wait_deadline: DateTime.add(Auth.now(), -1, :second)]
        )

        id
      end

    assert for(_index <- 1..4, do: Recovery.scan().wait_timeouts) == [2, 2, 1, 0]

    for id <- ids do
      assert status(id) == "failed"
      assert run(id).error["code"] == "WAIT_TIMEOUT"
      assert Enum.count(event_types(id), &(&1 == "wait.timed_out")) == 1
    end
  end

  test "an expired lease fences a cancellation before its cancel deadline", %{alice: alice} do
    id = start_run!(alice)
    assert {:execute, context} = Engine.claim(id)
    assert {:ok, %{"status" => "cancelling"}} = Runs.cancel(alice.actor, id)
    assert DateTime.compare(run(id).cancel_deadline, Auth.now()) == :gt
    expire_leases(id)

    assert %{expired_leases: 1, cancel_fenced: 0} = Recovery.scan()
    assert run(id).status == "cancelled"
    assert run(id).cancellation_outcome == "fenced_timeout"
    assert [%{status: "abandoned"}] = attempts(id)
    assert Engine.commit_result(context, {:ok, %{"late" => true}}) == :stale
    assert status(id) == "cancelled"
  end

  test "the periodic scanner repairs expired runs and continues scheduling scans", %{alice: alice} do
    id = start_run!(alice)
    set_run(id, expires_at: DateTime.add(Auth.now(), -1, :second))
    put_runs(scan_interval_ms: 20)

    with_scanner(fn scanner ->
      assert_receive {:scan_event, [:fyrlet, :run, :recovery], %{expired_runs: 1}}, 2_000
      assert status(id) == "expired"
      assert_receive {:scan_event, [:fyrlet, :run, :recovery], %{expired_runs: 0}}, 2_000
      send(scanner, {:unrecognized, :message})
      assert :sys.get_state(scanner) == %{}
      assert Process.alive?(scanner)
    end)
  end

  test "a failed scan is logged and does not prevent subsequent periodic recovery" do
    put_runs(scan_interval_ms: 60_000, scan_batch: :invalid)

    with_scanner(fn scanner ->
      log =
        capture_log(fn ->
          send(scanner, :scan)
          assert :sys.get_state(scanner) == %{}
        end)

      assert log =~ "Run recovery failed"
      assert Process.alive?(scanner)
      put_runs(scan_interval_ms: 20, scan_batch: 2)
      send(scanner, :scan)
      assert_receive {:scan_event, [:fyrlet, :run, :recovery], %{expired_runs: 0}}, 2_000
      assert_receive {:scan_event, [:fyrlet, :run, :recovery], %{expired_runs: 0}}, 2_000
    end)
  end

  test "queue telemetry reports the oldest pending run and busiest project's live leases", %{
    alice: alice
  } do
    pending = start_run!(alice)
    set_run(pending, inserted_at: DateTime.add(Auth.now(), -2, :second))
    other = user(project())

    for actor <- [alice, alice, other] do
      id = start_run!(actor)
      assert {:execute, _context} = Engine.claim(id)
    end

    assert Recovery.scan().expired_leases == 0

    assert_received {:scan_event, [:fyrlet, :run, :queue],
                     %{pending: 1, busiest_project_leases: 2, oldest_age_ms: age}}

    assert age >= 2_000
  end

  defp with_scanner(fun) do
    scanner = start_supervised!(Supervisor.child_spec(Recovery, restart: :temporary))

    try do
      fun.(scanner)
    after
      if Process.alive?(scanner), do: GenServer.stop(scanner)
    end
  end
end
