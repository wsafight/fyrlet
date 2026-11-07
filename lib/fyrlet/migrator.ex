defmodule Fyrlet.Migrator do
  @moduledoc """
  Runs Fyrlet's migrations together with the host application's.

  Fyrlet and a host share one `Fyrlet.Repo` (so a business write, its idempotency record
  and the invalidation job commit in one transaction), hence one migration history. The
  host lists its own migration directories:

      config :fyrlet, migration_paths: [{:my_app, "priv/repo/migrations"}]

  An entry is `{otp_app, relative_path}` (resolved inside the release or build) or a
  plain path (resolved against the working directory).
  """

  def core_path, do: Application.app_dir(:fyrlet, "priv/repo/migrations")

  def paths,
    do: [core_path() | Enum.map(host_paths(), &resolve/1)] ++ Fyrlet.Plugins.migration_paths()

  @doc "Runs all pending migrations. Works inside a release, without starting the app."
  def migrate do
    {:ok, _result, _apps} =
      Ecto.Migrator.with_repo(Fyrlet.Repo, fn repo ->
        Ecto.Migrator.run(repo, paths(), :up, all: true)
      end)

    :ok
  end

  defp host_paths, do: Application.get_env(:fyrlet, :migration_paths, [])

  defp resolve({app, path}) when is_atom(app) and is_binary(path),
    do: Application.app_dir(app, path)

  defp resolve(path) when is_binary(path), do: Path.expand(path)
end
