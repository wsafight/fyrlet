defmodule Fyrlet.Bench.AdvanceStatements do
  @moduledoc "Every statement issued to advance one run step, in order. Sandboxed; not in the normal suite."
  use Fyrlet.RunsCase

  test "statements" do
    alice = user(project(), "alice")

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

    id = start_run!(alice)
    Oban.drain_queue(queue: :fyrlet)

    me = self()
    handler = {:adv, make_ref()}

    :telemetry.attach(
      handler,
      [:fyrlet, :repo, :query],
      fn _, m, meta, _ ->
        send(me, {:q, meta.query, System.convert_time_unit(m.total_time, :native, :microsecond)})
      end,
      nil
    )

    Fyrlet.Runs.Engine.run_once(id)
    :telemetry.detach(handler)

    queries = drain([])
    IO.puts("\n#{length(queries)} statements to advance one step:")

    for {{q, t}, i} <- Enum.with_index(queries, 1) do
      short =
        q
        |> String.replace(~r/\s+/, " ")
        |> String.replace(~r/SELECT .*? FROM/, "SELECT… FROM")
        |> String.slice(0, 96)

      IO.puts(
        "  #{String.pad_leading(Integer.to_string(i), 2)}  #{String.pad_leading(Integer.to_string(t), 4)}µs  #{short}"
      )
    end

    dup =
      queries |> Enum.frequencies_by(fn {q, _} -> q end) |> Enum.filter(fn {_, n} -> n > 1 end)

    IO.puts("\nidentical statement text issued more than once:")

    for {q, n} <- dup,
        do: IO.puts("  #{n}x  #{q |> String.replace(~r/\s+/, " ") |> String.slice(0, 100)}")
  end

  defp drain(acc),
    do: receive(do: ({:q, q, t} -> drain([{q, t} | acc])), after: (50 -> Enum.reverse(acc)))
end
