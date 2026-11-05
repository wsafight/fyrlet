import Config

config :fyrlet, Fyrlet.Repo,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :fyrlet, FyrletWeb.Endpoint, server: false
config :fyrlet, Oban, testing: :manual, plugins: false, queues: false
config :fyrlet, reconciliation_interval: 100
config :fyrlet, definitions: [Fyrlet.Example.Inbox, Fyrlet.TestDefinition]
config :logger, level: :warning
