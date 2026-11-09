defmodule Fyrlet.ConformancePluginTest do
  use ExUnit.Case, async: false
  alias Fyrlet.Conformance.Plugin, as: Conformance
  alias Fyrlet.TestPlugins.Counter

  setup do
    previous = Application.fetch_env!(:fyrlet, :plugins)

    on_exit(fn ->
      Application.put_env(:fyrlet, :plugins, previous)
      Application.delete_env(:fyrlet, :conformance_dir)
    end)

    :ok
  end

  # The deliberately missing `version/0` is what the shape check must report; not declaring
  # `@behaviour` keeps that a property of the fixture rather than a compile warning here
  # (`Fyrlet.Conformance.Plugin` checks exported functions, not the behaviour declaration).
  defmodule NoVersion do
    def name, do: "noversion"
  end

  defmodule BadCapabilities do
    @behaviour Fyrlet.Plugin
    def name, do: "badcaps"
    def version, do: "1.0.0"
    def capabilities, do: %{"zero" => 0, "text" => "one"}
  end

  defmodule BadRequires do
    @behaviour Fyrlet.Plugin
    def name, do: "badrequires"
    def version, do: "1.0.0"
    def requires, do: ["ok", 2]
  end

  defmodule Loose do
    @behaviour Fyrlet.Plugin
    def name, do: "loose"
    def version, do: "1.0.0"
  end

  defmodule UnconfiguredBroken do
    @behaviour Fyrlet.Plugin
    def name, do: "unconfiguredbroken"
    def version, do: "1.0.0"
    def requires, do: ["missing_everywhere"]
  end

  defmodule Silent do
    @behaviour Fyrlet.Plugin
    def name, do: "silent"
    def version, do: "1.0.0"
    def call(conn, _path), do: conn
  end

  defmodule Live do
    @behaviour Fyrlet.Plugin
    def name, do: "live"
    def version, do: "1.0.0"

    def children(_config),
      do: [%{id: :live_agent, start: {Agent, :start_link, [fn -> :ok end]}}]
  end

  defmodule Migrating do
    @behaviour Fyrlet.Plugin
    def name, do: "migrating"
    def version, do: "1.0.0"
    def migrations, do: [Application.fetch_env!(:fyrlet, :conformance_dir)]
  end

  test "run/1 reports every check and the reference plugin passes all of them" do
    checks = Conformance.run(Counter)

    assert Enum.map(checks, &elem(&1, 0)) == [
             :shape,
             :identity,
             :migrations,
             :capabilities_declared,
             :contract_only,
             :fail_closed,
             :lifecycle
           ]

    assert Enum.all?(checks, fn {_name, result} -> result == :ok end)
    assert Conformance.failures(Counter) == []
  end

  test "shapes are checked before anything else" do
    assert [{:shape, "module cannot be loaded"}] =
             Conformance.failures(NotARealModule.Anywhere)

    assert [{:shape, "name/0 and version/0 are required"}] =
             Conformance.failures(NoVersion)

    assert [{:shape, "capabilities/0 must return %{name => positive integer}"}] =
             Conformance.failures(BadCapabilities)

    assert [{:shape, "requires/0 must return a list of names"}] =
             Conformance.failures(BadRequires)
  end

  test "a plugin that is not configured is probed without changing the configuration" do
    assert Conformance.failures(Loose) == []
    refute Loose in Enum.map(Fyrlet.Plugins.load(), & &1.module)

    failures = Conformance.failures(UnconfiguredBroken)
    assert {:identity, reason} = List.keyfind(failures, :identity, 0)
    assert reason =~ "missing_everywhere"
  end

  test "a configured plugin that failed to load reports the same reason" do
    [{:identity, reason}] = Conformance.failures(Fyrlet.TestPlugins.Broken)
    assert reason =~ "does_not_exist"
  end

  test "its migrations may neither touch core tables nor create foreign ones" do
    dir = Path.join(System.tmp_dir!(), "conformance-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    Application.put_env(:fyrlet, :conformance_dir, dir)

    File.write!(Path.join(dir, "1.exs"), "alter table(:sessions) do end")
    failures = Conformance.failures(Migrating) |> Map.new()
    assert failures[:migrations] =~ "changes Fyrlet's table sessions"

    File.write!(Path.join(dir, "1.exs"), "create table(:not_prefixed) do end")
    failures = Conformance.failures(Migrating) |> Map.new()
    assert failures[:migrations] =~ "not prefixed migrating_"

    File.write!(Path.join(dir, "1.exs"), "create table(:migrating_items) do end")
    assert Map.get(Conformance.failures(Migrating) |> Map.new(), :migrations) == nil
  end

  test "an entry that never sends a response is treated as unreachable" do
    [{:fail_closed, reason}] = Conformance.failures(Silent)
    assert reason =~ "answered 500"
  end

  test "a plugin whose processes start and stop cleanly passes lifecycle" do
    assert Conformance.failures(Live) == []
  end
end
