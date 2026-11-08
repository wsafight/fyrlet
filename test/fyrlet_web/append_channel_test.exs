defmodule FyrletWeb.AppendChannelTest do
  use Fyrlet.DataCase, async: false
  import Phoenix.ChannelTest, except: [join: 2]
  alias Fyrlet.Features.Stream
  @endpoint FyrletWeb.Endpoint

  setup do
    Process.flag(:trap_exit, true)
    previous = Application.get_env(:fyrlet, :streams)
    timeout = Application.fetch_env!(:fyrlet, :snapshot_ack_timeout)
    project = project()
    alice = user(project)
    room = "r" <> Integer.to_string(System.unique_integer([:positive]))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fyrlet, :streams, previous),
        else: Application.delete_env(:fyrlet, :streams)

      Application.put_env(:fyrlet, :snapshot_ack_timeout, timeout)
      Application.delete_env(:fyrlet, :feed_deny)
    end)

    %{project: project, alice: alice, room: room}
  end

  # ---- helpers ---------------------------------------------------------------------------

  defp post(user, room, texts) do
    {:ok, %{"cursor" => cursor}} =
      Fyrlet.Runtime.call(
        user.actor,
        "feed.post",
        %{"room" => room, "texts" => List.wrap(texts)},
        Ecto.UUID.generate(),
        capabilities: %{"append" => 1}
      )

    Oban.drain_queue(queue: :fyrlet)
    cursor
  end

  defp join_feed(user, room, options \\ %{}) do
    socket(FyrletWeb.UserSocket, "sessions:" <> user.actor.session_id, %{actor: user.actor})
    |> subscribe_and_join(
      "append:" <> Ecto.UUID.generate(),
      Map.merge(
        %{
          "protocol_version" => 1,
          "capabilities" => %{"append" => 1},
          "name" => "feed.recent",
          "params" => %{"room" => room}
        },
        options
      )
    )
  end

  defp ack(socket, payload),
    do:
      push(socket, "ack", %{
        "g" => payload["generation"] || payload["g"],
        "s" => payload["seq"] || payload["s"],
        "c" => payload["cursor"]
      })

  defp texts(items), do: Enum.map(items, & &1["text"])

  defp fallbacks do
    test = self()
    id = {:fallback, make_ref()}

    :telemetry.attach(
      id,
      [:fyrlet, :delta, :snapshot_fallback],
      fn _event, _measurements, metadata, _ -> send(test, {:fallback, metadata.reason}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  # ---- join ------------------------------------------------------------------------------

  test "the snapshot is the newest window with a cursor", %{alice: alice, room: room} do
    post(alice, room, ["a", "b", "c", "d", "e", "f", "g"])
    {:ok, snapshot, _socket} = join_feed(alice, room)

    assert texts(snapshot["data"]) == ["c", "d", "e", "f", "g"]
    assert %{"seq" => 1, "mode" => "append", "max_items" => 5, "protocol_version" => 1} = snapshot
    assert is_binary(snapshot["cursor"]) and is_binary(snapshot["generation"])
    assert snapshot["capabilities"] == %{"append" => 1}
  end

  test "confirmation replaces even an unacknowledged snapshot with a fresh window", %{
    alice: alice,
    room: room
  } do
    {:ok, initial, socket} =
      join_feed(alice, room, %{"capabilities" => %{"append" => 1, "view_confirmation" => 1}})

    post(alice, room, "committed")
    reference = push(socket, "refresh", %{"confirmation_id" => "after-commit"})
    assert_reply reference, :ok, %{"accepted" => true}
    assert_push "snapshot", confirmed
    assert confirmed["confirmed"] == ["after-commit"]
    assert confirmed["seq"] > initial["seq"]
    assert texts(confirmed["data"]) == ["committed"]
    ack(socket, confirmed)
    leave(socket)
  end

  test "batches continue exactly at the cursor and acknowledgements are cumulative", %{
    alice: alice,
    room: room
  } do
    {:ok, snapshot, socket} = join_feed(alice, room)
    assert snapshot["data"] == []
    ack(socket, snapshot)

    first = post(alice, room, "one")
    assert_push "append", batch
    assert batch["base_cursor"] == snapshot["cursor"]
    assert batch["cursor"] == first
    assert batch["g"] == snapshot["generation"] and batch["s"] == 2
    assert texts(batch["items"]) == ["one"]

    # Two more batches before any acknowledgement: both are sent, chained by cursor.
    second = post(alice, room, "two")
    third = post(alice, room, "three")
    assert_push "append", %{"base_cursor" => ^first, "cursor" => ^second, "s" => 3}
    assert_push "append", %{"base_cursor" => ^second, "cursor" => ^third, "s" => 4}

    # One cumulative acknowledgement of the last batch settles all three.
    push(socket, "ack", %{"g" => snapshot["generation"], "s" => 4, "c" => third})
    fourth = post(alice, room, "four")
    assert_push "append", %{"base_cursor" => ^third, "cursor" => ^fourth, "s" => 5}
  end

  test "a transaction that rolls back appends nothing", %{alice: alice, room: room} do
    {:ok, snapshot, socket} = join_feed(alice, room)
    ack(socket, snapshot)

    assert {:error, %{code: "CONFLICT"}} =
             Fyrlet.Runtime.call(
               alice.actor,
               "feed.post_then_fail",
               %{"room" => room},
               Ecto.UUID.generate(),
               capabilities: %{"append" => 1}
             )

    Oban.drain_queue(queue: :fyrlet)
    refute_push "append", _, 300
  end

  test "large appends are split into batches that together cover every item", %{
    alice: alice,
    room: room
  } do
    Application.put_env(:fyrlet, :streams, batch_items: 2)
    {:ok, snapshot, socket} = join_feed(alice, room)
    ack(socket, snapshot)
    post(alice, room, ["1", "2", "3", "4", "5"])

    assert_push "append", %{"items" => first, "base_cursor" => base, "cursor" => c1}
    assert_push "append", %{"items" => second, "base_cursor" => ^c1, "cursor" => c2}
    assert_push "append", %{"items" => third, "base_cursor" => ^c2}
    assert base == snapshot["cursor"]
    assert texts(first ++ second ++ third) == ["1", "2", "3", "4", "5"]
  end

  test "a change whose notification was lost is found by the periodic check", %{
    alice: alice,
    room: room,
    project: project
  } do
    {:ok, snapshot, socket} = join_feed(alice, room)
    ack(socket, snapshot)

    # Appended without any invalidation job at all.
    {:ok, _} =
      Repo.transaction(fn ->
        Stream.append(project.project.id, "feed.#{room}", [%{"text" => "quiet"}])
      end)

    assert_push "append", %{"items" => [%{"text" => "quiet"}]}, 1_000
  end

  # ---- flow control ----------------------------------------------------------------------

  test "nothing is sent on top of an unacknowledged snapshot", %{alice: alice, room: room} do
    {:ok, snapshot, socket} = join_feed(alice, room)
    post(alice, room, "waiting")
    refute_push "append", _, 300

    ack(socket, snapshot)
    assert_push "append", %{"items" => [%{"text" => "waiting"}]}
  end

  test "a subscriber too far ahead of its acknowledgements gets a snapshot, not a backlog", %{
    alice: alice,
    room: room
  } do
    fallbacks()
    Application.put_env(:fyrlet, :streams, window_batches: 2)
    {:ok, snapshot, socket} = join_feed(alice, room)
    ack(socket, snapshot)

    post(alice, room, "1")
    post(alice, room, "2")
    assert_push "append", %{"s" => 2}
    assert_push "append", %{"s" => 3}

    post(alice, room, "3")
    assert_push "snapshot", reset
    assert reset["generation"] == snapshot["generation"]
    assert reset["seq"] == 4
    assert texts(reset["data"]) == ["1", "2", "3"]
    assert_received {:fallback, "overflow"}

    # Acknowledgements of the superseded batches change nothing; the snapshot's does.
    push(socket, "ack", %{"g" => snapshot["generation"], "s" => 3, "c" => "stale"})
    post(alice, room, "4")
    refute_push "append", _, 200
    ack(socket, reset)
    assert_push "append", %{"base_cursor" => base, "items" => [%{"text" => "4"}]}
    assert base == reset["cursor"]
  end

  test "the byte budget bounds the unacknowledged window too", %{alice: alice, room: room} do
    fallbacks()
    Application.put_env(:fyrlet, :streams, window_bytes: 40)
    {:ok, snapshot, socket} = join_feed(alice, room)
    ack(socket, snapshot)
    post(alice, room, "first batch of text")
    assert_push "append", _
    post(alice, room, "second batch of text")
    assert_push "snapshot", %{"seq" => 3}
    assert_received {:fallback, "overflow"}
  end

  test "a subscriber that never acknowledges is closed", %{alice: alice, room: room} do
    Application.put_env(:fyrlet, :snapshot_ack_timeout, 100)
    {:ok, _snapshot, socket} = join_feed(alice, room)
    assert_push "status", %{"state" => "closed", "error" => %{"code" => "LIMIT_EXCEEDED"}}, 1_000
    assert_receive {:EXIT, _pid, :normal}
    refute Process.alive?(socket.channel_pid)
  end

  test "acknowledgements that do not match what was sent are ignored", %{alice: alice, room: room} do
    Application.put_env(:fyrlet, :snapshot_ack_timeout, 300)
    {:ok, snapshot, socket} = join_feed(alice, room)

    for bad <- [
          %{"g" => "other", "s" => 1, "c" => snapshot["cursor"]},
          %{"g" => snapshot["generation"], "s" => 1, "c" => "wrong"},
          %{"g" => snapshot["generation"], "s" => 9, "c" => snapshot["cursor"]},
          %{"g" => snapshot["generation"], "s" => "1", "c" => snapshot["cursor"]},
          %{"g" => snapshot["generation"], "s" => 1}
        ] do
      push(socket, "ack", bad)
    end

    assert_push "status", %{"error" => %{"code" => "LIMIT_EXCEEDED"}}, 1_500
  end

  # ---- resets ----------------------------------------------------------------------------

  test "a rewritten stream resets the view with a higher seq in the same generation", %{
    alice: alice,
    room: room,
    project: project
  } do
    fallbacks()
    post(alice, room, ["old"])
    {:ok, snapshot, socket} = join_feed(alice, room)
    ack(socket, snapshot)

    {:ok, _} = Repo.transaction(fn -> Stream.reset(project.project.id, "feed.#{room}") end)
    post(alice, room, "new")

    assert_push "snapshot", reset
    assert reset["generation"] == snapshot["generation"] and reset["seq"] == 2
    assert texts(reset["data"]) == ["new"]
    assert_received {:fallback, "gap"}
  end

  test "trimmed history cannot be continued", %{alice: alice, room: room, project: project} do
    fallbacks()
    # Only the explicit sync below may look at the stream, so the order of events is fixed.
    reconcile = Application.fetch_env!(:fyrlet, :reconciliation_interval)
    Application.put_env(:fyrlet, :reconciliation_interval, 60_000)
    on_exit(fn -> Application.put_env(:fyrlet, :reconciliation_interval, reconcile) end)

    {:ok, snapshot, socket} = join_feed(alice, room)
    ack(socket, snapshot)

    {:ok, _} =
      Repo.transaction(fn ->
        Stream.append(
          project.project.id,
          "feed.#{room}",
          for(n <- 1..12, do: %{"text" => "#{n}"})
        )
      end)

    # Retention trims everything the client's cursor points into before it ever syncs.
    Stream.prune(2)
    send(socket.channel_pid, :sync)
    assert_push "snapshot", %{"seq" => 2, "data" => data}, 1_000
    assert texts(data) == ["11", "12"]
    assert_received {:fallback, "gap"}
    refute_push "append", _, 100
  end

  test "refresh sends a new snapshot, but not while one is outstanding", %{
    alice: alice,
    room: room
  } do
    fallbacks()
    {:ok, snapshot, socket} = join_feed(alice, room)

    ref = push(socket, "refresh", %{})
    assert_reply ref, :ok
    refute_push "snapshot", _, 100

    ack(socket, snapshot)
    ref = push(socket, "refresh", %{})
    assert_reply ref, :ok
    assert_push "snapshot", %{"seq" => 2, "generation" => generation}
    assert generation == snapshot["generation"]
    assert_received {:fallback, "refresh"}
  end

  # ---- admission and authorization -------------------------------------------------------

  test "only clients that negotiated append may join", %{alice: alice, room: room} do
    assert {:error, %{"error" => %{"code" => "UNSUPPORTED_VERSION"}}} =
             join_feed(alice, room, %{"protocol_version" => 2})

    assert {:error, %{"error" => %{"code" => "UNSUPPORTED_CAPABILITY"}}} =
             join_feed(alice, room, %{"capabilities" => %{"runs" => 1}})

    assert {:error, %{"error" => %{"code" => "UNSUPPORTED_CAPABILITY"}}} =
             join_feed(alice, room, %{"capabilities" => nil})
  end

  test "channels and subscriptions must match: append only on append, snapshot only on snapshot",
       %{
         alice: alice,
         room: room
       } do
    assert {:error, %{"error" => %{"code" => "VALIDATION_FAILED"}}} =
             join_feed(alice, room, %{"name" => "feed.plain"})

    assert {:error, %{"error" => %{"code" => "VALIDATION_FAILED"}}} =
             socket(FyrletWeb.UserSocket, "sessions:" <> alice.actor.session_id, %{
               actor: alice.actor
             })
             |> subscribe_and_join("subscription:" <> Ecto.UUID.generate(), %{
               "protocol_version" => 1,
               "capabilities" => %{"append" => 1},
               "name" => "feed.recent",
               "params" => %{"room" => room}
             })

    assert {:error, %{"error" => %{"code" => "VALIDATION_FAILED"}}} =
             join_feed(alice, room, %{"params" => %{}})
  end

  test "a denied subscriber is refused, and one whose access is revoked is closed", %{
    alice: alice,
    room: room
  } do
    {:ok, snapshot, socket} = join_feed(alice, room)
    ack(socket, snapshot)

    Application.put_env(:fyrlet, :feed_deny, alice.actor.subject_id)
    assert {:error, %{"error" => %{"code" => "FORBIDDEN"}}} = join_feed(alice, room)

    {:ok, _} =
      Repo.transaction(fn ->
        Stream.append(alice.actor.project_id, "feed.#{room}", [%{"text" => "secret"}])
      end)

    send(socket.channel_pid, :sync)
    assert_push "status", %{"state" => "closed", "error" => %{"code" => "FORBIDDEN"}}, 1_000
    refute_push "append", _
  end

  test "another project's stream is never read", %{alice: alice, room: room} do
    other = user(project(), "mallory")
    post(other, room, ["theirs"])
    {:ok, snapshot, _socket} = join_feed(alice, room)
    assert snapshot["data"] == []
  end
end
