defmodule Fyrlet.Features.Stream.Reader do
  @moduledoc false
  # Shared reads of stream batches (see `Fyrlet.Features.Stream.after_cursor_shared/4`).
  #
  # A hit is an ETS lookup in the caller's own process. A miss goes to one of a few reader
  # processes chosen by stream, which re-checks the table and, if still missing, reads the
  # database once while everyone else asking for the same batch queues behind it: 1000
  # subscribers of a room that all wake up at the same moment cost one read, not 1000.
  # If anything about the shared path is unavailable, the caller just reads for itself.
  use GenServer

  @table __MODULE__
  @partitions __MODULE__.Partitions
  @max_entries 10_000
  @max_reads_per_partition 4

  # ---- supervision ----------------------------------------------------------------------

  defmodule Supervisor do
    @moduledoc false
    use Elixir.Supervisor

    def start_link(options), do: Elixir.Supervisor.start_link(__MODULE__, options)

    @impl true
    def init(_options) do
      Elixir.Supervisor.init(
        [
          Fyrlet.Features.Stream.Reader.Table,
          {PartitionSupervisor,
           child_spec: Fyrlet.Features.Stream.Reader,
           name: Fyrlet.Features.Stream.Reader.Partitions}
        ],
        strategy: :one_for_one
      )
    end
  end

  # Owns the ETS table and sweeps expired batches.
  defmodule Table do
    @moduledoc false
    use GenServer

    def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

    @impl true
    def init(_options) do
      :ets.new(Fyrlet.Features.Stream.Reader, [
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

      Process.send_after(self(), :sweep, 1_000)
      {:ok, %{}}
    end

    @impl true
    def handle_info(:sweep, state) do
      now = System.monotonic_time(:millisecond)

      :ets.select_delete(Fyrlet.Features.Stream.Reader, [
        {{:_, :"$1", :_}, [{:<, :"$1", now}], [true]}
      ])

      Process.send_after(self(), :sweep, 1_000)
      {:noreply, state}
    end

    def handle_info(_message, state), do: {:noreply, state}
  end

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(_options), do: {:ok, %{pending: %{}, queue: :queue.new(), active: %{}}}

  # ---- reading --------------------------------------------------------------------------

  @doc false
  def batch(project_id, name, cursor, options, read) do
    if available?() do
      key = {project_id, name, cursor, options}

      case lookup(key) do
        {:ok, value} -> value
        :miss -> fill(key, project_id, name, read)
      end
    else
      read.()
    end
  end

  # Batches are dropped when a stream is rewritten or trimmed, so a reader never continues a
  # chain the stream no longer has. The TTL is the backstop for other nodes.
  @doc false
  def drop(project_id, name) do
    if available?(),
      do: :ets.select_delete(@table, [{{{project_id, name, :_, :_}, :_, :_}, [], [true]}])

    :ok
  end

  defp fill(key, project_id, name, read) do
    case GenServer.call(
           {:via, PartitionSupervisor, {@partitions, {project_id, name}}},
           {:fill, key, read},
           5_000
         ) do
      :unavailable -> read.()
      result -> result
    end
  catch
    :exit, _reason -> read.()
  end

  @impl true
  def handle_call({:fill, key, read}, from, state) do
    case lookup(key) do
      {:ok, value} ->
        {:reply, value, state}

      :miss ->
        case Map.get(state.pending, key) do
          nil ->
            pending = %{leader: {from, read}, waiters: :queue.new()}

            state = %{
              state
              | pending: Map.put(state.pending, key, pending),
                queue: :queue.in(key, state.queue)
            }

            {:noreply, start_next(state)}

          pending ->
            waiters = :queue.in({from, read}, pending.waiters)
            pending = Map.put(state.pending, key, %{pending | waiters: waiters})
            {:noreply, %{state | pending: pending}}
        end
    end
  end

  @impl true
  def handle_info({:read_result, reader, result}, state) do
    case Map.get(state.active, reader) do
      nil -> {:noreply, state}
      {_monitor, _key} -> {:noreply, complete(state, reader, result)}
    end
  end

  def handle_info({:DOWN, monitor, :process, reader, _reason}, state) do
    case Map.get(state.active, reader) do
      {^monitor, _key} -> {:noreply, complete(state, reader, :unavailable)}
      _missing -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Distinct batch keys run in parallel, with a fixed bound per stream partition. Callers of
  # one key share its in-flight read instead of queueing a database query behind the GenServer.
  defp start_next(%{active: active} = state) when map_size(active) >= @max_reads_per_partition,
    do: state

  defp start_next(state) do
    case :queue.out(state.queue) do
      {{:value, key}, queue} ->
        %{leader: {_from, read}} = Map.fetch!(state.pending, key)
        server = self()

        {reader, monitor} =
          spawn_monitor(fn ->
            result =
              try do
                read.()
              rescue
                _exception -> :unavailable
              catch
                _kind, _reason -> :unavailable
              end

            send(server, {:read_result, self(), result})
          end)

        state = %{
          state
          | queue: queue,
            active: Map.put(state.active, reader, {monitor, key})
        }

        start_next(state)

      {:empty, _queue} ->
        state
    end
  end

  defp complete(state, reader, result) do
    {{monitor, key}, active} = Map.pop(state.active, reader)
    Process.demonitor(monitor, [:flush])
    pending = Map.fetch!(state.pending, key)

    state =
      if shareable?(result) do
        store(key, result)
        GenServer.reply(elem(pending.leader, 0), result)

        Enum.each(:queue.to_list(pending.waiters), fn {from, _read} ->
          GenServer.reply(from, result)
        end)

        %{state | pending: Map.delete(state.pending, key)}
      else
        # Empty, reset and failed reads are not shared: a later caller must get a fresh head,
        # or its own fallback read, just as it did when reads ran serially in this process.
        GenServer.reply(elem(pending.leader, 0), result)

        case :queue.out(pending.waiters) do
          {{:value, leader}, waiters} ->
            state = %{
              state
              | pending: Map.put(state.pending, key, %{leader: leader, waiters: waiters}),
                queue: :queue.in(key, state.queue)
            }

            state

          {:empty, _waiters} ->
            %{state | pending: Map.delete(state.pending, key)}
        end
      end

    start_next(%{state | active: active})
  end

  defp shareable?({:ok, _from, _to, _items, _more}), do: true

  defp shareable?({:ok, %{encoded: encoded, bytes: bytes}}) when is_binary(encoded),
    do: is_integer(bytes)

  defp shareable?(_other), do: false

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, expires, value}] ->
        if expires > System.monotonic_time(:millisecond), do: {:ok, value}, else: :miss

      [] ->
        :miss
    end
  end

  defp store(key, {:ok, _from, _to, _items, _more} = batch) do
    if :ets.info(@table, :size) < @max_entries do
      ttl = Fyrlet.Features.Stream.limit(:shared_read_ttl_ms)
      :ets.insert(@table, {key, System.monotonic_time(:millisecond) + ttl, batch})
    end

    :ok
  end

  # Never share "nothing new" or "cannot continue": both can be outdated a moment later.
  defp store(_key, _other), do: :ok

  defp available?, do: :ets.whereis(@table) != :undefined
end
