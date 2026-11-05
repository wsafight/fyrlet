defmodule Fyrlet.RuntimeEdgeTest do
  use Fyrlet.DataCase, async: false
  use Oban.Testing, repo: Fyrlet.Repo

  setup do
    %{project: project(), alice: user(project(), "alice")}
  end

  test "operation telemetry reports duration, name and result", %{alice: alice} do
    attach([:fyrlet, :operation, :stop])

    assert {:ok, _item} = add(alice.actor)

    assert_receive {:telemetry, [:fyrlet, :operation, :stop], %{duration: duration},
                    %{name: "inbox.add", result: :ok}}

    assert is_integer(duration) and duration >= 0

    assert {:ok, "ok"} = Runtime.call(alice.actor, "test.echo", %{})

    assert_receive {:telemetry, [:fyrlet, :operation, :stop], _measurements,
                    %{name: "test.echo", result: :ok}}

    assert {:error, %Error{code: "INTERNAL_ERROR"}} =
             Runtime.call(alice.actor, "test.bad_output", %{}, "bad")

    assert_receive {:telemetry, [:fyrlet, :operation, :stop], _measurements,
                    %{name: "test.bad_output", result: :error}}

    assert {:error, %Error{code: "NOT_FOUND"}} = Runtime.call(alice.actor, "missing.op", %{})

    assert_receive {:telemetry, [:fyrlet, :operation, :stop], _measurements,
                    %{name: "missing.op", result: :error}}
  end

  test "snapshot telemetry reports success and errors", %{alice: alice} do
    attach([:fyrlet, :subscription, :query])
    {:ok, subscription} = Runtime.prepare_subscription(alice.actor, "inbox.recent", %{})

    assert {:ok, []} = Runtime.snapshot(alice.actor, subscription)

    assert_receive {:telemetry, [:fyrlet, :subscription, :query], %{duration: duration},
                    %{name: "inbox.recent", result: :ok}}

    assert is_integer(duration)

    {:ok, _revoked} = Auth.revoke_own_session(alice.actor)

    assert {:error, %Error{code: "UNAUTHENTICATED"}} =
             Runtime.snapshot(alice.actor, subscription)

    assert_receive {:telemetry, [:fyrlet, :subscription, :query], _measurements,
                    %{name: "inbox.recent", result: :error}}
  end

  test "snapshot size limits reject oversized results without truncation", %{alice: alice} do
    previous = Application.fetch_env!(:fyrlet, :max_snapshot_bytes)
    on_exit(fn -> Application.put_env(:fyrlet, :max_snapshot_bytes, previous) end)

    {:ok, item} = add(alice.actor, "snapshot payload")
    {:ok, subscription} = Runtime.prepare_subscription(alice.actor, "inbox.recent", %{})

    Application.put_env(:fyrlet, :max_snapshot_bytes, 20)

    assert {:error, %Error{code: "LIMIT_EXCEEDED", message: message}} =
             Runtime.snapshot(alice.actor, subscription)

    assert message =~ "size limit"

    serialized = Jason.encode!([item])
    Application.put_env(:fyrlet, :max_snapshot_bytes, byte_size(serialized))

    assert {:ok, [^item]} = Runtime.snapshot(alice.actor, subscription)

    Application.put_env(:fyrlet, :max_snapshot_bytes, byte_size(serialized) - 1)
    assert {:error, %Error{code: "LIMIT_EXCEEDED"}} = Runtime.snapshot(alice.actor, subscription)
  end

  test "idempotency TTL comes from configuration", %{alice: alice} do
    previous = Application.fetch_env!(:fyrlet, :idempotency_ttl)
    on_exit(fn -> Application.put_env(:fyrlet, :idempotency_ttl, previous) end)
    Application.put_env(:fyrlet, :idempotency_ttl, 10)

    assert {:ok, _item} = Runtime.call(alice.actor, "inbox.add", %{"text" => "ttl"}, "ttl-key")

    stored = Repo.get_by!(Fyrlet.Idempotency, key: "ttl-key")
    assert DateTime.diff(stored.expires_at, Auth.now(), :second) in 8..10
  end

  test "committed writes notify immediately and idempotent replays do not notify", %{alice: alice} do
    {:ok, subscription} = Runtime.prepare_subscription(alice.actor, "inbox.recent", %{})
    Phoenix.PubSub.subscribe(Fyrlet.PubSub, subscription.scope)
    key = Ecto.UUID.generate()

    assert {:ok, item} = Runtime.call(alice.actor, "inbox.add", %{"text" => "fast"}, key)
    assert_receive {:invalidated, identifier}
    assert_enqueued worker: Fyrlet.InvalidationWorker

    assert {:ok, ^item} = Runtime.call(alice.actor, "inbox.add", %{"text" => "fast"}, key)
    refute_receive {:invalidated, _identifier}, 20

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :fyrlet)
    assert_receive {:invalidated, ^identifier}
  end

  test "nested writes defer notifications to the durable job", %{alice: alice} do
    {:ok, subscription} = Runtime.prepare_subscription(alice.actor, "inbox.recent", %{})
    Phoenix.PubSub.subscribe(Fyrlet.PubSub, subscription.scope)

    assert {:ok, {:ok, _item}} =
             Repo.transaction(fn ->
               result = add(alice.actor)
               refute_receive {:invalidated, _identifier}, 20
               result
             end)

    refute_receive {:invalidated, _identifier}, 20
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :fyrlet)
    assert_receive {:invalidated, _identifier}
  end

  test "rolled back writes emit no notification and leave no durable job", %{alice: alice} do
    {:ok, subscription} = Runtime.prepare_subscription(alice.actor, "inbox.recent", %{})
    Phoenix.PubSub.subscribe(Fyrlet.PubSub, subscription.scope)

    assert {:error, :cancelled} =
             Repo.transaction(fn ->
               assert {:ok, _item} = add(alice.actor)
               refute_receive {:invalidated, _identifier}, 20
               Repo.rollback(:cancelled)
             end)

    refute_receive {:invalidated, _identifier}, 20
    assert Repo.aggregate(InboxItem, :count) == 0
    refute_enqueued worker: Fyrlet.InvalidationWorker

    assert {:error, %Error{code: "INTERNAL_ERROR"}} =
             Runtime.call(alice.actor, "test.bad_output", %{}, Ecto.UUID.generate())

    refute_receive {:invalidated, _identifier}, 20
    refute_enqueued worker: Fyrlet.InvalidationWorker
  end

  test "concurrent writes with the same key collapse to one result", %{alice: alice} do
    key = Ecto.UUID.generate()

    results =
      1..8
      |> Task.async_stream(
        fn _index -> Runtime.call(alice.actor, "inbox.add", %{"text" => "same"}, key) end,
        max_concurrency: 8,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _item}, &1))
    items = Enum.map(results, fn {:ok, item} -> item end)
    assert length(Enum.uniq_by(items, & &1["id"])) == 1
    assert Repo.aggregate(InboxItem, :count) == 1
    assert Repo.aggregate(Fyrlet.Idempotency, :count) == 1
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "concurrent writes with distinct keys are all persisted", %{alice: alice} do
    results =
      1..8
      |> Task.async_stream(
        fn index ->
          Runtime.call(
            alice.actor,
            "inbox.add",
            %{"text" => "item #{index}"},
            Ecto.UUID.generate()
          )
        end,
        max_concurrency: 8,
        timeout: 15_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _item}, &1))
    assert Repo.aggregate(InboxItem, :count) == 8
    assert Repo.aggregate(Fyrlet.Idempotency, :count) == 8
    assert Repo.aggregate(Oban.Job, :count) == 8
  end

  defp attach(event) do
    handler = "runtime-edge-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      event,
      fn name, measurements, metadata, _config ->
        send(parent, {:telemetry, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    handler
  end
end
