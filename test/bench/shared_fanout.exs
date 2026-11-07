defmodule Fyrlet.Bench.SharedFanout do
  @moduledoc """
  Fan-out cost of an `identical` shared subscription: N members of one room, one change.
  Reports session statements per change and the time until every member has the snapshot.

      mix test test/bench/shared_fanout.exs                 # N=100
      FANOUT=400 ROUNDS=10 mix test test/bench/shared_fanout.exs

  Runs inside the SQL sandbox, so it leaves nothing behind. Not part of the normal suite.
  """
  use Fyrlet.DataCase, async: false
  import Phoenix.ChannelTest, except: [join: 2]
  @endpoint FyrletWeb.Endpoint
  alias Fyrlet.SharedRooms

  @tag timeout: 300_000
  test "shared fan-out" do
    Process.flag(:trap_exit, true)
    n = String.to_integer(System.get_env("FANOUT", "100"))
    rounds = String.to_integer(System.get_env("ROUNDS", "5"))
    Application.put_env(:fyrlet, :batch_session_checks, true)
    on_exit(fn -> Application.put_env(:fyrlet, :batch_session_checks, false) end)
    Application.put_env(:fyrlet, :reconciliation_interval, 600_000)
    previous = Application.get_env(:fyrlet, :max_subscriptions)
    Application.put_env(:fyrlet, :max_subscriptions, n + 10)
    on_exit(fn -> Application.put_env(:fyrlet, :max_subscriptions, previous) end)

    :ok = SharedRooms.start()
    SharedRooms.reset()
    project = project()
    users = for i <- 1..n, do: user(project, "u#{i}")
    for u <- users, do: SharedRooms.add_member("r1", u.actor.subject_id)
    SharedRooms.post("r1", "hello")

    sockets =
      for u <- users do
        {:ok, snapshot, socket} =
          socket(FyrletWeb.UserSocket, "sessions:" <> u.actor.session_id, %{actor: u.actor})
          |> subscribe_and_join("subscription:" <> Ecto.UUID.generate(), %{
            "protocol_version" => 1,
            "name" => "room.recent",
            "params" => %{"room" => "r1"}
          })

        push(socket, "ack", %{"g" => snapshot["generation"], "s" => snapshot["seq"]})
        {socket, snapshot["generation"]}
      end

    Process.sleep(200)
    counter = :counters.new(1, [])
    handler = {:queries, make_ref()}

    :telemetry.attach(
      handler,
      [:fyrlet, :repo, :query],
      fn _, _, meta, _ ->
        if meta.query =~ ~s(FROM "sessions"), do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    results =
      for r <- 1..rounds do
        :counters.put(counter, 1, 0)
        SharedRooms.post("r1", "m#{r}")
        started = System.monotonic_time(:microsecond)
        Phoenix.PubSub.broadcast(Fyrlet.PubSub, "room:#{project.project.id}:r1", :invalidated)
        seqs = collect(n, [])
        elapsed = System.monotonic_time(:microsecond) - started
        queries = :counters.get(counter, 1)

        for {socket, generation} <- sockets,
            do: push(socket, "ack", %{"g" => generation, "s" => Map.fetch!(seqs, socket.topic)})

        Process.sleep(50)
        {queries, elapsed}
      end

    :telemetry.detach(handler)
    ms = results |> Enum.map(&elem(&1, 1)) |> Enum.sort() |> Enum.at(div(rounds, 2))
    q = results |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> Enum.at(div(rounds, 2))

    IO.puts(
      "members=#{n} session_statements/change=#{q} time_to_all=#{Float.round(ms / 1000, 1)} ms (median of #{rounds})"
    )
  end

  defp collect(0, acc), do: Map.new(acc)

  defp collect(left, acc) do
    receive do
      %Phoenix.Socket.Message{event: "snapshot", topic: topic, payload: p} ->
        collect(left - 1, [{topic, p["seq"]} | acc])
    after
      10_000 -> flunk("timed out with #{left} members missing a snapshot")
    end
  end
end
