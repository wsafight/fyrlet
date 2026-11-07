defmodule Fyrlet.Bench.AppendFanout do
  @moduledoc """
  Fan-out cost of append subscriptions: N subscribers in one room, P posts in a row.
  Reports database queries per post and the time until every subscriber has the batch.

      mix test test/bench/append_fanout.exs                 # N=100
      FANOUT=400 POSTS=30 mix test test/bench/append_fanout.exs

  Runs inside the SQL sandbox, so it leaves nothing behind. Not part of the normal suite.
  """
  use Fyrlet.DataCase, async: false
  import Phoenix.ChannelTest, except: [join: 2]
  @endpoint FyrletWeb.Endpoint

  @tag timeout: 300_000
  test "fan-out" do
    Process.flag(:trap_exit, true)
    n = String.to_integer(System.get_env("FANOUT", "100"))
    posts = String.to_integer(System.get_env("POSTS", "20"))
    batch? = System.get_env("BATCH_SESSIONS", "true") == "true"
    Application.put_env(:fyrlet, :batch_session_checks, batch?)
    on_exit(fn -> Application.put_env(:fyrlet, :batch_session_checks, false) end)
    # Rely on notifications only; the periodic check would add reads of its own.
    Application.put_env(:fyrlet, :reconciliation_interval, 600_000)

    # The test process is every socket's transport, so lift the per-connection cap.
    previous = Application.get_env(:fyrlet, :max_subscriptions)
    Application.put_env(:fyrlet, :max_subscriptions, n + 10)
    on_exit(fn -> Application.put_env(:fyrlet, :max_subscriptions, previous) end)

    project = project()
    room = "bench"

    users = for i <- 1..n, do: user(project, "u#{i}")

    sockets =
      for u <- users do
        {:ok, snapshot, socket} =
          socket(FyrletWeb.UserSocket, "sessions:" <> u.actor.session_id, %{actor: u.actor})
          |> subscribe_and_join("append:" <> Ecto.UUID.generate(), %{
            "protocol_version" => 1,
            "capabilities" => %{"append" => 1},
            "name" => "feed.recent",
            "params" => %{"room" => room}
          })

        push(socket, "ack", %{"g" => snapshot["generation"], "s" => 1, "c" => snapshot["cursor"]})
        {socket.topic, socket, snapshot["generation"]}
      end

    poster = hd(users)
    counter = :counters.new(1, [])
    handler = {:queries, make_ref()}

    :telemetry.attach(
      handler,
      [:fyrlet, :repo, :query],
      fn _, _, _, _ ->
        :counters.add(counter, 1, 1)
      end,
      nil
    )

    results =
      for p <- 1..posts do
        :counters.put(counter, 1, 0)
        started = System.monotonic_time(:microsecond)

        {:ok, %{"cursor" => cursor}} =
          Fyrlet.Runtime.call(
            poster.actor,
            "feed.post",
            %{"room" => room, "texts" => ["m#{p}"]},
            Ecto.UUID.generate(),
            capabilities: %{"append" => 1}
          )

        Oban.drain_queue(queue: :fyrlet)
        received = collect(n, [])
        elapsed = System.monotonic_time(:microsecond) - started

        # Acknowledge so the next batch is not held back.
        for {topic, socket, generation} <- sockets do
          {s, c} = Map.fetch!(received, topic)
          push(socket, "ack", %{"g" => generation, "s" => s, "c" => c})
        end

        # Let the acks land before the next round, and count only this round's queries.
        queries = :counters.get(counter, 1)
        Process.sleep(20)
        {p, queries, elapsed, cursor}
      end

    :telemetry.detach(handler)
    measured = Enum.drop(results, 2)

    q =
      measured |> Enum.map(&elem(&1, 1)) |> Enum.sort() |> then(&Enum.at(&1, div(length(&1), 2)))

    t =
      measured |> Enum.map(&elem(&1, 2)) |> Enum.sort() |> then(&Enum.at(&1, div(length(&1), 2)))

    IO.puts(
      "\nFANOUT n=#{n} posts=#{posts} batch_sessions=#{batch?}: " <>
        "#{q} queries/post (#{Float.round(q / n, 2)} per subscriber), " <>
        "median time to reach all #{n}: #{Float.round(t / 1000, 1)} ms"
    )
  end

  # Waits for one `append` per subscriber; returns %{topic => {seq, cursor}}.
  defp collect(0, acc), do: Map.new(acc)

  defp collect(left, acc) do
    receive do
      %Phoenix.Socket.Message{event: "append", payload: %{"s" => s, "cursor" => c}, topic: topic} ->
        collect(left - 1, [{topic, {s, c}} | acc])
    after
      10_000 ->
        flunk("only #{length(acc)} of #{length(acc) + left} subscribers received the batch")
    end
  end
end
