defmodule FyrletEffectEmail.MixProject do
  use Mix.Project

  def project do
    [
      app: :fyrlet_effect_email,
      version: "0.1.0",
      elixir: "~> 1.18",
      build_path: "../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger, :inets, :ssl, :public_key]]

  # Implements Fyrlet.Effects.Adapter; its tests need no running Fyrlet.
  defp deps do
    [
      {:fyrlet, path: "../..", runtime: false}
    ]
  end
end
