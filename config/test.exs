import Config

config :fyrlet, Fyrlet.Repo,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :fyrlet, FyrletWeb.Endpoint, server: false
config :fyrlet, Oban, testing: :manual, plugins: false, queues: false
config :fyrlet, reconciliation_interval: 100

config :fyrlet,
  definitions: [
    Fyrlet.TestRecords,
    Fyrlet.TestDefinition,
    Fyrlet.RunsTestDefinition,
    Fyrlet.IngestTestDefinition,
    Fyrlet.SharedTestDefinition,
    Fyrlet.AppendTestDefinition,
    Fyrlet.PresenceTestDefinition
  ],
  migration_paths: ["test/support/migrations"]

config :logger, level: :warning
# Many tests rewrite contracts, plugins and definitions at run time.
config :fyrlet, runtime_cache: false
config :fyrlet, batch_session_checks: false

# Most tests exercise the durable fallback job; test/fyrlet/invalidation_mode_test.exs covers both modes.
config :fyrlet, durable_invalidation: true
# Runs are enabled in tests; the recovery scanner is driven explicitly, not on a timer.
config :fyrlet,
  capabilities: %{
    "runs" => 1,
    "executors" => 1,
    "anonymous_read" => 1,
    "ingest" => 1,
    "append" => 1,
    "presence" => 1
  },
  run_recovery: false

config :fyrlet,
  effect_adapters: %{
    "idem" => Fyrlet.EffectTest.Idempotent,
    "query" => Fyrlet.EffectTest.QueryOnly,
    "manual" => Fyrlet.EffectTest.Manual
  }

config :fyrlet,
  plugins: [
    Fyrlet.TestPlugins.Counter,
    Fyrlet.TestPlugins.Mirror,
    {Fyrlet.TestPlugins.Broken, required: false}
  ]

config :fyrlet, :effects, retry_base_seconds: 0, retry_max_seconds: 0, reconcile_delay_seconds: 0
