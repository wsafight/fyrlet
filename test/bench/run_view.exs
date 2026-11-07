defmodule Fyrlet.Bench.RunView do
  @moduledoc """
  Cost of reading a run's view when its steps carry large outputs.

      mix test test/bench/run_view.exs

  Runs in the SQL sandbox. Not part of the normal suite.
  """
  use Fyrlet.RunsCase
  alias Fyrlet.Runs.View

  @tag timeout: 300_000
  test "view cost" do
    alice = user(project(), "alice")
    kb = String.to_integer(System.get_env("OUTPUT_KB", "30"))
    steps = String.to_integer(System.get_env("STEPS", "10"))
    big = String.duplicate("x", kb * 1024)

    Application.put_env(:fyrlet, :run_plans, %{
      "runs.demo" => fn _, _ ->
        {:ok,
         steps: for(n <- 1..steps, do: %{type: :step, name: "s#{n}", input: %{"blob" => big}})}
      end
    })

    Application.put_env(
      :fyrlet,
      :run_steps,
      %{}
      |> then(fn m ->
        Enum.reduce(1..steps, m, fn n, acc ->
          Map.put(acc, "s#{n}", fn _, _ -> {:ok, %{"blob" => big}} end)
        end)
      end)
    )

    id = start_run!(alice)
    assert drive(id) == "completed"
    run = run(id)

    for _ <- 1..30, do: View.build(run)

    samples =
      for _ <- 1..5 do
        {t, _} = :timer.tc(fn -> for _ <- 1..60, do: View.build(run) end)
        t / 60
      end

    median = samples |> Enum.sort() |> Enum.at(2)

    IO.puts(
      "\\nRUN VIEW #{steps} steps x #{kb} KB output: #{Float.round(median / 1000, 2)} ms per View.build (5 samples: #{Enum.map_join(samples, ", ", &Float.round(&1 / 1000, 2))})"
    )
  end
end
