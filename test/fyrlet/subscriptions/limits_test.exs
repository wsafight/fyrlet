defmodule Fyrlet.SubscriptionLimitsTest do
  use Fyrlet.DataCase, async: false
  import Phoenix.ChannelTest, except: [join: 2]
  alias Fyrlet.Subscriptions.Limits
  @endpoint FyrletWeb.Endpoint

  defmodule Shared do
    def shared_query(_name, _context, _input), do: {:ok, [String.duplicate("x", 20)], %{}}
  end

  defmodule Append do
    @behaviour Fyrlet.Definition
    def contract do
      %{
        "operations" => %{},
        "subscriptions" => %{
          "limited.feed" => %{
            "mode" => "append",
            "capability" => "append",
            "max_items" => 3,
            "max_snapshot_bytes" => 2,
            "input" => Fyrlet.Schema.object(%{}),
            "output" => %{
              "type" => "array",
              "items" => Fyrlet.Schema.object(%{"text" => %{"type" => "string"}}, ["text"])
            }
          }
        }
      }
    end

    def authorize(_name, _actor, _input), do: :ok
    def execute(_name, _actor, _input), do: {:ok, [], []}
    def scope(_name, actor, _input), do: "limits:#{actor.project_id}:#{actor.subject_id}"
    def stream(_name, actor, _input), do: {:ok, "limits.#{actor.subject_id}"}
  end

  test "a contract can lower the global snapshot ceiling but cannot raise it" do
    maximum = Application.fetch_env!(:fyrlet, :max_snapshot_bytes)
    assert Limits.snapshot_bytes(%{}) == maximum
    assert Limits.snapshot_bytes(%{"max_snapshot_bytes" => 128}) == 128
    assert Limits.snapshot_bytes(%{"max_snapshot_bytes" => maximum + 1}) == maximum
    assert :ok = Limits.check_snapshot(128, %{"max_snapshot_bytes" => 128})

    assert {:error, %Error{code: "LIMIT_EXCEEDED", details: %{"limit" => 128}}} =
             Limits.check_snapshot(129, %{"max_snapshot_bytes" => 128})
  end

  test "the identical shared runtime applies the contract ceiling" do
    subscription = %{
      module: Shared,
      name: "limited.shared",
      parameters: %{},
      specification: %{
        "output" => %{"type" => "array", "items" => %{"type" => "string"}},
        "max_snapshot_bytes" => 2
      }
    }

    assert {:error, %Error{code: "LIMIT_EXCEEDED", details: %{"limit" => 2}}} =
             Runtime.shared_view(subscription, %{})

    assert {:ok, _view} =
             Runtime.shared_view(
               put_in(subscription.specification["max_snapshot_bytes"], 24),
               %{}
             )
  end

  test "append joins and explicit refresh enforce the same contract ceiling" do
    Process.flag(:trap_exit, true)
    previous = Application.fetch_env!(:fyrlet, :definitions)
    Application.put_env(:fyrlet, :definitions, [Append | previous])
    on_exit(fn -> Application.put_env(:fyrlet, :definitions, previous) end)
    alice = user(project())

    join = fn ->
      socket(FyrletWeb.UserSocket, "sessions:" <> alice.actor.session_id, %{actor: alice.actor})
      |> subscribe_and_join("append:" <> Ecto.UUID.generate(), %{
        "protocol_version" => 1,
        "capabilities" => %{"append" => 1},
        "name" => "limited.feed",
        "params" => %{}
      })
    end

    assert {:ok, initial, socket} = join.()
    assert initial["data"] == []

    push(socket, "ack", %{
      "g" => initial["generation"],
      "s" => initial["seq"],
      "c" => initial["cursor"]
    })

    :sys.get_state(socket.channel_pid)

    {:ok, _} =
      Repo.transaction(fn ->
        Fyrlet.Features.Stream.append(
          alice.actor.project_id,
          "limits.#{alice.actor.subject_id}",
          [%{"text" => "too large"}]
        )
      end)

    push(socket, "refresh", %{})

    assert_push "status", %{
      "error" => %{"code" => "LIMIT_EXCEEDED", "details" => %{"limit" => 2}}
    }

    assert {:error, %{"error" => %{"code" => "LIMIT_EXCEEDED"}}} = join.()
  end
end
