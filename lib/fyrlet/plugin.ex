defmodule Fyrlet.Plugin do
  @moduledoc """
  The smallest surface a capability package needs (temp spec §7.2), extracted from the seams the
  built-in packages (anonymous entry, webhooks, ingest, executors, the HTTP effect adapter)
  actually used: supervised processes, migrations, an HTTP entry, contract entries with a
  capability, and Oban workers.

  A plugin is trusted server code in the same VM and database as Fyrlet. The rules below are
  checked at startup and by `Fyrlet.Conformance.Plugin`; they describe what the official paths
  enforce, not a sandbox against hostile code.

      config :fyrlet, plugins: [MyPlugin, {OptionalPlugin, required: false}]

  Rules:

    * A plugin only adds. It may not change Fyrlet's tables (its migrations must create tables
      carrying its own name as prefix), replace snapshot authority, or define protocol events.
    * Anything a client can see is declared: `capabilities/0` names it, and contract entries it
      adds are listed in the contract only while its capability is enabled.
    * A credential-checking entry is fail-closed. A request that cannot be authenticated is
      refused; a plugin that fails to load closes its entry and never falls back to anonymous.
    * A required plugin that fails stops Fyrlet from starting. An optional one is isolated: its
      entry is closed, its capabilities are not advertised, and `mix fyrlet.plugins` reports it
      as degraded.
  """

  @doc "A short lowercase name; becomes the HTTP prefix `/api/v1/plugins/<name>/`."
  @callback name() :: String.t()
  @callback version() :: String.t()
  @doc "Capabilities this plugin adds, as `%{name => version}`."
  @callback capabilities() :: %{String.t() => pos_integer()}
  @doc "Capabilities that must already exist (core or an earlier plugin) for this one to work."
  @callback requires() :: [String.t()]
  @doc "Supervised processes."
  @callback children(config :: keyword()) :: [
              Supervisor.child_spec() | module() | {module(), term()}
            ]
  @doc "Absolute directories of namespaced migrations, in order."
  @callback migrations() :: [Path.t()]
  @doc "`Fyrlet.Definition` modules whose operations and subscriptions the plugin adds."
  @callback definitions() :: [module()]
  @doc "Oban queues the plugin's workers need, as `[queue: concurrency]`."
  @callback queues() :: keyword()
  @doc """
  Handles `/api/v1/plugins/<name>/<path>`. Receives the `Plug.Conn` and the remaining path
  segments and must return a sent `Plug.Conn`.
  """
  @callback call(Plug.Conn.t(), [String.t()]) :: Plug.Conn.t()

  @doc """
  Paths (relative to the plugin's prefix) served without credentials. Default none.

  `Fyrlet.Plugins.dispatch/3` enforces this: every other path requires a valid service key
  or user session before `call/2` runs. Each entry is a relative path such as `"ping"` or
  `"events/recent"`; the segment `*` matches any single segment. List a path only when the
  plugin authenticates it another way (for example the webhooks HMAC signature).
  """
  @callback public_paths() :: [String.t()]

  @optional_callbacks requires: 0,
                      public_paths: 0,
                      children: 1,
                      migrations: 0,
                      definitions: 0,
                      queues: 0,
                      call: 2,
                      capabilities: 0
end
