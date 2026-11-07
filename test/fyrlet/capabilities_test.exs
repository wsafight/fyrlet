defmodule Fyrlet.CapabilitiesTest do
  use ExUnit.Case, async: false
  alias Fyrlet.{Capabilities, Error, Registry}
  alias Fyrlet.RegistryFixtures.Dynamic

  setup do
    previous = Application.fetch_env!(:fyrlet, :definitions)
    capabilities = Application.fetch_env!(:fyrlet, :capabilities)

    on_exit(fn ->
      Application.put_env(:fyrlet, :definitions, previous)
      Application.put_env(:fyrlet, :capabilities, capabilities)
      Application.delete_env(:fyrlet, :registry_test_contract)
    end)
  end

  defp contract do
    %{
      "operations" => %{
        "demo.read" => %{
          "kind" => "read",
          "input" => Fyrlet.Schema.object(%{}),
          "output" => %{"type" => "string"}
        }
      },
      "subscriptions" => %{
        "demo.plain" => %{"input" => Fyrlet.Schema.object(%{}), "output" => %{"type" => "string"}},
        "demo.gated" => %{
          "capability" => "gated",
          "input" => Fyrlet.Schema.object(%{}),
          "output" => %{"type" => "string"}
        }
      }
    }
  end

  defp register(capabilities) do
    Application.put_env(:fyrlet, :registry_test_contract, contract())
    Application.put_env(:fyrlet, :definitions, [Dynamic])
    Application.put_env(:fyrlet, :capabilities, capabilities)
  end

  describe "negotiate/1" do
    test "a client that declares nothing gets nothing" do
      Application.put_env(:fyrlet, :capabilities, %{"runs" => 1})
      assert {:ok, %{}} = Capabilities.negotiate(nil)
      assert {:ok, %{}} = Capabilities.negotiate(%{})
    end

    test "the enabled set is the intersection, at the lower version" do
      Application.put_env(:fyrlet, :capabilities, %{"runs" => 2, "ingest" => 1})

      assert {:ok, %{"runs" => 1}} = Capabilities.negotiate(%{"runs" => 1, "unknown" => 5})
      assert {:ok, %{"runs" => 2}} = Capabilities.negotiate(%{"runs" => 9})
      assert {:ok, %{"runs" => 1, "ingest" => 1}} = Capabilities.negotiate(["runs", "ingest"])
    end

    test "malformed declarations are rejected" do
      assert {:error, %Error{code: "VALIDATION_FAILED"}} = Capabilities.negotiate("runs")
      assert {:error, %Error{code: "VALIDATION_FAILED"}} = Capabilities.negotiate(%{"runs" => 0})
      assert {:error, %Error{code: "VALIDATION_FAILED"}} = Capabilities.negotiate([1, 2])

      too_many = Map.new(1..33, &{"c#{&1}", 1})
      assert {:error, %Error{code: "VALIDATION_FAILED"}} = Capabilities.negotiate(too_many)
    end

    test "only the one protocol version is supported" do
      assert Capabilities.protocol_version() == 1
      assert Capabilities.supported_version?(1)
      refute Capabilities.supported_version?(2)
    end

    test "require/2 reports UNSUPPORTED_CAPABILITY with HTTP 400" do
      assert :ok = Capabilities.require(%{"runs" => 1}, "runs")

      assert {:error, %Error{code: "UNSUPPORTED_CAPABILITY"} = error} =
               Capabilities.require(%{}, "runs")

      assert Error.status(error) == 400
    end
  end

  describe "header parsing" do
    test "names default to version 1 and versions must be positive integers" do
      Application.put_env(:fyrlet, :capabilities, %{"runs" => 3})

      assert {:ok, %{"runs" => 1}} = Capabilities.negotiate_header("runs")
      assert {:ok, %{"runs" => 2}} = Capabilities.negotiate_header("runs=2, other=4")
      assert {:ok, %{}} = Capabilities.negotiate_header(nil)
      assert {:error, %Error{code: "VALIDATION_FAILED"}} = Capabilities.negotiate_header("runs=x")
      assert {:error, %Error{code: "VALIDATION_FAILED"}} = Capabilities.negotiate_header("runs=0")
      assert {:error, %Error{code: "VALIDATION_FAILED"}} = Capabilities.negotiate_header("=1")
    end
  end

  describe "the exported contract" do
    test "lists entries only when their capability is enabled" do
      register(%{"gated" => 1})
      exported = Registry.export()

      assert exported["protocol_version"] == 1
      refute Map.has_key?(exported, "protocol_versions")
      assert Map.has_key?(exported["subscriptions"], "demo.plain")
      assert exported["capabilities"]["gated"] == 1
      # Loaded plugins are advertised; the failed optional one is not.
      assert exported["capabilities"]["counter"] == 1
      refute Map.has_key?(exported["capabilities"], "broken")
      assert Map.has_key?(exported["subscriptions"], "demo.gated")

      register(%{})
      refute Map.has_key?(Registry.export()["subscriptions"], "demo.gated")
      assert Map.has_key?(Registry.export()["subscriptions"], "demo.plain")
    end

    test "names the schema dialect" do
      register(%{"gated" => 1})
      assert Registry.export()["schema_dialect"] == "fyrlet-subset"
    end

    test "a run operation is rejected unless the runs capability is enabled" do
      contract =
        put_in(
          contract(),
          ["operations", "demo.start"],
          Fyrlet.Runs.operation(Fyrlet.Schema.object(%{}))
        )

      Application.put_env(:fyrlet, :registry_test_contract, contract)
      Application.put_env(:fyrlet, :definitions, [Dynamic])
      Application.put_env(:fyrlet, :capabilities, %{})

      assert_raise RuntimeError, ~r/runs capability is not enabled/, fn ->
        Registry.validate!()
      end

      Application.put_env(:fyrlet, :capabilities, %{"runs" => 1})
      assert :ok = Registry.validate!()
      assert Map.has_key?(Registry.export()["operations"], "demo.start")
    end
  end
end
