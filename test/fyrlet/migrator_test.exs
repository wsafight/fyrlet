defmodule Fyrlet.MigratorTest do
  use Fyrlet.DataCase, async: false
  alias Fyrlet.Migrator

  test "core, host and plugin migration directories are all included" do
    paths = Migrator.paths()

    assert Migrator.core_path() in paths
    assert Enum.all?(paths, &File.dir?/1), "every configured migration path must exist"

    assert Enum.any?(paths, &String.ends_with?(&1, "test/support/migrations"))
    assert Enum.any?(paths, &String.ends_with?(&1, "plugins/counter/migrations"))
  end

  test "a {otp_app, relative_path} entry resolves inside the build" do
    previous = Application.fetch_env!(:fyrlet, :migration_paths)
    Application.put_env(:fyrlet, :migration_paths, [{:fyrlet, "priv/repo/migrations"}])

    on_exit(fn -> Application.put_env(:fyrlet, :migration_paths, previous) end)

    assert Application.app_dir(:fyrlet, "priv/repo/migrations") == Migrator.core_path()
    assert Migrator.core_path() in Migrator.paths()
  end

  test "a plain path is expanded against the working directory" do
    previous = Application.fetch_env!(:fyrlet, :migration_paths)

    Application.put_env(:fyrlet, :migration_paths, [
      "test/support/migrations",
      Path.join(["test", "support", "migrations"])
    ])

    on_exit(fn -> Application.put_env(:fyrlet, :migration_paths, previous) end)

    resolved =
      Migrator.paths()
      |> Enum.filter(&String.ends_with?(&1, "test/support/migrations"))

    assert length(resolved) == 2
    assert Enum.all?(resolved, &(Path.type(&1) == :absolute))
  end

  test "migrate/0 is idempotent on an up-to-date database" do
    assert :ok = Migrator.migrate()
    assert :ok = Migrator.migrate()
  end

  test "the release helper runs the same migrations" do
    assert :ok = Fyrlet.Release.migrate()
  end
end
