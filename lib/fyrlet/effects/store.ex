defmodule Fyrlet.Effects.Store do
  @moduledoc false
  import Ecto.Query
  alias Fyrlet.{Auth, Error, Repo}
  alias Fyrlet.Effects.Effect
  alias Fyrlet.Runs.Notify

  def lock(id), do: Repo.one(from(e in Effect, where: e.id == ^id, lock: "FOR UPDATE"))

  def change(%Effect{} = effect, fields) do
    {1, [updated]} =
      Repo.update_all(from(e in Effect, where: e.id == ^effect.id, select: e),
        set: Keyword.put(fields, :updated_at, Auth.now())
      )

    updated
  end

  # One statement instead of an UPDATE and an INSERT; see Fyrlet.Runs.Store.event/4.
  @record_sql """
  WITH next AS (
    UPDATE fyrlet_effects SET event_seq = event_seq + 1 WHERE id = $1 RETURNING event_seq
  )
  INSERT INTO fyrlet_effect_events (id, effect_id, seq, type, payload, receipt_id, at)
  SELECT $2::uuid, $1::uuid, next.event_seq, $3::text, $4::jsonb, $5::text, $6::timestamp FROM next
  """

  @doc false
  def record(effect_id, type, payload, receipt_id \\ nil) do
    %{num_rows: 1} =
      Repo.query!(@record_sql, [
        Ecto.UUID.dump!(effect_id),
        Ecto.UUID.bingenerate(),
        type,
        payload,
        receipt_id,
        DateTime.to_naive(Auth.now())
      ])

    :ok
  end

  def transact(fun), do: Fyrlet.Runs.Engine.transact(fun)

  def wrap_result(result) when is_map(result), do: result
  def wrap_result(nil), do: %{}
  def wrap_result(other), do: %{"value" => inspect_reason(other)}

  def error_map(%Error{} = error), do: Error.to_map(error)
  def error_map(reason), do: %{"code" => "EFFECT_FAILED", "message" => inspect_reason(reason)}

  def inspect_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  def inspect_reason(reason), do: reason |> inspect() |> String.slice(0, 500)

  def label({tag, _}) when is_atom(tag), do: tag
  def label(atom) when is_atom(atom), do: atom
  def label(_other), do: :unexpected

  def emit(effect, status) do
    Notify.emit([:fyrlet, :effect, :stop], %{attempts: effect.attempts}, %{
      adapter: effect.adapter,
      status: status,
      unknown: status == "unknown"
    })
  end

  def emit_reconcile(effect, outcome) do
    age = DateTime.diff(Auth.now(), effect.first_dispatched_at || effect.inserted_at, :second)

    Notify.emit([:fyrlet, :effect, :reconcile], %{age_s: age}, %{
      adapter: effect.adapter,
      outcome: outcome,
      resolution_required: effect.resolution_required
    })
  end
end
