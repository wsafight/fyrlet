defmodule Fyrlet.Bench.QueryCounts do
  @moduledoc """
  How many database statements each user-visible operation issues, by kind.

      mix test test/bench/query_counts.exs

  Runs in the SQL sandbox; leaves nothing behind. Not part of the normal suite.
  """
  use Fyrlet.RunsCase
  import Phoenix.ChannelTest, except: [join: 2]
  @endpoint FyrletWeb.Endpoint

  defp measure(label, fun) do
    me = self()
    id = {:q, make_ref()}

    :telemetry.attach(
      id,
      [:fyrlet, :repo, :query],
      fn _, _, meta, _ -> send(me, {:q, meta.query}) end,
      nil
    )

    result = fun.()
    Process.sleep(60)
    :telemetry.detach(id)
    queries = drain([])
    kinds = Enum.frequencies_by(queries, &kind/1) |> Enum.sort_by(fn {_, n} -> -n end)

    IO.puts(
      "#{String.pad_trailing(label, 44)} #{String.pad_leading(Integer.to_string(length(queries)), 3)} statements   #{inspect(kinds)}"
    )

    result
  end

  defp drain(acc), do: receive(do: ({:q, q} -> drain([q | acc])), after: (0 -> Enum.reverse(acc)))

  defp kind(q) do
    cond do
      q =~ ~s(FROM "sessions") -> :session
      q =~ "oban_jobs" -> :oban
      q =~ "pg_notify" -> :notify
      q =~ "advisory" -> :lock
      q in ["begin", "commit"] -> :tx
      q =~ "fyrlet_stream" -> :stream
      q =~ "idempotency" -> :idempotency
      q =~ "fyrlet_run" -> :runs
      q =~ "fyrlet_effects" -> :effects
      true -> :data
    end
  end

  @tag timeout: 120_000
  test "counts" do
    Process.flag(:trap_exit, true)
    Application.put_env(:fyrlet, :batch_session_checks, false)
    # The periodic reconcile is 100 ms in tests (30 s in production); keep it out of the count.
    reconcile = Application.fetch_env!(:fyrlet, :reconciliation_interval)
    Application.put_env(:fyrlet, :reconciliation_interval, 600_000)
    on_exit(fn -> Application.put_env(:fyrlet, :reconciliation_interval, reconcile) end)
    project = project()
    alice = user(project, "alice")
    for i <- 1..5, do: add(alice.actor, "seed #{i}")
    # Fallback jobs of the seed writes would otherwise run (and notify) inside the measurement.
    Oban.drain_queue(queue: :fyrlet)

    IO.puts("")

    join_params = %{
      "protocol_version" => 1,
      "name" => "records.recent",
      "params" => %{"limit" => 50}
    }

    {:ok, snapshot, socket} =
      measure("subscription join (private snapshot)", fn ->
        socket(FyrletWeb.UserSocket, "sessions:" <> alice.actor.session_id, %{actor: alice.actor})
        |> subscribe_and_join("subscription:" <> Ecto.UUID.generate(), join_params)
      end)

    push(socket, "ack", %{"g" => snapshot["generation"], "s" => 1})

    measure("write + delivery to that subscriber", fn ->
      add(alice.actor, "new")
      Oban.drain_queue(queue: :fyrlet)
      assert_push "snapshot", _
    end)

    append_params = %{
      "protocol_version" => 1,
      "capabilities" => %{"append" => 1},
      "name" => "feed.recent",
      "params" => %{"room" => "r"}
    }

    {:ok, a, aso} =
      measure("append join", fn ->
        socket(FyrletWeb.UserSocket, "sessions:" <> alice.actor.session_id, %{actor: alice.actor})
        |> subscribe_and_join("append:" <> Ecto.UUID.generate(), append_params)
      end)

    push(aso, "ack", %{"g" => a["generation"], "s" => 1, "c" => a["cursor"]})

    Application.put_env(:fyrlet, :run_plans, %{
      "runs.demo" => fn _, _ ->
        {:ok,
         steps: [%{type: :step, name: "a", input: %{}}, %{type: :step, name: "b", input: %{}}]}
      end
    })

    Application.put_env(:fyrlet, :run_steps, %{
      "a" => fn _, _ -> {:ok, %{}} end,
      "b" => fn _, _ -> {:ok, %{}} end
    })

    id = measure("start run", fn -> start_run!(alice) end)
    Oban.drain_queue(queue: :fyrlet)
    measure("advance one step", fn -> Fyrlet.Runs.Engine.run_once(id) end)
    Oban.drain_queue(queue: :fyrlet)
    measure("Runs.get (run view)", fn -> Fyrlet.Runs.get(alice.actor, id) end)

    {:ok, rs} = Fyrlet.Runtime.prepare_subscription(alice.actor, "fyrlet.run", %{"run_id" => id})

    measure("fyrlet.run: build the view (one refresh)", fn ->
      Fyrlet.Runtime.view(alice.actor, rs)
    end)

    measure("fyrlet.runs.recent (list)", fn ->
      {:ok, rec} =
        Fyrlet.Runtime.prepare_subscription(alice.actor, "fyrlet.runs.recent", %{"limit" => 20})

      Fyrlet.Runtime.view(alice.actor, rec)
    end)
  end
end
