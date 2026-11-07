defmodule Fyrlet.Registry do
  alias Fyrlet.Error

  def validate! do
    for kind <- ["operations", "subscriptions"] do
      Enum.reduce(definitions(), MapSet.new(), fn module, names ->
        Code.ensure_loaded!(module)

        for callback <- [contract: 0, authorize: 3, execute: 3, scope: 3] do
          {name, arity} = callback

          unless function_exported?(module, name, arity),
            do: raise("Missing #{name}/#{arity} in #{inspect(module)}")
        end

        Enum.reduce(Map.fetch!(module.contract(), kind), names, fn {name, specification}, seen ->
          unless Regex.match?(~r/^[a-z][a-z0-9_.]{1,127}$/, name),
            do: raise("Invalid contract name: #{name}")

          if MapSet.member?(seen, name), do: raise("Duplicate #{kind} name: #{name}")

          unless is_map(specification["input"]) and is_map(specification["output"]),
            do: raise("Missing schemas for #{name}")

          Fyrlet.Schema.validate_definition!(specification["input"])
          Fyrlet.Schema.validate_definition!(specification["output"])

          if kind == "operations" and
               specification["kind"] not in ["read", "write", "run", "ingest"],
             do: raise("Invalid operation kind: #{name}")

          if kind == "subscriptions", do: validate_sharing!(module, name, specification)
          if kind == "subscriptions", do: validate_append!(module, name, specification)

          if kind == "operations" and specification["kind"] == "run",
            do: validate_run!(module, name, specification)

          if kind == "operations" and specification["kind"] == "ingest",
            do: validate_ingest!(module, name, specification)

          MapSet.put(seen, name)
        end)
      end)
    end

    validate_presence!()
    :ok
  end

  # `presence` entries are rooms: `%{"input" => schema, "meta" => schema (optional)}`. Who may
  # enter and which room it is come from the definition's `authorize/3` and `scope/3`.
  defp validate_presence!() do
    Enum.reduce(definitions(), MapSet.new(), fn module, seen ->
      Enum.reduce(Map.get(module.contract(), "presence", %{}), seen, fn {name, specification},
                                                                        seen ->
        unless Regex.match?(~r/^[a-z][a-z0-9_.]{1,127}$/, name),
          do: raise("Invalid presence name: #{name}")

        if MapSet.member?(seen, name), do: raise("Duplicate presence name: #{name}")

        unless Fyrlet.Capabilities.enabled?("presence"),
          do: raise("Presence #{name} is declared but the presence capability is not enabled")

        unless is_map(specification["input"]), do: raise("Missing input schema for #{name}")
        Fyrlet.Schema.validate_definition!(specification["input"])

        if Map.has_key?(specification, "meta") do
          meta = specification["meta"]

          unless is_map(meta) and meta["type"] == "object",
            do: raise("The meta schema of #{name} must be an object")

          Fyrlet.Schema.validate_definition!(meta)
        end

        MapSet.put(seen, name)
      end)
    end)
  end

  # `mode: "append"` subscriptions are delivered by the append channel from a stream
  # (`Fyrlet.Features.Stream`): the result is the newest `max_items` items, and updates are batches of
  # new items. Everything a member sees is the same, so per-member filtering, sharing and
  # field-level delta delivery do not apply.
  defp validate_append!(module, name, specification) do
    case specification["mode"] do
      nil ->
        :ok

      "append" ->
        if specification["capability"] != "append",
          do: raise("Subscription #{name} is append mode and must declare capability \"append\"")

        unless Fyrlet.Capabilities.enabled?("append"),
          do:
            raise("Subscription #{name} is append mode but the append capability is not enabled")

        unless function_exported?(module, :stream, 3),
          do:
            raise("Subscription #{name} is append mode and needs stream/3 in #{inspect(module)}")

        max_items = specification["max_items"]

        unless is_integer(max_items) and max_items in 1..500,
          do: raise("Subscription #{name} needs max_items between 1 and 500")

        if specification["output"]["type"] != "array",
          do: raise("Subscription #{name} is append mode and its output must be an array")

        if specification["sharing"] || specification["shared"],
          do: raise("Subscription #{name} cannot combine append mode with sharing")

      other ->
        raise("Subscription #{name} has unknown mode #{inspect(other)}")
    end
  end

  defp validate_sharing!(module, name, specification) do
    case specification["sharing"] do
      nil ->
        :ok

      "identical" ->
        if specification["shared"] == true,
          do: raise("Subscription #{name} cannot be both shared and sharing identical")

        for {function, arity} <- [shared_query: 3, membership: 3] do
          unless function_exported?(module, function, arity),
            do:
              raise(
                "Subscription #{name} shares identically and needs #{function}/#{arity} in #{inspect(module)}"
              )
        end

      other ->
        raise("Subscription #{name} has unknown sharing #{inspect(other)}")
    end
  end

  defp validate_ingest!(module, name, specification) do
    unless Fyrlet.Capabilities.enabled?("ingest"),
      do: raise("Operation #{name} is an ingest but the ingest capability is not enabled")

    unless function_exported?(module, :ingest, 3),
      do: raise("Ingest operation #{name} needs ingest/3 in #{inspect(module)}")

    unless is_map(specification["item_schema"]),
      do: raise("Ingest operation #{name} must be built with Fyrlet.Features.Ingest.operation/2")
  end

  defp validate_run!(module, name, specification) do
    unless Fyrlet.Capabilities.enabled?("runs"),
      do: raise("Operation #{name} is a run but the runs capability is not enabled")

    planning = specification["planning"] || "static"

    callbacks =
      case planning do
        "static" -> [run: 3, step: 3]
        # One planning mode per operation: a dynamic one is driven by advance/3 and has no run/3 plan.
        "dynamic" -> [advance: 3, step: 3]
        other -> raise("Run operation #{name} has unknown planning #{inspect(other)}")
      end

    for {function, arity} <- callbacks do
      unless function_exported?(module, function, arity),
        do: raise("Run operation #{name} needs #{function}/#{arity} in #{inspect(module)}")
    end

    if specification["output"] != Fyrlet.Runs.start_output(),
      do: raise("Run operation #{name} must declare Fyrlet.Runs.start_output() as its output")

    if specification["on_conflict"] not in [nil | Fyrlet.Runs.conflict_policies()],
      do: raise("Run operation #{name} has an invalid on_conflict")
  end

  def fetch(kind, name) when is_binary(name) do
    case index() do
      %{^kind => %{^name => {module, specification}}} -> {:ok, module, specification}
      _unknown -> {:error, Error.not_found()}
    end
  end

  @doc "Forgets the cached contract index; the next lookup rebuilds it."
  def refresh, do: Fyrlet.StaticCache.clear(:registry)

  # `kind => name => {module, specification}`. Contracts are fixed for a set of definition
  # modules, so the index is built once for that set instead of rebuilding every module's
  # contract on every lookup. The first definition that declares a name wins.
  defp index do
    modules = definitions()

    Fyrlet.StaticCache.fetch(:registry, modules, fn ->
      for kind <- ["operations", "subscriptions", "presence"], into: %{} do
        entries =
          Enum.reduce(modules, %{}, fn module, acc ->
            Enum.reduce(Map.get(module.contract(), kind, %{}), acc, fn {name, specification},
                                                                       acc ->
              Map.put_new(acc, name, {module, specification})
            end)
          end)

        {kind, entries}
      end
    end)
  end

  @doc """
  Exports the contract: the operations, subscriptions and presence rooms this server can serve, and
  the capabilities it has enabled. An entry that depends on a capability (`run` and `ingest`
  operations, `append` subscriptions, presence rooms) is listed only when that capability is
  enabled; a client still has to negotiate it to use it.
  """
  def export do
    %{
      "protocol_version" => Fyrlet.Capabilities.protocol_version(),
      "capabilities" => Fyrlet.Capabilities.supported(),
      "contract_version" => "0.1.0",
      "schema_dialect" => "fyrlet-subset",
      "operations" => available(merge("operations")),
      "subscriptions" => available(merge("subscriptions"))
    }
    |> put_presence()
  end

  defp put_presence(contract) do
    rooms = merge("presence")

    if rooms != %{} and Fyrlet.Capabilities.enabled?("presence"),
      do: Map.put(contract, "presence", rooms),
      else: contract
  end

  defp available(entries),
    do: Map.reject(entries, fn {_name, spec} -> not available?(spec) end)

  defp available?(spec) do
    capability =
      spec["capability"] ||
        case spec["kind"] do
          "run" -> "runs"
          "ingest" -> "ingest"
          _other -> nil
        end

    is_nil(capability) or Fyrlet.Capabilities.enabled?(capability)
  end

  defp merge(kind),
    do: Enum.reduce(definitions(), %{}, &Map.merge(&2, Map.get(&1.contract(), kind, %{})))

  @doc "Every registered definition, including built-ins of enabled capabilities."
  def definition_modules do
    configured = Application.fetch_env!(:fyrlet, :definitions) ++ Fyrlet.Plugins.definitions()

    if Fyrlet.Capabilities.enabled?("runs"),
      do: configured ++ [Fyrlet.Runs.Definition],
      else: configured
  end

  defp definitions, do: definition_modules()
end
