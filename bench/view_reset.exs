# Micro-benchmark of View.reset for membership changes (add / remove inside a window).
# Pure function only: no database, network or JSON transport. Verifies equal output.
#   MIX_ENV=prod mix run --no-start bench/view_reset.exs
alias Fyrlet.Subscriptions.View

rows = String.to_integer(System.get_env("BENCH_ROWS", "50"))
bytes = String.to_integer(System.get_env("BENCH_PAYLOAD_BYTES", "128"))
iterations = String.to_integer(System.get_env("BENCH_ITERATIONS", "3000"))
rounds = 5

record = fn index, version ->
  %{
    "id" => "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(index), 12, "0"),
    "text" => String.duplicate("x", bytes),
    "content_type" => "text",
    "archived" => false,
    "version" => version,
    "inserted_at" => "2026-11-07T00:00:00.#{String.pad_leading(Integer.to_string(index), 6, "0")}Z",
    "updated_at" => "2026-11-07T00:00:00.000000Z"
  }
end

window = for index <- rows..1//-1, do: record.(index, 1)
previous = View.new(window, %{reserve: %{}, complete: true})
# Add one record at the head and drop the tail, as an inbox.add does.
added = [record.(rows + 1, 1) | Enum.take(window, rows - 1)]

run = fn ->
  {micros, _} = :timer.tc(fn -> for _ <- 1..iterations, do: View.reset(previous, added, previous.context) end)
  micros / iterations
end

reference = View.reset(previous, added, previous.context)
true = View.data(reference) == added
true = reference.bytes == 2 + (rows - 1) + Enum.sum(for r <- added, do: byte_size(Jason.encode!(r)))
true = reference.patch["a"] == [hd(added)] and length(reference.patch["r"]) == 1

run.()
samples = for _ <- 1..rounds, do: run.()
IO.puts("rows=#{rows} payload=#{bytes}B iterations=#{iterations}")
IO.puts("View.reset add-one (us/op): " <> Enum.map_join(samples, " / ", &Float.round(&1, 1) |> to_string()))
IO.puts("median: #{Float.round(Enum.sort(samples) |> Enum.at(2), 1)} us/op")
