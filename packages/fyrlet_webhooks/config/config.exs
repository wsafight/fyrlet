import Config

import_config "../../config/shared.exs"

config :fyrlet,
  definitions: [FyrletWebhooks.TestDefinition],
  plugins: [FyrletWebhooks]
