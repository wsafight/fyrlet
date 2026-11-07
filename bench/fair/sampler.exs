snap = fn ->
  for pid <- Process.list(), pid != self(), info = Process.info(pid, [:reductions, :initial_call, :dictionary, :registered_name]), info != nil, into: %{} do
    label =
      case info[:registered_name] do
        n when is_atom(n) and n != [] -> inspect(n)
        _ ->
          case Keyword.get(info[:dictionary], :"$initial_call") || info[:initial_call] do
            {m, f, a} -> "#{inspect(m)}.#{f}/#{a}"
            other -> inspect(other)
          end
      end
    {pid, {label, info[:reductions]}}
  end
end
c = :counters.new(1, [])
:telemetry.attach("fair-count", [:fyrlet, :operation, :stop], fn _, _, _, _ -> :counters.add(c, 1, 1) end, nil)
# Sharded runs warm up, idle until the common start time, then load. Wait for: activity, then a quiet period
# (2 s), then 3 consecutive seconds above the threshold; settle 2 more seconds before sampling.
wait = fn wait, last, phase, streak ->
  :timer.sleep(1000)
  now = :counters.get(c, 1)
  rate = now - last
  case phase do
    :activity -> wait.(wait, now, if(rate > 300, do: :quiet, else: :activity), 0)
    :quiet ->
      streak = if rate < 20, do: streak + 1, else: 0
      wait.(wait, now, if(streak >= 2, do: :load, else: :quiet), streak)
    :load ->
      streak = if rate > 300, do: streak + 1, else: 0
      if streak >= 3, do: :ok, else: wait.(wait, now, :load, streak)
  end
end
wait.(wait, 0, :activity, 0)
:timer.sleep(2000)
me = self()
IO.puts("LOAD DETECTED")
:msacc.start(10_000)
a = snap.()
:timer.sleep(10_000)
b = snap.()
stats = :msacc.stats()
:msacc.stop()
delta = for {pid, {label, r2}} <- b, {_, r1} <- [Map.get(a, pid, {nil, 0})], do: {label, max(r2 - r1, 0)}
total = Enum.sum(Enum.map(delta, &elem(&1, 1)))
IO.puts("TOTAL_REDUCTIONS #{total}")
IO.puts("--- reductions by process type (% of total)")
delta |> Enum.group_by(&elem(&1, 0), &elem(&1, 1)) |> Enum.map(fn {k, v} -> {k, Enum.sum(v), length(v)} end)
|> Enum.sort_by(&-elem(&1, 1)) |> Enum.take(25)
|> Enum.each(fn {k, v, n} -> IO.puts("#{Float.round(v * 100 / max(total, 1), 1)}%\t#{n}\t#{k}") end)
IO.puts("--- msacc (scheduler thread time by state, %)")
for s <- stats, s.type == :scheduler do
  t = Enum.sum(Map.values(s.counters))
  s.counters |> Enum.sort_by(&-elem(&1, 1)) |> Enum.take(8)
  |> Enum.each(fn {k, v} -> IO.puts("sched#{s.id}\t#{Float.round(v * 100 / max(t, 1), 1)}%\t#{k}") end)
end
