defmodule Fyrlet.Runs.Recovery do
  @moduledoc """
  Periodically repairs what a crash, a lost wake-up or a missing executor left behind.

  Every repair re-reads state under the run's row lock and is idempotent, so several scans
  (or nodes) running at once are safe, just wasteful. The scan never trusts that a wake-up
  was delivered: it looks at the tables.
  """
  use GenServer
  import Ecto.Query
  alias Fyrlet.{Auth, Repo}
  alias Fyrlet.Runs.{Attempt, Engine, Limits, Resolver, Run, Step, Store, Worker}

  @active ~w(pending running waiting cancelling)

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(_options) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:scan, state) do
    try do
      scan()
    rescue
      exception ->
        require Logger
        Logger.error("Run recovery failed: #{inspect(exception.__struct__)}")
    end

    schedule()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule, do: Process.send_after(self(), :scan, Limits.get(:scan_interval_ms))

  @doc "Runs one full scan and returns how many repairs of each kind it made."
  def scan do
    now = Auth.now()

    stats = %{
      expired_leases: expired_leases(now),
      rescheduled: rewake_stalled(now),
      wait_timeouts: wait_timeouts(now),
      cancel_fenced: cancel_deadlines(now),
      expired_runs: expired_runs(now),
      grants: invalid_grants(now),
      definitions: definitions(now)
    }

    effects = Fyrlet.Effects.recover(now)

    stats =
      Map.merge(stats, %{
        effect_lost_claims: effects.lost_claims,
        effect_redispatched: effects.redispatched,
        effect_reconciled: effects.reconciled,
        effect_escalated: effects.escalated
      })

    :telemetry.execute([:fyrlet, :run, :recovery], stats, %{})
    gauges(now)
    stats
  end

  # Queue age and overdue waits, so a stuck system is visible before users report it.
  defp gauges(now) do
    oldest =
      Repo.one(from(r in Run, where: r.status == "pending", select: min(r.inserted_at)))

    pending = Repo.one(from(r in Run, where: r.status == "pending", select: count(r.id)))

    busiest =
      Repo.one(
        from(a in Attempt,
          where: a.status == "leased" and a.lease_expires_at > ^now,
          group_by: a.project_id,
          order_by: [desc: count(a.id)],
          limit: 1,
          select: count(a.id)
        )
      ) || 0

    :telemetry.execute(
      [:fyrlet, :run, :queue],
      %{
        oldest_age_ms: if(oldest, do: DateTime.diff(now, oldest, :millisecond), else: 0),
        pending: pending,
        busiest_project_leases: busiest
      },
      %{}
    )

    overdue =
      Repo.one(
        from(s in Step,
          join: r in Run,
          on: r.id == s.run_id and r.current_step_seq == s.seq,
          where: s.status == "waiting" and s.wait_deadline <= ^now and r.status == "waiting",
          select: count(s.id)
        )
      )

    unavailable =
      Repo.one(
        from(r in Run,
          where: r.status == "waiting" and r.wait_reason == "definition_unavailable",
          select: count(r.id)
        )
      )

    :telemetry.execute(
      [:fyrlet, :run, :wait],
      %{overdue: overdue, definition_unavailable: unavailable},
      %{}
    )
  end

  # ---- individual repairs -------------------------------------------------------------

  defp expired_leases(now) do
    ids =
      Repo.all(
        from(a in Attempt,
          where: a.status == "leased" and a.lease_expires_at <= ^now,
          distinct: true,
          select: a.run_id,
          limit: ^Limits.get(:scan_batch)
        )
      )

    Enum.count(ids, fn run_id ->
      Engine.transact(fn ->
        case Store.lock_run(run_id) do
          %Run{status: "cancelling"} = run ->
            # The executor is gone and cannot confirm: the cancel ends fenced, not confirmed.
            Store.close_run(run, "cancelled", cancellation_outcome: "fenced_timeout")
            true

          %Run{status: status} = run when status in ["pending", "running", "waiting"] ->
            case Store.lock_step(run.id, run.current_step_seq) do
              %Step{type: "step", status: "running"} = step ->
                Engine.abandon_expired(run, step, now)
                true

              _other ->
                false
            end

          _terminal_or_missing ->
            false
        end
      end)
    end)
  end

  defp rewake_stalled(now) do
    cutoff = DateTime.add(now, -Limits.get(:stale_wake_seconds), :second)

    ids =
      Repo.all(
        from(r in Run,
          where: r.status in ["pending", "running"] and r.updated_at < ^cutoff,
          where:
            fragment(
              "NOT EXISTS (SELECT 1 FROM fyrlet_run_attempts a WHERE a.run_id = ? AND a.status = 'leased')",
              r.id
            ),
          select: r.id,
          limit: ^Limits.get(:scan_batch)
        )
      )

    Enum.each(ids, fn id -> Repo.transaction(fn -> Worker.wake(id) end) end)
    length(ids)
  end

  defp wait_timeouts(now) do
    due =
      Repo.all(
        from(s in Step,
          join: r in Run,
          on: r.id == s.run_id and r.current_step_seq == s.seq,
          where:
            s.status == "waiting" and s.wait_deadline <= ^now and
              r.status in ["waiting", "running"],
          select: {s.run_id, s.id},
          limit: ^Limits.get(:scan_batch)
        )
      )

    Enum.count(due, fn {run_id, step_id} ->
      Engine.expire_wait(run_id, step_id) not in [:noop, nil]
    end)
  end

  defp cancel_deadlines(now) do
    ids =
      Repo.all(
        from(r in Run,
          where: r.status == "cancelling" and r.cancel_deadline <= ^now,
          where: r.expires_at > ^now,
          select: r.id,
          limit: ^Limits.get(:scan_batch)
        )
      )

    Enum.count(ids, fn id ->
      Engine.transact(fn ->
        case Store.lock_run(id) do
          %Run{status: "cancelling"} = run ->
            Store.close_run(run, "cancelled", cancellation_outcome: "fenced_timeout")
            true

          _other ->
            false
        end
      end)
    end)
  end

  defp expired_runs(now) do
    ids =
      Repo.all(
        from(r in Run,
          where: r.status in ^@active and r.expires_at <= ^now,
          select: r.id,
          limit: ^Limits.get(:scan_batch)
        )
      )

    Enum.count(ids, fn id ->
      Engine.transact(fn ->
        case Store.lock_run(id) do
          %Run{status: status} = run when status in @active ->
            outcome =
              if status == "cancelling", do: [cancellation_outcome: "fenced_timeout"], else: []

            Store.close_run(
              run,
              "expired",
              [error: Engine.error_map("RUN_EXPIRED", "The run reached its deadline")] ++ outcome
            )

            true

          _other ->
            false
        end
      end)
    end)
  end

  defp invalid_grants(now) do
    ids =
      Repo.all(
        from(r in Run,
          join: g in Fyrlet.Runs.Grant,
          on: g.id == r.execution_grant_id,
          where: r.status in ["pending", "running", "waiting"],
          where: not is_nil(g.revoked_at) or g.expires_at <= ^now,
          select: r.id,
          limit: ^Limits.get(:scan_batch)
        )
      )

    Enum.count(ids, fn id ->
      Engine.transact(fn ->
        case Store.lock_run(id) do
          %Run{status: status} = run when status in ["pending", "running", "waiting"] ->
            Engine.fail_for_grant(run)
            true

          _other ->
            false
        end
      end)
    end)
  end

  defp definitions(now) do
    cutoff = DateTime.add(now, -Limits.get(:definition_unavailable_ttl), :second)

    runs =
      Repo.all(
        from(r in Run,
          where: r.status == "waiting" and r.wait_reason == "definition_unavailable",
          limit: ^Limits.get(:scan_batch)
        )
      )

    Enum.count(runs, fn run ->
      cond do
        Resolver.implementation(run) != nil ->
          Repo.transaction(fn -> Worker.wake(run.id) end)
          true

        DateTime.compare(run.updated_at, cutoff) == :lt ->
          Engine.transact(fn ->
            case Store.lock_run(run.id) do
              %Run{status: "waiting", wait_reason: "definition_unavailable"} = locked ->
                Store.close_run(locked, "failed",
                  error:
                    Engine.error_map(
                      "DEFINITION_UNAVAILABLE",
                      "The pinned definition version is no longer available"
                    )
                )

                true

              _other ->
                false
            end
          end)

        true ->
          false
      end
    end)
  end
end
