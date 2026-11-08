defmodule Fyrlet.Plugins do
  @moduledoc """
  Loads, validates and reports plugins. See `Fyrlet.Plugin` for the contract.

  `load/0` is pure with respect to the running system: it returns, for every configured plugin,
  either `:ok` or the reason it cannot be used, so a failure is visible before anything starts.
  """
  alias Fyrlet.Error

  @name ~r/^[a-z][a-z0-9_]{1,31}$/
  @version ~r/^\d+\.\d+\.\d+$/
  @core_tables ~w(projects service_keys subjects sessions idempotency_results inbox_items oban_jobs fyrlet_runs fyrlet_run_steps fyrlet_run_attempts fyrlet_run_signals fyrlet_run_events fyrlet_execution_grants fyrlet_effects fyrlet_effect_events fyrlet_executors fyrlet_ingest_batches fyrlet_ingest_items fyrlet_streams fyrlet_stream_entries schema_migrations)

  @doc """
  Configured plugins as `[%{module, required, status}]` in order. The result depends only on
  the plugin and capability configuration, so it is computed once per configuration (this is
  called by every capability check, i.e. on every request).
  """
  def load do
    key = {Application.get_env(:fyrlet, :plugins, []), core_capabilities()}
    Fyrlet.StaticCache.fetch(:plugins, key, &compute/0)
  end

  @doc "Forgets the cached result; the next call checks the plugins again."
  def reload, do: Fyrlet.StaticCache.clear(:plugins)

  defp compute do
    entries = Application.get_env(:fyrlet, :plugins, []) |> Enum.map(&normalise/1)

    # Plugins are taken in order. A name or capability already taken by an earlier plugin that
    # loaded is refused for the later one; the earlier one is never disturbed.
    {loaded, _state} =
      Enum.map_reduce(entries, {core_capabilities(), MapSet.new()}, fn entry,
                                                                       {available, names} ->
        status = check(entry.module, available, names)

        state =
          if status == :ok,
            do:
              {merge(available, capabilities(entry.module)),
               MapSet.put(names, entry.module.name())},
            else: {available, names}

        {%{entry | status: status}, state}
      end)

    loaded
  end

  def active, do: for(%{status: :ok} = entry <- load(), do: entry)

  @doc "Raises when a required plugin is unusable. Optional failures are left in the report."
  def validate! do
    case Enum.find(load(), &(&1.required and &1.status != :ok)) do
      nil ->
        :ok

      %{module: module, status: {:error, reason}} ->
        raise "Required plugin #{inspect(module)} cannot start: #{reason}"
    end
  end

  def definitions, do: Enum.flat_map(active(), &call(&1.module, :definitions, []))
  def capabilities, do: Enum.reduce(active(), %{}, &merge(&2, capabilities(&1.module)))
  def queues, do: Enum.flat_map(active(), &call(&1.module, :queues, []))
  def migration_paths, do: Enum.flat_map(active(), &call(&1.module, :migrations, []))

  def children do
    for %{module: module} <- active(), child <- call(module, :children, [[]], []), do: child
  end

  @doc """
  Routes `/api/v1/plugins/<name>/...`. Unknown, closed or failed plugins answer 404.

  Authentication is enforced here, not left to each plugin: only paths listed in the plugin's
  `public_paths/0` (segments, `*` matches one segment) are served anonymously. Everything else
  needs a valid service key or user session before the plugin's `call/2` runs, so a plugin
  that forgets to check credentials is still closed.
  """
  def dispatch(conn, name, rest) do
    case Enum.find(active(), &(&1.module.name() == name)) do
      nil ->
        FyrletWeb.Response.error(conn, Error.not_found())

      %{module: module} ->
        cond do
          not function_exported?(module, :call, 2) ->
            FyrletWeb.Response.error(conn, Error.not_found())

          public_path?(module, rest) or authenticated?(conn) ->
            module.call(conn, rest)

          true ->
            FyrletWeb.Response.error(conn, Error.unauthorized())
        end
    end
  end

  defp public_path?(module, rest) do
    module
    |> call(:public_paths, [])
    |> Enum.any?(fn pattern ->
      segments = String.split(pattern, "/", trim: true)

      length(segments) == length(rest) and
        Enum.zip(segments, rest)
        |> Enum.all?(fn {segment, part} ->
          segment == "*" or segment == part
        end)
    end)
  end

  defp authenticated?(conn) do
    with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization") do
      case Fyrlet.Auth.authenticate_key(token) do
        {:ok, _key} -> true
        {:error, _reason} -> session?(conn, token)
      end
    else
      _no_bearer -> false
    end
  end

  defp session?(conn, token) do
    with [project_id] <- Plug.Conn.get_req_header(conn, "x-project-id"),
         {:ok, _actor} <- Fyrlet.Auth.authenticate(token, project_id) do
      true
    else
      _no_session -> false
    end
  end

  # ---- validation ---------------------------------------------------------------------

  defp check(module, available, names) do
    with :ok <- loadable(module),
         :ok <- identity(module, names),
         :ok <- requirements(module, available),
         :ok <- unique_capabilities(module, available),
         :ok <- migrations(module),
         :ok <- definitions_ok(module) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp loadable(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :name, 0) and
         function_exported?(module, :version, 0),
       do: :ok,
       else: {:error, "module is missing or does not implement name/0 and version/0"}
  end

  defp identity(module, names) do
    name = module.name()

    cond do
      not (is_binary(name) and Regex.match?(@name, name)) ->
        {:error, "invalid name #{inspect(name)}"}

      not (is_binary(module.version()) and Regex.match?(@version, module.version())) ->
        {:error, "version must be MAJOR.MINOR.PATCH"}

      MapSet.member?(names, name) ->
        {:error, "duplicate plugin name #{name}"}

      true ->
        :ok
    end
  end

  defp requirements(module, available) do
    missing = call(module, :requires, []) |> Enum.reject(&Map.has_key?(available, &1))

    if missing == [],
      do: :ok,
      else: {:error, "requires capability #{Enum.join(missing, ", ")} which is not available"}
  end

  defp unique_capabilities(module, available) do
    clash = module |> capabilities() |> Map.keys() |> Enum.filter(&Map.has_key?(available, &1))

    if clash == [],
      do: :ok,
      else: {:error, "capability #{Enum.join(clash, ", ")} is already provided"}
  end

  defp migrations(module) do
    name = module.name()

    problems =
      for path <- call(module, :migrations, []),
          file <- Path.wildcard(Path.join(path, "*.exs")),
          problem <- migration_problems(File.read!(file), name),
          do: "#{Path.basename(file)}: #{problem}"

    missing =
      for path <- call(module, :migrations, []),
          not File.dir?(path),
          do: "migration directory #{path} does not exist"

    case missing ++ problems do
      [] -> :ok
      [first | _] -> {:error, first}
    end
  end

  # Plugins add tables of their own. Touching Fyrlet's tables, or creating one that is not
  # clearly the plugin's, is refused.
  defp migration_problems(source, plugin) do
    touched =
      Regex.scan(~r/(?:alter|drop|rename)\s+table\(\s*:(\w+)/, source) |> Enum.map(&List.last/1)

    created =
      Regex.scan(~r/create(?:_if_not_exists)?\s+table\(\s*:(\w+)/, source)
      |> Enum.map(&List.last/1)

    Enum.flat_map(touched, fn table ->
      if table in @core_tables, do: ["changes Fyrlet's table #{table}"], else: []
    end) ++
      Enum.flat_map(created, fn table ->
        cond do
          table in @core_tables ->
            ["recreates Fyrlet's table #{table}"]

          not String.starts_with?(table, plugin <> "_") ->
            ["table #{table} must be prefixed #{plugin}_"]

          true ->
            []
        end
      end)
  end

  defp definitions_ok(module) do
    Enum.reduce_while(call(module, :definitions, []), :ok, fn definition, :ok ->
      if Code.ensure_loaded?(definition) and function_exported?(definition, :contract, 0),
        do: {:cont, :ok},
        else: {:halt, {:error, "#{inspect(definition)} is not a Fyrlet.Definition"}}
    end)
  end

  # ---- helpers ------------------------------------------------------------------------

  defp normalise({module, options}) when is_atom(module) and is_list(options),
    do: %{module: module, required: Keyword.get(options, :required, true), status: :pending}

  defp normalise(module) when is_atom(module),
    do: %{module: module, required: true, status: :pending}

  defp core_capabilities, do: Application.get_env(:fyrlet, :capabilities, %{})

  defp capabilities(module), do: call(module, :capabilities, [], %{})
  defp merge(left, right), do: Map.merge(left, right)

  defp call(module, function, default), do: call(module, function, [], default)

  defp call(module, function, arguments, default) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(arguments)),
      do: apply(module, function, arguments),
      else: default
  rescue
    exception ->
      require Logger

      Logger.warning(
        "Plugin #{inspect(module)}.#{function} raised, using its fail-closed default: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      default
  end

  def core_tables, do: @core_tables
end
