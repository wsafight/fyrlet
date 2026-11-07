defmodule Fyrlet.Subscriptions.TrackerTest do
  use ExUnit.Case, async: false
  alias Fyrlet.Subscriptions.Tracker

  setup do
    previous = Application.fetch_env(:fyrlet, :max_subscriptions_per_node)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fyrlet, :max_subscriptions_per_node, value)
        :error -> Application.delete_env(:fyrlet, :max_subscriptions_per_node)
      end
    end)
  end

  test "the node limit accepts positive integers and an omitted setting" do
    Application.delete_env(:fyrlet, :max_subscriptions_per_node)
    assert :ok = Tracker.validate!()

    for limit <- [1, 10_000, 1_000_000] do
      Application.put_env(:fyrlet, :max_subscriptions_per_node, limit)
      assert :ok = Tracker.validate!()
    end
  end

  test "invalid static node limits fail startup validation" do
    for limit <- [nil, 0, -1, 1.5, "10000", :infinity] do
      Application.put_env(:fyrlet, :max_subscriptions_per_node, limit)

      assert_raise ArgumentError, "max_subscriptions_per_node must be a positive integer", fn ->
        Tracker.validate!()
      end
    end
  end
end
