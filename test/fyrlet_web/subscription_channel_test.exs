defmodule FyrletWeb.SubscriptionChannelTest do
  use Fyrlet.DataCase, async: false
  import Phoenix.ChannelTest, except: [join: 2]
  @endpoint FyrletWeb.Endpoint

  setup do
    Process.flag(:trap_exit, true)
    project = project()
    alice = user(project)

    on_exit(fn ->
      entries =
        Registry.select(Fyrlet.ObserverRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])

      for {{%{project_id: identifier}, _subscription}, observer} <- entries,
          identifier == project.project.id do
        try do
          GenServer.stop(observer)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    %{project: project, alice: alice}
  end

  test "socket accepts only subprotocol user credentials", %{project: project, alice: alice} do
    test_process = self()
    handler = "socket-log-test-#{Ecto.UUID.generate()}"

    :telemetry.attach(
      handler,
      [:phoenix, :socket_connected],
      fn _event, _measurements, metadata, owner -> send(owner, {:socket_log, metadata.log}) end,
      test_process
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, _socket} =
             connect(FyrletWeb.UserSocket, %{"project_id" => project.project.id},
               connect_info: %{auth_token: alice.token}
             )

    assert_receive {:socket_log, false}

    assert :error =
             connect(FyrletWeb.UserSocket, %{
               "project_id" => project.project.id,
               "token" => alice.token
             })

    assert :error =
             connect(FyrletWeb.UserSocket, %{"project_id" => project.project.id},
               connect_info: %{auth_token: project.service_key}
             )
  end

  test "initial snapshot, acknowledgement and durable invalidations converge", %{alice: alice} do
    {:ok, snapshot, socket} = join(alice)
    assert snapshot["data"] == []
    assert snapshot["seq"] == 1
    push(socket, "ack", ack_payload(snapshot))
    {:ok, {:ok, item}} = Repo.transaction(fn -> add(alice.actor) end)
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :fyrlet)
    assert_push "snapshot", refreshed
    assert refreshed["data"] == [item]
    assert refreshed["seq"] == 2
    assert refreshed["generation"] == snapshot["generation"]
    leave(socket)
  end

  test "one pending snapshot coalesces notifications until acknowledgement", %{alice: alice} do
    {:ok, initial, socket} = join(alice)
    {:ok, item} = add(alice.actor)
    for _index <- 1..10, do: send(socket.channel_pid, :invalidated)
    refute_push "snapshot", _snapshot, 30
    push(socket, "ack", ack_payload(initial))
    assert_push "snapshot", snapshot
    assert snapshot["data"] == [item]
    assert Repo.aggregate(TestRecord, :count) == 1
    leave(socket)
  end

  test "periodic reconciliation repairs an unbroadcast commit", %{alice: alice} do
    {:ok, initial, socket} = join(alice)
    push(socket, "ack", ack_payload(initial))
    {:ok, {:ok, item}} = Repo.transaction(fn -> add(alice.actor) end)
    assert_push "snapshot", snapshot, 500
    assert snapshot["data"] == [item]
    leave(socket)
  end

  test "unchanged invalidations and reconciliation do not push duplicate snapshots", %{
    alice: alice
  } do
    {:ok, initial, socket} = join(alice)
    acknowledge(socket, initial)

    send(socket.channel_pid, :invalidated)
    send(socket.channel_pid, :reconcile)
    refute_push "snapshot", _snapshot, 120

    {:ok, item} = add(alice.actor)
    assert_push "snapshot", changed
    assert changed["data"] == [item]
    assert changed["seq"] == 2
    acknowledge(socket, changed)

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :fyrlet)
    refute_push "snapshot", _snapshot, 120
    leave(socket)
  end

  test "an explicit refresh pushes an unchanged snapshot after acknowledgement", %{alice: alice} do
    {:ok, initial, socket} = join(alice)
    reference = push(socket, "refresh", %{})
    assert_reply reference, :ok, %{"accepted" => true}
    refute_push "snapshot", _snapshot, 20

    push(socket, "ack", ack_payload(initial))
    assert_push "snapshot", refreshed
    assert refreshed["data"] == initial["data"]
    assert refreshed["seq"] == 2
    assert refreshed["generation"] == initial["generation"]
    leave(socket)
  end

  test "durable retries skip duplicate queries but reconciliation still reauthorizes", %{
    alice: alice
  } do
    previous = Application.fetch_env!(:fyrlet, :reconciliation_interval)
    Application.put_env(:fyrlet, :reconciliation_interval, 60_000)
    on_exit(fn -> Application.put_env(:fyrlet, :reconciliation_interval, previous) end)
    {:ok, initial, socket} = join(alice)
    acknowledge(socket, initial)
    handler = "invalidation-query-test-#{Ecto.UUID.generate()}"

    :telemetry.attach(
      handler,
      [:fyrlet, :subscription, :query],
      fn _event, _measurements, _metadata, owner -> send(owner, :queried) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, item} = add(alice.actor)
    assert_receive :queried
    assert_push "snapshot", changed
    assert changed["data"] == [item]
    acknowledge(socket, changed)

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :fyrlet)
    refute_receive :queried, 30
    refute_push "snapshot", _snapshot, 30

    Repo.update_all(
      from(session in Fyrlet.Session, where: session.id == ^alice.actor.session_id),
      set: [revoked_at: Auth.now()]
    )

    send(socket.channel_pid, :reconcile)
    assert_receive :queried
    assert_push "status", %{"error" => %{"code" => "UNAUTHENTICATED"}}
  end

  test "out of order invalidations still refresh the current view", %{alice: alice} do
    {:ok, initial, socket} = join(alice)
    acknowledge(socket, initial)
    send(socket.channel_pid, {:invalidated, 200})
    acknowledge(socket, initial)

    {:ok, {:ok, item}} = Repo.transaction(fn -> add(alice.actor) end)
    send(socket.channel_pid, {:invalidated, 100})
    assert_push "snapshot", changed
    assert changed["data"] == [item]
    leave(socket)
  end

  test "revoked sessions cannot produce further snapshots", %{alice: alice} do
    {:ok, initial, socket} = join(alice)
    push(socket, "ack", ack_payload(initial))

    Repo.update_all(
      from(session in Fyrlet.Session, where: session.id == ^alice.actor.session_id),
      set: [revoked_at: Auth.now()]
    )

    send(socket.channel_pid, :invalidated)
    assert_push "status", %{"error" => %{"code" => "UNAUTHENTICATED"}}
  end

  test "unacknowledged snapshots close and channel resources are reclaimed", %{alice: alice} do
    previous = Application.fetch_env!(:fyrlet, :snapshot_ack_timeout)
    Application.put_env(:fyrlet, :snapshot_ack_timeout, 30)
    on_exit(fn -> Application.put_env(:fyrlet, :snapshot_ack_timeout, previous) end)
    {:ok, _initial, socket} = join(alice)
    reference = Process.monitor(socket.channel_pid)
    assert_push "status", %{"error" => %{"code" => "LIMIT_EXCEEDED"}}
    assert_receive {:DOWN, ^reference, :process, _pid, _reason}
  end

  test "rejoining creates a new generation and protocol mismatches fail", %{alice: alice} do
    {:ok, first, socket} = join(alice)
    leave(socket)
    {:ok, second, socket} = join(alice)
    refute first["generation"] == second["generation"]
    leave(socket)
    socket = socket(FyrletWeb.UserSocket, "test", %{actor: alice.actor})

    assert {:error, %{"error" => %{"code" => "UNSUPPORTED_VERSION"}}} =
             subscribe_and_join(socket, "subscription:" <> Ecto.UUID.generate(), %{
               "protocol_version" => 999
             })
  end

  test "a connection's subscription limit does not admit a twenty-first channel", %{alice: alice} do
    sockets =
      for _index <- 1..20 do
        {:ok, _snapshot, socket} = join(alice)
        socket
      end

    assert {:error, %{"error" => %{"code" => "LIMIT_EXCEEDED"}}} = join(alice)
    Enum.each(sockets, &leave/1)
  end

  test "expired sessions end subscriptions without emitting another snapshot", %{alice: alice} do
    {:ok, initial, socket} = join(alice)
    push(socket, "ack", ack_payload(initial))
    send(socket.channel_pid, :expired)
    assert_push "status", %{"error" => %{"code" => "UNAUTHENTICATED"}}
  end

  test "a snapshot size limit failure closes the subscription", %{alice: alice} do
    previous = Application.fetch_env!(:fyrlet, :max_snapshot_bytes)
    Application.put_env(:fyrlet, :max_snapshot_bytes, 30)
    on_exit(fn -> Application.put_env(:fyrlet, :max_snapshot_bytes, previous) end)
    {:ok, initial, socket} = join(alice)
    push(socket, "ack", ack_payload(initial))
    {:ok, _item} = add(alice.actor)
    send(socket.channel_pid, :invalidated)
    assert_push "status", %{"error" => %{"code" => "LIMIT_EXCEEDED"}}
  end

  test "negotiated deltas carry only changed fields and explicit refresh restores a full view", %{
    alice: alice
  } do
    for index <- 1..5, do: add(alice.actor, String.duplicate("payload #{index}", 20))
    {:ok, initial, socket} = join(alice, %{"delivery" => "delta-v1"})
    assert initial["delivery"] == "delta-v1"
    acknowledge(socket, initial)
    item = hd(initial["data"])

    {:ok, updated} =
      Runtime.call(
        alice.actor,
        "records.update",
        %{"id" => item["id"], "text" => "changed", "expected_version" => 1},
        Ecto.UUID.generate()
      )

    assert_push "delta", delta
    assert delta["b"] == 1
    assert delta["s"] == 2
    assert delta["g"] == initial["generation"]
    assert byte_size(Base.url_decode64!(delta["g"], padding: false)) == 16

    assert delta["p"] == %{
             "c" => [[item["id"], Map.take(updated, ["text", "version", "updated_at"])]]
           }

    acknowledge(socket, delta)
    push(socket, "refresh", %{})
    assert_push "snapshot", full
    assert full["seq"] == 3
    assert hd(full["data"]) == updated
    leave(socket)
  end

  test "a lagging client receives a fresh full view after acknowledgement", %{alice: alice} do
    for _index <- 1..5, do: add(alice.actor, String.duplicate("payload", 30))
    {:ok, initial, socket} = join(alice, %{"delivery" => "delta-v1"})
    item = hd(initial["data"])

    for version <- 1..3 do
      assert {:ok, _item} =
               Runtime.call(
                 alice.actor,
                 "records.update",
                 %{
                   "id" => item["id"],
                   "text" => "version #{version + 1}",
                   "expected_version" => version
                 },
                 Ecto.UUID.generate()
               )
    end

    refute_push "delta", _delta, 20
    push(socket, "ack", ack_payload(initial))
    assert_push "snapshot", refreshed
    assert Enum.any?(refreshed["data"], &(&1["id"] == item["id"] and &1["version"] == 4))
    leave(socket)
  end

  test "acknowledgements have no reply and stale generations cannot unblock delivery", %{
    alice: alice
  } do
    {:ok, initial, socket} = join(alice)
    {:ok, item} = add(alice.actor)
    reference = push(socket, "ack", %{"g" => "stale", "s" => 1})
    refute_reply reference, :ok, %{}, 20
    refute_push "snapshot", _snapshot, 20
    reference = push(socket, "ack", ack_payload(initial))
    assert_push "snapshot", snapshot
    assert snapshot["data"] == [item]
    refute_reply reference, :ok, %{}, 20
    leave(socket)
  end

  test "equivalent views share execution but sessions and parameters remain isolated", %{
    project: project,
    alice: alice
  } do
    {:ok, _first, first} = join(alice)
    {:ok, _second, second} = join(alice)
    assert first.assigns.observer == second.assigns.observer
    assert map_size(:sys.get_state(first.assigns.observer).clients) == 2
    {:ok, _other_limit, other_limit} = join(alice, %{"params" => %{"limit" => 1}})
    refute first.assigns.observer == other_limit.assigns.observer
    another_session = user(project)
    {:ok, _other_session, other_session} = join(another_session)
    refute first.assigns.observer == other_session.assigns.observer
    Enum.each([first, second, other_limit, other_session], &leave/1)
  end

  test "a null ACK racing an unchanged refresh cannot release its pending delivery", %{
    alice: alice
  } do
    {:ok, initial, socket} = join(alice)
    acknowledge(socket, initial)
    observer = socket.assigns.observer
    :sys.get_state(observer)
    :sys.suspend(observer)
    reference = push(socket, "refresh", %{})
    assert_reply reference, :ok, %{"accepted" => true}
    :sys.suspend(socket.channel_pid)

    on_exit(fn ->
      for process <- [observer, socket.channel_pid], Process.alive?(process) do
        try do
          :sys.resume(process)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    push(socket, "ack", %{"g" => initial["generation"], "s" => nil})
    :sys.resume(observer)
    send(observer, :refresh)
    :sys.get_state(observer)
    :sys.resume(socket.channel_pid)
    assert_push "snapshot", refreshed
    :sys.get_state(socket.channel_pid)
    refute :sys.get_state(observer).clients[socket.channel_pid].ready
    {:ok, item} = add(alice.actor)
    refute_push "snapshot", _unacknowledged, 20
    acknowledge(socket, refreshed)
    assert_push "snapshot", updated
    assert updated["data"] == [item]
    leave(socket)
  end

  test "a slow subscription does not block a ready subscriber of the same view", %{alice: alice} do
    {:ok, initial_slow, slow} = join(alice)
    {:ok, initial_fast, fast} = join(alice)
    acknowledge(fast, initial_fast)
    fast_topic = fast.topic
    slow_topic = slow.topic
    {:ok, item} = add(alice.actor)

    assert_receive %Phoenix.Socket.Message{
      topic: ^fast_topic,
      event: "snapshot",
      payload: fast_payload
    }

    assert fast_payload["data"] == [item]
    refute_receive %Phoenix.Socket.Message{topic: ^slow_topic, event: "snapshot"}, 20
    acknowledge(slow, initial_slow)

    assert_receive %Phoenix.Socket.Message{
      topic: ^slow_topic,
      event: "snapshot",
      payload: slow_payload
    }

    assert slow_payload["data"] == [item]
    Enum.each([slow, fast], &leave/1)
  end

  test "ten equivalent subscriptions execute one refresh rather than ten", %{alice: alice} do
    previous = Application.fetch_env!(:fyrlet, :reconciliation_interval)
    Application.put_env(:fyrlet, :reconciliation_interval, 60_000)
    on_exit(fn -> Application.put_env(:fyrlet, :reconciliation_interval, previous) end)
    {:ok, item} = add(alice.actor, String.duplicate("payload", 100))

    sockets =
      for _index <- 1..10 do
        {:ok, initial, socket} = join(alice)
        acknowledge(socket, initial)
        socket
      end

    observer = hd(sockets).assigns.observer
    assert Enum.all?(:sys.get_state(observer).clients, fn {_channel, client} -> client.ready end)
    handler = "shared-query-#{Ecto.UUID.generate()}"

    :telemetry.attach(
      handler,
      [:fyrlet, :subscription, :query],
      fn _event, _measurements, _metadata, owner -> send(owner, :shared_query) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, updated} =
             Runtime.call(
               alice.actor,
               "records.update",
               %{"id" => item["id"], "expected_version" => 1, "text" => "shared"},
               Ecto.UUID.generate()
             )

    assert_receive :shared_query

    for _index <- 1..10 do
      assert_push "snapshot", payload
      assert payload["data"] == [updated]
    end

    refute_receive :shared_query, 20
    Enum.each(sockets, &leave/1)
  end

  test "an observer failure is retryable and removing its last client reclaims it", %{
    alice: alice
  } do
    {:ok, _initial, socket} = join(alice)
    observer = socket.assigns.observer
    Process.exit(observer, :kill)
    assert_push "status", %{"error" => %{"code" => "INTERNAL_ERROR", "retryable" => true}}
    {:ok, _next, next} = join(alice)
    refute observer == next.assigns.observer
    monitor = Process.monitor(next.assigns.observer)
    leave(next)
    assert_receive {:DOWN, ^monitor, :process, _observer, :normal}
  end

  test "an earlier ACK timer cannot expire a later delivery prematurely", %{alice: alice} do
    {:ok, initial, socket} = join(alice)
    timer = socket.assigns.ack_timer
    acknowledge(socket, initial)
    {:ok, _item} = add(alice.actor)
    assert_push "snapshot", refreshed
    send(socket.channel_pid, :ack_timeout)
    refute_push "status", _status, 20
    acknowledge(socket, refreshed)
    assert Process.read_timer(timer) != false
    leave(socket)
  end

  defp acknowledge(socket, payload) do
    push(socket, "ack", ack_payload(payload))
    :sys.get_state(socket.channel_pid)
  end

  defp ack_payload(payload),
    do: %{
      "g" => Map.get(payload, "generation", payload["g"]),
      "s" => Map.get(payload, "seq", payload["s"])
    }

  defp join(alice, options \\ %{}) do
    socket(FyrletWeb.UserSocket, "sessions:" <> alice.actor.session_id, %{actor: alice.actor})
    |> subscribe_and_join(
      "subscription:" <> Ecto.UUID.generate(),
      Map.merge(
        %{
          "protocol_version" => 1,
          "name" => "records.recent",
          "params" => %{}
        },
        options
      )
    )
  end
end
