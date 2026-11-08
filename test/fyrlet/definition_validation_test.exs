defmodule Fyrlet.DefinitionValidationTest do
  use ExUnit.Case, async: false
  alias Fyrlet.{Registry, Schema, ValidationFixtures}

  setup do
    previous =
      for key <- [:definitions, :capabilities, :validation_test_contract], into: %{} do
        {key, Application.fetch_env(:fyrlet, key)}
      end

    Application.put_env(:fyrlet, :capabilities, %{
      "runs" => 1,
      "ingest" => 1,
      "append" => 1,
      "presence" => 1
    })

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, configured} -> Application.put_env(:fyrlet, key, configured)
          :error -> Application.delete_env(:fyrlet, key)
        end
      end
    end)
  end

  test "core definitions require no optional capabilities or callbacks" do
    Application.put_env(:fyrlet, :capabilities, %{})

    configure(ValidationFixtures.Core, %{"demo.read" => operation()}, %{
      "demo.watch" => subscription()
    })

    assert :ok = Registry.validate!()
  end

  test "subscription snapshot ceilings accept positive values up to the node ceiling" do
    for limit <- [1, 32_768, Application.fetch_env!(:fyrlet, :max_snapshot_bytes)] do
      configure(ValidationFixtures.Core, %{}, %{
        "demo.watch" => Map.put(subscription(), "max_snapshot_bytes", limit)
      })

      assert :ok = Registry.validate!()
    end
  end

  test "subscription snapshot ceilings reject invalid values and attempts to raise the node ceiling" do
    for limit <- [
          nil,
          0,
          -1,
          1.5,
          "128",
          Application.fetch_env!(:fyrlet, :max_snapshot_bytes) + 1
        ] do
      configure(ValidationFixtures.Core, %{}, %{
        "demo.watch" => Map.put(subscription(), "max_snapshot_bytes", limit)
      })

      assert_invalid(~r/needs max_snapshot_bytes between/)
    end
  end

  test "definition versions have no implicit default" do
    assert_raise UndefinedFunctionError, fn ->
      Fyrlet.Definition.current_version(ValidationFixtures.Core, "demo.read")
    end
  end

  test "definition versions preserve operation-specific strings and normalize integers" do
    for {operation, version} <- [{"demo.numeric", "2"}, {"demo.named", "release-3"}] do
      assert Fyrlet.Definition.current_version(ValidationFixtures.Versioned, operation) == version
    end
  end

  test "static runs accept the default planning mode and every conflict policy" do
    for policy <- [nil | Fyrlet.Runs.conflict_policies()] do
      configure(ValidationFixtures.StaticRun, %{
        "demo.run" => Map.put(run(), "on_conflict", policy)
      })

      assert :ok = Registry.validate!()
    end
  end

  test "dynamic runs work with advance and step without a static planner" do
    configure(ValidationFixtures.DynamicRun, %{
      "demo.run" => Map.put(run(), "planning", "dynamic")
    })

    assert :ok = Registry.validate!()
  end

  test "runs cannot be declared when their capability is disabled" do
    disable("runs")
    configure(ValidationFixtures.StaticRun, %{"demo.run" => run()})
    assert_invalid(~r/runs capability is not enabled/)
  end

  test "a static run needs its planner callback" do
    configure(ValidationFixtures.Core, %{"demo.run" => run()})
    assert_invalid(~r/needs run\/3/)
  end

  test "a run needs its step executor even when its planner exists" do
    configure(ValidationFixtures.RunWithoutStep, %{"demo.run" => run()})
    assert_invalid(~r/needs step\/3/)
  end

  test "a run needs an explicit definition version" do
    configure(ValidationFixtures.RunWithoutVersion, %{"demo.run" => run()})
    assert_invalid(~r/needs definition_version\/1/)
  end

  test "a run needs an explicit pinned implementation resolver" do
    configure(ValidationFixtures.RunWithoutImplementation, %{"demo.run" => run()})
    assert_invalid(~r/needs implementation\/2/)
  end

  test "a historical run whose resolver was removed is unavailable instead of crashing recovery" do
    Application.put_env(:fyrlet, :definitions, [ValidationFixtures.RunWithoutImplementation])

    run = %{
      definition_module: inspect(ValidationFixtures.RunWithoutImplementation),
      operation: "demo.run",
      definition_version: "1"
    }

    assert Fyrlet.Runs.Resolver.implementation(run) == nil
  end

  test "a static planner cannot substitute for a dynamic planner" do
    configure(ValidationFixtures.StaticRun, %{"demo.run" => Map.put(run(), "planning", "dynamic")})

    assert_invalid(~r/needs advance\/3/)
  end

  test "unknown planning modes are rejected" do
    for mode <- ["", "hybrid", 2] do
      configure(ValidationFixtures.StaticRun, %{"demo.run" => Map.put(run(), "planning", mode)})
      assert_invalid(~r/unknown planning/)
    end
  end

  test "run start outputs must match the runtime receipt schema" do
    configure(ValidationFixtures.StaticRun, %{
      "demo.run" => Map.put(run(), "output", %{"type" => "string"})
    })

    assert_invalid(~r/must declare Fyrlet.Runs.start_output/)
  end

  test "unknown run conflict policies are rejected" do
    configure(ValidationFixtures.StaticRun, %{
      "demo.run" => Map.put(run(), "on_conflict", "replace")
    })

    assert_invalid(~r/invalid on_conflict/)
  end

  test "ingest definitions accept their capability, callback and item schema together" do
    configure(ValidationFixtures.Ingest, %{"demo.ingest" => ingest()})
    assert :ok = Registry.validate!()
  end

  test "ingest definitions require the enabled capability" do
    disable("ingest")
    configure(ValidationFixtures.Ingest, %{"demo.ingest" => ingest()})
    assert_invalid(~r/ingest capability is not enabled/)
  end

  test "ingest definitions require ingest even when execute exists" do
    configure(ValidationFixtures.Core, %{"demo.ingest" => ingest()})
    assert_invalid(~r/needs ingest\/3/)
  end

  test "ingest definitions require an item schema" do
    for schema <- [nil, "invalid"] do
      configure(ValidationFixtures.Ingest, %{
        "demo.ingest" => Map.put(ingest(), "item_schema", schema)
      })

      assert_invalid(~r/must be built with Fyrlet.Features.Ingest.operation/)
    end
  end

  test "append definitions accept both retention boundaries" do
    for max_items <- [1, 500] do
      configure(ValidationFixtures.Append, %{}, %{
        "demo.feed" => Map.put(append(), "max_items", max_items)
      })

      assert :ok = Registry.validate!()
    end
  end

  test "append definitions require explicit capability metadata" do
    configure(ValidationFixtures.Append, %{}, %{"demo.feed" => Map.delete(append(), "capability")})

    assert_invalid(~r/must declare capability "append"/)
  end

  test "append definitions require the enabled capability" do
    disable("append")
    configure(ValidationFixtures.Append, %{}, %{"demo.feed" => append()})
    assert_invalid(~r/append capability is not enabled/)
  end

  test "append definitions require their stream callback" do
    configure(ValidationFixtures.Core, %{}, %{"demo.feed" => append()})
    assert_invalid(~r/needs stream\/3/)
  end

  test "append retention must be an integer between one and five hundred" do
    for max_items <- [nil, 0, -1, 501, 1.5, "10"] do
      configure(ValidationFixtures.Append, %{}, %{
        "demo.feed" => Map.put(append(), "max_items", max_items)
      })

      assert_invalid(~r/max_items between 1 and 500/)
    end
  end

  test "append output must be an array" do
    configure(ValidationFixtures.Append, %{}, %{
      "demo.feed" => Map.put(append(), "output", %{"type" => "string"})
    })

    assert_invalid(~r/output must be an array/)
  end

  test "append mode cannot be combined with either sharing mechanism" do
    for {key, value, module} <- [
          {"shared", true, ValidationFixtures.Append},
          {"sharing", "identical", ValidationFixtures.Shared}
        ] do
      specification = Map.put(append(), key, value)
      configure(module, %{}, %{"demo.feed" => specification})

      assert_invalid(~r/cannot combine append mode with sharing/)
    end
  end

  test "unknown subscription modes are rejected" do
    configure(ValidationFixtures.Core, %{}, %{
      "demo.watch" => Map.put(subscription(), "mode", "tail")
    })

    assert_invalid(~r/unknown mode/)
  end

  test "identical sharing accepts query and membership callbacks" do
    configure(ValidationFixtures.Shared, %{}, %{"demo.watch" => shared()})
    assert :ok = Registry.validate!()
  end

  test "identical sharing requires a shared query" do
    configure(ValidationFixtures.Core, %{}, %{"demo.watch" => shared()})
    assert_invalid(~r/needs shared_query\/3/)
  end

  test "identical sharing requires membership even when query exists" do
    configure(ValidationFixtures.SharedWithoutMembership, %{}, %{"demo.watch" => shared()})
    assert_invalid(~r/needs membership\/3/)
  end

  test "identical sharing requires an explicit projection version" do
    configure(ValidationFixtures.SharedWithoutVersion, %{}, %{"demo.watch" => shared()})
    assert_invalid(~r/needs definition_version\/1/)
  end

  test "identical and per-member sharing cannot be combined" do
    configure(ValidationFixtures.Shared, %{}, %{"demo.watch" => Map.put(shared(), "shared", true)})

    assert_invalid(~r/cannot be both shared and sharing identical/)
  end

  test "unknown sharing modes are rejected" do
    configure(ValidationFixtures.Core, %{}, %{
      "demo.watch" => Map.put(subscription(), "sharing", "partial")
    })

    assert_invalid(~r/unknown sharing/)
  end

  test "presence can declare an optional object metadata schema" do
    for specification <- [
          presence(),
          Map.put(presence(), "meta", Schema.object(%{"page" => %{"type" => "string"}}))
        ] do
      configure_presence(%{"demo.room" => specification})
      assert :ok = Registry.validate!()
    end
  end

  test "presence requires the enabled capability" do
    disable("presence")
    configure_presence(%{"demo.room" => presence()})
    assert_invalid(~r/presence capability is not enabled/)
  end

  test "presence rejects missing input and non-object metadata" do
    configure_presence(%{"demo.room" => %{}})
    assert_invalid(~r/Missing input schema/)

    for meta <- [nil, "invalid", %{"type" => "string"}] do
      configure_presence(%{"demo.room" => Map.put(presence(), "meta", meta)})
      assert_invalid(~r/meta schema of demo.room must be an object/)
    end
  end

  test "presence validates room names and rejects duplicates across definitions" do
    configure_presence(%{"Bad Room" => presence()})
    assert_invalid(~r/Invalid presence name/)
    configure_presence(%{"demo.room" => presence()})
    Application.put_env(:fyrlet, :definitions, [ValidationFixtures.Core, ValidationFixtures.Core])
    assert_invalid(~r/Duplicate presence name: demo.room/)
  end

  defp configure(module, operations, subscriptions \\ %{}) do
    Application.put_env(:fyrlet, :definitions, [module])

    Application.put_env(:fyrlet, :validation_test_contract, %{
      "operations" => operations,
      "subscriptions" => subscriptions
    })
  end

  defp configure_presence(rooms) do
    configure(ValidationFixtures.Core, %{})
    contract = Application.fetch_env!(:fyrlet, :validation_test_contract)
    Application.put_env(:fyrlet, :validation_test_contract, Map.put(contract, "presence", rooms))
  end

  defp disable(name) do
    capabilities = Application.fetch_env!(:fyrlet, :capabilities)
    Application.put_env(:fyrlet, :capabilities, Map.delete(capabilities, name))
  end

  defp assert_invalid(message),
    do: assert_raise(RuntimeError, message, fn -> Registry.validate!() end)

  defp operation,
    do: %{"kind" => "read", "input" => Schema.object(%{}), "output" => %{"type" => "string"}}

  defp subscription, do: Map.delete(operation(), "kind")
  defp run, do: Map.merge(operation(), %{"kind" => "run", "output" => Fyrlet.Runs.start_output()})

  defp ingest, do: Fyrlet.Features.Ingest.operation(Schema.object(%{}))

  defp append,
    do:
      Map.merge(subscription(), %{
        "mode" => "append",
        "capability" => "append",
        "max_items" => 10,
        "output" => %{"type" => "array", "items" => %{"type" => "string"}}
      })

  defp shared, do: Map.put(subscription(), "sharing", "identical")
  defp presence, do: %{"input" => Schema.object(%{})}
end
