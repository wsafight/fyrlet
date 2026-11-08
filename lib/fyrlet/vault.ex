defmodule Fyrlet.Vault do
  @moduledoc """
  Optional encryption at rest for run, step, signal and effect payloads.

      config :fyrlet, :vault, keys: %{"2026-11" => <<32 bytes>>, "2026-05" => <<32 bytes>>}, current: "2026-11"

  AES-256-GCM, a fresh random IV per value, the key id stored with the ciphertext. New values
  use `current`; any key still listed can read older ones, so keys can be rotated by adding a
  new one and retiring the old after the data was rewritten. With no vault configured values
  are stored as they are. A value encrypted under a key that is no longer configured cannot be
  read: that fails loudly instead of returning something wrong.

  A configuration that is present but unusable (no `:current`, an unknown or short key) is not
  "no vault": `validate!/0` refuses to boot and `encrypt/1` raises, so a typo can never
  silently downgrade data to plaintext. Corrupt or non-base64 ciphertext decrypts to `:error`
  instead of raising, so one damaged row cannot crash its reader.

  Hashes used for de-duplication (`payload_hash`, request hashes) are computed from the
  plaintext before storing and are not encrypted, so de-duplication keeps working.
  """

  @aad "fyrlet.v1"

  @doc "Raises at boot when a vault is configured but unusable; nil config means plaintext."
  def validate! do
    case Application.get_env(:fyrlet, :vault) do
      nil ->
        :ok

      config when is_list(config) ->
        keys = Keyword.get(config, :keys)

        unless is_map(keys) and
                 Enum.all?(keys, fn {id, key} ->
                   is_binary(id) and is_binary(key) and byte_size(key) == 32
                 end),
               do: raise(ArgumentError, "Vault :keys must map id strings to 32-byte binary keys")

        unless is_binary(config[:current]) and is_map_key(keys, config[:current]),
          do: raise(ArgumentError, "Vault :current must name a key present in :keys")

        :ok

      other ->
        raise ArgumentError, "Vault config must be a keyword list, got: #{inspect(other)}"
    end
  end

  def enabled?, do: current() != nil

  def encrypt(%{} = value) do
    case current() do
      nil ->
        value

      {id, key} ->
        iv = :crypto.strong_rand_bytes(12)

        {cipher, tag} =
          :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, Jason.encode!(value), @aad, true)

        %{"__enc" => 1, "k" => id, "d" => Base.encode64(iv <> tag <> cipher)}
    end
  end

  def decrypt(%{"__enc" => 1, "k" => id, "d" => data}) do
    with {:ok, key} <- key(id),
         {:ok, decoded} <- Base.decode64(data),
         <<iv::binary-12, tag::binary-16, cipher::binary>> <- decoded,
         plain when is_binary(plain) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, cipher, @aad, tag, false) do
      {:ok, Jason.decode!(plain)}
    else
      _unreadable -> :error
    end
  end

  def decrypt(%{} = value), do: {:ok, value}

  defp current do
    case Application.get_env(:fyrlet, :vault) do
      nil ->
        nil

      config when is_list(config) ->
        with id when is_binary(id) <- config[:current],
             {:ok, key} <- key(id) do
          {id, key}
        else
          _broken ->
            raise ArgumentError,
                  "Fyrlet vault is configured but unusable: :current must name a 32-byte " <>
                    "key in :keys. Refusing to store plaintext silently; fix the config " <>
                    "or remove :vault entirely for plaintext storage."
        end

      other ->
        raise ArgumentError, "Vault config must be a keyword list, got: #{inspect(other)}"
    end
  end

  defp key(id) do
    case Application.get_env(:fyrlet, :vault, [])[:keys] do
      %{^id => key} when byte_size(key) == 32 -> {:ok, key}
      _missing -> :error
    end
  end
end

defmodule Fyrlet.EncryptedMap do
  @moduledoc "A map column that is encrypted at rest when a vault is configured."
  use Ecto.Type

  @impl true
  def type, do: :map

  @impl true
  def cast(value) when is_map(value), do: {:ok, value}
  def cast(_other), do: :error

  @impl true
  def dump(value) when is_map(value), do: {:ok, Fyrlet.Vault.encrypt(value)}
  def dump(_other), do: :error

  @impl true
  def load(value) when is_map(value), do: Fyrlet.Vault.decrypt(value)
  def load(_other), do: :error
end
