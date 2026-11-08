defmodule Fyrlet.Repo.Migrations.HotPathIndexes do
  use Ecto.Migration

  def change do
    # Effects.over_rate?/2 counts rows per project within the last second on every dispatch.
    create index(:fyrlet_effects, [:project_id, :claimed_at], where: "claimed_at IS NOT NULL")

    # Store.leased_attempts/1 and abandon_leases/1 run on every step claim and run close.
    create index(:fyrlet_run_attempts, [:run_id],
             where: "status = 'leased'",
             name: :fyrlet_run_attempts_leased_run_index
           )

    # PruneWorker.prune_grants/1 anti-joins runs against grants; Recovery joins by grant.
    create index(:fyrlet_runs, [:execution_grant_id])

    # Runs.check_signal_limits/2 counts recent signals per run on every signal.
    create index(:fyrlet_run_signals, [:run_id, :received_at])
  end
end
