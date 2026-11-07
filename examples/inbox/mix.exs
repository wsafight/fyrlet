defmodule InboxExample.MixProject do
  use Mix.Project

  def project do
    [
      app: :inbox_example,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      # Share the repository's downloaded dependencies and lock file; an application
      # outside this repository would fetch its own.
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      deps: [{:fyrlet, path: "../.."}],
      aliases: [test: ["fyrlet.migrate --create --quiet", "test"]]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_environment), do: ["lib"]
end
