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

IO.puts("LOAD DETECTED")
pids =
  for pid <- Process.list(),
      {:dictionary, d} <- [Process.info(pid, :dictionary) || {:dictionary, []}],
      match?({FyrletWeb.OperationChannel, _, _}, d[:"$initial_call"]) or
        inspect(d[:"$initial_call"]) =~ "OperationChannel",
      do: pid
pids = Enum.take(pids, 100)
IO.puts("PROFILING #{length(pids)} OperationChannel processes")

# Poor-man's sampling profiler: no :tools needed. Only processes that are running or runnable (CPU demand)
# are counted; waiting in receive is ignored.
deadline = System.monotonic_time(:millisecond) + 8_000
loop = fn loop, top, owner, n ->
  if System.monotonic_time(:millisecond) >= deadline do
    {top, owner, n}
  else
    {top, owner, n} =
      Enum.reduce(pids, {top, owner, n}, fn pid, {top, owner, n} ->
        case Process.info(pid, [:status, :current_stacktrace]) do
          [status: st, current_stacktrace: [{m, f, a, _} = _head | _] = stack] when st in [:running, :runnable] ->
            key = {m, f, a}
            frame = Enum.find(stack, fn {mod, _, _, _} -> String.starts_with?(Atom.to_string(mod), "Elixir.Fyrlet") end)
            own = if frame, do: elem(frame, 0) |> inspect() |> Kernel.<>("." <> Atom.to_string(elem(frame, 1)) <> "/" <> Integer.to_string(elem(frame, 2))), else: "(none)"
            {Map.update(top, key, 1, &(&1 + 1)), Map.update(owner, own, 1, &(&1 + 1)), n + 1}
          _ -> {top, owner, n}
        end
      end)
    :timer.sleep(2)
    loop.(loop, top, owner, n)
  end
end
{top, owner, n} = loop.(loop, %{}, %{}, 0)
IO.puts("SAMPLES #{n}")
show = fn title, map ->
  IO.puts("--- #{title}")
  map |> Enum.sort_by(&-elem(&1, 1)) |> Enum.take(30)
  |> Enum.each(fn {k, v} -> IO.puts("#{Float.round(v * 100 / max(n, 1), 1)}%\t#{if is_tuple(k), do: inspect(k), else: k}") end)
end
show.("top frame (running/runnable)", top)
show.("first Fyrlet frame on the stack", owner)
