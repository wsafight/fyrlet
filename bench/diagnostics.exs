directory = System.fetch_env!("BENCH_DIAGNOSTICS_DIR")
statistics = :ets.new(:bench_diagnostics, [:public, :set, write_concurrency: true])
counters = :ets.new(:bench_counters, [:public, :set, write_concurrency: true])

:ok =
  :telemetry.attach_many(
    "bench-runtime-counters",
    [[:fyrlet, :subscription, :query], [:fyrlet, :auth, :batch], [:fyrlet, :transport, :batch]],
    fn event, measurements, _metadata, table ->
      key = Enum.join(event, ".")

      :ets.update_counter(
        table,
        key,
        [
          {2, 1},
          {3, Map.get(measurements, :requests, 0)},
          {4, Map.get(measurements, :messages, 0)}
        ],
        {key, 0, 0, 0}
      )
    end,
    counters
  )

:ok =
  :telemetry.attach(
    "bench-query-diagnostics",
    [:fyrlet, :repo, :query],
    fn _event, measurements, metadata, table ->
      command = metadata.query |> String.split(" ", parts: 2) |> hd()
      key = {command, metadata[:source] || "transaction"}

      :ets.update_counter(
        table,
        key,
        [{2, 1}, {3, measurements.total_time}, {4, Map.get(measurements, :queue_time, 0)}],
        {key, 0, 0, 0}
      )
    end,
    statistics
  )

profile = System.get_env("BENCH_EPROF") == "1"

if profile do
  :code.root_dir()
  |> List.to_string()
  |> Path.join("lib/tools-*/ebin")
  |> Path.wildcard()
  |> Code.prepend_paths()

  {:ok, _applications} = Application.ensure_all_started(:tools)
  {:ok, _pid} = :eprof.start()
  :profiling = :eprof.start_profiling(Process.list())
end

File.write!(Path.join(directory, "diagnostics.ready"), "")

memory_interval = String.to_integer(System.get_env("BENCH_MEMORY_INTERVAL_MS", "0"))

memory_snapshot = fn ->
  groups =
    Enum.reduce(Process.list(), %{}, fn process, groups ->
      case Process.info(process, [:memory, :message_queue_len, :dictionary, :binary]) do
        nil ->
          groups

        information ->
          {module, _function, _arity} =
            Keyword.get(information[:dictionary], :"$initial_call", {:unknown, :unknown, 0})

          {binary_bytes, largest_binary} =
            Enum.reduce(information[:binary], {0, 0}, fn {_reference, size, _references},
                                                         {total, largest} ->
              {total + size, max(largest, size)}
            end)

          previous =
            Map.get(groups, module, %{
              count: 0,
              bytes: 0,
              max_bytes: 0,
              queued: 0,
              binary_bytes: 0,
              largest_binary: 0
            })

          Map.put(groups, module, %{
            count: previous.count + 1,
            bytes: previous.bytes + information[:memory],
            max_bytes: max(previous.max_bytes, information[:memory]),
            queued: previous.queued + information[:message_queue_len],
            binary_bytes: previous.binary_bytes + binary_bytes,
            largest_binary: max(previous.largest_binary, largest_binary)
          })
      end
    end)

  buffers =
    Port.list()
    |> Enum.flat_map(fn port ->
      case Port.info(port, :name) do
        {:name, ~c"tcp_inet"} ->
          case :inet.getopts(port, [:buffer, :recbuf, :sndbuf]) do
            {:ok, options} -> [options]
            _closed -> []
          end

        _other ->
          []
      end
    end)
    |> Enum.frequencies()
    |> Enum.map(fn {options, count} -> Map.put(Map.new(options), :count, count) end)

  sample = %{
    at: DateTime.utc_now(),
    observers: Registry.count(Fyrlet.ObserverRegistry),
    memory: Map.new(:erlang.memory()),
    groups: groups,
    tcp_buffers: buffers
  }

  File.write!(Path.join(directory, "memory.ndjson"), Jason.encode!(sample) <> "\n", [:append])
end

wait = fn wait ->
  unless File.exists?(Path.join(directory, "diagnostics.stop")) do
    if memory_interval > 0, do: memory_snapshot.()
    Process.sleep(if(memory_interval > 0, do: memory_interval, else: 100))
    wait.(wait)
  end
end

wait.(wait)
:telemetry.detach("bench-query-diagnostics")
:telemetry.detach("bench-runtime-counters")

if profile do
  :profiling_stopped = :eprof.stop_profiling()
  :ok = :eprof.log(String.to_charlist(Path.join(directory, "eprof.txt")))
  :ok = :eprof.analyze(:total, sort: :time)
  :eprof.stop()
end

queries =
  statistics
  |> :ets.tab2list()
  |> Enum.map(fn {{command, source}, count, duration, queue} ->
    %{
      command: command,
      source: source,
      count: count,
      total_ms: System.convert_time_unit(duration, :native, :microsecond) / 1000,
      queue_ms: System.convert_time_unit(queue, :native, :microsecond) / 1000
    }
  end)
  |> Enum.sort_by(& &1.count, :desc)

File.write!(Path.join(directory, "queries.json"), Jason.encode!(queries, pretty: true))

counts =
  counters
  |> :ets.tab2list()
  |> Enum.map(fn {event, count, requests, messages} ->
    %{event: event, count: count, requests: requests, messages: messages}
  end)

File.write!(Path.join(directory, "counters.json"), Jason.encode!(counts, pretty: true))

runtime = %{
  observer_registry: Registry.count(Fyrlet.ObserverRegistry),
  observer_supervisor: DynamicSupervisor.count_children(Fyrlet.ObserverSupervisor),
  process_count: :erlang.system_info(:process_count),
  memory: Map.new(:erlang.memory())
}

File.write!(Path.join(directory, "runtime.json"), Jason.encode!(runtime, pretty: true))
File.write!(Path.join(directory, "diagnostics.done"), "")
