defmodule Fyrlet.TransactionTest do
  use Fyrlet.DataCase, async: false
  alias Fyrlet.{Repo, Transaction}
  alias Fyrlet.Runs.Notify

  setup do
    handler = "transaction-#{Ecto.UUID.generate()}"
    pid = self()

    :telemetry.attach(
      handler,
      [:fyrlet, :test, :commit],
      fn _, _, metadata, _ -> send(pid, metadata.outcome) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  test "nested calls publish only after the outer transaction commits" do
    assert :done =
             Transaction.run(fn ->
               Transaction.run(fn ->
                 Notify.emit([:fyrlet, :test, :commit], %{}, %{outcome: :committed})
               end)

               refute_received :committed
               :done
             end)

    assert_received :committed
  end

  test "an outer rollback discards nested notifications and writes" do
    assert {:error, :rejected} =
             Transaction.run(fn ->
               Transaction.run(fn ->
                 Notify.emit([:fyrlet, :test, :commit], %{}, %{outcome: :rolled_back})
               end)

               Repo.rollback(:rejected)
             end)

    refute_received :rolled_back
    assert :next = Transaction.run(fn -> :next end)
  end

  test "exceptions release transaction ownership and discard pending telemetry" do
    assert_raise RuntimeError, fn ->
      Transaction.run(fn ->
        Notify.emit([:fyrlet, :test, :commit], %{}, %{outcome: :failed})
        raise "failed callback"
      end)
    end

    assert :next = Transaction.run(fn -> :next end)
    refute_received :failed
  end
end
