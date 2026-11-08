defmodule Fyrlet.Capabilities do
  @moduledoc """
  Optional server capabilities and their negotiation with clients.

  A client declares the capabilities it understands when it joins a channel (or in the
  `X-Fyrlet-Capabilities` header); declaring none is allowed and gets none. The enabled set is the
  intersection with what the server supports, and each capability is enabled at the lower of the two
  versions. Events and entries that belong to a capability are only sent to a connection that
  negotiated it.

  `protocol_version` is the version of the protocol itself. There is one, `1`; a client that joins
  with another gets `UNSUPPORTED_VERSION`, which is how a future incompatible change would announce
  itself.
  """
  alias Fyrlet.Error

  @protocol_version 1
  @max_declared 32

  def protocol_version, do: @protocol_version

  @doc "Capabilities the server has enabled, as `%{name => version}`."
  def supported do
    %{"view_confirmation" => 1}
    |> Map.merge(Fyrlet.Plugins.capabilities())
    |> Map.merge(Application.get_env(:fyrlet, :capabilities, %{}))
  end

  def enabled?(name), do: Map.has_key?(supported(), name)

  @doc """
  Negotiates the capabilities of one connection.

  `requested` is what the client declared: a `%{name => version}` map, a list of names
  (version 1), or `nil` for none.
  """
  def negotiate(requested) do
    with {:ok, declared} <- normalize(requested) do
      server = supported()

      {:ok,
       for({name, version} <- declared, Map.has_key?(server, name), into: %{}) do
         {name, min(version, Map.fetch!(server, name))}
       end}
    end
  end

  @doc "Whether `version` is the protocol version this server speaks."
  def supported_version?(version), do: version == @protocol_version

  @doc "Parses the `X-Fyrlet-Capabilities` header value, e.g. `runs=1, ingest`."
  def parse_header(nil), do: {:ok, %{}}
  def parse_header(""), do: {:ok, %{}}

  def parse_header(value) when is_binary(value) do
    entries = value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    if length(entries) > @max_declared do
      invalid()
    else
      Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, acc} ->
        case String.split(entry, "=", parts: 2) do
          [name] when name != "" -> {:cont, {:ok, Map.put(acc, name, 1)}}
          [name, version] -> parse_pair(acc, name, version)
          _other -> {:halt, invalid()}
        end
      end)
    end
  end

  @doc "Negotiates the capabilities declared in the HTTP header of a request."
  def negotiate_header(value) do
    with {:ok, declared} <- parse_header(value), do: negotiate(declared)
  end

  @doc "Returns `:ok` when `name` is part of the negotiated set, otherwise `UNSUPPORTED_CAPABILITY`."
  def require(negotiated, name) do
    if Map.has_key?(negotiated, name), do: :ok, else: {:error, unsupported(name)}
  end

  def unsupported(name) do
    Error.new("UNSUPPORTED_CAPABILITY", "The capability is not enabled for this request", %{
      "capability" => name
    })
  end

  defp parse_pair(acc, name, version) do
    case Integer.parse(String.trim(version)) do
      {number, ""} when number > 0 and name != "" -> {:cont, {:ok, Map.put(acc, name, number)}}
      _invalid -> {:halt, invalid()}
    end
  end

  defp normalize(nil), do: {:ok, %{}}

  defp normalize(names) when is_list(names) and length(names) <= @max_declared do
    if Enum.all?(names, &(is_binary(&1) and &1 != "")),
      do: {:ok, Map.new(names, &{&1, 1})},
      else: invalid()
  end

  defp normalize(map) when is_map(map) and map_size(map) <= @max_declared do
    if Enum.all?(map, fn {name, version} ->
         is_binary(name) and name != "" and is_integer(version) and version > 0
       end),
       do: {:ok, map},
       else: invalid()
  end

  defp normalize(_other), do: invalid()

  defp invalid do
    {:error,
     Error.new("VALIDATION_FAILED", "Capabilities must be names with positive integer versions")}
  end
end
