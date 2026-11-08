defmodule Fyrlet.PruningTest do
  use Fyrlet.DataCase, async: false
  alias Fyrlet.{Idempotency, Pruning, PruneWorker}
  alias Fyrlet.Features.Stream

  setup do
    previous = Application.fetch_env(:fyrlet, :pruning)
    Application.put_env(:fyrlet, :pruning, max_rows: 2, max_duration_ms: 5_000)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fyrlet, :pruning, value)
        :error -> Application.delete_env(:fyrlet, :pruning)
      end
    end)

    :ok
  end

  test "one retention job respects its row budget and schedules bounded continuation" do
    alice = user(project())
    for index <- 1..5, do: add(alice.actor, "record #{index}")
    Repo.update_all(Idempotency, set: [expires_at: DateTime.add(Auth.now(), -60, :second)])
    handler = {__MODULE__, self()}

    :telemetry.attach(
      handler,
      [:fyrlet, :prune],
      fn _, measurements, metadata, owner -> send(owner, {measurements, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok = PruneWorker.perform(%Oban.Job{})
    assert Repo.aggregate(Idempotency, :count) == 3
    assert_receive {%{deleted: 2}, %{limited: true}}

    assert Repo.exists?(
             from(job in Oban.Job,
               where:
                 job.worker == "Fyrlet.PruneWorker" and job.args == ^%{"offset" => 1} and
                   job.state == "scheduled"
             )
           )

    for offset <- 1..3, do: PruneWorker.perform(%Oban.Job{args: %{"offset" => offset}})
    assert Repo.aggregate(Idempotency, :count) == 0
    assert Repo.aggregate(TestRecord, :count) == 5
  end

  test "partial stream trimming advances its retention floor only over deleted entries" do
    project_id = project().project.id

    {:ok, {:ok, _cursor}} =
      Repo.transaction(fn ->
        Stream.append(project_id, "room", for(index <- 1..7, do: %{"n" => index}))
      end)

    assert {1, %{deleted: 2, limited: true}} = Pruning.run(fn -> Stream.prune(2) end)
    assert Repo.aggregate(Stream.Entry, :count) == 5
    assert Repo.get_by!(Stream.Head, project_id: project_id, name: "room").trimmed_before == 3
    assert Stream.after_cursor(project_id, "room", "0:1") == :reset
    assert {:ok, _, _, _} = Stream.after_cursor(project_id, "room", "0:2")
    for _index <- 1..2, do: Pruning.run(fn -> Stream.prune(2) end)
    assert Repo.aggregate(Stream.Entry, :count) == 2
    assert Repo.get_by!(Stream.Head, project_id: project_id, name: "room").trimmed_before == 6
  end

  test "the duration budget stops new work and scoped state is restored after failures" do
    Application.put_env(:fyrlet, :pruning, max_rows: 2, max_duration_ms: 1)

    assert {:done, %{limited: true, deleted: 0}} =
             Pruning.run(fn ->
               Process.sleep(5)
               refute Pruning.available?()
               :done
             end)

    assert_raise RuntimeError, fn -> Pruning.run(fn -> raise "failed cleanup" end) end
    assert Pruning.batch_size(5_000) == 5_000
  end
end
