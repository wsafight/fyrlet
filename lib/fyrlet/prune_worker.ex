defmodule Fyrlet.PruneWorker do
  @moduledoc """
  Periodically removes expired idempotency results, long-expired sessions, finished runs,
  stream entries beyond their retention, and finished ingest items.

  Deletes run in bounded batches so one pass never holds a long lock or
  produces one huge transaction on a busy table.
  """
  use Oban.Worker,
    queue: :fyrlet,
    max_attempts: 3,
    unique: [period: 300, states: [:available, :scheduled, :retryable]]

  import Ecto.Query
  alias Fyrlet.{Auth, Idempotency, Pruning, Session}

  @batch 5_000
  @session_grace 86_400

  @impl true
  def perform(job) do
    offset = Map.get(job.args || %{}, "offset", 0)
    offset = if is_integer(offset) and offset in 0..8, do: offset, else: 0
    {_result, stats} = Pruning.run(fn -> prune_all(offset) end)

    if stats.limited,
      do: %{"offset" => rem(offset + 1, 9)} |> new(schedule_in: 1) |> Oban.insert!()

    :telemetry.execute([:fyrlet, :prune], Map.take(stats, [:deleted, :duration_ms]), %{
      limited: stats.limited
    })

    :ok
  end

  defp prune_all(offset) do
    now = Auth.now()

    steps = [
      fn -> prune(Idempotency, dynamic([entry], entry.expires_at < ^now)) end,
      fn ->
        prune(
          Session,
          dynamic([entry], entry.expires_at < ^DateTime.add(now, -@session_grace, :second))
        )
      end,
      fn -> prune_signals(now) end,
      fn -> prune_runs(now) end,
      fn -> prune_grants() end,
      fn -> Fyrlet.Runs.Privacy.purge_expired(now) end,
      fn -> Fyrlet.Features.Stream.prune() end,
      fn -> Fyrlet.Features.Ingest.prune(now) end,
      fn -> Fyrlet.Features.Anonymous.prune(DateTime.add(now, -@session_grace, :second)) end
    ]

    for step <- Enum.drop(steps, offset) ++ Enum.take(steps, offset),
        Pruning.available?(),
        do: step.()

    :ok
  end

  # Only finished runs are ever removed; an active run, its waits and its signals stay.
  defp prune_signals(now) do
    terminal = ["completed", "failed", "cancelled", "expired"]
    signal_cutoff = DateTime.add(now, -Fyrlet.Runs.Limits.get(:signal_retention), :second)

    signals =
      from(signal in Fyrlet.Runs.Signal,
        join: run in Fyrlet.Runs.Run,
        on: run.id == signal.run_id,
        where: run.status in ^terminal and signal.received_at < ^signal_cutoff,
        select: signal.id,
        limit: ^Pruning.batch_size(@batch)
      )

    Pruning.delete_all(from(signal in Fyrlet.Runs.Signal, where: signal.id in subquery(signals)))
  end

  defp prune_runs(now) do
    terminal = ["completed", "failed", "cancelled", "expired"]
    run_cutoff = DateTime.add(now, -Fyrlet.Runs.Limits.get(:terminal_retention), :second)

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
        limit: ^Pruning.batch_size(100)
      )

    {count, _rows} =
      Pruning.delete_all(from(run in Fyrlet.Runs.Run, where: run.id in subquery(old_runs)))

    if count == 100 and Pruning.available?(), do: prune_runs(now)
  end

  defp prune_grants do
    grants =
      from(grant in Fyrlet.Runs.Grant,
        as: :grant,
        where:
          not exists(
            from(run in Fyrlet.Runs.Run, where: run.execution_grant_id == parent_as(:grant).id)
          ),
        select: grant.id,
        limit: ^Pruning.batch_size(@batch)
      )

    Pruning.delete_all(from(grant in Fyrlet.Runs.Grant, where: grant.id in subquery(grants)))
  end

  defp prune(schema, condition) do
    identifiers =
      from(entry in schema,
        where: ^condition,
        select: entry.id,
        limit: ^Pruning.batch_size(@batch)
      )

    {count, _rows} =
      Pruning.delete_all(from(entry in schema, where: entry.id in subquery(identifiers)))

    if count == @batch and Pruning.available?(), do: prune(schema, condition), else: :ok
  end
end
