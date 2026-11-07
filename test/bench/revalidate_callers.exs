defmodule Fyrlet.Bench.RevalidateCallers do
  @moduledoc "Who calls Auth.revalidate during one write and its delivery. Sandboxed; not in the normal suite."
  use Fyrlet.DataCase, async: false
  import Phoenix.ChannelTest, except: [join: 2]
  @endpoint FyrletWeb.Endpoint

  test "callers" do
    Process.flag(:trap_exit, true)
    Application.put_env(:fyrlet, :batch_session_checks, false)
    # The periodic reconcile is 100 ms in tests (30 s in production); keep it out of the count.
    reconcile = Application.fetch_env!(:fyrlet, :reconciliation_interval)
    Application.put_env(:fyrlet, :reconciliation_interval, 600_000)
    on_exit(fn -> Application.put_env(:fyrlet, :reconciliation_interval, reconcile) end)
    alice = user(project(), "alice")
    for i <- 1..3, do: add(alice.actor, "seed #{i}")
    # Fallback jobs of the seed writes would otherwise run (and notify) inside the measurement.
    Oban.drain_queue(queue: :fyrlet)

    {:ok, snapshot, socket} =
      socket(FyrletWeb.UserSocket, "sessions:" <> alice.actor.session_id, %{actor: alice.actor})
      |> subscribe_and_join("subscription:" <> Ecto.UUID.generate(), %{
        "protocol_version" => 1,
        "name" => "inbox.recent",
        "params" => %{"limit" => 50}
      })

    push(socket, "ack", %{"g" => snapshot["generation"], "s" => 1})
    Process.sleep(30)

    {:ok, tracer} = Agent.start_link(fn -> [] end)

    :erlang.trace_pattern({Fyrlet.Auth, :revalidate, 2}, [{:_, [], [{:message, {:caller}}]}], [
      :local
    ])

    handler = fn
      {:trace, pid, :call, {_, fun, args}, caller}, acc ->
        Agent.update(
          tracer,
          &[
            {pid,
             {fun,
              args
              |> Enum.take(1)
              |> inspect(limit: 3, printable_limit: 30)
              |> String.slice(0, 70)}}
            | &1
          ]
        )

        acc

      _other, acc ->
        acc
    end

    {:ok, _} = :dbg.tracer(:process, {handler, nil})
    :dbg.p(:all, [:call])
    :dbg.tpl(Fyrlet.Subscriptions.Observer, :schedule, 2, [{:_, [], [{:message, {:caller}}]}])
    :dbg.tp(Fyrlet.Subscriptions.Observer, :handle_cast, 2, [{:_, [], [{:message, {:caller}}]}])
    :dbg.tp(Fyrlet.Subscriptions.Observer, :handle_info, 2, [{:_, [], [{:message, {:caller}}]}])

    add(alice.actor, "new")
    Oban.drain_queue(queue: :fyrlet)
    assert_push "snapshot", _
    Process.sleep(80)
    :dbg.stop()

    calls = Agent.get(tracer, & &1) |> Enum.reverse()
    IO.puts("\nAuth.revalidate called #{length(calls)} times during one write + delivery:")
    for {pid, {f, a}} <- calls, do: IO.puts("  #{inspect(pid)}  #{f} #{a}")
  end
end
