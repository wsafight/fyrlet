defmodule FyrletWeb.PresenceChannelTest do
  use Fyrlet.DataCase, async: false
  import Phoenix.ChannelTest, except: [join: 2]
  @endpoint FyrletWeb.Endpoint
  alias Fyrlet.Registry

  setup do
    Process.flag(:trap_exit, true)

    saved =
      for key <- [
            :presence_deny,
            :quotas,
            :presence_max_members,
            :presence_updates_per_second,
            :presence_max_meta_bytes
          ],
          into: %{},
          do: {key, Application.get_env(:fyrlet, key)}

    on_exit(fn ->
      for {key, value} <- saved do
        if is_nil(value),
          do: Application.delete_env(:fyrlet, key),
          else: Application.put_env(:fyrlet, key, value)
      end
    end)

    project = project()
    %{project: project, alice: user(project, "alice"), bob: user(project, "bob")}
  end

  defp payload(room, extra) do
    Map.merge(
      %{
        "protocol_version" => 1,
        "capabilities" => %{"presence" => 1},
        "name" => "room.presence",
        "params" => %{"room" => room}
      },
      extra
    )
  end

  defp enter(user, room, extra \\ %{}) do
    socket(FyrletWeb.UserSocket, "sessions:" <> user.actor.session_id, %{actor: user.actor})
    |> subscribe_and_join("presence:" <> Ecto.UUID.generate(), payload(room, extra))
  end

  defp code({:error, %{"error" => %{"code" => code}}}), do: code

  test "a member gets the roster, and others see joins, meta updates and leaves", %{
    alice: alice,
    bob: bob
  } do
    {:ok, first, alice_socket} = enter(alice, "r1")
    assert first["self"] == alice.actor.subject_id

    assert [%{"data" => %{"typing" => false}, "joined_at" => joined, "ref" => ref}] =
             first["state"][alice.actor.subject_id]

    assert is_binary(joined) and is_binary(ref)

    {:ok, second, bob_socket} = enter(bob, "r1", %{"meta" => %{"status" => "here"}})

    assert Map.keys(second["state"]) |> Enum.sort() ==
             Enum.sort([alice.actor.subject_id, bob.actor.subject_id])

    bob_id = bob.actor.subject_id

    assert_push "diff", %{
      "joins" => %{^bob_id => [%{"data" => %{"status" => "here", "typing" => false}}]},
      "leaves" => leaves
    }

    assert leaves == %{}

    ref = push(bob_socket, "update", %{"meta" => %{"typing" => true}})
    assert_reply ref, :ok

    assert_push "diff", %{
      "joins" => %{^bob_id => [%{"data" => %{"typing" => true}}]},
      "leaves" => %{^bob_id => [_old]}
    }

    leave(bob_socket)
    assert_push "diff", %{"leaves" => %{^bob_id => [_]}}
    leave(alice_socket)
  end

  test "one person on two devices is one key with two metas", %{alice: alice} do
    {:ok, _, one} = enter(alice, "r1")
    {:ok, state, two} = enter(alice, "r1")
    assert [_, _] = state["state"][alice.actor.subject_id]
    assert map_size(state["state"]) == 1
    leave(one)
    leave(two)
  end

  test "rooms are separate, and the same room name in another project is another room", %{
    alice: alice,
    bob: bob
  } do
    outsider = user(project(), "carol")
    {:ok, _, alice_socket} = enter(alice, "r1")
    {:ok, other_room, _b} = enter(bob, "r2")
    assert Map.keys(other_room["state"]) == [bob.actor.subject_id]
    {:ok, other_project, _c} = enter(outsider, "r1")
    assert Map.keys(other_project["state"]) == [outsider.actor.subject_id]

    # Each channel hears its own join; nobody else's reaches alice's channel.
    topic = alice_socket.topic
    {bob_id, carol_id} = {bob.actor.subject_id, outsider.actor.subject_id}

    for foreign <- [bob_id, carol_id] do
      refute_receive %Phoenix.Socket.Message{
                       topic: ^topic,
                       event: "diff",
                       payload: %{"joins" => %{^foreign => _}}
                     },
                     100
    end
  end

  test "the client cannot choose its identity or send meta outside the schema", %{alice: alice} do
    for bad <- [
          %{"typing" => "yes"},
          %{"subject_id" => "someone-else"},
          %{"status" => String.duplicate("x", 17)},
          "text"
        ] do
      assert code(enter(alice, "r1", %{"meta" => bad})) == "VALIDATION_FAILED"
    end

    Application.put_env(:fyrlet, :presence_max_meta_bytes, 20)

    assert code(enter(alice, "r1", %{"meta" => %{"status" => "0123456789abcde"}})) ==
             "LIMIT_EXCEEDED"
  end

  test "joining is refused without v2, the capability, a known name, valid params or authorization",
       %{alice: alice} do
    assert code(enter(alice, "r1", %{"protocol_version" => 2})) == "UNSUPPORTED_VERSION"
    assert code(enter(alice, "r1", %{"capabilities" => %{}})) == "UNSUPPORTED_CAPABILITY"
    assert code(enter(alice, "r1", %{"capabilities" => nil})) == "UNSUPPORTED_CAPABILITY"
    assert code(enter(alice, "r1", %{"name" => "nope.presence"})) == "NOT_FOUND"
    assert code(enter(alice, "r1", %{"name" => "inbox.add"})) == "NOT_FOUND"
    assert code(enter(alice, "r1", %{"params" => %{}})) == "VALIDATION_FAILED"
    assert code(enter(alice, "r1", %{"name" => 5})) == "UNSUPPORTED_VERSION"

    Application.put_env(:fyrlet, :presence_deny, [alice.actor.subject_id])
    assert code(enter(alice, "r1")) == "FORBIDDEN"
  end

  test "an anonymous principal cannot enter a presence room", %{project: project} do
    Application.put_env(:fyrlet, :anonymous, %{
      project.project.id => %{ttl: 600, per_minute: 5, max_active: 4}
    })

    on_exit(fn -> Application.delete_env(:fyrlet, :anonymous) end)
    {:ok, session} = Fyrlet.Features.Anonymous.issue(project.project.id)
    {:ok, actor} = Fyrlet.Auth.authenticate(session["token"], project.project.id)

    result =
      socket(FyrletWeb.UserSocket, "sessions:" <> actor.session_id, %{actor: actor})
      |> subscribe_and_join(
        "presence:" <> Ecto.UUID.generate(),
        payload("r1", %{"capabilities" => %{"presence" => 1, "anonymous_read" => 1}})
      )

    assert code(result) == "FORBIDDEN"
  end

  test "a full room refuses a new member but not one that is already in it", %{
    alice: alice,
    bob: bob
  } do
    Application.put_env(:fyrlet, :presence_max_members, 1)
    {:ok, _, _a} = enter(alice, "r1")
    assert code(enter(bob, "r1")) == "LIMIT_EXCEEDED"
    assert {:ok, _, _again} = enter(alice, "r1")
  end

  test "meta updates are validated and rate limited", %{alice: alice} do
    Application.put_env(:fyrlet, :presence_updates_per_second, 3)
    {:ok, _, socket} = enter(alice, "r1")

    ref = push(socket, "update", %{"meta" => %{"typing" => "nope"}})
    assert_reply ref, :error, %{"error" => %{"code" => "VALIDATION_FAILED"}}

    outcomes =
      for n <- 1..8 do
        ref = push(socket, "update", %{"meta" => %{"status" => "s#{n}"}})

        receive do
          %Phoenix.Socket.Reply{ref: ^ref, status: status, payload: payload} -> {status, payload}
        after
          1_000 -> :timeout
        end
      end

    refused =
      Enum.filter(outcomes, &match?({:error, %{"error" => %{"code" => "LIMIT_EXCEEDED"}}}, &1))

    assert refused != [] and Enum.any?(outcomes, &match?({:ok, _}, &1))
    ref = push(socket, "nothing", %{})
    assert_reply ref, :error, %{"error" => %{"code" => "NOT_FOUND"}}
  end

  test "membership is re-checked: losing authorization or the session ends the channel", %{
    alice: alice,
    bob: bob
  } do
    {:ok, _, a} = enter(alice, "r1")
    {:ok, _, b} = enter(bob, "r1")

    Application.put_env(:fyrlet, :presence_deny, [alice.actor.subject_id])
    send(a.channel_pid, :recheck)
    assert_push "status", %{"state" => "closed", "error" => %{"code" => "FORBIDDEN"}}

    {:ok, _} = Fyrlet.Auth.revoke_own_session(bob.actor)
    send(b.channel_pid, :recheck)
    assert_push "status", %{"state" => "closed", "error" => %{"code" => "UNAUTHENTICATED"}}
  end

  test "a presence channel counts against the project subscription cap", %{alice: alice, bob: bob} do
    Application.put_env(:fyrlet, :quotas, default: [max_subscriptions: 1])
    {:ok, _, _a} = enter(alice, "r1")
    assert code(enter(bob, "r1")) == "LIMIT_EXCEEDED"
  end

  test "the contract lists presence rooms when the capability is enabled" do
    assert %{"room.presence" => room, "lobby.presence" => _} = Registry.export()["presence"]

    assert room["meta"]["properties"]["typing"]["default"] == false
  end

  test "an expired session closes the channel", %{alice: alice} do
    {:ok, _, socket} = enter(alice, "r1")
    send(socket.channel_pid, :expired)
    assert_push "status", %{"state" => "closed", "error" => %{"code" => "UNAUTHENTICATED"}}
  end
end
