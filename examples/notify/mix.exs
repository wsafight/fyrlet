defmodule NotifyExample.MixProject do
  use Mix.Project

  def project do
    [
      app: :notify_example,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: ["lib", Path.expand("../support/lib", __DIR__)],
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      deps: [
        {:fyrlet, path: "../.."},
        {:fyrlet_effect_http, path: "../../packages/fyrlet_effect_http"},
        {:fyrlet_effect_email, path: "../../packages/fyrlet_effect_email"}
      ],
      aliases: [test: ["fyrlet.migrate --create --quiet", "test"]]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
