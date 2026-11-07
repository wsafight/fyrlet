defmodule Fyrlet.Effects.Resolution do
  @moduledoc """
  Human decisions about effects whose outcome stayed unknown.
  """
  import Fyrlet.Effects.Store
  alias Fyrlet.{Auth, Error, Repo}
  alias Fyrlet.Effects.{Effect, Worker}
  alias Fyrlet.Runs.{Run, Store}

  @doc """
  A person's decision about an effect whose outcome stayed unknown. Decisions are recorded
  with the operator and evidence and never overwrite the attempts that came before.

  Decisions: `"succeeded"`, `"failed"`, `"abandon"`, and `"resend"` (which needs
  `acknowledge_duplicates: true` unless the receiver can still de-duplicate).
  """
  def resolve(effect_id, decision, operator, evidence, options \\ []) do
    with :ok <- present(operator, "operator"),
         :ok <- present(evidence, "evidence") do
      transact(fn ->
        with %Effect{run_id: run_id} <- Repo.get(Effect, effect_id),
             %Run{} = run <- Store.lock_run(run_id),
             %Effect{status: status} = effect when status in ["unknown", "accepted"] <-
               lock(effect_id) do
          apply_decision(run, effect, decision, operator, evidence, options)
        else
          nil ->
            {:error, Error.not_found()}

          %Effect{} ->
            {:error, Error.new("CONFLICT", "Only an unresolved effect can be resolved")}

          _other ->
            {:error, Error.not_found()}
        end
      end)
    end
  end

  defp apply_decision(run, effect, decision, operator, evidence, options) do
    now = Auth.now()
    note = %{"decision" => decision, "operator" => operator, "evidence" => evidence}

    case decision do
      "succeeded" ->
        effect =
          change(effect,
            status: "succeeded",
            finished_at: now,
            resolution_required: false,
            result: %{"resolved_by" => operator}
          )

        record(effect.id, "effect.resolved", note)
        Fyrlet.Runs.Engine.effect_resolved(run, effect, :succeeded)
        {:ok, effect}

      "failed" ->
        effect =
          change(effect,
            status: "failed",
            finished_at: now,
            resolution_required: false,
            last_error: %{"code" => "RESOLVED_FAILED", "message" => evidence}
          )

        record(effect.id, "effect.resolved", note)
        Fyrlet.Runs.Engine.effect_resolved(run, effect, :failed)
        {:ok, effect}

      "abandon" ->
        effect =
          change(effect,
            status: "failed",
            finished_at: now,
            resolution_required: false,
            last_error: %{"code" => "ABANDONED_BY_OPERATOR", "message" => evidence}
          )

        record(effect.id, "effect.resolved", note)
        Fyrlet.Runs.Engine.effect_resolved(run, effect, :failed)
        {:ok, effect}

      "resend" ->
        if resend_allowed?(effect, now, options) do
          effect =
            change(effect,
              status: "pending",
              resolution_required: false,
              next_attempt_at: now,
              max_attempts: effect.max_attempts + 1
            )

          record(effect.id, "effect.resolved", note)
          Worker.enqueue("dispatch", effect.id)
          {:ok, effect}
        else
          {:error,
           Error.new("CONFLICT", "Resending may duplicate the effect; acknowledge it explicitly")}
        end

      _other ->
        {:error, Error.new("VALIDATION_FAILED", "Unknown decision")}
    end
  end

  defp resend_allowed?(effect, now, options),
    do:
      Keyword.get(options, :acknowledge_duplicates, false) == true or
        Fyrlet.Effects.within_idempotency_window?(effect, now)

  defp present(value, _label) when is_binary(value) and byte_size(value) in 1..2_000, do: :ok

  defp present(_value, label),
    do: {:error, Error.new("VALIDATION_FAILED", "#{label} is required")}
end
