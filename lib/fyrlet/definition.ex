defmodule Fyrlet.Definition do
  @moduledoc """
  The application definition facade. Existing definitions use this single behaviour.

  Every definition provides `contract/0`, `authorize/3`, `execute/3` and `scope/3`.
  Optional callbacks belong to the features declared in its contract:

  * Incremental snapshots: `change/4`, `load_subscription/3`, `update_subscription/5`.
  * Identical sharing: `shared_query/3`, `membership/3`, `policy_version/1`.
  * Append subscriptions: `stream/3`.
  * Managed data access: `data_scope/3`.
  * Runs: `run/3` or `advance/3`, `step/3`, `plan_options/3`, `run_authorize/4`,
    `implementation/2`.
  * Ingest: `ingest/3`.

  `definition_version/1` identifies a shared projection or pins a run implementation.
  It defaults to `"1"`; a sharing authorization policy has its own `policy_version/1`.
  `Fyrlet.Registry.validate!/0` checks declared features and their required callbacks
  at startup through `Fyrlet.Definition.Validation`.
  """

  @doc "The current definition version used by shared subscriptions and durable runs."
  def current_version(module, name) do
    Code.ensure_loaded!(module)

    if function_exported?(module, :definition_version, 1),
      do: to_string(module.definition_version(name)),
      else: "1"
  end

  @callback contract() :: map()
  @callback authorize(String.t(), Fyrlet.Actor.t(), map()) :: :ok | {:error, Fyrlet.Error.t()}
  @callback execute(String.t(), Fyrlet.Actor.t(), map()) ::
              {:ok, term(), [String.t()]} | {:error, Fyrlet.Error.t()}
  @callback scope(String.t(), Fyrlet.Actor.t(), map()) :: String.t()
  @callback change(String.t(), Fyrlet.Actor.t(), map(), term()) :: map() | nil
  @callback load_subscription(String.t(), Fyrlet.Actor.t(), map()) ::
              {:ok, term(), map()} | {:error, Fyrlet.Error.t()}
  @callback update_subscription(
              String.t(),
              Fyrlet.Actor.t(),
              map(),
              Fyrlet.Subscriptions.View.t(),
              map()
            ) ::
              {:replace, String.t(), term()}
              | {:reset, term(), map()}
              | {:context, map()}
              | :unchanged
              | :reload

  # Durable runs (capability "runs").
  @doc "Plans a run: `{:ok, steps: [...], business_key: ..., ttl_seconds: ...}` or an error."
  @callback run(String.t(), Fyrlet.Actor.t(), map()) ::
              {:ok, keyword()} | {:error, Fyrlet.Error.t()}
  @doc "Dynamic planning: decides the next node from persisted state and the event that just happened. No I/O."
  @callback advance(String.t(), map(), term()) ::
              {:step, String.t(), map()}
              | {:wait, map()}
              | {:done, map()}
              | {:error, Fyrlet.Error.t()}
  @doc "Business key and lifetime for a dynamically planned run."
  @callback plan_options(String.t(), Fyrlet.Actor.t(), map()) :: keyword()
  @doc "Processes one ingested item inside the transaction that completes it."
  @callback ingest(String.t(), Fyrlet.Actor.t(), map()) :: :ok | {:error, Fyrlet.Error.t()}
  @doc "Shared (`sharing: \"identical\"`) subscriptions: the result for a scope. Receives no actor."
  @callback shared_query(String.t(), map(), map()) ::
              {:ok, term(), map()} | {:error, Fyrlet.Error.t()}
  @doc "Whether an actor may receive an identical shared subscription. Checked before every delivery."
  @callback membership(String.t(), Fyrlet.Actor.t(), map()) :: :member | :not_member
  @doc "Bumped when who may see what changes in a way the scope alone does not show."
  @callback policy_version(String.t()) :: String.t() | integer()
  @doc "Append-mode subscriptions (`mode: \"append\"`): the `Fyrlet.Features.Stream` name that backs it. Checked after `authorize/3`."
  @callback stream(String.t(), Fyrlet.Actor.t(), map()) ::
              {:ok, String.t()} | {:error, Fyrlet.Error.t()}
  @doc "Executes one step of a run. Returns the step's output map or an error."
  @callback step(String.t(), map(), map()) :: {:ok, map()} | {:error, Fyrlet.Error.t()}
  @doc "Authorizes `:start`, `:view`, `:signal` or `:cancel`. Without it only the starter may act."
  @callback run_authorize(String.t(), atom(), Fyrlet.Actor.t(), map()) ::
              :ok | {:error, Fyrlet.Error.t()}
  @doc "The shared projection version, or the version a run is pinned to. Defaults to \"1\"."
  @callback definition_version(String.t()) :: String.t() | integer()
  @doc "The module implementing `version` of an operation, or nil when it is gone."
  @callback implementation(String.t(), String.t()) :: module() | nil

  @doc "Row-level policy for managed access: `{:ok, project: field, subject: field}` or `:unsupported`."
  @callback data_scope(:read | :write, Fyrlet.Actor.t(), map()) :: {:ok, keyword()} | :unsupported

  @optional_callbacks change: 4,
                      data_scope: 3,
                      update_subscription: 5,
                      load_subscription: 3,
                      ingest: 3,
                      shared_query: 3,
                      membership: 3,
                      policy_version: 1,
                      stream: 3,
                      run: 3,
                      advance: 3,
                      plan_options: 3,
                      step: 3,
                      run_authorize: 4,
                      definition_version: 1,
                      implementation: 2
end
