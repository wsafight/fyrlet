defmodule FyrletWeb.CapabilityChannelTest do
  use Fyrlet.DataCase, async: false
  import Phoenix.ChannelTest, except: [join: 2]
  @endpoint FyrletWeb.Endpoint
  alias Fyrlet.RegistryFixtures.Dynamic

  setup do
    Process.flag(:trap_exit, true)
    previous = Application.fetch_env!(:fyrlet, :definitions)
    capabilities = Application.fetch_env!(:fyrlet, :capabilities)

    Application.put_env(:fyrlet, :registry_test_contract, %{
      "operations" => %{},
      "subscriptions" => %{
        "demo.plain" => %{"input" => Fyrlet.Schema.object(%{}), "output" => %{"type" => "string"}},
        "demo.gated" => %{
          "capability" => "gated",
          "input" => Fyrlet.Schema.object(%{}),
          "output" => %{"type" => "string"}
        }
      }
    })

    Application.put_env(:fyrlet, :definitions, [Dynamic])
    Application.put_env(:fyrlet, :capabilities, %{"gated" => 2})

    on_exit(fn ->
      Application.put_env(:fyrlet, :definitions, previous)
      Application.put_env(:fyrlet, :capabilities, capabilities)
      Application.delete_env(:fyrlet, :registry_test_contract)
    end)

    %{alice: user(project())}
  end

  defp join_as(alice, name, options) do
    socket(FyrletWeb.UserSocket, "sessions:" <> alice.actor.session_id, %{actor: alice.actor})
    |> subscribe_and_join(
      "subscription:" <> Ecto.UUID.generate(),
      Map.merge(%{"name" => name, "params" => %{}}, options)
    )
  end

  @base %{"protocol_version" => 1}

  test "a client that declares nothing gets an empty set and cannot reach a gated subscription",
       %{
         alice: alice
       } do
    {:ok, snapshot, socket} = join_as(alice, "demo.plain", @base)
    assert snapshot["protocol_version"] == 1
    assert snapshot["capabilities"] == %{}
    leave(socket)

    assert {:error, %{"error" => %{"code" => "UNSUPPORTED_CAPABILITY"}}} =
             join_as(alice, "demo.gated", @base)
  end

  test "a client receives the capabilities it negotiated, at the lower version", %{alice: alice} do
    {:ok, snapshot, socket} =
      join_as(alice, "demo.gated", Map.put(@base, "capabilities", %{"gated" => 5}))

    assert snapshot["protocol_version"] == 1
    assert snapshot["capabilities"] == %{"gated" => 2}
    leave(socket)

    {:ok, plain, socket} = join_as(alice, "demo.plain", @base)
    assert plain["capabilities"] == %{}
    leave(socket)
  end

  test "a gated subscription is refused without the capability and bad declarations fail", %{
    alice: alice
  } do
    assert {:error, %{"error" => %{"code" => "UNSUPPORTED_CAPABILITY"}}} =
             join_as(alice, "demo.gated", Map.put(@base, "capabilities", ["other"]))

    assert {:error, %{"error" => %{"code" => "VALIDATION_FAILED"}}} =
             join_as(alice, "demo.plain", Map.put(@base, "capabilities", "gated"))

    for unsupported <- [0, 2, 3] do
      assert {:error, %{"error" => %{"code" => "UNSUPPORTED_VERSION"}}} =
               join_as(alice, "demo.plain", %{"protocol_version" => unsupported})
    end
  end

  test "the operations channel negotiates the same way", %{alice: alice} do
    socket =
      socket(FyrletWeb.UserSocket, "sessions:" <> alice.actor.session_id, %{actor: alice.actor})

    assert {:ok, %{"protocol_version" => 1, "capabilities" => %{}}, _socket} =
             subscribe_and_join(socket, "operations", @base)

    assert {:ok, %{"protocol_version" => 1, "capabilities" => %{"gated" => 1}}, _socket} =
             subscribe_and_join(
               socket,
               "operations",
               Map.put(@base, "capabilities", %{"gated" => 1})
             )

    assert {:error, %{"error" => %{"code" => "UNSUPPORTED_VERSION"}}} =
             subscribe_and_join(socket, "operations", %{"protocol_version" => 2})
  end
end
