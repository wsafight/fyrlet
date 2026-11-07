defmodule Fyrlet.WorkersTest do
  @moduledoc "The Oban entry points must delegate to the same code paths the tests exercise directly."
  use Fyrlet.RunsCase
  import Ecto.Query
  alias Fyrlet.Effects
  alias Fyrlet.Effects.{Effect, Event}
  alias Fyrlet.Features.Ingest
  alias Fyrlet.Features.Ingest.Item, as: IngestItem
  alias InboxExample.Item, as: Row

  setup do
    project = project()
    alice = user(project, "alice")
    on_exit(fn -> Application.delete_env(:fyrlet, :effect_handlers) end)
    %{alice: alice}
  end

  defp send_run(alice, adapter) do
    Application.put_env(:fyrlet, :run_plans, %{
      "runs.demo" => fn _, _ ->
        {:ok, steps: [%{type: :step, name: "send", input: %{}}]}
      end
    })

    Application.put_env(:fyrlet, :run_steps, %{
      "send" => fn _, _ ->
        {:effect, %{adapter: adapter, key: "mail", payload: %{"to" => "a@example.com"}}}
      end
    })

    id = start_run!(alice)
    assert drive(id) == "waiting"
    id
  end

  defp effect(run_id), do: Repo.one!(from(e in Effect, where: e.run_id == ^run_id))

  defp effect_event_types(effect_id),
    do:
      Repo.all(
        from(e in Event, where: e.effect_id == ^effect_id, order_by: e.seq, select: e.type)
      )

  test "the dispatch worker delivers a pending effect", %{alice: alice} do
    id = send_run(alice, "idem")
    e = effect(id)
    assert e.status == "pending"

    assert :ok = Effects.Worker.perform(%Oban.Job{args: %{"effect_id" => e.id}})

    assert effect(id).status == "succeeded"
    assert drive(id) == "completed"
  end

  test "the reconcile worker applies a late adapter answer", %{alice: alice} do
    id = send_run(alice, "query")
    e = effect(id)

    # A provider that accepted the request but never confirmed it: the effect is unknown.
    Repo.update_all(from(x in Effect, where: x.id == ^e.id), set: [status: "unknown"])

    Application.put_env(:fyrlet, :effect_handlers, %{
      query: fn _ -> {:succeeded, %{"late" => true}} end
    })

    assert :ok =
             Effects.Worker.perform(%Oban.Job{
               args: %{"kind" => "reconcile", "effect_id" => e.id}
             })

    reconciled = Repo.get!(Effect, e.id)
    assert reconciled.status == "succeeded"
    assert reconciled.result == %{"late" => true}
    assert "effect.reconciled" in effect_event_types(e.id)
    assert drive(id) == "completed"
  end

  test "the cancel worker asks a cancellable adapter without changing the effect's state", %{
    alice: alice
  } do
    id = send_run(alice, "idem")
    e = effect(id)
    Repo.update_all(from(x in Effect, where: x.id == ^e.id), set: [status: "accepted"])

    Application.put_env(:fyrlet, :effect_handlers, %{cancel: fn _ -> :ok end})

    assert :ok =
             Effects.Worker.perform(%Oban.Job{
               args: %{"kind" => "cancel", "effect_id" => e.id}
             })

    assert Repo.get!(Effect, e.id).status == "accepted"
    assert "effect.cancel_requested" in effect_event_types(e.id)
  end

  test "the ingest worker processes a stored batch idempotently", %{alice: alice} do
    items = [
      %{"key" => "a", "data" => %{"n" => 1, "text" => "one"}},
      %{"key" => "b", "data" => %{"n" => 2, "text" => "two"}}
    ]

    assert {:ok, %{"batch_id" => batch}} =
             Fyrlet.Runtime.call(
               alice.actor,
               "events.ingest",
               %{"items" => items},
               nil,
               capabilities: %{"ingest" => 1}
             )

    job = %Oban.Job{args: %{"batch_id" => batch}}
    assert :ok = Ingest.Worker.perform(job)
    assert Repo.aggregate(Row, :count) == 2

    statuses =
      Repo.all(
        from(i in IngestItem,
          where: i.batch_id == ^batch,
          order_by: i.seq,
          select: i.status
        )
      )

    assert statuses == ["done", "done"]

    # Re-running the job must not apply the handler twice.
    assert :ok = Ingest.Worker.perform(job)
    assert Repo.aggregate(Row, :count) == 2
  end

  test "process/1 is a no-op for a batch that does not exist" do
    assert :ok = Ingest.process(Ecto.UUID.generate())
  end
end
