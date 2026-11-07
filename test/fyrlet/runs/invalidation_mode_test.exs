defmodule Fyrlet.Runs.InvalidationModeTest do
  use Fyrlet.RunsCase

  setup do
    previous = Application.fetch_env!(:fyrlet, :durable_invalidation)
    on_exit(fn -> Application.put_env(:fyrlet, :durable_invalidation, previous) end)
    %{alice: user(project(), "alice")}
  end

  defp invalidation_jobs,
    do: Enum.filter(Repo.all(Oban.Job), &(&1.worker == "Fyrlet.InvalidationWorker"))

  test "starting a run notifies the person's run scope without a per-write job", %{alice: alice} do
    Application.put_env(:fyrlet, :durable_invalidation, false)
    Phoenix.PubSub.subscribe(Fyrlet.PubSub, Runs.scope(alice.actor))

    assert {:ok, %{"run_id" => _id, "existing" => false}} =
             start_run(alice, "runs.demo", %{"source" => "a"})

    assert_receive message
    assert elem(message, 0) == :invalidated
    assert elem(message, 1) < 0
    assert invalidation_jobs() == []
  end

  test "durable mode still persists the invalidation job for a run", %{alice: alice} do
    Application.put_env(:fyrlet, :durable_invalidation, true)
    Phoenix.PubSub.subscribe(Fyrlet.PubSub, Runs.scope(alice.actor))

    assert {:ok, %{"run_id" => _id}} = start_run(alice, "runs.demo", %{"source" => "b"})

    assert [%Oban.Job{id: id}] = invalidation_jobs()
    assert_receive message
    assert elem(message, 1) == id
  end
end
