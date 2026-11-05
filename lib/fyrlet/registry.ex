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

          if kind == "operations" and specification["kind"] not in ["read", "write"],
            do: raise("Invalid operation kind: #{name}")

          MapSet.put(seen, name)
        end)
      end)
    end

    :ok
  end

  def fetch(kind, name) when is_binary(name) do
    Enum.find_value(definitions(), {:error, Error.not_found()}, fn module ->
      case get_in(module.contract(), [kind, name]) do
        nil -> nil
        specification -> {:ok, module, specification}
      end
    end)
  end

  def export do
    %{
      "protocol_version" => 1,
      "contract_version" => "0.1.0",
      "schema_dialect" => "realtime-subset-v1",
      "operations" => merge("operations"),
      "subscriptions" => merge("subscriptions")
    }
  end

  defp merge(kind),
    do: Enum.reduce(definitions(), %{}, &Map.merge(&2, Map.fetch!(&1.contract(), kind)))

  defp definitions, do: Application.fetch_env!(:fyrlet, :definitions)
end
