defmodule Fyrlet.Runs.LimitsTest do
  use ExUnit.Case, async: false
  alias Fyrlet.Runs.Limits

  setup do
    previous = Application.get_env(:fyrlet, :runs)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fyrlet, :runs, previous),
        else: Application.delete_env(:fyrlet, :runs)
    end)

    :ok
  end

  test "every default is present and bounded" do
    defaults = Limits.defaults()

    assert Keyword.keyword?(defaults)
    assert Keyword.fetch!(defaults, :max_nodes) == 50
    assert Keyword.fetch!(defaults, :payload_max_bytes) == 65_536
    assert Keyword.fetch!(defaults, :max_attempts) == 3
    assert Keyword.fetch!(defaults, :lease_seconds) == 60

    for {key, value} <- defaults do
      assert is_integer(value) or (key == :payload_retention and is_nil(value)),
             "#{key} must be bounded, got #{inspect(value)}"

      if is_integer(value), do: assert(value >= 0, "#{key} must not be negative")
    end
  end

  test "get/1 returns the default when nothing is configured" do
    Application.delete_env(:fyrlet, :runs)

    assert Limits.get(:max_nodes) == 50
    assert Limits.get(:scan_interval_ms) == 30_000
    assert Limits.get(:payload_retention) == nil
  end

  test "get/1 reads an override and leaves other defaults alone" do
    Application.put_env(:fyrlet, :runs, max_nodes: 7, lease_seconds: 5)

    assert Limits.get(:max_nodes) == 7
    assert Limits.get(:lease_seconds) == 5
    assert Limits.get(:retry_base_seconds) == 2
    assert Limits.get(:local_chain) == 1
  end

  test "an unknown key is a programming error, not a silent nil" do
    assert_raise KeyError, fn -> Limits.get(:not_a_limit) end
  end
end
