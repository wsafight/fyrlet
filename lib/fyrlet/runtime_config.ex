defmodule Fyrlet.RuntimeConfig do
  @moduledoc """
  Runtime settings read from the environment.

  A host application's `config/runtime.exs` cannot rely on Fyrlet's own config files
  (dependencies' config is not loaded), so it calls this instead:

      import Config
      config :fyrlet, Fyrlet.RuntimeConfig.settings(config_env())

  Supported variables: `DATABASE_URL`, `POOL_SIZE`, `PORT`, `PHX_SERVER`,
  `CORS_ORIGINS`, `SECRET_KEY_BASE` and `ALLOWED_ORIGINS` (both required in `:prod`),
  `FYRLET_OBSERVER_HIBERNATE_AFTER_MS` and
  `FYRLET_MAX_SUBSCRIPTIONS_PER_NODE` (the node-wide channel ceiling),
  `FYRLET_IDEMPOTENCY_TTL_SECONDS`, `FYRLET_CLUSTER_NODES` (comma-separated name@host peers),
  and the per-project defaults `FYRLET_PROJECT_READS_PER_SECOND`, `FYRLET_PROJECT_WRITES_PER_SECOND`
  and `FYRLET_PROJECT_MAX_SUBSCRIPTIONS` (see `Fyrlet.Quota`), `FYRLET_INGEST_RETENTION_SECONDS`
  (seconds, or `forever`; see `Fyrlet.Retention`) and `FYRLET_METRICS_TOKEN`
  (enables `GET /metrics`; see `Fyrlet.Metrics`).
  """

  @default_cors "http://localhost:5173,http://127.0.0.1:5173"

  @doc "Returns a keyword list suitable for `config :fyrlet, settings`."
  def settings(env, get_env \\ &System.get_env/1) do
    repo =
      compact(
        pool_size: integer(get_env, "POOL_SIZE", 1, 10_000),
        url: get_env.("DATABASE_URL")
      )

    endpoint = endpoint(env, get_env)

    if env == :prod and is_nil(get_env.("DATABASE_URL")),
      do: raise("environment variable DATABASE_URL is missing")

    compact(
      observer_hibernate_after: hibernate(get_env),
      idempotency_ttl: integer(get_env, "FYRLET_IDEMPOTENCY_TTL_SECONDS", 1),
      max_subscriptions_per_node:
        integer(get_env, "FYRLET_MAX_SUBSCRIPTIONS_PER_NODE", 1, 1_000_000),
      cluster_nodes: cluster_nodes(get_env.("FYRLET_CLUSTER_NODES")),
      quotas: quotas(get_env),
      retention: retention(get_env),
      metrics: metrics(get_env.("FYRLET_METRICS_TOKEN")),
      cors_origins: split(get_env.("CORS_ORIGINS") || @default_cors)
    ) ++
      if(repo == [], do: [], else: [{Fyrlet.Repo, repo}]) ++
      if(endpoint == [], do: [], else: [{FyrletWeb.Endpoint, endpoint}])
  end

  defp endpoint(:test, _get_env), do: []

  defp endpoint(env, get_env) do
    http = [
      http: [
        ip: if(env == :prod, do: {0, 0, 0, 0}, else: {127, 0, 0, 1}),
        port: integer(get_env, "PORT", 1, 65_535) || 4000
      ]
    ]

    server = if get_env.("PHX_SERVER") in ["true", "1"], do: [server: true], else: []

    production =
      if env == :prod do
        [
          secret_key_base: required(get_env, "SECRET_KEY_BASE"),
          check_origin: split(required(get_env, "ALLOWED_ORIGINS"))
        ]
      else
        []
      end

    http ++ server ++ production
  end

  defp required(get_env, name),
    do: get_env.(name) || raise("environment variable #{name} is missing")

  defp hibernate(get_env) do
    case get_env.("FYRLET_OBSERVER_HIBERNATE_AFTER_MS") do
      nil -> nil
      "infinity" -> :infinity
      _value -> integer(get_env, "FYRLET_OBSERVER_HIBERNATE_AFTER_MS", 0)
    end
  end

  # A whole number in `min..max`, or an error that names the variable: a bare
  # `String.to_integer/1` failure says nothing about which setting was wrong.
  defp integer(get_env, name, min, max \\ nil) do
    with value when is_binary(value) <- get_env.(name),
         {number, ""} <- Integer.parse(String.trim(value)),
         true <- number >= min and (is_nil(max) or number <= max) do
      number
    else
      nil ->
        nil

      _invalid ->
        range = if max, do: "between #{min} and #{max}", else: "at least #{min}"
        raise ArgumentError, "environment variable #{name} must be a whole number #{range}"
    end
  end

  # Defaults for every project; per-project overrides are set in application config.
  defp quotas(get_env) do
    default =
      compact(
        reads_per_second: integer(get_env, "FYRLET_PROJECT_READS_PER_SECOND", 1, 1_000_000),
        writes_per_second: integer(get_env, "FYRLET_PROJECT_WRITES_PER_SECOND", 1, 1_000_000),
        max_subscriptions: integer(get_env, "FYRLET_PROJECT_MAX_SUBSCRIPTIONS", 1, 1_000_000)
      )

    if default == [], do: nil, else: [default: default]
  end

  # Retention default for every project; per-project overrides are set in application config.
  # "forever" keeps finished ingest data indefinitely.
  defp retention(get_env) do
    case get_env.("FYRLET_INGEST_RETENTION_SECONDS") do
      nil ->
        nil

      "forever" ->
        [default: [ingest_seconds: nil]]

      _seconds ->
        [default: [ingest_seconds: integer(get_env, "FYRLET_INGEST_RETENTION_SECONDS", 60)]]
    end
  end

  defp metrics(nil), do: nil
  defp metrics(token), do: [token: token]

  defp cluster_nodes(nil), do: nil
  defp cluster_nodes(value), do: Fyrlet.Cluster.nodes(value)

  # Entries are trimmed: "//a.example, //b.example" would otherwise keep a leading space on the
  # second origin, which then never matches.
  defp split(value),
    do:
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

  defp compact(list), do: Enum.reject(list, fn {_key, value} -> is_nil(value) end)
end
