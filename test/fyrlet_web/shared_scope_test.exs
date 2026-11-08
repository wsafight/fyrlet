defmodule FyrletWeb.SharedScopeTest do
  use Fyrlet.DataCase, async: false
  import Phoenix.ChannelTest, except: [join: 2]
  @endpoint FyrletWeb.Endpoint
  alias Fyrlet.{Schema, SharedRooms}

  setup do
    Process.flag(:trap_exit, true)
    :ok = SharedRooms.start()
    SharedRooms.reset()
    project = project()
    members = for name <- ~w(alice bob carol), into: %{}, do: {name, user(project, name)}
    outsider = user(project, "mallory")
    for {_n, u} <- members, do: SharedRooms.add_member("r1", u.actor.subject_id)

    on_exit(fn ->
      Application.delete_env(:fyrlet, :room_deny)
      Application.delete_env(:fyrlet, :room_policy_version)
      Application.delete_env(:fyrlet, :room_definition_version)

      for {{:identical, _, project_id, _, _, _, _, _}, observer} <-
            Registry.select(Fyrlet.ObserverRegistry, [
              {{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}
            ]),
          project_id == project.project.id do
        try do
          GenServer.stop(observer)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{
      project: project,
      alice: members["alice"],
      bob: members["bob"],
      carol: members["carol"],
      outsider: outsider
    }
  end

  @v1 %{"protocol_version" => 1}

  defp join_room(user, room \\ "r1", options \\ @v1) do
    socket(FyrletWeb.UserSocket, "sessions:" <> user.actor.session_id, %{actor: user.actor})
    |> subscribe_and_join(
      "subscription:" <> Ecto.UUID.generate(),
      Map.merge(%{"name" => "room.recent", "params" => %{"room" => room}}, options)
    )
  end

  defp observers(project) do
    Registry.select(Fyrlet.ObserverRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {key, _pid} ->
      match?({:identical, _, _, _, _, _, _, _}, key) and elem(key, 2) == project.project.id
    end)
  end

  defp ack(snapshot), do: %{"g" => snapshot["generation"], "s" => snapshot["seq"]}

  test "members share one observer and one query per change, and receive identical data", %{
    alice: alice,
    bob: bob,
    project: project
  } do
    slow_reconcile()
    SharedRooms.post("r1", "hello")
    {:ok, first, socket_a} = join_room(alice)
    queries_after_first = SharedRooms.queries()
    {:ok, second, socket_b} = join_room(bob)

    assert length(observers(project)) == 1

    assert SharedRooms.queries() == queries_after_first,
           "the second member must not trigger a query"

    assert first["data"] == second["data"]
    assert [%{"text" => "hello"}] = first["data"]
    push(socket_a, "ack", ack(first))
    push(socket_b, "ack", ack(second))
    for socket <- [socket_a, socket_b], do: :sys.get_state(socket.channel_pid)
    [{_key, observer}] = observers(project)
    assert Enum.all?(flush(observer).clients, fn {_channel, client} -> client.ready end)

    SharedRooms.post("r1", "second")
    before = SharedRooms.queries()
    Phoenix.PubSub.broadcast(Fyrlet.PubSub, "room:#{project.project.id}:r1", :invalidated)
    assert_push "snapshot", for_a, 1_000
    assert_push "snapshot", for_b, 1_000
    assert SharedRooms.queries() == before + 1, "one query serves every member"
    assert for_a["data"] == for_b["data"] and length(for_a["data"]) == 2
    leave(socket_a)
    leave(socket_b)
  end

  test "confirmation bypasses a warm shared cache and belongs only to the requesting member", %{
    alice: alice,
    bob: bob
  } do
    slow_reconcile()
    options = Map.put(@v1, "capabilities", %{"view_confirmation" => 1})
    {:ok, initial, first} = join_room(alice, "r1", options)
    {:ok, other, second} = join_room(bob, "r1", options)
    push(first, "ack", ack(initial))
    push(second, "ack", ack(other))
    SharedRooms.post("r1", "written without notification")
    reference = push(first, "refresh", %{"confirmation_id" => "fresh-primary-read"})
    assert_reply reference, :ok, %{"accepted" => true}
    assert_push "snapshot", snapshot
    assert_push "snapshot", sibling

    requested =
      Enum.find([snapshot, sibling], &(&1["subscription_id"] == initial["subscription_id"]))

    other = Enum.find([snapshot, sibling], &(&1["subscription_id"] != initial["subscription_id"]))
    assert requested["confirmed"] == ["fresh-primary-read"]
    assert [%{"text" => "written without notification"}] = requested["data"]
    refute Map.has_key?(other, "confirmed")
    for socket <- [first, second], do: leave(socket)
  end

  test "a warm cache gives a non-member nothing", %{alice: alice, outsider: outsider} do
    SharedRooms.post("r1", "private to the room")
    {:ok, _snapshot, socket} = join_room(alice)
    assert {:error, %{"error" => %{"code" => "FORBIDDEN"}}} = join_room(outsider)
    leave(socket)

    # Not a member of a room that does not exist yet either.
    assert {:error, %{"error" => %{"code" => "FORBIDDEN"}}} = join_room(alice, "other-room")
  end

  test "authorize/3 still decides for each member", %{alice: alice, bob: bob} do
    {:ok, _, socket} = join_room(alice)
    Application.put_env(:fyrlet, :room_deny, bob.actor.subject_id)
    assert {:error, %{"error" => %{"code" => "FORBIDDEN"}}} = join_room(bob)
    leave(socket)
  end

  # The test environment reconciles every 100 ms, which would remove a member on its own.
  # Each path below is exercised with that timer out of the way.
  defp slow_reconcile do
    previous = Application.fetch_env!(:fyrlet, :reconciliation_interval)
    Application.put_env(:fyrlet, :reconciliation_interval, 600_000)
    on_exit(fn -> Application.put_env(:fyrlet, :reconciliation_interval, previous) end)
  end

  defp flush(observer), do: :sys.get_state(observer)

  test "a membership-change signal removes a member at once; the others carry on", %{
    alice: alice,
    bob: bob,
    project: project
  } do
    slow_reconcile()
    {:ok, a, socket_a} = join_room(alice)
    {:ok, b, socket_b} = join_room(bob)
    push(socket_a, "ack", ack(a))
    push(socket_b, "ack", ack(b))
    [{_key, observer}] = observers(project)
    flush(observer)
    {topic_a, topic_b} = {socket_a.topic, socket_b.topic}

    SharedRooms.remove_member("r1", bob.actor.subject_id)
    send(observer, :membership_changed)

    assert_receive %Phoenix.Socket.Message{
                     topic: ^topic_b,
                     event: "status",
                     payload: %{"state" => "closed", "error" => %{"code" => "FORBIDDEN"}}
                   },
                   1_000

    refute_received %Phoenix.Socket.Message{topic: ^topic_a, event: "status"}

    SharedRooms.post("r1", "after removal")
    Phoenix.PubSub.broadcast(Fyrlet.PubSub, "room:#{project.project.id}:r1", :invalidated)

    assert_receive %Phoenix.Socket.Message{
                     topic: ^topic_a,
                     event: "snapshot",
                     payload: %{"data" => [%{"text" => "after removal"}]}
                   },
                   1_000

    refute_receive %Phoenix.Socket.Message{topic: ^topic_b, event: "snapshot"}, 150
    leave(socket_a)
  end

  test "ordinary invalidation revokes membership even when the shared data is unchanged", %{
    alice: alice,
    bob: bob,
    project: project
  } do
    slow_reconcile()
    {:ok, alice_snapshot, alice_socket} = join_room(alice)
    {:ok, bob_snapshot, bob_socket} = join_room(bob)
    push(alice_socket, "ack", ack(alice_snapshot))
    push(bob_socket, "ack", ack(bob_snapshot))
    [{_key, observer}] = observers(project)
    flush(observer)
    alice_topic = alice_socket.topic
    bob_topic = bob_socket.topic

    SharedRooms.remove_member("r1", bob.actor.subject_id)
    Phoenix.PubSub.broadcast(Fyrlet.PubSub, "room:#{project.project.id}:r1", :invalidated)

    assert_receive %Phoenix.Socket.Message{
                     topic: ^bob_topic,
                     event: "status",
                     payload: %{"state" => "closed", "error" => %{"code" => "FORBIDDEN"}}
                   },
                   1_000

    refute_receive %Phoenix.Socket.Message{topic: ^alice_topic}, 150
    refute_received %Phoenix.Socket.Message{topic: ^bob_topic, event: "snapshot"}
    leave(alice_socket)
  end

  test "with no signal and no timer, a removed member is still stopped before data reaches them",
       %{alice: alice, bob: bob, project: project} do
    slow_reconcile()
    {:ok, a, socket_a} = join_room(alice)
    {:ok, b, socket_b} = join_room(bob)
    push(socket_a, "ack", ack(a))
    push(socket_b, "ack", ack(b))
    [{_key, observer}] = observers(project)
    flush(observer)
    {topic_a, topic_b} = {socket_a.topic, socket_b.topic}

    SharedRooms.remove_member("r1", bob.actor.subject_id)
    SharedRooms.post("r1", "secret after removal")
    Phoenix.PubSub.broadcast(Fyrlet.PubSub, "room:#{project.project.id}:r1", :invalidated)

    assert_receive %Phoenix.Socket.Message{
                     topic: ^topic_b,
                     event: "status",
                     payload: %{"state" => "closed"}
                   },
                   1_000

    assert_receive %Phoenix.Socket.Message{
                     topic: ^topic_a,
                     event: "snapshot",
                     payload: %{"data" => [%{"text" => "secret after removal"}]}
                   },
                   1_000

    refute_received %Phoenix.Socket.Message{topic: ^topic_b, event: "snapshot"}
    leave(socket_a)
  end

  test "the periodic reconciliation also removes a member nobody signalled about", %{
    alice: alice,
    bob: bob
  } do
    {:ok, a, socket_a} = join_room(alice)
    {:ok, _b, socket_b} = join_room(bob)
    push(socket_a, "ack", ack(a))
    topic_b = socket_b.topic
    SharedRooms.remove_member("r1", bob.actor.subject_id)

    assert_receive %Phoenix.Socket.Message{
                     topic: ^topic_b,
                     event: "status",
                     payload: %{"state" => "closed"}
                   },
                   2_000

    leave(socket_a)
  end

  test "a member whose session is revoked is stopped on the next check", %{
    alice: alice,
    bob: bob,
    project: project
  } do
    slow_reconcile()
    {:ok, a, socket_a} = join_room(alice)
    {:ok, _b, socket_b} = join_room(bob)
    push(socket_a, "ack", ack(a))
    [{_key, observer}] = observers(project)
    flush(observer)
    topic_b = socket_b.topic

    {:ok, _} = Fyrlet.Auth.revoke_own_session(bob.actor)
    send(observer, :membership_changed)

    assert_receive %Phoenix.Socket.Message{
                     topic: ^topic_b,
                     event: "status",
                     payload: %{"state" => "closed"}
                   },
                   1_000

    leave(socket_a)
  end

  test "with batched session checks a revoked member is still the only one stopped", %{
    alice: alice,
    bob: bob,
    carol: carol,
    project: project
  } do
    Application.put_env(:fyrlet, :batch_session_checks, true)
    on_exit(fn -> Application.put_env(:fyrlet, :batch_session_checks, false) end)
    slow_reconcile()
    {:ok, a, socket_a} = join_room(alice)
    {:ok, b, socket_b} = join_room(bob)
    {:ok, c, socket_c} = join_room(carol)

    for {socket, snapshot} <- [{socket_a, a}, {socket_b, b}, {socket_c, c}],
        do: push(socket, "ack", ack(snapshot))

    [{_key, observer}] = observers(project)
    flush(observer)
    topic_b = socket_b.topic

    {:ok, _} = Fyrlet.Auth.revoke_own_session(bob.actor)
    SharedRooms.post("r1", "after revoke")
    Phoenix.PubSub.broadcast(Fyrlet.PubSub, "room:#{project.project.id}:r1", :invalidated)

    assert_receive %Phoenix.Socket.Message{
                     topic: ^topic_b,
                     event: "status",
                     payload: %{"state" => "closed"}
                   },
                   1_000

    assert_push "snapshot", %{"data" => data}, 1_000
    assert Enum.any?(data, &(&1["text"] == "after revoke"))
    refute_receive %Phoenix.Socket.Message{topic: ^topic_b, event: "snapshot"}

    leave(socket_a)
    leave(socket_c)
  end

  test "different rooms, parameters, policy and projection versions never share", %{
    alice: alice,
    bob: bob,
    project: project
  } do
    for user <- [alice, bob], do: SharedRooms.add_member("r2", user.actor.subject_id)
    {:ok, _, a1} = join_room(alice, "r1")
    {:ok, _, b1} = join_room(bob, "r1")
    {:ok, _, a2} = join_room(alice, "r2")
    assert length(observers(project)) == 2

    Application.put_env(:fyrlet, :room_policy_version, "2")
    {:ok, _, a3} = join_room(alice, "r1")
    assert length(observers(project)) == 3

    Application.put_env(:fyrlet, :room_definition_version, 2)
    {:ok, _, projection_socket} = join_room(alice, "r1")
    assert length(observers(project)) == 4
    assert Fyrlet.Definition.current_version(Fyrlet.SharedTestDefinition, "room.recent") == "2"
    for socket <- [a1, b1, a2, a3, projection_socket], do: leave(socket)
  end

  test "the shared query sees the project and scope but no person", %{
    alice: alice,
    project: project
  } do
    {:ok, _, socket} = join_room(alice)
    [context | _] = SharedRooms.contexts()
    assert Map.keys(context) |> Enum.sort() == [:project_id, :scope]

    assert context.project_id == project.project.id and
             context.scope == "room:#{project.project.id}:r1"

    leave(socket)
  end

  test "an observer holds no actor and ends when its last member leaves", %{
    alice: alice,
    project: project
  } do
    {:ok, _, socket} = join_room(alice)
    [{_key, observer}] = observers(project)
    assert :sys.get_state(observer).actor == nil
    leave(socket)
    ref = Process.monitor(observer)
    assert_receive {:DOWN, ^ref, :process, ^observer, _}, 2_000
  end

  test "sharing telemetry reports the members served", %{alice: alice, bob: bob, project: project} do
    test = self()
    handler = "shared-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:fyrlet, :scope, :shared],
      fn _e, m, meta, _ -> send(test, {:shared, m, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, a, sa} = join_room(alice)
    {:ok, b, sb} = join_room(bob)
    push(sa, "ack", ack(a))
    push(sb, "ack", ack(b))
    SharedRooms.post("r1", "x")
    Phoenix.PubSub.broadcast(Fyrlet.PubSub, "room:#{project.project.id}:r1", :invalidated)
    assert_receive {:shared, %{members: 2}, %{name: "room.recent", mode: :identical}}, 1_000
  end

  test "the registry demands the callbacks and refuses ambiguous declarations" do
    defmodule NoCallbacks do
      @behaviour Fyrlet.Definition
      def contract, do: Application.fetch_env!(:fyrlet, :registry_test_contract)
      def authorize(_, _, _), do: :ok
      def execute(_, _, _), do: {:ok, "x", []}
      def scope(_, _, _), do: "s"
    end

    spec = fn extra ->
      %{
        "operations" => %{},
        "subscriptions" => %{
          "a.b" =>
            Map.merge(%{"input" => Schema.object(%{}), "output" => %{"type" => "string"}}, extra)
        }
      }
    end

    previous = Application.fetch_env!(:fyrlet, :definitions)

    on_exit(fn ->
      Application.put_env(:fyrlet, :definitions, previous)
      Application.delete_env(:fyrlet, :registry_test_contract)
    end)

    Application.put_env(:fyrlet, :definitions, [NoCallbacks])

    Application.put_env(:fyrlet, :registry_test_contract, spec.(%{"sharing" => "identical"}))
    assert_raise RuntimeError, ~r/needs shared_query\/3/, fn -> Fyrlet.Registry.validate!() end

    Application.put_env(:fyrlet, :registry_test_contract, spec.(%{"sharing" => "masked"}))
    assert_raise RuntimeError, ~r/unknown sharing/, fn -> Fyrlet.Registry.validate!() end

    Application.put_env(
      :fyrlet,
      :registry_test_contract,
      spec.(%{"sharing" => "identical", "shared" => true})
    )

    assert_raise RuntimeError, ~r/both shared and sharing identical/, fn ->
      Fyrlet.Registry.validate!()
    end
  end
end
