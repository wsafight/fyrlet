import Config

config :fyrlet,
  ecto_repos: [Fyrlet.Repo],
  definitions: [Fyrlet.Example.Inbox],
  session_ttl: 600,
  reconciliation_interval: 30_000,
  max_subscriptions: 20,
  max_snapshot_bytes: 262_144,
  max_channel_queue: 200,
  snapshot_ack_timeout: 15_000,
  idempotency_ttl: 86_400

config :fyrlet, Fyrlet.Repo,
  url: "ecto://postgres:postgres@127.0.0.1:55432/realtime_#{config_env()}",
  pool_size: 10,
  parameters: [statement_timeout: "10000"]

config :fyrlet, Oban,
  repo: Fyrlet.Repo,
  queues: [fyrlet: 10],
  plugins: [{Oban.Plugins.Pruner, max_age: 86_400}]

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
