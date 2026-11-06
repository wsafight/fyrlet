defmodule Fyrlet.Bench.JSON do
  import Jason.Helpers

  def encoded(%{"p" => _patch} = payload),
    do:
      Jason.encode!(
        json_map(
          g: payload["g"],
          b: payload["b"],
          s: payload["s"],
          p: payload["p"]
        )
      )

  def encoded(payload),
    do:
      Jason.encode!(
        json_map(
          protocol_version: payload["protocol_version"],
          subscription_id: payload["subscription_id"],
          generation: payload["generation"],
          seq: payload["seq"],
          project_id: payload["project_id"],
          subject_id: payload["subject_id"],
          delivery: payload["delivery"],
          data: payload["data"]
        )
      )

  def run do
    records =
      for _index <- 1..50 do
        %{
          "id" => Ecto.UUID.generate(),
          "text" => String.duplicate("更新\n\"\\", 16),
          "version" => 2,
          "content_type" => "text",
          "archived" => false,
          "inserted_at" => "2026-11-06T00:00:00.000000Z",
          "updated_at" => "2026-11-06T00:00:01.000000Z"
        }
      end

    delta = %{
      "g" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      "b" => 1,
      "s" => 2,
      "p" => %{
        "c" => [[hd(records)["id"], Map.take(hd(records), ["text", "version", "updated_at"])]]
      }
    }

    snapshot = %{
      "protocol_version" => 1,
      "subscription_id" => Ecto.UUID.generate(),
      "generation" => delta["g"],
      "seq" => 1,
      "project_id" => Ecto.UUID.generate(),
      "subject_id" => Ecto.UUID.generate(),
      "delivery" => "delta-v1",
      "data" => records
    }

    topic = "subscription:" <> snapshot["subscription_id"]
    frame = fn payload -> ["1", nil, topic, "delta", payload] end

    encoders = [
      {"map/twice",
       fn payload ->
         encoded = Jason.encode!(payload)
         {byte_size(encoded), Jason.encode!(frame.(payload))}
       end},
      {"map/reuse",
       fn payload ->
         encoded = Jason.encode!(payload)
         {byte_size(encoded), Jason.encode!(frame.(Jason.Fragment.new(encoded)))}
       end},
      {"helpers/reuse",
       fn payload ->
         encoded = encoded(payload)
         {byte_size(encoded), Jason.encode!(frame.(Jason.Fragment.new(encoded)))}
       end}
    ]

    iterations = System.get_env("BENCH_JSON_ITERATIONS", "10000") |> String.to_integer()
    if iterations < 1 or iterations > 100_000, do: raise("Invalid iteration count")

    results =
      for {name, payload} <- [{"delta", delta}, {"snapshot-50", snapshot}],
          repetition <- 1..5,
          {codec, encode} <-
            Enum.drop(encoders, rem(repetition, 3)) ++ Enum.take(encoders, rem(repetition, 3)) do
        {size, check} = encode.(payload)
        unless Jason.decode!(check) == frame.(payload), do: raise("Codec changed the JSON value")

        unless size == byte_size(Jason.encode!(payload)),
          do: raise("Codec changed the payload size")

        for _index <- 1..100, do: encode.(payload)
        :erlang.garbage_collect()

        {microseconds, bytes} =
          :timer.tc(fn ->
            Enum.reduce(1..iterations, 0, fn _index, total ->
              {_size, encoded} = encode.(payload)
              total + byte_size(encoded)
            end)
          end)

        %{
          name: name,
          codec: codec,
          repetition: repetition,
          iterations: iterations,
          payload_bytes: size,
          encoded_bytes: bytes,
          microseconds_per_iteration: microseconds / iterations
        }
      end

    File.mkdir_p!(".local/bench")
    path = ".local/bench/json-#{System.system_time(:millisecond)}.json"

    File.write!(
      path,
      Jason.encode!(%{results: results, erlang: System.otp_release(), elixir: System.version()},
        pretty: true
      )
    )

    results
    |> Enum.group_by(&{&1.name, &1.codec})
    |> Enum.sort()
    |> Enum.each(fn {{name, codec}, samples} ->
      times = Enum.map(samples, & &1.microseconds_per_iteration)

      IO.puts(
        "#{name} #{codec}: #{Float.round(Enum.min(times), 2)}–#{Float.round(Enum.max(times), 2)} us"
      )
    end)

    IO.puts("Results: #{path}")
  end
end

Fyrlet.Bench.JSON.run()
