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
    series = ~s(fyrlet_operations_total{name="inbox.add",result="ok"})
    before = sample(scrape().resp_body, series)

    for n <- 1..3,
        do:
          {:ok, _} =
            Runtime.call(alice.actor, "inbox.add", %{"text" => "m#{n}"}, Ecto.UUID.generate())

    body = scrape().resp_body
    assert sample(body, series) == before + 3
    assert body =~ "# TYPE fyrlet_operation_duration_seconds histogram"

    count = sample(body, ~s(fyrlet_operation_duration_seconds_count{name="inbox.add"}))

    assert sample(body, ~s(fyrlet_operation_duration_seconds_bucket{le="+Inf",name="inbox.add"})) ==
             count

    assert sample(body, ~s(fyrlet_operation_duration_seconds_sum{name="inbox.add"})) > 0

    # Buckets are cumulative: never decreasing as the bound grows.
    counts =
      for line <- String.split(body, "\n"),
          line =~ ~s(fyrlet_operation_duration_seconds_bucket{le=),
          line =~ ~s(name="inbox.add"),
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
        do: Runtime.call(alice.actor, "inbox.add", %{"text" => "q#{n}"}, Ecto.UUID.generate())

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
end
