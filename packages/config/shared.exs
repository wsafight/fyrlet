import Config

# What a host application must give Fyrlet at compile time (dependencies' own config files
# are not loaded; see docs/INSTALL.md). Shared by the packages' test setups.
config :fyrlet,
  ecto_repos: [Fyrlet.Repo],
  definitions: [],
  migration_paths: [],
  session_ttl: 600,
  reconciliation_interval: 30_000,
  max_subscriptions: 20,
  max_snapshot_bytes: 262_144,
  max_channel_queue: 200,
  snapshot_ack_timeout: 15_000,
  max_observers: 10_000,
  observer_hibernate_after: 1_000,
  channel_hibernate_after: 15_000,
  socket_batch_max_messages: 64,
  socket_batch_max_bytes: 262_144,
  idempotency_ttl: 86_400,
  batch_session_checks: false,
  run_recovery: false,
  capabilities: %{"runs" => 1}

config :fyrlet, Fyrlet.Repo,
  url: "ecto://postgres:postgres@127.0.0.1:55432/fyrlet_packages_#{config_env()}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :fyrlet, Oban, repo: Fyrlet.Repo, testing: :manual, plugins: false, queues: false

config :fyrlet, FyrletWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: FyrletWeb.ErrorJSON], layout: false],
  pubsub_server: Fyrlet.PubSub,
  secret_key_base: String.duplicate("package-test-secret-", 4),
  server: false

config :phoenix, :json_library, Jason
config :logger, level: :warning
