if Mix.env() == :prod or System.get_env("FYRLET_DOMAIN_INTEGRATION") != "1" do
  raise "This server fixture is only for explicitly enabled local integration tests"
end

defmodule DomainIntegrationMetrics do
  use GenServer

  @keys ~w(db_queries view_queries snapshot_encodes snapshot_encode_bytes append_bytes append_items fallback_gap fallback_overflow fallback_refresh)

  def start, do: GenServer.start(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(__MODULE__, [:named_table, :public, write_concurrency: true])
    reset()

    :telemetry.attach_many(
      "domain-integration-metrics",
      [
        [:fyrlet, :repo, :query],
        [:fyrlet, :subscription, :query],
        [:fyrlet, :subscription, :serialize],
        [:fyrlet, :subscription, :append],
        [:fyrlet, :delta, :snapshot_fallback]
      ],
      &__MODULE__.record/4,
      nil
    )

    {:ok, nil}
  end

  def reset, do: :ets.insert(__MODULE__, Enum.map(@keys, &{&1, 0}))
  def snapshot, do: Map.new(:ets.tab2list(__MODULE__))

  def record([:fyrlet, :repo, :query], _measurements, _metadata, _config),
    do: increment("db_queries", 1)

  def record([:fyrlet, :subscription, :query], _measurements, %{result: :ok}, _config),
    do: increment("view_queries", 1)

  def record([:fyrlet, :subscription, :serialize], measurements, _metadata, _config) do
    increment("snapshot_encodes", 1)
    increment("snapshot_encode_bytes", measurements.bytes)
  end

  def record([:fyrlet, :subscription, :append], measurements, _metadata, _config) do
    increment("append_bytes", measurements.bytes)
    increment("append_items", measurements.items)
  end

  def record([:fyrlet, :delta, :snapshot_fallback], _measurements, metadata, _config),
    do: increment("fallback_#{metadata.reason}", 1)

  def record(_event, _measurements, _metadata, _config), do: :ok
  defp increment(key, amount), do: :ets.update_counter(__MODULE__, key, {2, amount}, {key, 0})
end

{:ok, _metrics} = DomainIntegrationMetrics.start()

defmodule DomainIntegrationReceiver do
  use Plug.Router
  plug :match
  plug :dispatch

  get "/metrics" do
    send_resp(conn, 200, Jason.encode!(DomainIntegrationMetrics.snapshot()))
  end

  get "/runtime" do
    tracker = :sys.get_state(Fyrlet.Subscriptions.Tracker)

    info =
      Map.merge(Fyrlet.Diagnostics.cluster(), %{
        "subscriptions" => map_size(tracker.monitors),
        "observers" => Registry.count(Fyrlet.ObserverRegistry),
        "processes" => :erlang.system_info(:process_count),
        "memory_bytes" => :erlang.memory(:total),
        "reader_entries" =>
          case :ets.info(Fyrlet.Features.Stream.Reader, :size) do
            :undefined -> 0
            count -> count
          end
      })

    send_resp(conn, 200, Jason.encode!(info))
  end

  post "/metrics/reset" do
    DomainIntegrationMetrics.reset()
    send_resp(conn, 200, "{}")
  end

  post "/emails" do
    {:ok, _body, conn} = Plug.Conn.read_body(conn)
    key = List.first(Plug.Conn.get_req_header(conn, "idempotency-key"))
    send_resp(conn, 200, Jason.encode!(%{"id" => key}))
  end

  get "/emails/:id" do
    send_resp(conn, 200, Jason.encode!(%{"id" => id, "last_event" => "delivered"}))
  end

  post "/hook" do
    {:ok, _body, conn} = Plug.Conn.read_body(conn)
    send_resp(conn, 200, "{}")
  end
end

{:ok, server} =
  Bandit.start_link(
    plug: DomainIntegrationReceiver,
    port: String.to_integer(System.fetch_env!("DOMAIN_PROVIDER_PORT")),
    ip: {127, 0, 0, 1},
    startup_log: false
  )

Process.unlink(server)
{:ok, {_, port}} = ThousandIsland.listener_info(server)
Application.put_env(:fyrlet, :effects, reconcile_delay_seconds: 0, retry_base_seconds: 0)
Application.put_env(:fyrlet_effect_email, :resend_url, "http://127.0.0.1:#{port}")
Application.put_env(:fyrlet_effect_email, :allow_http, true)
Application.put_env(:fyrlet_effect_email, :allowed_senders, ["sender@example.com"])
Application.put_env(:fyrlet, :effect_secrets, %{"mail_provider" => "integration-test-key"})
Application.put_env(:notify_example, :sender, "sender@example.com")
Application.put_env(:fyrlet_effect_http, :allowed_hosts, ["127.0.0.1"])
Application.put_env(:fyrlet_effect_http, :allow_http, true)
