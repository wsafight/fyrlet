defmodule Fyrlet.MetricsTest do
  use Fyrlet.DataCase, async: false
  import Plug.Conn
  import Phoenix.ConnTest
  alias Fyrlet.{Metrics, Runtime}
  @endpoint FyrletWeb.Endpoint
  @token "a-metrics-token-of-32-bytes-or-so"

  setup do
    previous = Application.get_env(:fyrlet, :metrics)
    previous_quotas = Application.get_env(:fyrlet, :quotas)

    on_exit(fn ->
      restore(:metrics, previous)
      restore(:quotas, previous_quotas)
    end)

    project = project()
    %{alice: user(project)}
  end

  defp restore(key, nil), do: Application.delete_env(:fyrlet, key)
  defp restore(key, value), do: Application.put_env(:fyrlet, key, value)

  defp enable do
    Application.put_env(:fyrlet, :metrics, token: @token)
    start_supervised!(Metrics)
  end

  defp scrape(token \\ @token) do
    conn = build_conn()
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    get(conn, "/metrics")
  end

  # The value of one sample line, e.g. `fyrlet_operations_total{name="x",result="ok"}`.
  defp sample(text, series) do
    text
    |> String.split("\n")
    |> Enum.find_value(0, fn line ->
      case String.split(line, " ") do
        [^series, value] -> parse(value)
        _other -> nil
      end
    end)
  end

  defp parse(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _float -> String.to_float(value)
    end
  end

  test "metrics are off without a token: nothing recorded, the route looks absent" do
    Application.delete_env(:fyrlet, :metrics)
    refute Metrics.enabled?()
    assert Metrics.child_specs() == []
    assert json_response(scrape(), 404)["error"]["code"] == "NOT_FOUND"
  end

  test "the scrape needs the exact token and a short one is refused at boot" do
    enable()
    assert Metrics.enabled?()

    for wrong <- [nil, "wrong", @token <> "x", String.slice(@token, 0..-2//1)] do
      assert scrape(wrong).status == 404
    end

    conn = scrape()
    assert conn.status == 200
    assert ["text/plain; version=0.0.4" <> _] = get_resp_header(conn, "content-type")
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert conn.resp_body =~ "# TYPE fyrlet_vm_processes gauge"

    Application.put_env(:fyrlet, :metrics, token: "short")
    assert_raise ArgumentError, fn -> Metrics.validate!() end
    Application.put_env(:fyrlet, :metrics, token: @token)
    assert :ok = Metrics.validate!()
  end

  test "operations are counted by contract name and result, with a duration histogram", %{
    alice: alice
  } do
    enable()
    series = ~s(fyrlet_operations_total{name="records.add",result="ok"})
    before = sample(scrape().resp_body, series)

    for n <- 1..3,
        do:
          {:ok, _} =
            Runtime.call(alice.actor, "records.add", %{"text" => "m#{n}"}, Ecto.UUID.generate())

    body = scrape().resp_body
    assert sample(body, series) == before + 3
    assert body =~ "# TYPE fyrlet_operation_duration_seconds histogram"

    count = sample(body, ~s(fyrlet_operation_duration_seconds_count{name="records.add"}))

    assert sample(
             body,
             ~s(fyrlet_operation_duration_seconds_bucket{le="+Inf",name="records.add"})
           ) ==
             count

    assert sample(body, ~s(fyrlet_operation_duration_seconds_sum{name="records.add"})) > 0

    # Buckets are cumulative: never decreasing as the bound grows.
    counts =
      for line <- String.split(body, "\n"),
          line =~ ~s(fyrlet_operation_duration_seconds_bucket{le=),
          line =~ ~s(name="records.add"),
          do: line |> String.split(" ") |> List.last() |> String.to_integer()

    assert counts == Enum.sort(counts) and length(counts) == 13
  end

  test "a name that is not in the contract never becomes a label value", %{alice: alice} do
    enable()
    hostile = "attacker." <> Base.encode16(:crypto.strong_rand_bytes(8))

    before =
      sample(scrape().resp_body, ~s(fyrlet_operations_total{name="_unknown",result="error"}))

    assert {:error, _} = Runtime.call(alice.actor, hostile, %{}, Ecto.UUID.generate())

    body = scrape().resp_body
    refute body =~ hostile
    assert sample(body, ~s(fyrlet_operations_total{name="_unknown",result="error"})) == before + 1
  end

  test "quota refusals, session batches and database timings are exported", %{alice: alice} do
    enable()
    Application.put_env(:fyrlet, :quotas, default: [writes_per_second: 1])
    before = sample(scrape().resp_body, ~s(fyrlet_quota_rejected_total{class="write"}))

    for n <- 1..6,
        do: Runtime.call(alice.actor, "records.add", %{"text" => "q#{n}"}, Ecto.UUID.generate())

    body = scrape().resp_body
    assert sample(body, ~s(fyrlet_quota_rejected_total{class="write"})) > before
    assert sample(body, "fyrlet_db_query_seconds_count") > 0
    assert body =~ "# TYPE fyrlet_db_queue_seconds histogram"
  end

  test "shutdown detaches the telemetry handlers" do
    enable()

    assert Enum.any?(
             :telemetry.list_handlers([:fyrlet, :operation, :stop]),
             &(&1.id == {Metrics, :all})
           )

    stop_supervised!(Metrics)

    refute Enum.any?(
             :telemetry.list_handlers([:fyrlet, :operation, :stop]),
             &(&1.id == {Metrics, :all})
           )
  end

  test "rendering without a metrics process still exports live gauges" do
    refute Process.whereis(Metrics)
    body = Metrics.render()
    assert sample(body, "fyrlet_vm_processes") > 0
    assert sample(body, "fyrlet_vm_memory_bytes") > 0
    refute body =~ "fyrlet_operations_total"
  end

  test "empty and non-string tokens leave metrics disabled" do
    for token <- [nil, "", false, 123] do
      Application.put_env(:fyrlet, :metrics, token: token)
      assert Metrics.token() == nil
      refute Metrics.enabled?()
      assert Metrics.child_specs() == []
      assert :ok = Metrics.validate!()
    end
  end

  test "snapshot, delta and append events accumulate counts and payload sizes independently" do
    enable()

    for bytes <- [10, 25] do
      :telemetry.execute([:fyrlet, :subscription, :snapshot], %{bytes: bytes}, %{name: "feed"})
      :telemetry.execute([:fyrlet, :subscription, :delta], %{bytes: bytes}, %{name: "feed"})
    end

    for items <- [2, 5],
        do:
          :telemetry.execute([:fyrlet, :subscription, :append], %{items: items}, %{name: "feed"})

    :telemetry.execute([:fyrlet, :subscription, :snapshot], %{bytes: 99}, %{name: "other"})
    body = Metrics.render()

    for metric <- ["fyrlet_snapshots_total", "fyrlet_deltas_total", "fyrlet_append_batches_total"],
        do: assert(sample(body, metric <> ~s({name="feed"})) == 2)

    assert sample(body, ~s(fyrlet_snapshot_bytes_total{name="feed"})) == 35
    assert sample(body, ~s(fyrlet_delta_bytes_total{name="feed"})) == 35
    assert sample(body, ~s(fyrlet_append_items_total{name="feed"})) == 7
    assert sample(body, ~s(fyrlet_snapshot_bytes_total{name="other"})) == 99
  end

  test "serialization modes and snapshot fallbacks have distinct counters" do
    enable()

    for mode <- ["snapshot", "delta", "delta"],
        do:
          :telemetry.execute([:fyrlet, :subscription, :serialize], %{}, %{
            name: "feed",
            mode: mode
          })

    :telemetry.execute([:fyrlet, :delta, :snapshot_fallback], %{}, %{name: "feed"})
    body = Metrics.render()

    assert sample(body, ~s(fyrlet_snapshot_serializations_total{name="feed",mode="snapshot"})) ==
             1

    assert sample(body, ~s(fyrlet_snapshot_serializations_total{name="feed",mode="delta"})) == 2
    assert sample(body, ~s(fyrlet_snapshot_fallbacks_total{name="feed"})) == 1
  end

  test "query histograms convert native durations to seconds and include overflow observations" do
    enable()

    for duration <- [1_000, 6_000_000] do
      :telemetry.execute(
        [:fyrlet, :subscription, :query],
        %{duration: System.convert_time_unit(duration, :microsecond, :native)},
        %{name: "feed", result: "ok"}
      )
    end

    body = Metrics.render()
    assert sample(body, ~s(fyrlet_subscription_queries_total{name="feed",result="ok"})) == 2
    assert sample(body, ~s(fyrlet_subscription_query_duration_seconds_count{name="feed"})) == 2

    assert sample(
             body,
             ~s(fyrlet_subscription_query_duration_seconds_bucket{le="0.001",name="feed"})
           ) == 1

    assert sample(
             body,
             ~s(fyrlet_subscription_query_duration_seconds_bucket{le="5.0",name="feed"})
           ) == 1

    assert sample(
             body,
             ~s(fyrlet_subscription_query_duration_seconds_bucket{le="+Inf",name="feed"})
           ) == 2

    assert_in_delta sample(body, ~s(fyrlet_subscription_query_duration_seconds_sum{name="feed"})),
                    6.001,
                    0.000001
  end

  test "session batch sizes keep their count units and include batches beyond the last bucket" do
    enable()
    duration = System.convert_time_unit(2_500, :microsecond, :native)

    for requests <- [1, 2, 129],
        do:
          :telemetry.execute(
            [:fyrlet, :auth, :batch],
            %{requests: requests, duration: duration},
            %{}
          )

    body = Metrics.render()
    assert sample(body, ~s(fyrlet_session_check_batch_size_bucket{le="1.0"})) == 1
    assert sample(body, ~s(fyrlet_session_check_batch_size_bucket{le="2.0"})) == 2
    assert sample(body, ~s(fyrlet_session_check_batch_size_bucket{le="128.0"})) == 2
    assert sample(body, ~s(fyrlet_session_check_batch_size_bucket{le="+Inf"})) == 3
    assert sample(body, "fyrlet_session_check_batch_size_count") == 3
    assert sample(body, "fyrlet_session_check_batch_size_sum") == 132
    assert_in_delta sample(body, "fyrlet_session_check_duration_seconds_sum"), 0.0075, 0.000001
  end

  test "subscription gauges replace previous values and retain an explicit zero" do
    enable()

    for active <- [10, 3, 0] do
      :telemetry.execute([:fyrlet, :subscription, :count], %{active: active}, %{})
      body = Metrics.render()
      assert body =~ "# TYPE fyrlet_subscriptions_active gauge"
      assert sample(body, "fyrlet_subscriptions_active") == active
    end
  end

  test "concurrent transport batches do not lose counter updates" do
    enable()

    results =
      Task.async_stream(
        1..200,
        fn _index ->
          :telemetry.execute([:fyrlet, :transport, :batch], %{messages: 3, bytes: 100}, %{})
        end,
        max_concurrency: 16
      )

    assert Enum.all?(results, &match?({:ok, :ok}, &1))
    body = Metrics.render()
    assert sample(body, "fyrlet_transport_batches_total") == 200
    assert sample(body, "fyrlet_transport_batched_messages_total") == 600
  end

  test "database histograms ignore absent timings and convert valid timings independently" do
    enable()
    :telemetry.execute([:fyrlet, :repo, :query], %{}, %{})
    :telemetry.execute([:fyrlet, :repo, :query], %{queue_time: nil, query_time: "invalid"}, %{})
    refute Metrics.render() =~ "fyrlet_db_query_seconds_count"
    queue_time = System.convert_time_unit(1_500, :microsecond, :native)
    query_time = System.convert_time_unit(2_500, :microsecond, :native)
    :telemetry.execute([:fyrlet, :repo, :query], %{queue_time: queue_time}, %{})
    :telemetry.execute([:fyrlet, :repo, :query], %{query_time: query_time}, %{})
    body = Metrics.render()
    assert sample(body, "fyrlet_db_queue_seconds_count") == 1
    assert sample(body, "fyrlet_db_query_seconds_count") == 1
    assert_in_delta sample(body, "fyrlet_db_queue_seconds_sum"), 0.0015, 0.000001
    assert_in_delta sample(body, "fyrlet_db_query_seconds_sum"), 0.0025, 0.000001
  end

  test "Ops gauges replace previous values and report their freshness" do
    enable()

    :telemetry.execute(
      [:fyrlet, :ops, :status],
      %{alerts: 2, stuck_runs: 1, queue_age_seconds: 180, unresolved_effects: 3},
      %{}
    )

    body = Metrics.render()
    assert sample(body, "fyrlet_ops_alerts") == 2
    assert sample(body, "fyrlet_runs_stuck") == 1
    assert sample(body, "fyrlet_queue_age_seconds") == 180
    assert sample(body, "fyrlet_effects_unresolved") == 3
    assert sample(body, "fyrlet_ops_evaluated_at_seconds") >= System.system_time(:second) - 1

    :telemetry.execute(
      [:fyrlet, :ops, :status],
      %{alerts: 0, stuck_runs: 0, queue_age_seconds: 0, unresolved_effects: 0},
      %{}
    )

    assert sample(Metrics.render(), "fyrlet_queue_age_seconds") == 0
    assert sample(Metrics.render(), "fyrlet_effects_unresolved") == 0
  end

  test "Prometheus label values escape quotes, backslashes and newlines" do
    enable()

    :telemetry.execute([:fyrlet, :subscription, :snapshot], %{bytes: 12}, %{
      name: "feed\"\\\nnext"
    })

    body = Metrics.render()
    assert sample(body, "fyrlet_snapshots_total{name=\"feed\\\"\\\\\\nnext\"}") == 1
    refute body =~ "\nnext"
  end
end
