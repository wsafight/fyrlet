defmodule Fyrlet.Effects.Receipt do
  @moduledoc """
  Delivery receipts from the receiver of an effect.
  """
  import Fyrlet.Effects.Store
  alias Fyrlet.{Auth, Error, Repo}
  alias Fyrlet.Effects.{Effect, Event}
  alias Fyrlet.Runs.{Run, Store}

  @doc """
  Applies a delivery receipt from the receiver. `receipt_id` makes redelivery harmless;
  the receipt of a different outcome after a final one is recorded, never applied.
  """
  def receipt(effect_id, receipt_id, outcome, result \\ %{})
      when outcome in ["succeeded", "failed"] and is_binary(receipt_id) do
    transact(fn ->
      with %Effect{run_id: run_id} <- Repo.get(Effect, effect_id),
           %Run{} = run <- Store.lock_run(run_id),
           %Effect{} = effect <- lock(effect_id) do
        case Repo.get_by(Event, effect_id: effect.id, receipt_id: receipt_id) do
          %Event{} -> {:ok, %{"status" => "duplicate", "effect_status" => effect.status}}
          nil -> apply_receipt(run, effect, receipt_id, outcome, result)
        end
      else
        _missing -> {:error, Error.not_found()}
      end
    end)
    |> case do
      {:error, %Error{}} = error -> error
      {:ok, _} = ok -> ok
      other -> other
    end
  end

  defp apply_receipt(run, effect, receipt_id, outcome, result) do
    now = Auth.now()

    cond do
      effect.status in ["accepted", "unknown", "claimed", "pending"] ->
        status = if outcome == "succeeded", do: "succeeded", else: "failed"

        fields =
          if outcome == "succeeded",
            do: [
              status: status,
              result: wrap_result(result),
              finished_at: now,
              resolution_required: false,
              lease_id: nil
            ],
            else: [
              status: status,
              last_error: error_map(result),
              finished_at: now,
              resolution_required: false,
              lease_id: nil
            ]

        effect = change(effect, fields)
        record(effect.id, "effect.receipt", %{"outcome" => outcome}, receipt_id)
        emit(effect, status)
        Fyrlet.Runs.Engine.effect_resolved(run, effect, String.to_existing_atom(outcome))
        {:ok, %{"status" => "applied", "effect_status" => status}}

      effect.status == outcome ->
        record(
          effect.id,
          "effect.receipt",
          %{"outcome" => outcome, "note" => "repeat"},
          receipt_id
        )

        {:ok, %{"status" => "duplicate", "effect_status" => effect.status}}

      true ->
        record(
          effect.id,
          "effect.receipt_conflict",
          %{"received" => outcome, "recorded" => effect.status},
          receipt_id
        )

        {:error, Error.new("CONFLICT", "The receipt contradicts the recorded outcome")}
    end
  end
end
