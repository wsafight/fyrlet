defmodule Fyrlet.Registry do
  alias Fyrlet.Error

  def validate!, do: Fyrlet.Definition.Validation.validate!(definition_modules())

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
