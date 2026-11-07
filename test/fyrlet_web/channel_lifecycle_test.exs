defmodule FyrletWeb.ChannelLifecycleTest do
  use Fyrlet.DataCase, async: false
  import Phoenix.ChannelTest, except: [join: 2]
  alias Fyrlet.Subscriptions.Tracker
  @endpoint FyrletWeb.Endpoint

  @entries %{
    subscription: {"test.private_feed", %{}, %{}},
    append: {"feed.recent", %{"append" => 1}, %{"room" => "quality"}},
    presence: {"room.presence", %{"presence" => 1}, %{"room" => "quality"}}
  }

  setup do
    Process.flag(:trap_exit, true)
    previous = Application.fetch_env!(:fyrlet, :max_subscriptions_per_node)
    on_exit(fn -> Application.put_env(:fyrlet, :max_subscriptions_per_node, previous) end)
    %{alice: user(project())}
  end

  for {kind, next} <- [subscription: :append, append: :presence, presence: :subscription] do
    test "#{kind} rejects malformed identifiers without reserving a node slot", %{alice: alice} do
      baseline = active()

      assert {:error, %{"error" => %{"code" => "VALIDATION_FAILED"}}} =
               enter(alice, unquote(kind), "invalid")

      assert active() == baseline
    end

    test "#{kind} and #{next} share the node budget and release slots on leave", %{alice: alice} do
      baseline = active()
      Application.put_env(:fyrlet, :max_subscriptions_per_node, baseline + 1)
      {:ok, _reply, socket} = enter(alice, unquote(kind))
      assert active() == baseline + 1

      assert {:error,
              %{"error" => %{"code" => "LIMIT_EXCEEDED", "details" => %{"scope" => "node"}}}} =
               enter(alice, unquote(next))

      leave_and_wait(socket, baseline)
      {:ok, _reply, replacement} = enter(alice, unquote(next))
      leave_and_wait(replacement, baseline)
    end

    test "#{kind} expiry closes the channel and cancels its timers", %{alice: alice} do
      baseline = active()
      {:ok, _reply, socket} = enter(alice, unquote(kind))

      references =
        for key <- [:ack_timer, :expiry_timer, :reconcile_timer, :recheck_timer],
            reference = socket.assigns[key],
            is_reference(reference),
            do: reference

      references =
        case socket.assigns[:observation] do
          nil -> references
          observation -> [observation.reconcile_timer | references]
        end

      monitor = Process.monitor(socket.channel_pid)
      send(socket.channel_pid, :expired)
      assert_push "status", %{"state" => "closed", "error" => %{"code" => "UNAUTHENTICATED"}}
      assert_receive {:DOWN, ^monitor, :process, _channel, _reason}
      assert Enum.all?(references, &(Process.read_timer(&1) == false))
      wait_for_active(baseline)
    end
  end

  defp enter(alice, kind, identifier \\ Ecto.UUID.generate()) do
    {name, capabilities, params} = Map.fetch!(@entries, kind)

    socket(FyrletWeb.UserSocket, "sessions:" <> alice.actor.session_id, %{actor: alice.actor})
    |> subscribe_and_join("#{kind}:#{identifier}", %{
      "protocol_version" => 1,
      "name" => name,
      "params" => params,
      "capabilities" => capabilities
    })
  end

  defp active, do: map_size(:sys.get_state(Tracker).monitors)

  defp leave_and_wait(socket, expected) do
    monitor = Process.monitor(socket.channel_pid)
    leave(socket)
    assert_receive {:DOWN, ^monitor, :process, _channel, _reason}
    wait_for_active(expected)
  end

  defp wait_for_active(expected, attempts \\ 100) do
    if active() != expected do
      assert attempts > 0
      Process.sleep(1)
      wait_for_active(expected, attempts - 1)
    end
  end
end
