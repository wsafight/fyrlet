defmodule Fyrlet.PluginsTest do
  use Fyrlet.DataCase, async: false
  alias Fyrlet.Conformance
  alias Fyrlet.Plugins
  alias Fyrlet.TestPlugins.{Broken, Counter, Mirror}
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]
  @endpoint FyrletWeb.Endpoint

  setup do
    previous = Application.fetch_env!(:fyrlet, :plugins)
    on_exit(fn -> Application.put_env(:fyrlet, :plugins, previous) end)
    :ok
  end

  defp configure(list), do: Application.put_env(:fyrlet, :plugins, list)

  defp status(module),
    do: Plugins.load() |> Enum.find(&(&1.module == module)) |> Map.fetch!(:status)

  describe "loading and isolation" do
    test "valid plugins load in order and a dependent one sees the earlier capability" do
      assert status(Counter) == :ok
      assert status(Mirror) == :ok
      assert Plugins.capabilities() |> Map.keys() |> Enum.sort() == ["counter", "mirror"]
    end

    test "an optional plugin that cannot load is isolated: closed, unadvertised, reported" do
      assert {:error, reason} = status(Broken)
      assert reason =~ "does_not_exist"
      refute Map.has_key?(Fyrlet.Capabilities.supported(), "broken")
      refute Broken in Enum.map(Plugins.active(), & &1.module)

      conn = build_conn() |> get("/api/v1/plugins/broken/anything")
      assert conn.status == 404
      refute conn.resp_body =~ "should never be reachable"
    end

    test "a required plugin that cannot load stops startup" do
      configure([Counter, Broken])

      assert_raise RuntimeError, ~r/Required plugin .*Broken cannot start/, fn ->
        Plugins.validate!()
      end

      configure([{Broken, required: false}, Counter])
      assert :ok = Plugins.validate!()
    end

    test "dependencies are checked in order" do
      configure([Mirror, Counter])
      assert {:error, reason} = status(Mirror)
      assert reason =~ "requires capability counter"
      assert status(Counter) == :ok
    end

    test "names, versions, duplicates and capability clashes are refused" do
      defmodule BadName do
        @behaviour Fyrlet.Plugin
        def name, do: "Bad Name!"
        def version, do: "1.0.0"
      end

      defmodule BadVersion do
        @behaviour Fyrlet.Plugin
        def name, do: "badversion"
        def version, do: "one"
      end

      defmodule Clash do
        @behaviour Fyrlet.Plugin
        def name, do: "clash"
        def version, do: "1.0.0"
        def capabilities, do: %{"counter" => 1}
      end

      configure([
        Counter,
        {BadName, required: false},
        {BadVersion, required: false},
        {Clash, required: false},
        {Counter, required: false},
        {Nope.Missing, required: false}
      ])

      loaded = Plugins.load()
      assert {:error, "invalid name" <> _} = Enum.at(loaded, 1).status
      assert {:error, "version must" <> _} = Enum.at(loaded, 2).status
      assert {:error, "capability counter is already provided"} = Enum.at(loaded, 3).status
      assert {:error, "duplicate plugin name counter"} = Enum.at(loaded, 4).status
      assert {:error, "module is missing" <> _} = Enum.at(loaded, 5).status

      # Of two plugins with one name, the first keeps working and only the second is refused.
      assert Enum.at(loaded, 0).status == :ok
    end

    test "plugin migrations may not touch Fyrlet's tables or create unprefixed ones" do
      dir = Path.join(System.tmp_dir!(), "plugin-mig-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      defmodule Greedy do
        @behaviour Fyrlet.Plugin
        def name, do: "greedy"
        def version, do: "1.0.0"
        def migrations, do: [Application.fetch_env!(:fyrlet, :greedy_dir)]
      end

      Application.put_env(:fyrlet, :greedy_dir, dir)
      on_exit(fn -> Application.delete_env(:fyrlet, :greedy_dir) end)
      configure([{Greedy, required: false}])

      for {source, expected} <- [
            {"alter table(:sessions) do add :x, :text end", "changes Fyrlet's table sessions"},
            {"create table(:projects) do end", "recreates Fyrlet's table projects"},
            {"create table(:other_things) do end", "must be prefixed greedy_"},
            {"drop table(:fyrlet_runs)", "changes Fyrlet's table fyrlet_runs"}
          ] do
        File.write!(Path.join(dir, "1.exs"), source)
        assert {:error, reason} = status(Greedy)
        assert reason =~ expected, reason
      end

      File.write!(Path.join(dir, "1.exs"), "create table(:greedy_items) do end")
      assert status(Greedy) == :ok
      File.rm_rf!(dir)
      assert {:error, reason} = status(Greedy)
      assert reason =~ "does not exist"
    end
  end

  describe "what a loaded plugin adds" do
    test "its definitions join the contract, gated by its capability, and its migrations ran" do
      assert Fyrlet.Migrator.paths() |> Enum.any?(&String.ends_with?(&1, "counter/migrations"))

      assert {:ok, _spec} =
               Fyrlet.Registry.fetch("subscriptions", "counter.total")
               |> then(fn {:ok, _, s} -> {:ok, s} end)

      assert Map.has_key?(Fyrlet.Registry.export()["subscriptions"], "counter.total")
      assert Repo.query!("SELECT count(*) FROM counter_hits").rows == [[0]]
    end

    test "its process is supervised and its queue is merged without touching core queues" do
      assert Process.whereis(:counter_plugin_agent)
      assert Plugins.queues() == [counter: 2]
    end

    test "its subscription carries the capability the contract requires" do
      alice = user(project(), "alice")

      assert {:ok, %{specification: %{"capability" => "counter"}, scope: scope}} =
               Fyrlet.Runtime.prepare_subscription(alice.actor, "counter.total", %{})

      assert scope == "counter:" <> alice.actor.project_id
    end
  end

  describe "its HTTP entry is fail-closed" do
    test "authenticated callers are served; everyone else is refused" do
      project = project()
      alice = user(project, "alice")

      api = fn token ->
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("x-project-id", project.project.id)
      end

      assert json_response(api.(alice.token) |> get("/api/v1/plugins/counter/hits"), 200)[
               "project"
             ] == project.project.id

      assert api.("rts_wrong") |> get("/api/v1/plugins/counter/hits") |> Map.fetch!(:status) ==
               401

      assert build_conn() |> get("/api/v1/plugins/counter/hits") |> Map.fetch!(:status) == 401

      assert build_conn() |> get("/api/v1/plugins/counter/ping") |> Map.fetch!(:resp_body) ==
               "pong"

      assert build_conn() |> get("/api/v1/plugins/nope/x") |> Map.fetch!(:status) == 404
      assert build_conn() |> get("/api/v1/plugins/mirror/x") |> Map.fetch!(:status) == 401
    end

    test "closing the plugin closes the entry, with no fallback to an open path" do
      configure([])
      assert build_conn() |> get("/api/v1/plugins/counter/ping") |> Map.fetch!(:status) == 404
      refute Map.has_key?(Fyrlet.Capabilities.supported(), "counter")
    end
  end

  describe "conformance suite" do
    test "the reference plugins pass" do
      assert Conformance.Plugin.failures(Counter) == []
      assert Conformance.Plugin.failures(Mirror) == []
    end

    test "an open entry, an undeclared capability and a foreign contract section are caught" do
      defmodule Open do
        @behaviour Fyrlet.Plugin
        def name, do: "open"
        def version, do: "1.0.0"
        def call(conn, _path), do: Plug.Conn.send_resp(conn, 200, "come in")
      end

      defmodule LyingDefinition do
        def contract,
          do: %{
            "operations" => %{},
            "subscriptions" => %{"x.y" => %{"capability" => "undeclared"}},
            "events" => %{"custom" => %{}}
          }
      end

      defmodule Lying do
        @behaviour Fyrlet.Plugin
        def name, do: "lying"
        def version, do: "1.0.0"
        def definitions, do: [LyingDefinition]
      end

      assert [{:fail_closed, reason}] = Conformance.Plugin.failures(Open)
      assert reason =~ "without valid credentials"
      failures = Conformance.Plugin.failures(Lying) |> Map.new()
      assert failures[:capabilities_declared] =~ "undeclared"
      assert failures[:contract_only] =~ "events"
    end

    test "a plugin whose process cannot start fails the lifecycle check" do
      defmodule Crashing do
        @behaviour Fyrlet.Plugin
        def name, do: "crashing"
        def version, do: "1.0.0"
        def children(_config), do: [%{id: :boom, start: {__MODULE__, :start, []}}]
        def start, do: {:error, :nope}
      end

      assert [{:lifecycle, reason}] = Conformance.Plugin.failures(Crashing)
      assert reason =~ "failed to start"
    end
  end
end
