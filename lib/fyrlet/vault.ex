defmodule Fyrlet.Vault do
  @moduledoc """
  Optional encryption at rest for run, step, signal and effect payloads.

      config :fyrlet, :vault, keys: %{"2026-11" => <<32 bytes>>, "2026-05" => <<32 bytes>>}, current: "2026-11"

  AES-256-GCM, a fresh random IV per value, the key id stored with the ciphertext. New values
  use `current`; any key still listed can read older ones, so keys can be rotated by adding a
  new one and retiring the old after the data was rewritten. With no vault configured values
  are stored as they are. A value encrypted under a key that is no longer configured cannot be
  read: that fails loudly instead of returning something wrong.

  Hashes used for de-duplication (`payload_hash`, request hashes) are computed from the
  plaintext before storing and are not encrypted, so de-duplication keeps working.
  """

  @aad "fyrlet.v1"

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
         <<iv::binary-12, tag::binary-16, cipher::binary>> <- Base.decode64!(data),
         plain when is_binary(plain) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, cipher, @aad, tag, false) do
      {:ok, Jason.decode!(plain)}
    else
      _unreadable -> :error
    end
  end

  def decrypt(%{} = value), do: {:ok, value}

  defp current do
    with config when is_list(config) <- Application.get_env(:fyrlet, :vault),
         id when is_binary(id) <- config[:current],
         {:ok, key} <- key(id) do
      {id, key}
    else
      _none -> nil
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
