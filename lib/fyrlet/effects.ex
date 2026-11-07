defmodule Fyrlet.Effects do
  @moduledoc """
  Durable external side effects (the outbox).

  A step that needs to touch the outside world returns `{:effect, spec}`. The effect is
  stored in the same transaction as the step's state, so "the intent exists" and "the step is
  waiting for it" commit together or not at all. Only the dispatcher talks to the outside,
  and it does so outside any transaction.

  What this module does **not** do is promise that an external system acts once. It records
  intent, attempts and uncertain outcomes, retries only where the receiver's declared
  behaviour makes that safe, and otherwise stops and asks a person:

      idempotent        retry with the same operation_id while the receiver's window lasts
      query_only        ask the receiver what became of it; never resend because a query
                        found nothing
      allow_duplicates  retry even though a duplicate is possible (the step opted in)
      manual            an uncertain outcome pauses the effect for a person to decide

  An outcome that stays unknown is never turned into a failure on its own.
  """
  import Ecto.Query
  require Logger
  import Fyrlet.Effects.Store
  alias Fyrlet.{Auth, Error, Repo}
  alias Fyrlet.Effects.Adapter
  alias Fyrlet.Effects.{Effect, Worker}
  alias Fyrlet.Runs.{Faults, Plan, Run, Step, Store}

  @open ~w(pending claimed accepted unknown)
  @name ~r/^[a-z][a-z0-9_.-]{0,63}$/

  def open_states, do: @open

  defdelegate receipt(effect_id, receipt_id, outcome, result \\ %{}), to: Fyrlet.Effects.Receipt

  defdelegate resolve(effect_id, decision, operator, evidence, options \\ []),
    to: Fyrlet.Effects.Resolution

  defdelegate recover(now), to: Fyrlet.Effects.Recovery

  # ---- tunables -----------------------------------------------------------------------

  defp setting(key, default),
    do: :fyrlet |> Application.get_env(:effects, []) |> Keyword.get(key, default)

  defp lease_seconds, do: setting(:lease_seconds, 60)
  @doc false
  def reconcile_ttl, do: setting(:reconcile_ttl_seconds, 86_400)
  defp reconcile_delay, do: setting(:reconcile_delay_seconds, 30)
  defp retry_base, do: setting(:retry_base_seconds, 2)
  defp retry_max, do: setting(:retry_max_seconds, 300)

  # ---- creating (inside the step's commit transaction) --------------------------------

  @doc """
  Records the intent. Returns `{:ok, effect}` or `{:error, %Fyrlet.Error{}}`. The same
  step returning the same effect again (a retry) finds the existing one; the same key with a
  different request is a conflict.
  """
  def create(%Run{} = run, %Step{} = step, spec, now) do
    with {:ok, spec} <- normalise(spec),
         {:ok, module} <- adapter(spec.adapter),
         {:ok, payload} <- Plan.payload(spec.payload, "effect payload") |> wrap() do
      hash = Auth.hash(Jason.encode!(payload))

      case Repo.get_by(Effect, step_id: step.id, effect_key: spec.key) do
        %Effect{payload_hash: ^hash} = existing ->
          {:ok, existing}

        %Effect{} ->
          {:error,
           Error.new("EFFECT_CONFLICT", "The effect key was reused with a different request")}

        nil ->
          insert(run, step, spec, module, payload, hash, now)
      end
    end
  end

  defp insert(run, step, spec, module, payload, hash, now) do
    capabilities = module.capabilities()

    effect =
      Repo.insert!(%Effect{
        project_id: run.project_id,
        run_id: run.id,
        step_id: step.id,
        effect_key: spec.key,
        operation_id: "#{run.id}:#{step.seq}:#{spec.key}",
        adapter: spec.adapter,
        adapter_version: to_string(capabilities["version"] || "1"),
        delivery_policy: policy(capabilities, spec),
        payload: payload,
        payload_hash: hash,
        status: "pending",
        max_attempts: spec.max_attempts,
        next_attempt_at: now,
        secret_ref: spec.secret_ref
      })

    record(effect.id, "effect.created", %{"policy" => effect.delivery_policy})
    Worker.enqueue("dispatch", effect.id)
    {:ok, effect}
  end

  defp normalise(spec) when is_list(spec), do: normalise(Map.new(spec))

  defp normalise(%{adapter: adapter, payload: payload} = spec)
       when is_binary(adapter) and is_map(payload) do
    key = Map.get(spec, :key, "default")

    if is_binary(key) and Regex.match?(@name, key) do
      {:ok,
       %{
         adapter: adapter,
         key: key,
         payload: payload,
         secret_ref: Map.get(spec, :secret_ref),
         allow_duplicates: Map.get(spec, :retry_allow_duplicates, false) == true,
         max_attempts: Map.get(spec, :max_attempts, 5)
       }}
    else
      {:error, Error.new("VALIDATION_FAILED", "An effect key must be a short lowercase name")}
    end
  end

  defp normalise(_spec),
    do:
      {:error,
       Error.new("VALIDATION_FAILED", "An effect needs an adapter name and a payload map")}

  defp adapter(name) do
    case Adapter.fetch(name) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        {:error, Error.new("VALIDATION_FAILED", "Unknown effect adapter #{inspect(name)}")}
    end
  end

  defp policy(capabilities, spec) do
    cond do
      capabilities["idempotency"] -> "idempotent"
      capabilities["queryable"] -> "query_only"
      spec.allow_duplicates -> "allow_duplicates"
      true -> "manual"
    end
  end

  defp wrap({:ok, value}), do: {:ok, value}
  defp wrap({:error, error}), do: {:error, error}

  # ---- dispatching --------------------------------------------------------------------

  @doc "Claims and delivers one effect. Safe to call any number of times."
  def dispatch(effect_id) do
    case claim(effect_id) do
      {:dispatch, claimed, module} ->
        Faults.check(:effect_claimed)
        outcome = safe_dispatch(module, claimed)
        Faults.check(:effect_before_settle)
        settle(claimed, outcome)

      other ->
        other
    end
  end

  defp claim(effect_id) do
    transact(fn ->
      with %Effect{} = probe <- Repo.get(Effect, effect_id),
           %Run{} = run <- Store.lock_run(probe.run_id),
           %Effect{status: "pending"} = effect <- lock(effect_id) do
        now = Auth.now()

        cond do
          run.status in ["completed", "failed", "cancelled", "expired", "cancelling"] ->
            # Never started, so it can safely be withdrawn.
            change(effect, status: "cancelled", finished_at: now)
            record(effect.id, "effect.cancelled", %{"reason" => "run_" <> run.status})
            :noop

          effect.next_attempt_at && DateTime.compare(effect.next_attempt_at, now) == :gt ->
            :noop

          over_rate?(effect, now) ->
            # Over the project's dispatch budget: try again shortly rather than burst.
            Worker.enqueue("dispatch", effect.id, schedule_in: 1)
            :noop

          true ->
            {:ok, module} = Adapter.fetch(effect.adapter)

            claimed =
              change(effect,
                status: "claimed",
                lease_id: Ecto.UUID.generate(),
                execution_epoch: effect.execution_epoch + 1,
                lease_expires_at: DateTime.add(now, lease_seconds(), :second),
                attempts: effect.attempts + 1,
                claimed_at: now,
                first_dispatched_at: effect.first_dispatched_at || now
              )

            record(claimed.id, "effect.claimed", %{
              "attempt" => claimed.attempts,
              "epoch" => claimed.execution_epoch
            })

            {:dispatch, claimed, module}
        end
      else
        _other -> :noop
      end
    end)
  end

  defp over_rate?(effect, now) do
    recent =
      Repo.one(
        from(e in Effect,
          where:
            e.project_id == ^effect.project_id and e.claimed_at > ^DateTime.add(now, -1, :second),
          select: count(e.id)
        )
      )

    recent >= setting(:max_dispatch_per_second, 50)
  end

  defp safe_dispatch(module, effect) do
    case module.dispatch(adapter_view(effect)) do
      {:succeeded, _} = outcome -> outcome
      {:accepted, ref} = outcome when is_binary(ref) -> outcome
      {:failed, _} = outcome -> outcome
      {:retryable, _} = outcome -> outcome
      :unknown -> :unknown
      _other -> :unknown
    end
  rescue
    exception ->
      # The request may have left before the failure: the outcome is unknown, not failed.
      Logger.error("Effect adapter raised #{inspect(exception.__struct__)}")
      :unknown
  catch
    kind, _reason ->
      Logger.error("Effect adapter ended abnormally (#{kind})")
      :unknown
  end

  defp adapter_view(effect) do
    %{
      id: effect.id,
      run_id: effect.run_id,
      project_id: effect.project_id,
      operation_id: effect.operation_id,
      key: effect.effect_key,
      payload: effect.payload,
      secret_ref: effect.secret_ref,
      attempt: effect.attempts,
      external_ref: effect.external_ref,
      adapter_version: effect.adapter_version
    }
  end

  @doc false
  def settle(claimed, outcome) do
    transact(fn ->
      with %Run{} = run <- Store.lock_run(claimed.run_id),
           %Effect{} = effect <- lock(claimed.id) do
        if effect.status == "claimed" and effect.lease_id == claimed.lease_id and
             effect.execution_epoch == claimed.execution_epoch do
          settle_locked(run, effect, outcome)
        else
          record(effect.id, "effect.late_result", %{
            "outcome" => label(outcome),
            "epoch" => claimed.execution_epoch
          })

          :stale
        end
      else
        _gone -> :stale
      end
    end)
  end

  defp settle_locked(run, effect, outcome) do
    now = Auth.now()

    case outcome do
      {:succeeded, result} ->
        effect =
          change(effect,
            status: "succeeded",
            result: wrap_result(result),
            finished_at: now,
            lease_id: nil
          )

        record(effect.id, "effect.succeeded", %{})
        emit(effect, "succeeded")
        Fyrlet.Runs.Engine.effect_resolved(run, effect, :succeeded)
        :succeeded

      {:accepted, ref} ->
        effect =
          change(effect,
            status: "accepted",
            external_ref: ref,
            lease_id: nil,
            next_attempt_at: DateTime.add(now, reconcile_delay(), :second)
          )

        record(effect.id, "effect.accepted", %{"external_ref" => ref})
        schedule_reconcile(effect)
        emit(effect, "accepted")
        :accepted

      {:failed, reason} ->
        effect =
          change(effect,
            status: "failed",
            last_error: error_map(reason),
            finished_at: now,
            lease_id: nil
          )

        record(effect.id, "effect.failed", %{"reason" => inspect_reason(reason)})
        emit(effect, "failed")
        Fyrlet.Runs.Engine.effect_resolved(run, effect, :failed)
        :failed

      {:retryable, reason} ->
        retry_or_fail(run, effect, reason, now)

      :unknown ->
        uncertain(run, effect, now)
    end
  end

  defp retry_or_fail(run, effect, reason, now) do
    if effect.attempts < effect.max_attempts do
      delay = backoff(effect.attempts)

      change(effect,
        status: "pending",
        lease_id: nil,
        last_error: error_map(reason),
        next_attempt_at: DateTime.add(now, delay, :second)
      )

      record(effect.id, "effect.retry_scheduled", %{"delay_s" => delay})
      Worker.enqueue("dispatch", effect.id, schedule_in: delay)
      :retry
    else
      effect =
        change(effect,
          status: "failed",
          last_error: error_map(reason),
          finished_at: now,
          lease_id: nil
        )

      record(effect.id, "effect.failed", %{"reason" => "attempts_exhausted"})
      emit(effect, "failed")
      Fyrlet.Runs.Engine.effect_resolved(run, effect, :failed)
      :failed
    end
  end

  # An uncertain outcome: what may happen next depends on what the receiver guarantees.
  @doc false
  def uncertain(_run, effect, now) do
    cond do
      within_idempotency_window?(effect, now) and effect.attempts < effect.max_attempts ->
        delay = backoff(effect.attempts)

        change(effect,
          status: "pending",
          lease_id: nil,
          next_attempt_at: DateTime.add(now, delay, :second)
        )

        record(effect.id, "effect.retry_scheduled", %{
          "delay_s" => delay,
          "reason" => "unknown_within_idempotency_window"
        })

        Worker.enqueue("dispatch", effect.id, schedule_in: delay)
        :retry

      effect.delivery_policy == "allow_duplicates" and effect.attempts < effect.max_attempts ->
        delay = backoff(effect.attempts)

        change(effect,
          status: "pending",
          lease_id: nil,
          next_attempt_at: DateTime.add(now, delay, :second)
        )

        record(effect.id, "effect.retry_scheduled", %{
          "delay_s" => delay,
          "reason" => "duplicates_allowed"
        })

        Worker.enqueue("dispatch", effect.id, schedule_in: delay)
        :retry

      true ->
        manual? = effect.delivery_policy == "manual"

        effect =
          change(effect,
            status: "unknown",
            lease_id: nil,
            resolution_required: manual?,
            next_attempt_at: DateTime.add(now, reconcile_delay(), :second)
          )

        record(effect.id, "effect.unknown", %{"policy" => effect.delivery_policy})
        emit(effect, "unknown")
        if effect.delivery_policy == "query_only", do: schedule_reconcile(effect)
        :unknown
    end
  end

  @doc false
  def within_idempotency_window?(%Effect{delivery_policy: "idempotent"} = effect, now) do
    with {:ok, module} <- Adapter.fetch(effect.adapter),
         %{"window_seconds" => seconds} <- module.capabilities()["idempotency"],
         %DateTime{} = first <- effect.first_dispatched_at do
      DateTime.compare(DateTime.add(first, seconds, :second), now) == :gt
    else
      _other -> false
    end
  end

  @doc false
  def within_idempotency_window?(_effect, _now), do: false

  defp backoff(attempt),
    do: min(retry_base() * Integer.pow(2, max(attempt - 1, 0)), retry_max())

  # ---- reconciling --------------------------------------------------------------------

  defp schedule_reconcile(effect) do
    with {:ok, module} <- Adapter.fetch(effect.adapter),
         true <- module.capabilities()["queryable"] == true do
      delay = max(DateTime.diff(effect.next_attempt_at || Auth.now(), Auth.now(), :second), 0)
      Worker.enqueue("reconcile", effect.id, schedule_in: delay)
    end

    :ok
  end

  @doc "Asks the receiver what became of an accepted or unknown effect."
  def reconcile(effect_id) do
    with %Effect{status: status} = effect when status in ["accepted", "unknown"] <-
           Repo.get(Effect, effect_id),
         {:ok, module} <- Adapter.fetch(effect.adapter),
         true <-
           function_exported?(module, :query, 1) and module.capabilities()["queryable"] == true do
      outcome =
        try do
          module.query(adapter_view(effect))
        rescue
          _exception -> :unknown
        catch
          _kind, _reason -> :unknown
        end

      apply_reconciled(effect_id, effect.status, outcome)
    else
      _other -> :noop
    end
  end

  defp apply_reconciled(effect_id, expected_status, outcome) do
    transact(fn ->
      with %Effect{run_id: run_id} <- Repo.get(Effect, effect_id),
           %Run{} = run <- Store.lock_run(run_id),
           %Effect{status: ^expected_status} = effect <- lock(effect_id) do
        now = Auth.now()
        attempts = effect.reconcile_attempts + 1
        effect = change(effect, reconcile_attempts: attempts)

        case outcome do
          {:succeeded, result} ->
            effect =
              change(effect,
                status: "succeeded",
                result: wrap_result(result),
                finished_at: now,
                resolution_required: false
              )

            record(effect.id, "effect.reconciled", %{"outcome" => "succeeded"})
            emit_reconcile(effect, "succeeded")
            Fyrlet.Runs.Engine.effect_resolved(run, effect, :succeeded)
            :succeeded

          {:failed, reason} ->
            effect =
              change(effect,
                status: "failed",
                last_error: error_map(reason),
                finished_at: now,
                resolution_required: false
              )

            record(effect.id, "effect.reconciled", %{"outcome" => "failed"})
            emit_reconcile(effect, "failed")
            Fyrlet.Runs.Engine.effect_resolved(run, effect, :failed)
            :failed

          other ->
            # pending, not_found and unknown prove nothing: never resend because of them.
            record(effect.id, "effect.reconciled", %{"outcome" => to_string(label(other))})
            still_unknown(effect, now)
        end
      else
        _changed -> :noop
      end
    end)
  end

  defp still_unknown(effect, now) do
    age = DateTime.diff(now, effect.first_dispatched_at || effect.inserted_at, :second)

    effect =
      if age >= reconcile_ttl() and not effect.resolution_required do
        e = change(effect, resolution_required: true)
        record(e.id, "effect.resolution_required", %{"age_s" => age})
        e
      else
        effect
      end

    effect =
      change(effect,
        next_attempt_at:
          DateTime.add(now, reconcile_delay() * min(effect.reconcile_attempts + 1, 10), :second)
      )

    emit_reconcile(effect, "unresolved")
    schedule_reconcile(effect)
    :unresolved
  end

  # ---- cancelling ---------------------------------------------------------------------

  @doc "Withdraws effects that were never sent; asks cancellable receivers to drop accepted ones."
  def cancel_open(run_id) do
    now = Auth.now()

    for effect <-
          Repo.all(
            from(e in Effect, where: e.run_id == ^run_id and e.status in ["pending", "accepted"])
          ) do
      case effect.status do
        "pending" ->
          change(effect, status: "cancelled", finished_at: now)
          record(effect.id, "effect.cancelled", %{"reason" => "run_closed"})

        "accepted" ->
          Worker.enqueue("cancel", effect.id)
      end
    end

    :ok
  end

  @doc false
  def cancel_external(effect_id) do
    with %Effect{status: "accepted"} = effect <- Repo.get(Effect, effect_id),
         {:ok, module} <- Adapter.fetch(effect.adapter),
         true <-
           function_exported?(module, :cancel, 1) and module.capabilities()["cancellable"] == true do
      result =
        try do
          module.cancel(adapter_view(effect))
        rescue
          _exception -> {:error, :raised}
        end

      # The effect keeps its own state: a cancel request is not a cancel.
      transact(fn ->
        record(effect_id, "effect.cancel_requested", %{"result" => inspect_reason(result)})
      end)
    else
      _other -> :noop
    end
  end

  # ---- helpers ------------------------------------------------------------------------

  @doc "`{:error, EFFECT_UNKNOWN}` while the outcome of `effect_id` is not known."
  def ensure_known(effect_id) do
    case Repo.get(Effect, effect_id) do
      %Effect{status: "unknown"} ->
        {:error,
         Error.new("EFFECT_UNKNOWN", "The outcome of the external effect is not known", %{
           "effect_id" => effect_id
         })}

      %Effect{} ->
        :ok

      nil ->
        {:error, Error.not_found()}
    end
  end

  def summary(%Effect{} = effect) do
    %{
      "id" => effect.id,
      "key" => effect.effect_key,
      "adapter" => effect.adapter,
      "status" => effect.status,
      "policy" => effect.delivery_policy,
      "attempts" => effect.attempts,
      "resolution_required" => effect.resolution_required,
      "external_ref" => effect.external_ref
    }
  end
end
