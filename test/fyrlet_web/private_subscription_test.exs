defmodule FyrletWeb.PrivateSubscriptionTest do
  use Fyrlet.DataCase, async: false
  import Phoenix.ChannelTest, except: [join: 2]
  alias Fyrlet.Subscriptions.{Tracker, View}
  @endpoint FyrletWeb.Endpoint

  setup do
    Process.flag(:trap_exit, true)

    settings = [
      :definitions,
      :reconciliation_interval,
      :snapshot_ack_timeout,
      :max_subscriptions_per_node
    ]

    previous = for key <- settings, do: {key, Application.fetch_env(:fyrlet, key)}

    Application.put_env(:fyrlet, :definitions, [
      Fyrlet.PrivateTestRecords | Application.fetch_env!(:fyrlet, :definitions)
    ])

    Application.put_env(:fyrlet, :reconciliation_interval, 600_000)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, configured} -> Application.put_env(:fyrlet, key, configured)
          :error -> Application.delete_env(:fyrlet, key)
        end
      end

      for key <- [:private_deny, :private_revoke_on_load, :private_snapshot_bytes],
          do: Application.delete_env(:fyrlet, key)
    end)

    tenant = project()
    %{tenant: tenant, alice: user(tenant)}
  end

  test "private views run in their channel and retain no encoded snapshot", %{alice: alice} do
    {:ok, record} = add(alice.actor)
    {:ok, initial, first} = join_private(alice)
    {:ok, _, second} = join_private(alice)
    assert first.assigns.observer == first.channel_pid
    assert second.assigns.observer == second.channel_pid
    refute first.channel_pid == second.channel_pid
    assert observation(first).encoded == nil
    assert View.data(observation(first).view) == [record]
    assert initial["data"] == [record]
    assert first.assigns.observer_monitor == nil
    for socket <- [first, second], do: leave(socket)
  end

  for delivery <- ["snapshot", "delta-v1"] do
    test "#{delivery} private delivery preserves incremental updates and explicit refresh", %{
      alice: alice
    } do
      for index <- 1..5, do: add(alice.actor, String.duplicate("payload #{index}", 30))
      {:ok, initial, socket} = join_private(alice, %{"delivery" => unquote(delivery)})
      acknowledge(socket, initial)
      original = hd(initial["data"])

      {:ok, updated} =
        Runtime.call(
          alice.actor,
          "records.update",
          %{"id" => original["id"], "text" => "changed", "expected_version" => 1},
          Ecto.UUID.generate()
        )

      sequence =
        if unquote(delivery) == "delta-v1" do
          assert_push "delta", delta
          assert delta["b"] == 1 and delta["s"] == 2

          assert delta["p"]["c"] == [
                   [original["id"], Map.take(updated, ["text", "version", "updated_at"])]
                 ]

          acknowledge(socket, delta)
          2
        else
          assert_push "snapshot", snapshot
          assert hd(snapshot["data"]) == updated
          acknowledge(socket, snapshot)
          snapshot["seq"]
        end

      assert observation(socket).encoded == nil
      assert hd(View.data(observation(socket).view)) == updated
      reference = push(socket, "refresh", %{})
      assert_reply reference, :ok, %{"accepted" => true}
      assert_push "snapshot", refreshed
      assert refreshed["seq"] == sequence + 1
      assert hd(refreshed["data"]) == updated
      assert observation(socket).encoded == nil
      leave(socket)
    end
  end

  test "unacknowledged changes coalesce and a lagging delta client receives a current snapshot",
       %{alice: alice} do
    {:ok, record} = add(alice.actor)
    {:ok, initial, socket} = join_private(alice, %{"delivery" => "delta-v1"})

    for version <- 1..3 do
      assert {:ok, _} =
               Runtime.call(
                 alice.actor,
                 "records.update",
                 %{
                   "id" => record["id"],
                   "text" => "version #{version + 1}",
                   "expected_version" => version
                 },
                 Ecto.UUID.generate()
               )

      :sys.get_state(socket.channel_pid)
    end

    refute_push "snapshot", _, 20
    refute_push "delta", _, 20
    acknowledge(socket, initial)
    assert_push "snapshot", snapshot
    assert hd(snapshot["data"])["version"] == 4
    assert snapshot["seq"] == 2
    leave(socket)
  end

  test "an unchanged refresh waits for the current acknowledgement", %{alice: alice} do
    {:ok, initial, socket} = join_private(alice)
    reference = push(socket, "refresh", %{})
    assert_reply reference, :ok, %{"accepted" => true}
    refute_push "snapshot", _, 20
    push(socket, "ack", %{"g" => initial["generation"], "s" => nil})
    refute_push "snapshot", _, 20
    acknowledge(socket, initial)
    assert_push "snapshot", refreshed
    assert refreshed["seq"] == 2 and refreshed["data"] == initial["data"]
    leave(socket)
  end

  test "revocation during the initial load never returns business data", %{alice: alice} do
    Application.put_env(:fyrlet, :private_revoke_on_load, true)
    assert {:error, %{"error" => %{"code" => "UNAUTHENTICATED"}}} = join_private(alice)
  end

  test "revocation during a refresh closes the local view with an authentication error", %{
    alice: alice
  } do
    {:ok, initial, socket} = join_private(alice)
    acknowledge(socket, initial)
    Application.put_env(:fyrlet, :private_revoke_on_load, true)
    send(socket.channel_pid, :invalidated)
    assert_push "status", %{"error" => %{"code" => "UNAUTHENTICATED"}}
    refute_push "snapshot", _, 20
  end

  test "authorization failure in one private channel leaves another subject active", %{
    tenant: tenant,
    alice: alice
  } do
    bob = user(tenant, "bob")
    {:ok, first, denied} = join_private(alice)
    {:ok, second, allowed} = join_private(bob)
    acknowledge(denied, first)
    acknowledge(allowed, second)
    Application.put_env(:fyrlet, :private_deny, alice.actor.subject_id)
    send(denied.channel_pid, :invalidated)
    assert_push "status", %{"error" => %{"code" => "FORBIDDEN"}}
    {:ok, record} = add(bob.actor)
    assert_push "snapshot", snapshot
    assert snapshot["data"] == [record]
    leave(allowed)
  end

  test "manual reconciliation repairs a commit with no immediate notification", %{alice: alice} do
    {:ok, initial, socket} = join_private(alice)
    acknowledge(socket, initial)
    {:ok, {:ok, record}} = Repo.transaction(fn -> add(alice.actor) end)
    refute_push "snapshot", _, 20
    send(socket.channel_pid, :reconcile)
    assert_push "snapshot", snapshot
    assert snapshot["data"] == [record]
    leave(socket)
  end

  test "durable duplicates do not reload the same private view", %{alice: alice} do
    {:ok, initial, socket} = join_private(alice)
    acknowledge(socket, initial)
    send(socket.channel_pid, {:invalidated, 42})
    :sys.get_state(socket.channel_pid)
    :sys.get_state(socket.channel_pid)
    reference = make_ref()
    handler = "private-query-#{Ecto.UUID.generate()}"

    :telemetry.attach(
      handler,
      [:fyrlet, :subscription, :query],
      fn _, _, _, owner -> send(owner, reference) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    send(socket.channel_pid, {:invalidated, 42})
    :sys.get_state(socket.channel_pid)
    refute_receive ^reference, 20
    leave(socket)
  end

  test "a contract limit rejects both the initial snapshot and later growth", %{alice: alice} do
    Application.put_env(:fyrlet, :private_snapshot_bytes, 2)
    {:ok, initial, socket} = join_private(alice)
    acknowledge(socket, initial)
    {:ok, _} = add(alice.actor)

    assert_push "status", %{
      "error" => %{"code" => "LIMIT_EXCEEDED", "details" => %{"limit" => 2}}
    }

    assert {:error, %{"error" => %{"code" => "LIMIT_EXCEEDED"}}} = join_private(alice)
  end

  test "leaving cancels the local reconciliation timer and releases the tracker claim", %{
    alice: alice
  } do
    baseline = map_size(:sys.get_state(Tracker).monitors)
    {:ok, _, socket} = join_private(alice)
    timer = observation(socket).reconcile_timer
    assert Process.read_timer(timer) > 0
    monitor = Process.monitor(socket.channel_pid)
    leave(socket)
    assert_receive {:DOWN, ^monitor, :process, _, _}
    assert Process.read_timer(timer) == false
    wait_for_claims(baseline)
  end

  test "the node limit covers local views across separate transports and releases on exit", %{
    alice: alice
  } do
    baseline = map_size(:sys.get_state(Tracker).monitors)
    Application.put_env(:fyrlet, :max_subscriptions_per_node, baseline + 1)
    {:ok, _, first} = join_private(alice)

    assert {:error,
            %{"error" => %{"code" => "LIMIT_EXCEEDED", "details" => %{"scope" => "node"}}}} =
             join_private(alice)

    monitor = Process.monitor(first.channel_pid)
    leave(first)
    assert_receive {:DOWN, ^monitor, :process, _, _}
    wait_for_claims(baseline)
    assert {:ok, _, next} = join_private(alice)
    leave(next)
  end

  test "a private channel still enforces the acknowledgement deadline", %{alice: alice} do
    Application.put_env(:fyrlet, :snapshot_ack_timeout, 10)
    {:ok, _, _socket} = join_private(alice)
    assert_push "status", %{"error" => %{"code" => "LIMIT_EXCEEDED"}}
  end

  defp join_private(user, options \\ %{}) do
    socket(FyrletWeb.UserSocket, "sessions:" <> user.actor.session_id, %{actor: user.actor})
    |> subscribe_and_join(
      "subscription:" <> Ecto.UUID.generate(),
      Map.merge(%{"protocol_version" => 1, "name" => "private.recent", "params" => %{}}, options)
    )
  end

  defp observation(socket), do: :sys.get_state(socket.channel_pid).assigns.observation

  defp acknowledge(socket, snapshot) do
    push(socket, "ack", %{
      "g" => snapshot["generation"] || snapshot["g"],
      "s" => snapshot["seq"] || snapshot["s"]
    })

    :sys.get_state(socket.channel_pid)
  end

  defp wait_for_claims(expected, attempts \\ 100) do
    if map_size(:sys.get_state(Tracker).monitors) != expected do
      assert attempts > 0
      Process.sleep(1)
      wait_for_claims(expected, attempts - 1)
    end
  end
end
