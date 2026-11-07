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

  test "versioned committed changes avoid a business query and stale changes reload", %{
    alice: alice
  } do
    {:ok, item} = add(alice.actor)
    {:ok, subscription} = Runtime.prepare_subscription(alice.actor, "inbox.recent", %{})
    {:ok, previous} = Fyrlet.Fixtures.snapshot_with_metadata(alice.actor, subscription)
    input = %{"id" => item["id"], "text" => "changed", "expected_version" => 1}
    {:ok, updated} = Runtime.call(alice.actor, "inbox.update", input, Ecto.UUID.generate())
    change = InboxExample.Inbox.change("inbox.update", alice.actor, input, updated)
    handler = "change-query-#{Ecto.UUID.generate()}"

    :telemetry.attach(
      handler,
      [:fyrlet, :repo, :query],
      fn _event, _measurements, metadata, owner ->
        if String.starts_with?(metadata.query, "SELECT") and
             String.contains?(metadata.query, "inbox_items"),
           do: send(owner, :business_query)
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, %{data: [^updated]}} =
             Fyrlet.Fixtures.snapshot_with_metadata(alice.actor, subscription, previous, change)

    refute_receive :business_query, 20

    assert {:ok, %{data: [^updated]}} =
             Fyrlet.Fixtures.snapshot_with_metadata(
               alice.actor,
               subscription,
               %{previous | record_index: %{item["id"] => 1}},
               change
             )

    assert_receive :business_query

    assert {:ok, %{data: [^updated]}} =
             Fyrlet.Fixtures.snapshot_with_metadata(
               alice.actor,
               subscription,
               %{previous | data: [updated]},
               change
             )

    assert_receive :business_query

    {:ok, _revoked} = Auth.revoke_own_session(alice.actor)

    assert {:error, %Error{code: "UNAUTHENTICATED"}} =
             Fyrlet.Fixtures.snapshot_with_metadata(alice.actor, subscription, previous, change)
  end

  test "idempotency TTL comes from configuration", %{alice: alice} do
    previous = Application.fetch_env!(:fyrlet, :idempotency_ttl)
    on_exit(fn -> Application.put_env(:fyrlet, :idempotency_ttl, previous) end)
    Application.put_env(:fyrlet, :idempotency_ttl, 10)

    assert {:ok, _item} = Runtime.call(alice.actor, "inbox.add", %{"text" => "ttl"}, "ttl-key")

    stored = Repo.get_by!(Fyrlet.Idempotency, key: "ttl-key")
    assert DateTime.diff(stored.expires_at, Auth.now(), :second) in 8..10
  end

  test "incremental replacements retain output validation and exact snapshot size limits", %{
    alice: alice
  } do
    {:ok, item} = add(alice.actor)
    {:ok, subscription} = Runtime.prepare_subscription(alice.actor, "inbox.recent", %{})
    {:ok, previous} = Fyrlet.Fixtures.snapshot_with_metadata(alice.actor, subscription)
    input = %{"id" => item["id"], "text" => String.duplicate("更新", 40), "expected_version" => 1}
    {:ok, updated} = Runtime.call(alice.actor, "inbox.update", input, Ecto.UUID.generate())
    change = InboxExample.Inbox.change("inbox.update", alice.actor, input, updated)
    expected_bytes = byte_size(Jason.encode!([updated]))
    limit = Application.fetch_env!(:fyrlet, :max_snapshot_bytes)
    on_exit(fn -> Application.put_env(:fyrlet, :max_snapshot_bytes, limit) end)
    Application.put_env(:fyrlet, :max_snapshot_bytes, expected_bytes)

    assert {:ok, %{data: [^updated], bytes: ^expected_bytes}} =
             Fyrlet.Fixtures.snapshot_with_metadata(alice.actor, subscription, previous, change)

    Application.put_env(:fyrlet, :max_snapshot_bytes, expected_bytes - 1)

    assert {:error, %Error{code: "LIMIT_EXCEEDED"}} =
             Fyrlet.Fixtures.snapshot_with_metadata(alice.actor, subscription, previous, change)

    invalid = put_in(change, ["record", "text"], false)

    assert {:error, %Error{code: "INTERNAL_ERROR"}} =
             Fyrlet.Fixtures.snapshot_with_metadata(alice.actor, subscription, previous, invalid)
  end

  test "committed writes notify immediately and idempotent replays do not notify", %{alice: alice} do
    {:ok, subscription} = Runtime.prepare_subscription(alice.actor, "inbox.recent", %{})
    Phoenix.PubSub.subscribe(Fyrlet.PubSub, subscription.scope)
    key = Ecto.UUID.generate()

    assert {:ok, item} = Runtime.call(alice.actor, "inbox.add", %{"text" => "fast"}, key)
    assert_receive {:invalidated, identifier, %Fyrlet.CommittedChange{}}
    assert_enqueued worker: Fyrlet.InvalidationWorker

    assert {:ok, ^item} = Runtime.call(alice.actor, "inbox.add", %{"text" => "fast"}, key)
    refute_receive {:invalidated, _identifier, _change}, 20

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :fyrlet)
    assert_receive {:invalidated, ^identifier}
  end

  test "shared validated changes only reuse identical records and identical schemas", %{
    alice: alice
  } do
    {:ok, item} = add(alice.actor)
    {:ok, subscription} = Runtime.prepare_subscription(alice.actor, "inbox.recent", %{})
    {:ok, previous} = Fyrlet.Fixtures.snapshot_with_metadata(alice.actor, subscription)
    Phoenix.PubSub.subscribe(Fyrlet.PubSub, subscription.scope)
    input = %{"id" => item["id"], "text" => "更新\n\"\\", "expected_version" => 1}
    {:ok, updated} = Runtime.call(alice.actor, "inbox.update", input, Ecto.UUID.generate())
    assert_receive {:invalidated, _identifier, %Fyrlet.CommittedChange{} = change}
    expected_bytes = byte_size(Jason.encode!([updated]))

    assert {:ok,
            %{
              data: [^updated],
              bytes: ^expected_bytes,
              view: updated_view,
              record_index: indexed,
              unchanged: false
            }} =
             Fyrlet.Fixtures.snapshot_with_metadata(alice.actor, subscription, previous, change)

    assert updated_view.sizes == %{item["id"] => byte_size(Jason.encode!(updated))}
    assert indexed == %{item["id"] => 0}

    restricted =
      put_in(subscription.specification["output"]["items"]["properties"]["text"]["maxLength"], 1)

    assert {:error, %Error{code: "INTERNAL_ERROR"}} =
             Fyrlet.Fixtures.snapshot_with_metadata(alice.actor, restricted, previous, change)

    invalid = %{change | change: put_in(change.change, ["record", "text"], false)}

    assert {:error, %Error{code: "INTERNAL_ERROR"}} =
             Fyrlet.Fixtures.snapshot_with_metadata(alice.actor, subscription, previous, invalid)

    maximum = Application.fetch_env!(:fyrlet, :max_snapshot_bytes)
    on_exit(fn -> Application.put_env(:fyrlet, :max_snapshot_bytes, maximum) end)
    Application.put_env(:fyrlet, :max_snapshot_bytes, expected_bytes - 1)

    assert {:error, %Error{code: "LIMIT_EXCEEDED"}} =
             Fyrlet.Fixtures.snapshot_with_metadata(alice.actor, subscription, previous, change)
  end

  test "an identical indexed replacement retains the existing view and exact byte accounting", %{
    alice: alice
  } do
    {:ok, item} = add(alice.actor)
    {:ok, subscription} = Runtime.prepare_subscription(alice.actor, "inbox.recent", %{})
    {:ok, previous} = Fyrlet.Fixtures.snapshot_with_metadata(alice.actor, subscription)

    change =
      InboxExample.Inbox.change("inbox.update", alice.actor, %{"expected_version" => 1}, item)

    assert {:ok, %{data: data, unchanged: true, record_index: indexed, bytes: bytes}} =
             Fyrlet.Fixtures.snapshot_with_metadata(alice.actor, subscription, previous, change)

    assert data == previous.data
    assert indexed == previous.record_index
    assert bytes == previous.bytes
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
