defmodule Fyrlet.IngestRetentionTest do
  use Fyrlet.DataCase, async: false
  alias Fyrlet.Features.Ingest
  alias Fyrlet.Features.Ingest.{Batch, Item}
  alias Fyrlet.Retention

  @day 86_400

  setup do
    previous = Application.get_env(:fyrlet, :retention)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fyrlet, :retention, previous),
        else: Application.delete_env(:fyrlet, :retention)
    end)

    Application.delete_env(:fyrlet, :retention)
    a = user(project(), "alice")
    b = user(project(), "bob")
    %{a: a, b: b}
  end

  defp retention(value), do: Application.put_env(:fyrlet, :retention, value)
  defp ago(days), do: DateTime.add(Fyrlet.Auth.now(), -days * @day, :second)

  # A batch inserted `age` days ago with one item per `{status, processed_days_ago}`.
  defp batch(user, age, items) do
    stamp = ago(age)

    batch =
      Repo.insert!(%Batch{
        project_id: user.actor.project_id,
        subject_id: user.actor.subject_id,
        operation: "events.ingest",
        total: length(items),
        inserted_at: stamp,
        updated_at: stamp
      })

    for {{status, processed}, seq} <- Enum.with_index(items, 1) do
      Repo.insert!(%Item{
        batch_id: batch.id,
        project_id: user.actor.project_id,
        subject_id: user.actor.subject_id,
        operation: "events.ingest",
        seq: seq,
        item_key: "k-#{batch.id}-#{seq}",
        payload_hash: :crypto.hash(:sha256, "#{seq}"),
        payload: %{"n" => seq},
        status: status,
        processed_at: processed && ago(processed),
        inserted_at: stamp,
        updated_at: stamp
      })
    end

    batch
  end

  defp items(user),
    do: Repo.aggregate(from(i in Item, where: i.project_id == ^user.actor.project_id), :count)

  defp batches(user),
    do: Repo.aggregate(from(b in Batch, where: b.project_id == ^user.actor.project_id), :count)

  test "finished items past the default are deleted, then their emptied batch", %{a: a} do
    assert Retention.default(:ingest_seconds) == 7 * @day
    old = batch(a, 9, [{"done", 8}, {"dead", 8}])
    recent = batch(a, 2, [{"done", 1}])

    assert {2, 1} = Ingest.prune()
    assert items(a) == 1 and batches(a) == 1
    assert Repo.get(Batch, recent.id) && is_nil(Repo.get(Batch, old.id))
  end

  test "pending items are never deleted, however old, and keep their batch", %{a: a} do
    stuck = batch(a, 60, [{"pending", nil}, {"done", 59}])

    assert {1, 0} = Ingest.prune()
    assert items(a) == 1
    assert Repo.get(Batch, stuck.id), "a batch with an unprocessed item stays"
    assert [%{status: "pending"}] = Repo.all(from(i in Item, where: i.batch_id == ^stuck.id))
  end

  test "a project can keep data for less time, or forever, while others use the default", %{
    a: a,
    b: b
  } do
    forever = user(project(), "carol")

    retention(
      projects: %{
        a.actor.project_id => [ingest_seconds: @day],
        forever.actor.project_id => [ingest_seconds: nil]
      }
    )

    for u <- [a, b, forever], do: batch(u, 3, [{"done", 2}])

    Ingest.prune()
    assert {items(a), batches(a)} == {0, 0}, "override of one day removes a two-day-old item"
    assert {items(b), batches(b)} == {1, 1}, "the default of seven days keeps it"
    assert {items(forever), batches(forever)} == {1, 1}, "nil keeps it regardless"

    batch(forever, 400, [{"dead", 399}])
    Ingest.prune()
    assert items(forever) == 2
  end

  test "an override can be longer than the default", %{a: a, b: b} do
    retention(projects: %{a.actor.project_id => [ingest_seconds: 30 * @day]})
    for u <- [a, b], do: batch(u, 12, [{"done", 10}])

    Ingest.prune()
    assert items(a) == 1
    assert items(b) == 0
  end

  test "a nil default turns the pass off for everyone without an override", %{a: a, b: b} do
    retention(
      default: [ingest_seconds: nil],
      projects: %{b.actor.project_id => [ingest_seconds: @day]}
    )

    for u <- [a, b], do: batch(u, 30, [{"done", 29}])

    Ingest.prune()
    assert items(a) == 1
    assert items(b) == 0
  end

  test "the shared budget bounds item and batch cleanup together", %{a: a} do
    previous = Application.fetch_env(:fyrlet, :pruning)
    Application.put_env(:fyrlet, :pruning, max_rows: 2, max_duration_ms: 5_000)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fyrlet, :pruning, value)
        :error -> Application.delete_env(:fyrlet, :pruning)
      end
    end)

    batch(a, 20, List.duplicate({"done", 19}, 5))
    assert {{2, 0}, %{deleted: 2}} = Fyrlet.Pruning.run(fn -> Ingest.prune() end)
    assert items(a) == 3 and batches(a) == 1
    assert {{2, 0}, _stats} = Fyrlet.Pruning.run(fn -> Ingest.prune() end)
    assert {{1, 1}, _stats} = Fyrlet.Pruning.run(fn -> Ingest.prune() end)
    assert items(a) == 0 and batches(a) == 0
  end

  test "the periodic prune job runs it" do
    user = user(project(), "dave")
    batch(user, 20, [{"done", 19}])
    assert :ok = Fyrlet.PruneWorker.perform(%Oban.Job{})
    assert items(user) == 0
  end

  test "malformed retention configuration is refused when the application starts" do
    for bad <- [
          [default: [ingest_seconds: 59]],
          [default: [ingest_seconds: "7d"]],
          [default: [typo: 1_000]],
          [default: :nope],
          [projects: %{7 => [ingest_seconds: 100]}],
          [projects: %{"p" => [ingest_seconds: 0]}]
        ] do
      retention(bad)
      assert_raise ArgumentError, fn -> Retention.validate!() end
    end

    retention(default: [ingest_seconds: nil], projects: %{"p" => [ingest_seconds: 60]})
    assert :ok = Retention.validate!()
  end

  test "the default can come from the environment" do
    settings =
      Fyrlet.RuntimeConfig.settings(:dev, fn
        "FYRLET_INGEST_RETENTION_SECONDS" -> "3600"
        _other -> nil
      end)

    assert settings[:retention] == [default: [ingest_seconds: 3600]]

    forever =
      Fyrlet.RuntimeConfig.settings(:dev, fn
        "FYRLET_INGEST_RETENTION_SECONDS" -> "forever"
        _other -> nil
      end)

    assert forever[:retention] == [default: [ingest_seconds: nil]]
    refute Keyword.has_key?(Fyrlet.RuntimeConfig.settings(:dev, fn _ -> nil end), :retention)

    assert_raise ArgumentError, ~r/FYRLET_INGEST_RETENTION_SECONDS/, fn ->
      Fyrlet.RuntimeConfig.settings(:dev, fn
        "FYRLET_INGEST_RETENTION_SECONDS" -> "30"
        _other -> nil
      end)
    end
  end
end
