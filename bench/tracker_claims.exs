defmodule Fyrlet.Bench.TrackerClaims do
  use ExUnit.Case, async: false
  alias Fyrlet.Subscriptions.Tracker

  @tag timeout: 60_000
  test "bounded arrival bursts measure tracker call latency including cleanup" do
    baseline = map_size(:sys.get_state(Tracker).monitors)

    reports =
      for rate <- [1000, 5000] do
        rate_started = System.monotonic_time(:microsecond)

        batches =
          for _index <- 1..100 do
            started = System.monotonic_time(:microsecond)

            samples =
              1..div(rate, 100)
              |> Task.async_stream(
                fn _ ->
                  started = System.monotonic_time(:microsecond)
                  assert :ok = Tracker.claim(self(), self())
                  System.monotonic_time(:microsecond) - started
                end,
                max_concurrency: 50,
                timeout: 5000
              )
              |> Enum.map(fn {:ok, elapsed} -> elapsed end)

            elapsed = System.monotonic_time(:microsecond) - started
            Process.sleep(max(10 - ceil(elapsed / 1000), 0))
            {samples, max(elapsed, 10_000)}
          end

        samples = batches |> Enum.flat_map(&elem(&1, 0)) |> Enum.sort()
        duration = System.monotonic_time(:microsecond) - rate_started
        :sys.get_state(Tracker)
        assert map_size(:sys.get_state(Tracker).monitors) == baseline

        %{
          requested_claims_per_second: rate,
          claims: length(samples),
          achieved_claims_per_second: length(samples) * 1_000_000 / duration,
          p50_us: Enum.at(samples, div(length(samples), 2)),
          p99_us: Enum.at(samples, ceil(length(samples) * 0.99) - 1),
          max_us: List.last(samples)
        }
      end

    path = Path.expand("../.local/footprint/tracker.json", __DIR__)
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{kind: "tracker-arrival-microbenchmark", samples: reports}, pretty: true)
    )

    IO.puts(Jason.encode!(reports))
  end
end
