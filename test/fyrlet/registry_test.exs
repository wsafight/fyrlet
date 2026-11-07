defmodule Fyrlet.RegistryTest do
  use ExUnit.Case, async: false
  alias Fyrlet.{Error, Registry}
  alias Fyrlet.RegistryFixtures.{Dynamic, MissingCallback}

  @valid_contract %{
    "operations" => %{
      "demo.read" => %{
        "kind" => "read",
        "input" => Fyrlet.Schema.object(%{}),
        "output" => %{"type" => "string"}
      }
    },
    "subscriptions" => %{
      "demo.watch" => %{
        "input" => Fyrlet.Schema.object(%{}),
        "output" => %{"type" => "string"}
      }
    }
  }

  setup do
    previous = Application.fetch_env!(:fyrlet, :definitions)

    on_exit(fn ->
      Application.put_env(:fyrlet, :definitions, previous)
      Application.delete_env(:fyrlet, :registry_test_contract)
    end)
  end

  test "the configured test definitions are valid" do
    assert :ok = Registry.validate!()
  end

  test "validate! accepts a well-formed contract" do
    Application.put_env(:fyrlet, :definitions, [Dynamic])
    Application.put_env(:fyrlet, :registry_test_contract, @valid_contract)
    assert :ok = Registry.validate!()
  end

  test "validate! detects duplicate names across modules" do
    Application.put_env(:fyrlet, :definitions, [Dynamic, Dynamic])
    Application.put_env(:fyrlet, :registry_test_contract, @valid_contract)

    assert_raise RuntimeError, ~r/Duplicate operations name: demo.read/, fn ->
      Registry.validate!()
    end
  end

  test "validate! allows the same name in operations and subscriptions" do
    operation = @valid_contract["operations"]["demo.read"]
    subscription = @valid_contract["subscriptions"]["demo.watch"]

    contract = %{
      "operations" => %{"demo.same" => operation},
      "subscriptions" => %{"demo.same" => subscription}
    }

    Application.put_env(:fyrlet, :definitions, [Dynamic])
    Application.put_env(:fyrlet, :registry_test_contract, contract)
    assert :ok = Registry.validate!()
  end

  test "validate! rejects missing callbacks" do
    Application.put_env(:fyrlet, :definitions, [MissingCallback])

    assert_raise RuntimeError, ~r/Missing execute\/3/, fn ->
      Registry.validate!()
    end
  end

  test "validate! rejects contract names that are not lowercase dotted identifiers" do
    for name <- ["Bad", "1bad", "a", "has space", String.duplicate("a", 129)] do
      contract = put_in(@valid_contract, ["operations"], %{name => valid_operation()})
      Application.put_env(:fyrlet, :definitions, [Dynamic])
      Application.put_env(:fyrlet, :registry_test_contract, contract)

      assert_raise RuntimeError, ~r/Invalid contract name/, fn -> Registry.validate!() end
    end
  end

  test "validate! rejects malformed operation and subscription entries" do
    cases = [
      {%{
         "operations" => %{"demo.op" => %{"kind" => "read", "input" => %{}}},
         "subscriptions" => %{}
       }, RuntimeError, ~r/Missing schemas/},
      {%{
         "operations" => %{"demo.op" => Map.put(valid_operation(), "kind", "sideEffect")},
         "subscriptions" => %{}
       }, RuntimeError, ~r/Invalid operation kind/},
      {%{
         "operations" => %{
           "demo.op" => Map.put(valid_operation(), "input", %{"type" => "number"})
         },
         "subscriptions" => %{}
       }, ArgumentError, ~r/Unsupported contract schema/},
      {%{
         "operations" => %{},
         "subscriptions" => %{
           "demo.watch" => %{
             "input" => %{"type" => "number"},
             "output" => %{"type" => "string"}
           }
         }
       }, ArgumentError, ~r/Unsupported contract schema/}
    ]

    for {contract, exception, message} <- cases do
      Application.put_env(:fyrlet, :definitions, [Dynamic])
      Application.put_env(:fyrlet, :registry_test_contract, contract)

      assert_raise exception, message, fn -> Registry.validate!() end
    end
  end

  test "fetch/2 returns the owning module and specification" do
    assert {:ok, Fyrlet.TestRecords, specification} = Registry.fetch("operations", "records.add")
    assert specification["kind"] == "write"

    assert {:ok, Fyrlet.TestRecords, subscription} =
             Registry.fetch("subscriptions", "records.recent")

    assert subscription["output"]["type"] == "array"

    assert {:error, %Error{code: "NOT_FOUND"}} = Registry.fetch("operations", "records.recent")
    assert {:error, %Error{code: "NOT_FOUND"}} = Registry.fetch("subscriptions", "records.add")
    assert {:error, %Error{code: "NOT_FOUND"}} = Registry.fetch("operations", "missing.op")
  end

  test "fetch/2 requires a binary name" do
    assert_raise FunctionClauseError, fn -> Registry.fetch("operations", :records_add) end
  end

  test "export/0 merges operations and subscriptions with protocol metadata" do
    exported = Registry.export()

    assert exported["protocol_version"] == 1
    assert exported["contract_version"] == "0.1.0"
    assert exported["schema_dialect"] == "fyrlet-subset"
    assert Map.has_key?(exported["operations"], "records.add")
    assert Map.has_key?(exported["operations"], "test.echo")
    assert Map.has_key?(exported["subscriptions"], "records.recent")

    assert Map.has_key?(exported["operations"]["records.add"], "input")
    assert Map.has_key?(exported["operations"]["records.add"], "output")
  end

  defp valid_operation do
    %{
      "kind" => "read",
      "input" => Fyrlet.Schema.object(%{}),
      "output" => %{"type" => "string"}
    }
  end
end
