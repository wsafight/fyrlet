defmodule Fyrlet.Runs.Limits do
  @moduledoc """
  Bounded defaults for runs (temp spec §14). Override with `config :fyrlet, runs: [...]`.
  Nothing here may be unbounded.
  """

  @defaults [
    # Plan shape
    max_nodes: 50,
    payload_max_bytes: 65_536,
    max_attempts: 3,
    retry_base_seconds: 2,
    retry_max_seconds: 60,
    # Lifetimes (seconds)
    default_ttl: 604_800,
    max_ttl: 2_592_000,
    grant_cap: 2_592_000,
    lease_seconds: 60,
    cancel_deadline_seconds: 60,
    definition_unavailable_ttl: 3_600,
    terminal_retention: 2_592_000,
    signal_retention: 604_800,
    # Counts
    max_events: 1_000,
    signal_inbox: 50,
    max_pending_per_project: 1_000,
    max_concurrent_per_project: 100,
    signals_per_minute: 60,
    # Recovery
    scan_interval_ms: 30_000,
    stale_wake_seconds: 60,
    scan_batch: 100,
    # Steps one wake-up may run back to back. 1 means every step goes through the queue.
    local_chain: 1,
    ingest_max_pending: 10_000,
    # Seconds after which a finished run's payloads are erased (the run itself stays). nil = keep.
    payload_retention: nil
  ]

  def get(key) do
    :fyrlet |> Application.get_env(:runs, []) |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end

  def defaults, do: @defaults
end
