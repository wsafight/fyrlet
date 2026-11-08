defmodule Fyrlet.InvalidationNotifications do
  @moduledoc """
  Optional transactional PostgreSQL notifications for operation invalidations.

  Each enabled node listens on one database connection and broadcasts received scopes only
  within that node. Immediate PubSub delivery uses the same identifier, so subscribers can
  deduplicate both paths. Notifications missed while disconnected are repaired by normal
  subscription reconciliation; this is not a durable queue. Oversized payloads use Oban.
  """
  use GenServer
  alias Fyrlet.{InvalidationWorker, Repo}

  @channel "fyrlet_invalidation_v1"
  @max_payload_bytes 7_900

  def enabled?, do: Application.get_env(:fyrlet, :postgres_invalidation, false)

  def child_specs, do: if(enabled?(), do: [__MODULE__], else: [])

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  def enqueue(%Oban.Job{id: identifier, args: %{"scopes" => scopes}}) do
    payload = Jason.encode!(%{"id" => identifier, "scopes" => scopes})

    if byte_size(payload) <= @max_payload_bytes do
      Repo.query!("SELECT pg_notify($1, $2)", [@channel, payload])
      :ok
    else
      :too_large
    end
  end

  def decode(payload) when is_binary(payload) and byte_size(payload) <= @max_payload_bytes do
    with {:ok, %{"id" => identifier, "scopes" => scopes}} <- Jason.decode(payload),
         true <- is_integer(identifier) and identifier < 0,
         true <- is_list(scopes) and scopes != [],
         true <- Enum.all?(scopes, &(is_binary(&1) and byte_size(&1) > 0)) do
      {:ok, %Oban.Job{id: identifier, args: %{"scopes" => scopes}}}
    else
      _invalid -> :error
    end
  end

  def decode(_payload), do: :error

  @impl true
  def init(_options) do
    options =
      Repo.config()
      |> Keyword.drop([:name, :pool, :pool_size])
      |> Keyword.merge(auto_reconnect: true, sync_connect: false)

    {:ok, connection} = Postgrex.Notifications.start_link(options)
    {_status, reference} = Postgrex.Notifications.listen(connection, @channel)
    {:ok, %{connection: connection, reference: reference}}
  end

  @impl true
  def handle_info(
        {:notification, connection, reference, @channel, payload},
        %{connection: connection, reference: reference} = state
      ) do
    case decode(payload) do
      {:ok, job} -> InvalidationWorker.broadcast_local(job)
      :error -> :ok
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
