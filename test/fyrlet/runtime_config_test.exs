defmodule Fyrlet.RuntimeConfigTest do
  use ExUnit.Case, async: true
  alias Fyrlet.RuntimeConfig

  defp env(map), do: fn name -> Map.get(map, name) end

  test "an empty environment yields only the defaults that always apply" do
    settings = RuntimeConfig.settings(:dev, env(%{}))

    assert settings[:cors_origins] == ["http://localhost:5173", "http://127.0.0.1:5173"]
    assert settings[FyrletWeb.Endpoint][:http] == [ip: {127, 0, 0, 1}, port: 4000]
    refute Keyword.has_key?(settings, Fyrlet.Repo)
    refute Keyword.has_key?(settings, :idempotency_ttl)
  end

  test "tuning variables are parsed" do
    settings =
      RuntimeConfig.settings(
        :dev,
        env(%{
          "DATABASE_URL" => "ecto://u:p@db/x",
          "POOL_SIZE" => "25",
          "PORT" => "4400",
          "PHX_SERVER" => "true",
          "FYRLET_OBSERVER_HIBERNATE_AFTER_MS" => "infinity",
          "FYRLET_IDEMPOTENCY_TTL_SECONDS" => "600",
          "CORS_ORIGINS" => "https://a.example,https://b.example"
        })
      )

    assert settings[Fyrlet.Repo] == [pool_size: 25, url: "ecto://u:p@db/x"]
    assert settings[FyrletWeb.Endpoint][:server]
    assert settings[FyrletWeb.Endpoint][:http][:port] == 4400
    assert settings[:observer_hibernate_after] == :infinity
    assert settings[:idempotency_ttl] == 600
    assert settings[:cors_origins] == ["https://a.example", "https://b.example"]

    assert RuntimeConfig.settings(:dev, env(%{"FYRLET_OBSERVER_HIBERNATE_AFTER_MS" => "500"}))[
             :observer_hibernate_after
           ] == 500
  end

  test "production binds publicly and requires the database, secret and origins" do
    complete = %{
      "DATABASE_URL" => "ecto://u:p@db/x",
      "SECRET_KEY_BASE" => String.duplicate("s", 64),
      "ALLOWED_ORIGINS" => "//app.example,//admin.example"
    }

    endpoint = RuntimeConfig.settings(:prod, env(complete))[FyrletWeb.Endpoint]
    assert endpoint[:http][:ip] == {0, 0, 0, 0}
    assert endpoint[:secret_key_base] == complete["SECRET_KEY_BASE"]
    assert endpoint[:check_origin] == ["//app.example", "//admin.example"]

    for missing <- ["DATABASE_URL", "SECRET_KEY_BASE", "ALLOWED_ORIGINS"] do
      assert_raise RuntimeError, ~r/#{missing}/, fn ->
        RuntimeConfig.settings(:prod, env(Map.delete(complete, missing)))
      end
    end
  end

  test "the test environment never configures the endpoint" do
    refute Keyword.has_key?(
             RuntimeConfig.settings(:test, env(%{"PORT" => "1"})),
             FyrletWeb.Endpoint
           )
  end

  test "cluster peers are explicit, deduplicated and bounded" do
    settings =
      RuntimeConfig.settings(
        :dev,
        env(%{"FYRLET_CLUSTER_NODES" => "a@localhost, b@localhost,a@localhost"})
      )

    assert settings[:cluster_nodes] == [:a@localhost, :b@localhost]
    refute Keyword.has_key?(RuntimeConfig.settings(:dev, env(%{})), :cluster_nodes)

    for invalid <- [
          "localhost",
          "a@bad host",
          "a@localhost/extra",
          String.duplicate("a", 256) <> "@host",
          Enum.map_join(1..33, ",", &"peer#{&1}@localhost")
        ] do
      assert_raise ArgumentError, fn ->
        RuntimeConfig.settings(:dev, env(%{"FYRLET_CLUSTER_NODES" => invalid}))
      end
    end
  end

  test "numeric variables are checked and a bad one is named" do
    for {name, bad} <- [
          {"POOL_SIZE", "ten"},
          {"POOL_SIZE", "0"},
          {"POOL_SIZE", "-3"},
          {"POOL_SIZE", "10x"},
          {"PORT", "70000"},
          {"PORT", "0"},
          {"FYRLET_IDEMPOTENCY_TTL_SECONDS", "0"},
          {"FYRLET_OBSERVER_HIBERNATE_AFTER_MS", "soon"}
        ] do
      assert_raise ArgumentError, ~r/#{name}/, fn ->
        RuntimeConfig.settings(:dev, env(%{name => bad}))
      end
    end

    settings =
      RuntimeConfig.settings(
        :dev,
        env(%{
          "POOL_SIZE" => " 12 ",
          "PORT" => "65535",
          "FYRLET_OBSERVER_HIBERNATE_AFTER_MS" => "0"
        })
      )

    assert settings[Fyrlet.Repo][:pool_size] == 12
    assert settings[FyrletWeb.Endpoint][:http][:port] == 65_535
    assert settings[:observer_hibernate_after] == 0
  end

  test "origin lists ignore spaces around entries and empty entries" do
    settings =
      RuntimeConfig.settings(
        :prod,
        env(%{
          "DATABASE_URL" => "ecto://u:p@db/x",
          "SECRET_KEY_BASE" => String.duplicate("s", 64),
          "ALLOWED_ORIGINS" => "//a.example , //b.example,, ",
          "CORS_ORIGINS" => "https://a.example, https://b.example"
        })
      )

    assert settings[FyrletWeb.Endpoint][:check_origin] == ["//a.example", "//b.example"]
    assert settings[:cors_origins] == ["https://a.example", "https://b.example"]
  end
end
