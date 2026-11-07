Code.require_file("fixtures/footprint_definition.exs", __DIR__)

defmodule Fyrlet.Bench.ConnectionFootprint do
  use Fyrlet.DataCase, async: false
  import Phoenix.ChannelTest, except: [join: 2]
  @endpoint FyrletWeb.Endpoint

  @tag timeout: 300_000
  test "retained channel and observer memory under bounded snapshot fan-out" do
    Process.flag(:trap_exit, true)
    connections = integer("FOOTPRINT_CONNECTIONS", 40)
    subscriptions = integer("FOOTPRINT_SUBSCRIPTIONS", 5)
    bytes = integer("FOOTPRINT_BYTES", 65_536)
    rounds = integer("FOOTPRINT_ROUNDS", 6)
    shared = System.get_env("FOOTPRINT_SHARED") == "1"
    name = if shared, do: "footprint.shared", else: "footprint.private"
    label = System.get_env("FOOTPRINT_LABEL", "unlabelled")

    settings = [
      definitions: [Fyrlet.Bench.FootprintDefinition],
      reconciliation_interval: 600_000,
      max_subscriptions: connections * subscriptions + 10
    ]

    previous = for {key, _value} <- settings, do: {key, Application.fetch_env(:fyrlet, key)}
    for {key, value} <- settings, do: Application.put_env(:fyrlet, key, value)
    Application.put_env(:fyrlet, :footprint_version, 0)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, configured} -> Application.put_env(:fyrlet, key, configured)
          :error -> Application.delete_env(:fyrlet, key)
        end
      end

      Application.delete_env(:fyrlet, :footprint_version)
    end)

    tenant = project()
    actors = for index <- 1..connections, do: user(tenant, "footprint-#{index}").actor
    baseline = sample([])

    channels =
      for actor <- actors, _index <- 1..subscriptions do
        {:ok, initial, socket} =
          socket(FyrletWeb.UserSocket, "sessions:" <> actor.session_id, %{actor: actor})
          |> Map.put(:serializer, Phoenix.Socket.V2.JSONSerializer)
          |> subscribe_and_join("subscription:" <> Ecto.UUID.generate(), %{
            "protocol_version" => 1,
            "name" => name,
            "params" => %{"bytes" => bytes}
          })

        assert byte_size(Jason.encode!(initial["data"])) == bytes
        push(socket, "ack", ack(initial))
        %{socket | assigns: %{observer: socket.assigns.observer}}
      end

    owners = channels |> Enum.map(& &1.assigns.observer) |> Enum.uniq()
    processes = Enum.uniq(Enum.map(channels, & &1.channel_pid) ++ owners)

    on_exit(fn ->
      for process <- processes, Process.alive?(process) do
        try do
          GenServer.stop(process)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    synchronize(channels, owners)
    idle = sample(processes)
    counter = :counters.new(1, [])
    handler = "footprint-#{Ecto.UUID.generate()}"

    :telemetry.attach(
      handler,
      [:fyrlet, :repo, :query],
      fn _, _, _, value -> :counters.add(value, 1, 1) end,
      counter
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    samples =
      for round <- 1..rounds do
        :counters.put(counter, 1, 0)
        Application.put_env(:fyrlet, :footprint_version, round)
        started = System.monotonic_time(:microsecond)

        {deliveries, latencies} =
          Enum.reduce(actors, {%{}, []}, fn actor, {deliveries, latencies} ->
            scope_started = System.monotonic_time(:microsecond)

            Phoenix.PubSub.broadcast(
              Fyrlet.PubSub,
              Fyrlet.Bench.FootprintDefinition.scope(name, actor, %{}),
              :invalidated
            )

            {next, elapsed} = collect(subscriptions, scope_started, %{}, [])
            {Map.merge(deliveries, next), elapsed ++ latencies}
          end)

        all_ms = (System.monotonic_time(:microsecond) - started) / 1000
        for socket <- channels, do: push(socket, "ack", ack(Map.fetch!(deliveries, socket.topic)))
        synchronize(channels, owners)
        queries = :counters.get(counter, 1)
        latencies = Enum.sort(latencies)

        Map.merge(sample(processes), %{
          round: round,
          queries: queries,
          p95_ms: Enum.at(latencies, max(ceil(length(latencies) * 0.95) - 1, 0)) / 1000,
          all_ms: all_ms
        })
      end

    report = %{
      kind: "channel-process-footprint",
      serializer: "Phoenix.Socket.V2.JSONSerializer",
      concurrent_scopes: 1,
      runtime: %{
        elixir: System.version(),
        otp: System.otp_release(),
        schedulers: System.schedulers_online()
      },
      label: label,
      connections_modelled: connections,
      subscriptions_per_connection: subscriptions,
      snapshot_bytes: bytes,
      shared: shared,
      channels: length(channels),
      view_owner_processes: length(owners),
      distinct_processes: length(processes),
      baseline: baseline,
      idle: idle,
      samples: samples,
      boundaries:
        "ChannelTest with real PostgreSQL authentication; excludes TCP, TLS, Bandit transport and SDK memory. Not a connection-capacity result."
    }

    directory = Path.expand("../.local/footprint", __DIR__)
    File.mkdir_p!(directory)

    path =
      Path.join(
        directory,
        "#{label}-#{connections}-#{subscriptions}-#{bytes}-#{if(shared, do: "shared", else: "private")}.json"
      )

    File.write!(path, Jason.encode!(report, pretty: true))

    IO.puts(
      Jason.encode!(
        Map.take(report, [:label, :channels, :view_owner_processes, :distinct_processes, :idle])
      )
    )

    IO.puts("Footprint samples: #{path}")
    for socket <- channels, do: leave(socket)
  end

  defp integer(name, default) do
    value = String.to_integer(System.get_env(name, to_string(default)))
    if value < 1, do: raise(ArgumentError, "#{name} must be positive")
    value
  end

  defp synchronize(channels, owners) do
    for socket <- channels, do: :sys.get_state(socket.channel_pid)
    for process <- owners, do: :sys.get_state(process)
  end

  defp sample(processes) do
    for process <- processes, Process.alive?(process), do: :erlang.garbage_collect(process)
    :erlang.garbage_collect(self())

    {heap, binaries, queued} =
      Enum.reduce(processes, {0, %{}, 0}, fn process, {heap, binaries, queued} ->
        info = Process.info(process, [:memory, :binary, :message_queue_len])

        binaries =
          Enum.reduce(info[:binary], binaries, fn {identifier, size, _references}, acc ->
            Map.put(acc, identifier, size)
          end)

        {heap + info[:memory], binaries, queued + info[:message_queue_len]}
      end)

    binary_bytes = Enum.sum(Map.values(binaries))
    {rss, 0} = System.cmd("ps", ["-o", "rss=", "-p", System.pid()])

    %{
      heap_bytes: heap,
      referenced_binary_bytes: binary_bytes,
      retained_bytes: heap + binary_bytes,
      queued: queued,
      vm_processes: :erlang.system_info(:process_count),
      vm_binary_bytes: :erlang.memory(:binary),
      vm_total_bytes: :erlang.memory(:total),
      rss_bytes: String.to_integer(String.trim(rss)) * 1024
    }
  end

  defp ack(snapshot), do: %{"g" => snapshot["generation"], "s" => snapshot["seq"]}
  defp collect(0, _started, deliveries, latencies), do: {deliveries, latencies}

  defp collect(remaining, started, deliveries, latencies) do
    receive do
      {:socket_push, :text, encoded} ->
        [_join_ref, _reference, topic, "snapshot", snapshot] =
          Jason.decode!(IO.iodata_to_binary(encoded))

        refute Map.has_key?(deliveries, topic)

        collect(remaining - 1, started, Map.put(deliveries, topic, snapshot), [
          System.monotonic_time(:microsecond) - started | latencies
        ])

      %Phoenix.Socket.Message{event: "snapshot", topic: topic, payload: snapshot} ->
        refute Map.has_key?(deliveries, topic)

        collect(remaining - 1, started, Map.put(deliveries, topic, snapshot), [
          System.monotonic_time(:microsecond) - started | latencies
        ])
    after
      15_000 -> flunk("#{remaining} snapshots did not arrive")
    end
  end
end
