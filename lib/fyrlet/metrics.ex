defmodule Fyrlet.Metrics do
  @moduledoc """
  Prometheus metrics from Fyrlet's telemetry events, served at `GET /metrics`.

  **Off unless a token is configured**, because the endpoint reveals traffic shape:

      config :fyrlet, metrics: [token: "a long random string"]
      # or FYRLET_METRICS_TOKEN=...

  Scrape with `Authorization: Bearer <token>`. Without a configured token the route answers
  404 and nothing is recorded.

  Recording is one atomic ETS update per event in the process that emitted it (no message,
  no lock). Counters are per node; Prometheus sums them across nodes.

  Label values are bounded: operation names are only used if they are in the contract
  (anything else is `_unknown`), and there is no per-project or per-user label.
  """
  use GenServer

  @table __MODULE__
  # Upper bounds in microseconds; the last bucket is +Inf (the row's total count).
  @buckets_us [
    1_000,
    2_500,
    5_000,
    10_000,
    25_000,
    50_000,
    100_000,
    250_000,
    500_000,
    1_000_000,
    2_500_000,
    5_000_000
  ]
  @size_buckets [1, 2, 4, 8, 16, 32, 64, 128]

  @events [
    [:fyrlet, :operation, :stop],
    [:fyrlet, :subscription, :query],
    [:fyrlet, :subscription, :snapshot],
    [:fyrlet, :subscription, :delta],
    [:fyrlet, :subscription, :append],
    [:fyrlet, :subscription, :serialize],
    [:fyrlet, :subscription, :count],
    [:fyrlet, :delta, :snapshot_fallback],
    [:fyrlet, :auth, :batch],
    [:fyrlet, :transport, :batch],
    [:fyrlet, :quota, :rejected],
    [:fyrlet, :prune],
    [:fyrlet, :repo, :query]
  ]

  @help %{
    "fyrlet_operations_total" => {"counter", "Operation calls by contract name and result."},
    "fyrlet_operation_duration_seconds" => {"histogram", "Operation call duration."},
    "fyrlet_subscription_queries_total" =>
      {"counter", "Subscription data loads by name and result."},
    "fyrlet_subscription_query_duration_seconds" =>
      {"histogram", "Subscription data load duration."},
    "fyrlet_snapshots_total" => {"counter", "Snapshots sent to clients."},
    "fyrlet_snapshot_bytes_total" => {"counter", "Snapshot data bytes sent to clients."},
    "fyrlet_deltas_total" => {"counter", "Field-level deltas sent to clients."},
    "fyrlet_delta_bytes_total" => {"counter", "Delta patch bytes sent to clients."},
    "fyrlet_append_batches_total" => {"counter", "Append batches sent to clients."},
    "fyrlet_append_items_total" => {"counter", "Items in append batches sent to clients."},
    "fyrlet_snapshot_serializations_total" =>
      {"counter", "Times an observer encoded a full snapshot."},
    "fyrlet_snapshot_fallbacks_total" =>
      {"counter", "Deliveries that fell back to a full snapshot."},
    "fyrlet_subscriptions_active" => {"gauge", "Subscriptions open on this node."},
    "fyrlet_session_check_batch_size" => {"histogram", "Session checks answered by one query."},
    "fyrlet_session_check_duration_seconds" =>
      {"histogram", "Duration of a batched session query."},
    "fyrlet_transport_batches_total" => {"counter", "Multi-frame socket batches sent."},
    "fyrlet_transport_batched_messages_total" =>
      {"counter", "Frames sent inside socket batches."},
    "fyrlet_quota_rejected_total" => {"counter", "Calls refused by a project quota."},
    "fyrlet_db_queue_seconds" =>
      {"histogram", "Time a query waited for a pooled database connection."},
    "fyrlet_db_query_seconds" => {"histogram", "Time the database took to run a query."},
    "fyrlet_prune_deleted_total" =>
      {"counter", "Records deleted by retention jobs, excluding cascades."},
    "fyrlet_prune_limited_total" =>
      {"counter", "Retention jobs that exhausted their work budget."},
    "fyrlet_prune_duration_seconds" => {"histogram", "Retention job duration."},
    "fyrlet_observers" => {"gauge", "Running observers on this node."},
    "fyrlet_vm_processes" => {"gauge", "Erlang processes."},
    "fyrlet_vm_memory_bytes" => {"gauge", "Erlang VM memory in use."},
    "fyrlet_vm_run_queue" => {"gauge", "Runnable processes waiting for a scheduler."}
  }

  def enabled?, do: not is_nil(token())

  @doc "The configured scrape token, or nil when metrics are off."
  def token do
    case :fyrlet |> Application.get_env(:metrics, []) |> Keyword.get(:token) do
      value when is_binary(value) and byte_size(value) > 0 -> value
      _off -> nil
    end
  end

  @doc "Raises if a token is set but too short to be a secret; called when the application starts."
  def validate! do
    case token() do
      nil -> :ok
      value when byte_size(value) >= 16 -> :ok
      _short -> raise ArgumentError, "The metrics token must be at least 16 bytes"
    end
  end

  def child_specs, do: if(enabled?(), do: [__MODULE__], else: [])

  def start_link(_options), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    # So that `terminate/2` runs on shutdown and the telemetry handlers do not outlive the table.
    Process.flag(:trap_exit, true)

    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      write_concurrency: true,
      read_concurrency: true
    ])

    :telemetry.attach_many({__MODULE__, :all}, @events, &__MODULE__.handle_event/4, nil)
    {:ok, nil}
  end

  @impl true
  def terminate(_reason, _state), do: :telemetry.detach({__MODULE__, :all})

  # ---- recording ------------------------------------------------------------------------

  @doc false
  def handle_event([:fyrlet, :operation, :stop], %{duration: duration}, meta, _config) do
    labels = [name: operation(meta.name), result: meta.result]
    count("fyrlet_operations_total", labels)

    observe(
      "fyrlet_operation_duration_seconds",
      [name: labels[:name]],
      micros(duration),
      @buckets_us
    )
  end

  def handle_event([:fyrlet, :subscription, :query], %{duration: duration}, meta, _config) do
    count("fyrlet_subscription_queries_total", name: meta.name, result: meta.result)

    observe(
      "fyrlet_subscription_query_duration_seconds",
      [name: meta.name],
      micros(duration),
      @buckets_us
    )
  end

  def handle_event([:fyrlet, :subscription, :snapshot], %{bytes: bytes}, meta, _config) do
    count("fyrlet_snapshots_total", name: meta.name)
    count("fyrlet_snapshot_bytes_total", [name: meta.name], bytes)
  end

  def handle_event([:fyrlet, :subscription, :delta], %{bytes: bytes}, meta, _config) do
    count("fyrlet_deltas_total", name: meta.name)
    count("fyrlet_delta_bytes_total", [name: meta.name], bytes)
  end

  def handle_event([:fyrlet, :subscription, :append], %{items: items}, meta, _config) do
    count("fyrlet_append_batches_total", name: meta.name)
    count("fyrlet_append_items_total", [name: meta.name], items)
  end

  def handle_event([:fyrlet, :subscription, :serialize], _measurements, meta, _config),
    do: count("fyrlet_snapshot_serializations_total", name: meta.name, mode: meta.mode)

  def handle_event([:fyrlet, :subscription, :count], %{active: active}, _meta, _config),
    do: :ets.insert(@table, {{:gauge, "fyrlet_subscriptions_active", []}, active})

  def handle_event([:fyrlet, :delta, :snapshot_fallback], _measurements, meta, _config),
    do: count("fyrlet_snapshot_fallbacks_total", name: meta.name)

  def handle_event([:fyrlet, :auth, :batch], measurements, _meta, _config) do
    observe("fyrlet_session_check_batch_size", [], measurements.requests, @size_buckets)

    observe(
      "fyrlet_session_check_duration_seconds",
      [],
      micros(measurements.duration),
      @buckets_us
    )
  end

  def handle_event([:fyrlet, :transport, :batch], %{messages: messages}, _meta, _config) do
    count("fyrlet_transport_batches_total", [])
    count("fyrlet_transport_batched_messages_total", [], messages)
  end

  def handle_event([:fyrlet, :quota, :rejected], _measurements, meta, _config),
    do: count("fyrlet_quota_rejected_total", class: meta.class)

  def handle_event([:fyrlet, :prune], measurements, meta, _config) do
    count("fyrlet_prune_deleted_total", [], measurements.deleted)
    if meta.limited, do: count("fyrlet_prune_limited_total", [])
    observe("fyrlet_prune_duration_seconds", [], measurements.duration_ms * 1_000, @buckets_us)
  end

  def handle_event([:fyrlet, :repo, :query], measurements, _meta, _config) do
    if is_integer(measurements[:queue_time]),
      do: observe("fyrlet_db_queue_seconds", [], micros(measurements.queue_time), @buckets_us)

    if is_integer(measurements[:query_time]),
      do: observe("fyrlet_db_query_seconds", [], micros(measurements.query_time), @buckets_us)
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  # A requested name that is not in the contract must not become a label value.
  defp operation(name) do
    case Fyrlet.Registry.fetch("operations", name) do
      {:ok, _module, _specification} -> name
      _unknown -> "_unknown"
    end
  rescue
    _error -> "_unknown"
  end

  defp micros(native), do: System.convert_time_unit(native, :native, :microsecond)

  defp count(name, labels, amount \\ 1) do
    key = {:counter, name, labels}
    :ets.update_counter(@table, key, amount, {key, 0})
  end

  defp observe(name, labels, value, bounds) do
    key = {:histogram, name, labels}
    slots = length(bounds)

    index =
      Enum.find_index(bounds, &(value <= &1)) || slots

    # Row: {key, count, sum, bucket_0 .. bucket_n-1}; a value above every bound is only in count.
    default = List.to_tuple([key, 0, 0 | List.duplicate(0, slots)])
    ops = [{2, 1}, {3, value}] ++ if(index < slots, do: [{4 + index, 1}], else: [])
    :ets.update_counter(@table, key, ops, default)
  end

  # ---- rendering ------------------------------------------------------------------------

  @doc "The metrics in Prometheus text exposition format."
  def render do
    rows = if :ets.whereis(@table) == :undefined, do: [], else: :ets.tab2list(@table)

    recorded =
      rows
      |> Enum.group_by(&metric_name/1)
      |> Map.new()

    live = live_gauges()

    @help
    |> Enum.sort()
    |> Enum.flat_map(fn {name, {type, help}} ->
      entries = Map.get(recorded, name, []) ++ Map.get(live, name, [])

      if entries == [],
        do: [],
        else: [
          "# HELP ",
          name,
          " ",
          help,
          "\n# TYPE ",
          name,
          " ",
          type,
          "\n" | lines(name, type, entries)
        ]
    end)
    |> IO.iodata_to_binary()
  end

  # Every row is a tuple whose first element is `{kind, name, labels}`.
  defp metric_name(row), do: elem(elem(row, 0), 1)

  defp live_gauges do
    %{
      "fyrlet_observers" => [{{:gauge, "fyrlet_observers", []}, observers()}],
      "fyrlet_vm_processes" => [
        {{:gauge, "fyrlet_vm_processes", []}, :erlang.system_info(:process_count)}
      ],
      "fyrlet_vm_memory_bytes" => [
        {{:gauge, "fyrlet_vm_memory_bytes", []}, :erlang.memory(:total)}
      ],
      "fyrlet_vm_run_queue" => [
        {{:gauge, "fyrlet_vm_run_queue", []}, :erlang.statistics(:run_queue)}
      ]
    }
  end

  defp observers do
    Registry.count(Fyrlet.ObserverRegistry)
  rescue
    _error -> 0
  end

  defp lines(name, "histogram", entries) do
    bounds = if String.contains?(name, "batch_size"), do: @size_buckets, else: @buckets_us
    scale = if String.contains?(name, "batch_size"), do: 1, else: 1_000_000

    entries
    |> Enum.sort_by(&elem(elem(&1, 0), 2))
    |> Enum.flat_map(fn row ->
      {{:histogram, _name, labels}, total, sum} = {elem(row, 0), elem(row, 1), elem(row, 2)}
      counts = row |> Tuple.to_list() |> Enum.drop(3)

      {cumulative, _running} =
        Enum.map_reduce(Enum.zip(bounds, counts), 0, fn {bound, n}, running ->
          {{bound, running + n}, running + n}
        end)

      buckets =
        for {bound, running} <- cumulative,
            do: [
              name,
              "_bucket",
              label_text([{:le, format(bound / scale)} | labels]),
              " ",
              Integer.to_string(running),
              "\n"
            ]

      buckets ++
        [
          [
            name,
            "_bucket",
            label_text([{:le, "+Inf"} | labels]),
            " ",
            Integer.to_string(total),
            "\n"
          ],
          [name, "_sum", label_text(labels), " ", format(sum / scale), "\n"],
          [name, "_count", label_text(labels), " ", Integer.to_string(total), "\n"]
        ]
    end)
  end

  defp lines(name, _type, entries) do
    entries
    |> Enum.sort_by(fn {{_kind, _name, labels}, _value} -> labels end)
    |> Enum.map(fn {{_kind, _name, labels}, value} ->
      [name, label_text(labels), " ", Integer.to_string(value), "\n"]
    end)
  end

  defp label_text([]), do: ""

  defp label_text(labels) do
    inner =
      Enum.map_join(labels, ",", fn {key, value} -> ~s(#{key}="#{escape(to_string(value))}") end)

    "{" <> inner <> "}"
  end

  defp escape(value),
    do:
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")

  defp format(number) when is_float(number), do: :erlang.float_to_binary(number, [:short])
end
