defmodule Fyrlet.Effects.Recovery do
  @moduledoc """
  Repairs after crashes: lost claims, overdue dispatches, due reconciles, escalation.
  """
  import Ecto.Query
  import Fyrlet.Effects.Store
  alias Fyrlet.Repo
  alias Fyrlet.Effects.{Effect, Worker}
  alias Fyrlet.Runs.{Limits, Run, Store}

  @doc "Repairs effects a crash left behind. Returns counts."
  def recover(now) do
    %{
      lost_claims: lost_claims(now),
      redispatched: redispatch_due(now),
      reconciled: reconcile_due(now),
      escalated: escalate(now)
    }
  end

  # A dispatcher died after claiming: the request may or may not have left. Unknown.
  defp lost_claims(now) do
    ids =
      Repo.all(
        from(e in Effect,
          where: e.status == "claimed" and e.lease_expires_at <= ^now,
          select: e.id,
          limit: ^Limits.get(:scan_batch)
        )
      )

    Enum.count(ids, fn id ->
      transact(fn ->
        with %Effect{run_id: run_id} <- Repo.get(Effect, id),
             %Run{} = run <- Store.lock_run(run_id),
             %Effect{status: "claimed"} = effect <- lock(id),
             true <- DateTime.compare(effect.lease_expires_at, now) != :gt do
          record(effect.id, "effect.lease_lost", %{"epoch" => effect.execution_epoch})

          Fyrlet.Effects.uncertain(
            run,
            change(effect, execution_epoch: effect.execution_epoch + 1),
            now
          )

          true
        else
          _other -> false
        end
      end)
    end)
  end

  defp redispatch_due(now) do
    ids =
      Repo.all(
        from(e in Effect,
          where: e.status == "pending" and e.next_attempt_at <= ^now,
          select: e.id,
          limit: ^Limits.get(:scan_batch)
        )
      )

    Enum.each(ids, fn id -> Repo.transaction(fn -> Worker.enqueue("dispatch", id) end) end)
    length(ids)
  end

  defp reconcile_due(now) do
    ids =
      Repo.all(
        from(e in Effect,
          where: e.status in ["accepted", "unknown"] and e.next_attempt_at <= ^now,
          select: e.id,
          limit: ^Limits.get(:scan_batch)
        )
      )

    Enum.each(ids, fn id -> Repo.transaction(fn -> Worker.enqueue("reconcile", id) end) end)
    length(ids)
  end

  defp escalate(now) do
    cutoff = DateTime.add(now, -Fyrlet.Effects.reconcile_ttl(), :second)

    ids =
      Repo.all(
        from(e in Effect,
          where:
            e.status == "unknown" and e.resolution_required == false and
              e.first_dispatched_at <= ^cutoff,
          select: e.id,
          limit: ^Limits.get(:scan_batch)
        )
      )

    Enum.count(ids, fn id ->
      transact(fn ->
        with %Effect{run_id: run_id} <- Repo.get(Effect, id),
             %Run{} <- Store.lock_run(run_id),
             %Effect{status: "unknown", resolution_required: false} = effect <- lock(id) do
          effect = change(effect, resolution_required: true)
          record(effect.id, "effect.resolution_required", %{})
          emit_reconcile(effect, "resolution_required")
          true
        else
          _other -> false
        end
      end)
    end)
  end
end
