defmodule Mix.Tasks.Fyrlet.Contract do
  use Mix.Task
  @shortdoc "Exports the registered contract without starting the HTTP server"

  @moduledoc """
  Exports the registered contract.

      mix fyrlet.contract [OUTPUT_JSON]

  Without an output path the JSON is printed.
  """

  def run(arguments) do
    {_options, arguments} = OptionParser.parse!(arguments, strict: [])

    Mix.Task.run("compile")
    Fyrlet.Registry.validate!()
    json = Jason.encode!(Fyrlet.Registry.export(), pretty: true) <> "\n"

    case arguments do
      [] ->
        Mix.shell().info(json)

      [path] ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, json)

      _invalid ->
        Mix.raise("Usage: mix fyrlet.contract [OUTPUT_JSON]")
    end
  end
end
