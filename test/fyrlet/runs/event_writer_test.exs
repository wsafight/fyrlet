defmodule Fyrlet.Runs.EventWriterTest do
  @moduledoc """
  Run and effect events are each written with one statement (take the next sequence number and
  insert, under the row lock). These tests pin down what the two-statement version did.
  """
  use Fyrlet.RunsCase
  alias Fyrlet.Effects.Store, as: EffectStore
  alias Fyrlet.Runs.Store

  setup do
    alice = user(project(), "alice")

    Application.put_env(:fyrlet, :run_plans, %{
      "runs.demo" => fn _, _ -> {:ok, steps: [%{type: :step, name: "a", input: %{}}]} end
    })

    %{alice: alice, run_id: start_run!(alice)}
  end

  test "events get consecutive sequence numbers, in the order they were written", %{run_id: id} do
    before = length(events(id))
    for n <- 1..5, do: Store.event(id, "test.event", nil, %{"n" => n})
    written = Enum.drop(events(id), before)

    assert Enum.map(written, & &1.seq) == Enum.to_list((before + 1)..(before + 5))
    assert Enum.map(written, & &1.payload["n"]) == [1, 2, 3, 4, 5]
    assert run(id).event_seq == before + 5
  end

  test "the payload comes back exactly as it went in", %{run_id: id} do
    payload = %{
      "text" => "héllo ☃ \"quoted\" \\ back",
      "nested" => %{"list" => [1, 2.5, nil, true, %{"deep" => []}]},
      "empty" => %{},
      "big" => String.duplicate("x", 5_000)
    }

    Store.event(id, "test.payload", nil, payload)
    assert List.last(events(id)).payload == payload
  end

  test "the step is optional and recorded when given", %{run_id: id} do
    step = hd(steps(id))
    Store.event(id, "test.no_step", nil, %{})
    Store.event(id, "test.with_step", step.id, %{})
    [without, with] = Enum.take(events(id), -2)
    assert without.step_id == nil and with.step_id == step.id
  end

  test "created_at keeps microseconds and is not in the future", %{run_id: id} do
    Store.event(id, "test.time", nil, %{})
    event = List.last(events(id))
    assert %DateTime{microsecond: {_, 6}} = event.created_at
    assert DateTime.compare(event.created_at, DateTime.add(Fyrlet.Auth.now(), 1, :second)) == :lt
  end

  test "an event for a run that does not exist fails loudly instead of vanishing" do
    assert_raise MatchError, fn -> Store.event(Ecto.UUID.generate(), "test.orphan", nil, %{}) end
  end

  test "a rolled-back transaction takes its events and its sequence numbers back", %{run_id: id} do
    before = run(id).event_seq

    assert {:error, :boom} =
             Repo.transaction(fn ->
               Store.event(id, "test.rolled_back", nil, %{})
               Store.event(id, "test.rolled_back", nil, %{})
               Repo.rollback(:boom)
             end)

    assert run(id).event_seq == before
    refute "test.rolled_back" in event_types(id)
    Store.event(id, "test.after", nil, %{})
    assert List.last(events(id)).seq == before + 1
  end

  describe "effect events" do
    setup %{alice: alice} do
      Application.put_env(:fyrlet, :run_plans, %{
        "runs.demo" => fn _, _ -> {:ok, steps: [%{type: :step, name: "send", input: %{}}]} end
      })

      Application.put_env(:fyrlet, :run_steps, %{
        "send" => fn _, _ -> {:effect, %{adapter: "idem", key: "mail", payload: %{}}} end
      })

      id = start_run!(alice)
      drive(id)
      [effect] = Repo.all(Fyrlet.Effects.Effect)
      %{effect: effect}
    end

    defp effect_events(effect),
      do:
        Repo.all(
          from(e in Fyrlet.Effects.Event, where: e.effect_id == ^effect.id, order_by: e.seq)
        )

    test "sequence numbers are consecutive and payload and receipt id are kept", %{effect: effect} do
      before = length(effect_events(effect))
      EffectStore.record(effect.id, "test.one", %{"a" => 1})
      EffectStore.record(effect.id, "test.two", %{"b" => [1, 2]}, "receipt-1")
      [one, two] = Enum.drop(effect_events(effect), before)

      assert {one.seq, two.seq} == {before + 1, before + 2}
      assert {one.payload, one.receipt_id} == {%{"a" => 1}, nil}
      assert {two.payload, two.receipt_id} == {%{"b" => [1, 2]}, "receipt-1"}
      assert %DateTime{microsecond: {_, 6}} = two.at
    end

    test "a receipt id can be recorded once per effect", %{effect: effect} do
      EffectStore.record(effect.id, "test.receipt", %{}, "same")

      assert_raise Postgrex.Error, fn ->
        EffectStore.record(effect.id, "test.receipt", %{}, "same")
      end
    end

    test "an event for an effect that does not exist fails loudly" do
      assert_raise MatchError, fn ->
        EffectStore.record(Ecto.UUID.generate(), "test.orphan", %{})
      end
    end
  end
end
