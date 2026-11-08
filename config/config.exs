import Config

config :fyrlet,
  ecto_repos: [Fyrlet.Repo],
  # The host application lists its Fyrlet.Definition modules here.
  definitions: [],
  migration_paths: [],
  session_ttl: 600,
  # Sessions one service key may issue per minute (counted in the issuing transaction, so it
  # holds across nodes; concurrent bursts may slightly overshoot). Bounds session-table growth
  # if a key leaks. nil disables.
  session_issue_per_minute: 600,
  reconciliation_interval: 30_000,
  max_subscriptions: 20,
  max_subscriptions_per_node: 10_000,
  max_snapshot_bytes: 262_144,
  max_channel_queue: 200,
  snapshot_ack_timeout: 15_000,
  max_observers: 10_000,
  # Presence rooms (capability "presence"): members per room, bytes of one member's meta, and
  # how many meta updates one channel may send per second.
  presence_max_members: 500,
  presence_max_meta_bytes: 1024,
  presence_updates_per_second: 10,
  observer_hibernate_after: 1_000,
  socket_batch_max_messages: 64,
  socket_batch_max_bytes: 262_144,
  idempotency_ttl: 86_400,
  # Optional modules, as %{name => version}. Empty keeps v0.1 behaviour.
  capabilities: %{}

config :fyrlet, batch_session_checks: true

# Idle Channel processes hibernate to release heap. Phoenix's own default is 15 s;
# a smaller value lowers memory for many mostly idle connections at some CPU cost.
config :fyrlet,
       :channel_hibernate_after,
       String.to_integer(System.get_env("FYRLET_CHANNEL_HIBERNATE_MS", "15000"))

config :fyrlet, Fyrlet.Repo,
  url: "ecto://postgres:postgres@127.0.0.1:55432/fyrlet_#{config_env()}",
  pool_size: 10,
  parameters: [statement_timeout: "10000"]

config :fyrlet, Oban,
  repo: Fyrlet.Repo,
  queues: [fyrlet: 10],
  # Every write inserts a fallback invalidation job. Oban's defaults prune at most
  # 10_000 rows per 30 s (~333/s), which a sustained write rate above that outruns, and
  # a 24 h retention would keep tens of millions of completed rows. Keep one hour and
  # prune up to ~5_000 rows/s.
  pruner: [max_age: 3_600, interval: 10_000, limit: 50_000],
  cron: [crontab: [{"*/10 * * * *", Fyrlet.PruneWorker}]]

config :fyrlet, FyrletWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: FyrletWeb.ErrorJSON], layout: false],
  pubsub_server: Fyrlet.PubSub,
  secret_key_base: String.duplicate("local-development-secret-", 4),
  check_origin: ["//localhost", "//127.0.0.1"]

config :phoenix, :json_library, Jason
config :logger, :default_formatter, metadata: [:request_id]

import_config "#{config_env()}.exs"
