defmodule Fyrlet.PruneWorker do
  @moduledoc """
  Periodically removes expired idempotency results, long-expired sessions, finished runs,
  stream entries beyond their retention, and finished ingest items.

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

    prune_runs(now)
    Fyrlet.Runs.Privacy.purge_expired(now)
    Fyrlet.Features.Stream.prune()
    Fyrlet.Features.Ingest.prune(now)
    Fyrlet.Features.Anonymous.prune(DateTime.add(now, -@session_grace, :second))

    :ok
  end

  # Only finished runs are ever removed; an active run, its waits and its signals stay.
  defp prune_runs(now) do
    terminal = ["completed", "failed", "cancelled", "expired"]
    signal_cutoff = DateTime.add(now, -Fyrlet.Runs.Limits.get(:signal_retention), :second)
    run_cutoff = DateTime.add(now, -Fyrlet.Runs.Limits.get(:terminal_retention), :second)

    Repo.delete_all(
      from(signal in Fyrlet.Runs.Signal,
        join: run in Fyrlet.Runs.Run,
        on: run.id == signal.run_id,
        where: run.status in ^terminal and signal.received_at < ^signal_cutoff
      )
    )

    old_runs =
      from(run in Fyrlet.Runs.Run,
        as: :run,
        where: run.status in ^terminal and run.finished_at < ^run_cutoff,
        where:
          not exists(
            from(effect in Fyrlet.Effects.Effect,
              where:
                effect.run_id == parent_as(:run).id and
                  effect.status in ["pending", "claimed", "accepted", "unknown"]
            )
          ),
        select: run.id,
        limit: ^@batch
      )

    Repo.delete_all(from(run in Fyrlet.Runs.Run, where: run.id in subquery(old_runs)))

    Repo.delete_all(
      from(grant in Fyrlet.Runs.Grant,
        as: :grant,
        where:
          not exists(
            from(run in Fyrlet.Runs.Run, where: run.execution_grant_id == parent_as(:grant).id)
          )
      )
    )
  end

  defp prune(schema, condition) do
    identifiers = from(entry in schema, where: ^condition, select: entry.id, limit: @batch)

    {count, _rows} =
      Repo.delete_all(from(entry in schema, where: entry.id in subquery(identifiers)))

    if count == @batch, do: prune(schema, condition), else: :ok
  end
end
