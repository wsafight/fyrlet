defmodule Mix.Tasks.Fyrlet.Migrate do
  use Mix.Task
  @shortdoc "Runs Fyrlet's and the host application's pending migrations"

  @moduledoc """
  Runs the migrations of Fyrlet and of the directories in `config :fyrlet, migration_paths`.

      mix fyrlet.migrate [--create] [--quiet]

  `--create` creates the database first when it does not exist.
  """

  def run(arguments) do
    {options, _rest} = OptionParser.parse!(arguments, strict: [create: :boolean, quiet: :boolean])
    quiet = if options[:quiet], do: ["--quiet"], else: []

    Mix.Task.run("app.config")
    if options[:create], do: Mix.Task.run("ecto.create", ["-r", "Fyrlet.Repo"] ++ quiet)

    paths = Enum.flat_map(Fyrlet.Migrator.paths(), &["--migrations-path", &1])
    Mix.Task.run("ecto.migrate", ["-r", "Fyrlet.Repo"] ++ paths ++ quiet)
  end
end
