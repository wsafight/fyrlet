import Config

# Everything a host application must provide for Fyrlet at compile time. Dependencies'
# config files are not loaded, so these keys are listed here (see docs/INSTALL.md).
config :fyrlet,
  ecto_repos: [Fyrlet.Repo],
  definitions: [ChatExample.Definition],
  migration_paths: [{:chat_example, "priv/repo/migrations"}],
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
  batch_session_checks: true,
  capabilities: %{"append" => 1},
  effect_adapters: %{},
  host_router: FyrletExamples.Web,
  example_domain: "chat"

config :fyrlet, Fyrlet.Repo,
  url: "ecto://postgres:postgres@127.0.0.1:55432/chat_example_#{config_env()}",
  pool_size: 10,
  parameters: [statement_timeout: "10000"]

config :fyrlet, Oban,
  repo: Fyrlet.Repo,
  queues: [fyrlet: 10],
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

# A dependency's own config files are not loaded, so the host sets the level itself. The default
# in a release is :debug, which formats and writes every SQL statement.
config :logger, level: :info

if config_env() == :test do
  config :fyrlet, Fyrlet.Repo, pool: Ecto.Adapters.SQL.Sandbox
  config :fyrlet, FyrletWeb.Endpoint, server: false
  config :fyrlet, Oban, testing: :manual, plugins: false, queues: false
  config :fyrlet, batch_session_checks: false, run_recovery: false
  config :logger, level: :warning
end
