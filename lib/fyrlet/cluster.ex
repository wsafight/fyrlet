defmodule Fyrlet.Cluster do
  @moduledoc false
  use GenServer

  def start_link(nodes), do: GenServer.start_link(__MODULE__, nodes, name: __MODULE__)

  def nodes(value) when is_binary(value),
    do: value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> nodes()

  def nodes(values) when is_list(values) and length(values) <= 32 do
    Enum.map(values, fn value ->
      name = to_string(value)

      unless byte_size(name) <= 255 and
               Regex.match?(~r/\A[a-zA-Z0-9_.-]+@[a-zA-Z0-9_.-]+\z/, name),
             do: raise(ArgumentError, "Cluster peers must use name@host, at most 255 bytes each")

      String.to_atom(name)
    end)
    |> Enum.uniq()
  end

  def nodes(_values), do: raise(ArgumentError, "Configure at most 32 cluster peers")

  @impl true
  def init(peers) do
    if Node.alive?() do
      send(self(), :connect)
      {:ok, nodes(peers)}
    else
      {:stop, "Cluster peers require a named Erlang node; configure RELEASE_NODE or --sname"}
    end
  end

  @impl true
  def handle_info(:connect, peers) do
    for peer <- peers, peer != node() and peer not in Node.list(), do: Node.connect(peer)
    Process.send_after(self(), :connect, 1000)
    {:noreply, peers}
  end
end
