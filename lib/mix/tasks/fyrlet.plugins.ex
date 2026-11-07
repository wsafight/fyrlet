defmodule Mix.Tasks.Fyrlet.Plugins do
  use Mix.Task
  @shortdoc "Lists configured plugins, their capabilities and migration state"

  @moduledoc """
  Shows what is configured, what loaded, what was refused and why. Run it first when an entry
  that should exist does not.

      mix fyrlet.plugins
  """

  def run(_arguments) do
    Mix.Task.run("app.config")
    Mix.Task.run("compile")

    plugins = Fyrlet.Plugins.load()
    if plugins == [], do: Mix.shell().info("No plugins configured.")

    for %{module: module, required: required, status: status} <- plugins do
      {state, detail} =
        case status do
          :ok ->
            {"active", ""}

          {:error, reason} ->
            {if(required, do: "FAILED (required)", else: "degraded (optional, entry closed)"),
             reason}
        end

      loaded = Code.ensure_loaded?(module) and function_exported?(module, :name, 0)
      name = if loaded, do: module.name(), else: inspect(module)

      version =
        if loaded and function_exported?(module, :version, 0), do: module.version(), else: "?"

      capabilities =
        if loaded and function_exported?(module, :capabilities, 0),
          do: module.capabilities() |> Map.keys() |> Enum.join(","),
          else: ""

      migrations =
        if loaded and function_exported?(module, :migrations, 0),
          do: length(module.migrations()),
          else: 0

      Mix.shell().info(
        "#{name} #{version}  #{state}  capabilities=[#{capabilities}]  migration_dirs=#{migrations}  #{detail}"
      )
    end
  end
end
