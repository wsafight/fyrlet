defmodule FyrletWeb.SubscriptionChannelTest do
  use Fyrlet.DataCase, async: false
  import Phoenix.ChannelTest
  @endpoint FyrletWeb.Endpoint

  setup do
    Process.flag(:trap_exit, true)
    project = project()
    alice = user(project)
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
    push(socket, "ack", Map.take(snapshot, ["generation", "seq"]))
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
    push(socket, "ack", Map.take(initial, ["generation", "seq"]))
    assert_push "snapshot", snapshot
    assert snapshot["data"] == [item]
    assert Repo.aggregate(InboxItem, :count) == 1
    leave(socket)
  end

  test "periodic reconciliation repairs an unbroadcast commit", %{alice: alice} do
    {:ok, initial, socket} = join(alice)
    push(socket, "ack", Map.take(initial, ["generation", "seq"]))
    {:ok, {:ok, item}} = Repo.transaction(fn -> add(alice.actor) end)
    assert_push "snapshot", snapshot, 500
    assert snapshot["data"] == [item]
    leave(socket)
  end

  test "unchanged invalidations and reconciliation do not push duplicate snapshots", %{
    alice: alice
  } do
    {:ok, initial, socket} = join(alice)
    reference = push(socket, "ack", Map.take(initial, ["generation", "seq"]))
    assert_reply reference, :ok

    send(socket.channel_pid, :invalidated)
    send(socket.channel_pid, :reconcile)
    refute_push "snapshot", _snapshot, 120

    {:ok, item} = add(alice.actor)
    assert_push "snapshot", changed
    assert changed["data"] == [item]
    assert changed["seq"] == 2
    reference = push(socket, "ack", Map.take(changed, ["generation", "seq"]))
    assert_reply reference, :ok

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :fyrlet)
    refute_push "snapshot", _snapshot, 120
    leave(socket)
  end

  test "an explicit refresh pushes an unchanged snapshot after acknowledgement", %{alice: alice} do
    {:ok, initial, socket} = join(alice)
    reference = push(socket, "refresh", %{})
    assert_reply reference, :ok, %{"accepted" => true}
    refute_push "snapshot", _snapshot, 20

    push(socket, "ack", Map.take(initial, ["generation", "seq"]))
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
    reference = push(socket, "ack", Map.take(initial, ["generation", "seq"]))
    assert_reply reference, :ok
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
    reference = push(socket, "ack", Map.take(changed, ["generation", "seq"]))
    assert_reply reference, :ok

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
    reference = push(socket, "ack", Map.take(initial, ["generation", "seq"]))
    assert_reply reference, :ok
    send(socket.channel_pid, {:invalidated, 200})
    reference = push(socket, "ack", Map.take(initial, ["generation", "seq"]))
    assert_reply reference, :ok

    {:ok, {:ok, item}} = Repo.transaction(fn -> add(alice.actor) end)
    send(socket.channel_pid, {:invalidated, 100})
    assert_push "snapshot", changed
    assert changed["data"] == [item]
    leave(socket)
  end

  test "revoked sessions cannot produce further snapshots", %{alice: alice} do
    {:ok, initial, socket} = join(alice)
    push(socket, "ack", Map.take(initial, ["generation", "seq"]))

    Repo.update_all(
      from(session in Fyrlet.Session, where: session.id == ^alice.actor.session_id),
      set: [revoked_at: Auth.now()]
    )

    send(socket.channel_pid, :invalidated)
    assert_push "status", %{"error" => %{"code" => "UNAUTHENTICATED"}}
  end

  test "unacknowledged snapshots close and channel resources are reclaimed", %{alice: alice} do
    {:ok, initial, socket} = join(alice)
    reference = Process.monitor(socket.channel_pid)
    send(socket.channel_pid, {:ack_timeout, initial["seq"]})
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
    push(socket, "ack", Map.take(initial, ["generation", "seq"]))
    send(socket.channel_pid, :expired)
    assert_push "status", %{"error" => %{"code" => "UNAUTHENTICATED"}}
  end

  test "a snapshot size limit failure closes the subscription", %{alice: alice} do
    previous = Application.fetch_env!(:fyrlet, :max_snapshot_bytes)
    Application.put_env(:fyrlet, :max_snapshot_bytes, 30)
    on_exit(fn -> Application.put_env(:fyrlet, :max_snapshot_bytes, previous) end)
    {:ok, initial, socket} = join(alice)
    push(socket, "ack", Map.take(initial, ["generation", "seq"]))
    {:ok, _item} = add(alice.actor)
    send(socket.channel_pid, :invalidated)
    assert_push "status", %{"error" => %{"code" => "LIMIT_EXCEEDED"}}
  end

  defp join(alice) do
    socket(FyrletWeb.UserSocket, "sessions:" <> alice.actor.session_id, %{actor: alice.actor})
    |> subscribe_and_join("subscription:" <> Ecto.UUID.generate(), %{
      "protocol_version" => 1,
      "name" => "inbox.recent",
      "params" => %{}
    })
  end
end
