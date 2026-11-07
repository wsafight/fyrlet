defmodule Fyrlet.Runs.Resolver do
  @moduledoc """
  Finds the implementation pinned to a run's definition version (temp spec §3.8).

  A run records the module and version it was accepted under. It only executes with an
  implementation that declares exactly that version; if none is available the engine
  pauses the run as `definition_unavailable` instead of silently using newer code.
  """

  @default_version "1"

  @doc "The version a definition currently declares for an operation."
  def current_version(module, operation) do
    if function_exported?(module, :definition_version, 1),
      do: to_string(module.definition_version(operation)),
      else: @default_version
  end

  @doc "The registered definition module of a run, or nil."
  def definition(run) do
    module = String.to_existing_atom("Elixir." <> run.definition_module)
    if module in Fyrlet.Registry.definition_modules(), do: module
  rescue
    ArgumentError -> nil
  end

  @doc "The module implementing `run`'s pinned version, or nil when unavailable."
  def implementation(run) do
    with module when not is_nil(module) <- definition(run) do
      Code.ensure_loaded(module)

      if function_exported?(module, :implementation, 2) do
        module.implementation(run.operation, run.definition_version)
      else
        if current_version(module, run.operation) == run.definition_version, do: module
      end
    end
  end
end
