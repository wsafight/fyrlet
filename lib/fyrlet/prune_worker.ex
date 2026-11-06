defmodule Fyrlet.PruneWorker do
  @moduledoc """
  Periodically removes expired idempotency results and long-expired sessions.

  Deletes run in bounded batches so one pass never holds a long lock or
  produces one huge transaction on a busy table.
  """
  use Oban.Worker, queue: :fyrlet, max_attempts: 3, unique: [period: 300]
  import Ecto.Query
  alias Fyrlet.{Auth, Idempotency, Repo, Session}

  @batch 5_000
  @session_grace 86_400

  @impl true
  def perform(_job) do
    now = Auth.now()
    prune(Idempotency, dynamic([entry], entry.expires_at < ^now))

    prune(
      Session,
      dynamic([entry], entry.expires_at < ^DateTime.add(now, -@session_grace, :second))
    )

    :ok
  end

  defp prune(schema, condition) do
    identifiers = from(entry in schema, where: ^condition, select: entry.id, limit: @batch)

    {count, _rows} =
      Repo.delete_all(from(entry in schema, where: entry.id in subquery(identifiers)))

    if count == @batch, do: prune(schema, condition), else: :ok
  end
end
