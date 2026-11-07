import Config

import_config "../../config/shared.exs"

config :fyrlet,
  definitions: [FyrletOps.TestDefinition],
  plugins: [FyrletOps]

# The timer is off; tests drive the ticker themselves.
config :fyrlet_ops, interval_ms: false
