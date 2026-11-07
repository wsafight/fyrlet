defmodule Fyrlet.Runs.View do
  @moduledoc "Bounded read model of a run, used by the `fyrlet.run` subscription and HTTP."
  import Ecto.Query
  alias Fyrlet.Repo
  alias Fyrlet.Runs.{Event, Run, Step}

  @event_window 50
  @event_payload_bytes 1_024

  # The view shows summaries, so only the columns the summaries use are read. A step's input
  # and output (up to 64 KiB each) and an effect's payload and result (encrypted at rest) are
  # never fetched, decoded or decrypted for it.
  @step_fields [:id, :seq, :type, :name, :status, :current_attempt, :wait_deadline, :error]
  @effect_fields [
    :id,
    :effect_key,
    :adapter,
    :status,
    :delivery_policy,
    :attempts,
    :resolution_required,
    :external_ref,
    :inserted_at
  ]

  def build(%Run{} = run) do
    steps =
      Repo.all(
        from(s in Step,
          where: s.run_id == ^run.id,
          order_by: s.seq,
          select: struct(s, ^@step_fields)
        )
      )

    events =
      Repo.all(
        from(e in Event,
          where: e.run_id == ^run.id,
          order_by: [desc: e.seq],
          limit: ^(@event_window + 1)
        )
      )

    {shown, extra} = Enum.split(events, @event_window)

    summary(run)
    |> Map.merge(%{
      "current_step" => run.current_step_seq,
      "expires_at" => iso(run.expires_at),
      "cancel_deadline" => iso(run.cancel_deadline),
      "cancellation_outcome" => run.cancellation_outcome,
      "error_code" => run.error && run.error["code"],
      "error_message" => run.error && run.error["message"],
      "output_json" =>
        run.output && run.output |> Fyrlet.Runs.Privacy.redact(run.operation) |> Jason.encode!(),
      "steps" => Enum.map(steps, &step/1),
      "effects" => effects(run.id),
      "events" => shown |> Enum.reverse() |> Enum.map(&event/1),
      "events_truncated" => extra != []
    })
  end

  defp effects(run_id) do
    Fyrlet.Effects.Effect
    |> where([e], e.run_id == ^run_id)
    |> order_by([e], e.inserted_at)
    |> limit(100)
    |> select([e], struct(e, ^@effect_fields))
    |> Repo.all()
    |> Enum.map(&Fyrlet.Effects.summary/1)
  end

  @doc "The fields shared by the detail and list views."
  def summary(%Run{} = run) do
    %{
      "id" => run.id,
      "operation" => run.operation,
      "status" => run.status,
      "wait_reason" => run.wait_reason,
      "version" => run.version,
      "created_at" => iso(run.inserted_at),
      "finished_at" => iso(run.finished_at)
    }
  end

  defp step(%Step{} = step) do
    %{
      "id" => step.id,
      "seq" => step.seq,
      "type" => step.type,
      "name" => step.name,
      "status" => step.status,
      "attempt" => step.current_attempt,
      "wait_deadline" => iso(step.wait_deadline),
      "error_code" => step.error && step.error["code"]
    }
  end

  defp event(%Event{} = event) do
    json = Jason.encode!(event.payload)

    %{
      "seq" => event.seq,
      "type" => event.type,
      "step_id" => event.step_id,
      "at" => iso(event.created_at),
      "payload_json" => if(byte_size(json) <= @event_payload_bytes, do: json, else: nil)
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = time), do: DateTime.to_iso8601(time)
end
