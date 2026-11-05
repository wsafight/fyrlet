defmodule Mix.Tasks.Fyrlet.Project do
  use Mix.Task
  @shortdoc "Creates a project and prints its backend-only service credential"

  def run(arguments) do
    {options, names, invalid} = OptionParser.parse(arguments, strict: [output: :string])
    if invalid != [], do: Mix.raise("Usage: mix fyrlet.project [--output FILE] PROJECT_NAME")
    path = options[:output]
    if path && File.exists?(path), do: Mix.raise("Output file already exists: #{path}")
    Mix.Task.run("app.start")
    name = Enum.join(names, " ")
    if byte_size(name) not in 1..200, do: Mix.raise("Usage: mix fyrlet.project PROJECT_NAME")
    {:ok, result} = Fyrlet.Auth.create_project(name)

    json =
      Jason.encode!(%{
        project_id: result.project.id,
        key_id: result.key_id,
        service_key: result.service_key
      })

    if path do
      File.mkdir_p!(Path.dirname(path))

      File.open!(path, [:write, :exclusive], fn file ->
        File.chmod!(path, 0o600)
        IO.binwrite(file, json <> "\n")
      end)

      Mix.shell().info("Project created; backend credentials saved to #{path}")
    else
      Mix.shell().info(json)
    end
  end
end
