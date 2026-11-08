defmodule Fyrlet.MixProject do
  use Mix.Project

  def project do
    [
      app: :fyrlet,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Fyrlet.Application, []},
      extra_applications: [:logger, :crypto, :runtime_tools, :inets, :ssl, :public_key]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_environment), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8.0"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, "~> 0.21"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.8"},
      {:oban, "~> 2.19"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --only warning,consistency"
      ],
      test: ["fyrlet.migrate --create --quiet", "test"]
    ]
  end
end
