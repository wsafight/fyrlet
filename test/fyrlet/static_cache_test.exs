defmodule Fyrlet.StaticCacheTest do
  # The suite runs with the cache off (many tests rewrite contracts); these tests switch it on
  # to cover the path production uses.
  use ExUnit.Case, async: false
  alias Fyrlet.{Plugins, Registry, StaticCache}
  alias Fyrlet.RegistryFixtures.Dynamic

  @contract %{
    "operations" => %{
      "cache.echo" => %{
        "kind" => "read",
        "input" => %{
          "type" => "object",
          "properties" => %{},
          "required" => [],
          "additionalProperties" => false
        },
        "output" => %{"type" => "string"}
      }
    },
    "subscriptions" => %{}
  }

  setup do
    definitions = Application.fetch_env!(:fyrlet, :definitions)
    plugins = Application.fetch_env!(:fyrlet, :plugins)
    Application.put_env(:fyrlet, :runtime_cache, true)

    on_exit(fn ->
      Application.put_env(:fyrlet, :runtime_cache, false)
      Application.put_env(:fyrlet, :definitions, definitions)
      Application.put_env(:fyrlet, :plugins, plugins)
      Application.delete_env(:fyrlet, :registry_test_contract)
      Registry.refresh()
      Plugins.reload()
    end)

    Registry.refresh()
    Plugins.reload()
    :ok
  end

  test "a lookup is computed once and then served from the cache" do
    Application.put_env(:fyrlet, :definitions, [Dynamic])
    Application.put_env(:fyrlet, :registry_test_contract, @contract)
    assert {:ok, Dynamic, %{"kind" => "read"}} = Registry.fetch("operations", "cache.echo")

    # Same definitions, different contract: the cached index is still what is served...
    Application.put_env(:fyrlet, :registry_test_contract, %{
      "operations" => %{},
      "subscriptions" => %{}
    })

    assert {:ok, Dynamic, _} = Registry.fetch("operations", "cache.echo")

    # ...until it is refreshed.
    Registry.refresh()
    assert {:error, %{code: "NOT_FOUND"}} = Registry.fetch("operations", "cache.echo")
  end

  test "changing the set of definitions rebuilds the index by itself" do
    Application.put_env(:fyrlet, :registry_test_contract, @contract)
    Application.put_env(:fyrlet, :definitions, [])
    assert {:error, %{code: "NOT_FOUND"}} = Registry.fetch("operations", "cache.echo")

    Application.put_env(:fyrlet, :definitions, [Dynamic])
    assert {:ok, Dynamic, _} = Registry.fetch("operations", "cache.echo")
  end

  test "the first definition that declares a name wins, as before" do
    defmodule Other do
      def contract,
        do: %{
          "operations" => %{"cache.echo" => %{"kind" => "write", "input" => %{}, "output" => %{}}},
          "subscriptions" => %{}
        }
    end

    Application.put_env(:fyrlet, :registry_test_contract, @contract)
    Application.put_env(:fyrlet, :definitions, [Dynamic, Other])
    assert {:ok, Dynamic, %{"kind" => "read"}} = Registry.fetch("operations", "cache.echo")
    Application.put_env(:fyrlet, :definitions, [Other, Dynamic])
    assert {:ok, Other, %{"kind" => "write"}} = Registry.fetch("operations", "cache.echo")
  end

  test "unknown kinds and names are not found" do
    assert {:error, %{code: "NOT_FOUND"}} = Registry.fetch("operations", "nope.nothing")
    assert {:error, %{code: "NOT_FOUND"}} = Registry.fetch("tables", "inbox.add")
  end

  test "plugins are checked again when the plugin or capability configuration changes" do
    configured = Application.fetch_env!(:fyrlet, :plugins)
    assert Enum.any?(Plugins.load(), &(&1.module == Fyrlet.TestPlugins.Counter))

    Application.put_env(:fyrlet, :plugins, [])
    assert Plugins.load() == []
    refute Fyrlet.Capabilities.enabled?("counter")

    Application.put_env(:fyrlet, :plugins, configured)
    assert Fyrlet.Capabilities.enabled?("counter")

    capabilities = Application.fetch_env!(:fyrlet, :capabilities)
    Application.put_env(:fyrlet, :capabilities, Map.put(capabilities, "extra", 1))
    on_exit(fn -> Application.put_env(:fyrlet, :capabilities, capabilities) end)
    assert Fyrlet.Capabilities.enabled?("extra")
  end

  test "with the cache off every call recomputes" do
    Application.put_env(:fyrlet, :runtime_cache, false)
    counter = :counters.new(1, [])
    compute = fn -> :counters.add(counter, 1, 1) end
    for _ <- 1..3, do: StaticCache.fetch(:probe, :same_key, compute)
    assert :counters.get(counter, 1) == 3

    Application.put_env(:fyrlet, :runtime_cache, true)
    on_exit(fn -> StaticCache.clear(:probe) end)
    for _ <- 1..3, do: StaticCache.fetch(:probe, :same_key, compute)
    assert :counters.get(counter, 1) == 4
  end

  test "concurrent first lookups all get the same, correct answer" do
    Application.put_env(:fyrlet, :definitions, [Dynamic])
    Application.put_env(:fyrlet, :registry_test_contract, @contract)

    results =
      1..50
      |> Task.async_stream(fn _ -> Registry.fetch("operations", "cache.echo") end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, Dynamic, %{"kind" => "read"}}, &1))
  end
end
