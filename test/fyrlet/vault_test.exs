defmodule Fyrlet.VaultTest do
  use ExUnit.Case, async: false
  alias Fyrlet.{EncryptedMap, Vault}

  @key String.duplicate("k", 32)
  @other_key String.duplicate("o", 32)

  setup do
    previous = Application.get_env(:fyrlet, :vault)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fyrlet, :vault, previous),
        else: Application.delete_env(:fyrlet, :vault)
    end)

    :ok
  end

  defp configure(key_id, key) do
    Application.put_env(:fyrlet, :vault, keys: %{key_id => key}, current: key_id)
  end

  describe "vault" do
    test "values round-trip and each encryption uses a fresh IV" do
      configure("2026-11", @key)
      assert Vault.enabled?()

      first = Vault.encrypt(%{"to" => "a@example.com"})
      second = Vault.encrypt(%{"to" => "a@example.com"})

      assert %{"__enc" => 1, "k" => "2026-11", "d" => encoded} = first
      assert is_binary(encoded)
      assert first != second
      assert {:ok, %{"to" => "a@example.com"}} = Vault.decrypt(first)
      assert {:ok, %{"to" => "a@example.com"}} = Vault.decrypt(second)
    end

    test "plain maps pass through decrypt unchanged" do
      configure("2026-11", @key)
      assert {:ok, %{"plain" => true}} = Vault.decrypt(%{"plain" => true})
    end

    test "rotation: new values use the new key while old values stay readable" do
      configure("old", @key)
      old = Vault.encrypt(%{"version" => 1})

      Application.put_env(:fyrlet, :vault,
        keys: %{"old" => @key, "new" => @other_key},
        current: "new"
      )

      fresh = Vault.encrypt(%{"version" => 2})

      assert old["k"] == "old" and fresh["k"] == "new"
      assert {:ok, %{"version" => 1}} = Vault.decrypt(old)
      assert {:ok, %{"version" => 2}} = Vault.decrypt(fresh)
    end

    test "a value encrypted under a removed key fails loudly instead of returning data" do
      configure("old", @key)
      sealed = Vault.encrypt(%{"secret" => "x"})

      Application.put_env(:fyrlet, :vault, keys: %{"new" => @other_key}, current: "new")

      assert :error = Vault.decrypt(sealed)
    end

    test "tampered, truncated and structurally invalid ciphertexts are rejected" do
      configure("2026-11", @key)
      sealed = Vault.encrypt(%{"x" => 1})

      <<head::binary-20, byte, rest::binary>> = Base.decode64!(sealed["d"])
      flipped = %{sealed | "d" => Base.encode64(head <> <<Bitwise.bxor(byte, 1)>> <> rest)}
      assert :error = Vault.decrypt(flipped)

      short = %{sealed | "d" => Base.encode64(:crypto.strong_rand_bytes(5))}
      assert :error = Vault.decrypt(short)

      # A stored value that is not even base64 is corrupt data: decrypt refuses to guess.
      assert_raise ArgumentError, fn ->
        Vault.decrypt(%{"__enc" => 1, "k" => "2026-11", "d" => "%%%not-base64%%%"})
      end
    end

    test "no usable configuration means plaintext storage" do
      Application.delete_env(:fyrlet, :vault)
      refute Vault.enabled?()
      assert Vault.encrypt(%{"x" => 1}) == %{"x" => 1}

      Application.put_env(:fyrlet, :vault, keys: %{"k" => @key})
      refute Vault.enabled?()

      Application.put_env(:fyrlet, :vault, keys: %{"k" => @key}, current: "missing")
      refute Vault.enabled?()

      configure("short", "tiny")
      refute Vault.enabled?()
      assert Vault.encrypt(%{"x" => 1}) == %{"x" => 1}
    end
  end

  describe "encrypted map type" do
    test "casts maps and refuses everything else" do
      assert EncryptedMap.type() == :map
      assert EncryptedMap.cast(%{"a" => 1}) == {:ok, %{"a" => 1}}
      assert EncryptedMap.cast(%{}) == {:ok, %{}}
      assert EncryptedMap.cast(:nope) == :error
      assert EncryptedMap.cast("string") == :error
      assert EncryptedMap.cast([1]) == :error
      assert EncryptedMap.cast(nil) == :error
    end

    test "dumps and loads through the vault when enabled" do
      configure("2026-11", @key)

      assert {:ok, sealed} = EncryptedMap.dump(%{"a" => 1})
      assert sealed["__enc"] == 1
      refute sealed == %{"a" => 1}
      assert {:ok, %{"a" => 1}} = EncryptedMap.load(sealed)
    end

    test "stores plaintext maps when no vault is configured" do
      Application.delete_env(:fyrlet, :vault)

      assert {:ok, %{"a" => 1}} = EncryptedMap.dump(%{"a" => 1})
      assert {:ok, %{"a" => 1}} = EncryptedMap.load(%{"a" => 1})
    end

    test "refuses non-map dumps and loads" do
      assert EncryptedMap.dump(:nope) == :error
      assert EncryptedMap.dump(nil) == :error
      assert EncryptedMap.load(:nope) == :error
      assert EncryptedMap.load(nil) == :error
    end
  end
end
