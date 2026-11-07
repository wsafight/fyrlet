defmodule FyrletWeb.RunsSubscriptionTest do
  use Fyrlet.RunsCase
  import Phoenix.ChannelTest, except: [join: 2]
  @endpoint FyrletWeb.Endpoint

  setup do
    Process.flag(:trap_exit, true)
    project = project()
    alice = user(project, "alice")

    on_exit(fn ->
      entries =
        Registry.select(Fyrlet.ObserverRegistry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])

      for {{%{project_id: id}, _}, observer} <- entries, id == project.project.id do
        try do
          GenServer.stop(observer)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{alice: alice, project: project}
  end

  defp join_run(
         user,
         name,
         params,
         options \\ %{"protocol_version" => 1, "capabilities" => %{"runs" => 1}}
       ) do
    socket(FyrletWeb.UserSocket, "sessions:" <> user.actor.session_id, %{actor: user.actor})
    |> subscribe_and_join(
      "subscription:" <> Ecto.UUID.generate(),
      Map.merge(%{"name" => name, "params" => params}, options)
    )
  end

  # Snapshots may coalesce or show an intermediate state first; wait for the one wanted.
  defp await_status(socket, wanted, tries \\ 20) do
    assert_push "snapshot", snapshot, 1_000
    push(socket, "ack", ack(snapshot))

    cond do
      snapshot["data"]["status"] == wanted -> snapshot
      tries > 0 -> await_status(socket, wanted, tries - 1)
      true -> flunk("never saw status #{wanted}; last was #{snapshot["data"]["status"]}")
    end
  end

  defp ack(snapshot_or_delta),
    do: %{
      "g" => snapshot_or_delta["generation"] || snapshot_or_delta["g"],
      "s" => snapshot_or_delta["seq"] || snapshot_or_delta["s"]
    }

  test "a second client watches a run change and recovers (R09)", %{alice: alice} do
    id = start_run!(alice)
    {:ok, snapshot, socket} = join_run(alice, "fyrlet.run", %{"run_id" => id})

    assert snapshot["protocol_version"] == 1 and snapshot["capabilities"] == %{"runs" => 1}

    assert %{
             "status" => "pending",
             "steps" => [_, _, _],
             "events" => [%{"type" => "run.created"}]
           } = snapshot["data"]

    push(socket, "ack", ack(snapshot))

    assert drive(id) == "waiting"
    waiting = await_status(socket, "waiting")
    assert waiting["data"]["wait_reason"] == "signal"
    assert Enum.any?(waiting["data"]["events"], &(&1["type"] == "wait.entered"))

    {:ok, _} = signal(alice.actor, id)
    resumed = await_status(socket, "running")
    assert Enum.any?(resumed["data"]["events"], &(&1["type"] == "wait.satisfied"))
    leave(socket)

    # A client that connects later (a reconnect) gets the committed state, not a replay.
    assert drive(id) == "completed"
    {:ok, later, socket} = join_run(alice, "fyrlet.run", %{"run_id" => id})
    assert later["data"]["status"] == "completed" and later["data"]["output_json"] =~ "publish"

    assert Enum.map(later["data"]["steps"], & &1["status"]) == [
             "succeeded",
             "satisfied",
             "succeeded"
           ]

    leave(socket)
  end

  test "the recent list shows only the caller's runs and updates", %{alice: alice} do
    bob = user(project(), "bob")
    mine = start_run!(alice)
    _theirs = start_run!(bob)

    {:ok, snapshot, socket} = join_run(alice, "fyrlet.runs.recent", %{})
    assert [%{"id" => ^mine, "status" => "pending"}] = snapshot["data"]
    push(socket, "ack", ack(snapshot))

    {:ok, _} = Runs.cancel(alice.actor, mine)
    assert_push "snapshot", update, 1_000
    assert [%{"id" => ^mine, "status" => status}] = update["data"]
    assert status in ["cancelling", "cancelled"]
    leave(socket)
  end

  test "the run subscription needs protocol 2 with the capability and an authorized viewer", %{
    alice: alice,
    project: project
  } do
    id = start_run!(alice)
    stranger = user(project(), "eve")
    bob = user(project, "bob")

    assert {:error, %{"error" => %{"code" => "UNSUPPORTED_CAPABILITY"}}} =
             join_run(alice, "fyrlet.run", %{"run_id" => id}, %{"protocol_version" => 1})

    assert {:error, %{"error" => %{"code" => "UNSUPPORTED_CAPABILITY"}}} =
             join_run(alice, "fyrlet.run", %{"run_id" => id}, %{
               "protocol_version" => 1,
               "capabilities" => %{"other" => 1}
             })

    assert {:error, %{"error" => %{"code" => "NOT_FOUND"}}} =
             join_run(stranger, "fyrlet.run", %{"run_id" => id})

    assert {:error, %{"error" => %{"code" => "FORBIDDEN"}}} =
             join_run(bob, "fyrlet.run", %{"run_id" => id})

    assert {:error, %{"error" => %{"code" => "VALIDATION_FAILED"}}} =
             join_run(alice, "fyrlet.run", %{"run_id" => "x"})
  end

  test "long histories are bounded and marked truncated", %{alice: alice} do
    id = start_run!(alice)
    run = run(id)

    for n <- 1..80 do
      Fyrlet.Runs.Store.event(run.id, "noise.#{n}", nil, %{"n" => n})
    end

    view = Fyrlet.Runs.View.build(run(id))
    assert length(view["events"]) == 50 and view["events_truncated"]
    assert hd(view["events"])["seq"] < List.last(view["events"])["seq"]
    assert List.last(view["events"])["type"] == "noise.80"
  end
end
