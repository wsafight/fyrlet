defmodule Fyrlet.TransactionTest do
  use Fyrlet.DataCase, async: false
  alias Fyrlet.{AfterCommit, Repo, Transaction}

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
                 AfterCommit.emit([:fyrlet, :test, :commit], %{}, %{outcome: :committed})
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
                 AfterCommit.emit([:fyrlet, :test, :commit], %{}, %{outcome: :rolled_back})
               end)

               Repo.rollback(:rejected)
             end)

    refute_received :rolled_back
    assert :next = Transaction.run(fn -> :next end)
  end

  test "exceptions release transaction ownership and discard pending telemetry" do
    assert_raise RuntimeError, fn ->
      Transaction.run(fn ->
        AfterCommit.emit([:fyrlet, :test, :commit], %{}, %{outcome: :failed})
        raise "failed callback"
      end)
    end

    assert :next = Transaction.run(fn -> :next end)
    refute_received :failed
  end

  test "nested invalidations persist once and broadcast only after commit" do
    project = project()
    scope = "test:#{project.project.id}"
    Phoenix.PubSub.subscribe(Fyrlet.PubSub, scope)

    assert :done =
             Transaction.run(fn ->
               AfterCommit.invalidate(:record, project.project.id, [scope])

               Transaction.run(fn ->
                 AfterCommit.invalidate(:record, project.project.id, [scope])
               end)

               refute_received {:invalidated, _identifier}
               :done
             end)

    assert_received {:invalidated, identifier}
    refute_received {:invalidated, _other}
    assert Repo.get!(Oban.Job, identifier).args["scopes"] == [scope]
  end

  test "a rollback removes durable invalidations and pending broadcasts" do
    project = project()
    scope = "test:#{project.project.id}"
    Phoenix.PubSub.subscribe(Fyrlet.PubSub, scope)
    before = Repo.aggregate(Oban.Job, :count)

    assert {:error, :rejected} =
             Transaction.run(fn ->
               AfterCommit.invalidate(:record, project.project.id, [scope])
               Repo.rollback(:rejected)
             end)

    assert Repo.aggregate(Oban.Job, :count) == before
    assert :next = Transaction.run(fn -> :next end)
    refute_received {:invalidated, _identifier}
  end

  test "telemetry preserves insertion order across multiple nesting depths" do
    assert :done =
             Transaction.run(fn ->
               emit(:first)

               Transaction.run(fn ->
                 emit(:second)
                 Transaction.run(fn -> emit(:third) end)
                 emit(:fourth)
               end)

               emit(:fifth)
               refute_received :first
               refute_received :third
               :done
             end)

    for expected <- [:first, :second, :third, :fourth, :fifth] do
      assert_receive actual
      assert actual == expected
    end
  end

  test "an error tuple returned by the callback is a committed result" do
    project = project()
    scope = "test:#{project.project.id}"
    Phoenix.PubSub.subscribe(Fyrlet.PubSub, scope)

    assert {:error, :ordinary_value} =
             Transaction.run(fn ->
               AfterCommit.invalidate(:record, project.project.id, [scope])
               emit(:committed_error_tuple)
               {:error, :ordinary_value}
             end)

    assert_received :committed_error_tuple
    assert_received {:invalidated, identifier}
    assert Repo.get!(Oban.Job, identifier).args["scopes"] == [scope]
  end

  test "the same invalidation key is independently persisted in successive transactions" do
    project = project()
    scope = "test:#{project.project.id}"
    Phoenix.PubSub.subscribe(Fyrlet.PubSub, scope)
    before = Repo.aggregate(Oban.Job, :count)

    for _index <- 1..2 do
      assert :ok =
               Transaction.run(fn ->
                 AfterCommit.invalidate(:record, project.project.id, [scope])
                 AfterCommit.invalidate(:record, project.project.id, [scope])
               end)
    end

    assert_received {:invalidated, first}
    assert_received {:invalidated, second}
    assert first != second
    refute_received {:invalidated, _identifier}
    assert Repo.aggregate(Oban.Job, :count) == before + 2
  end

  test "different keys and projects retain independent durable jobs and scopes" do
    first = project()
    second = project()
    first_scope = "test:#{first.project.id}"
    second_scope = "test:#{second.project.id}"
    Phoenix.PubSub.subscribe(Fyrlet.PubSub, first_scope)
    Phoenix.PubSub.subscribe(Fyrlet.PubSub, second_scope)

    Transaction.run(fn ->
      AfterCommit.invalidate({first.project.id, :record}, first.project.id, [first_scope])
      AfterCommit.invalidate({second.project.id, :record}, second.project.id, [second_scope])
    end)

    assert_received {:invalidated, first_id}
    assert_received {:invalidated, second_id}
    jobs = [Repo.get!(Oban.Job, first_id), Repo.get!(Oban.Job, second_id)]

    assert MapSet.new(Enum.map(jobs, & &1.args)) ==
             MapSet.new([
               %{"project_id" => first.project.id, "scopes" => [first_scope]},
               %{"project_id" => second.project.id, "scopes" => [second_scope]}
             ])

    refute_received {:invalidated, _identifier}
  end

  for failure <- [:raise, :throw, :exit] do
    test "#{failure} rolls back jobs and releases ownership for the next transaction" do
      project = project()
      scope = "test:#{project.project.id}"
      Phoenix.PubSub.subscribe(Fyrlet.PubSub, scope)
      before = Repo.aggregate(Oban.Job, :count)

      callback = fn ->
        Transaction.run(fn ->
          AfterCommit.invalidate(:record, project.project.id, [scope])
          emit(:discarded)

          case unquote(failure) do
            :raise -> raise "failed callback"
            :throw -> throw(:failed_callback)
            :exit -> exit(:failed_callback)
          end
        end)
      end

      case unquote(failure) do
        :raise -> assert_raise RuntimeError, "failed callback", callback
        :throw -> assert catch_throw(callback.()) == :failed_callback
        :exit -> assert catch_exit(callback.()) == :failed_callback
      end

      assert Repo.aggregate(Oban.Job, :count) == before
      refute_received {:invalidated, _identifier}
      refute_received :discarded

      Transaction.run(fn ->
        AfterCommit.invalidate(:record, project.project.id, [scope])
        emit(:recovered)
      end)

      assert_received {:invalidated, identifier}
      assert_received :recovered
      assert Repo.get!(Oban.Job, identifier)
      assert Repo.aggregate(Oban.Job, :count) == before + 1
    end
  end

  test "a nested rollback allows the same key to be used by a later successful transaction" do
    project = project()
    scope = "test:#{project.project.id}"
    Phoenix.PubSub.subscribe(Fyrlet.PubSub, scope)

    assert {:error, :nested_rejection} =
             Transaction.run(fn ->
               AfterCommit.invalidate(:record, project.project.id, [scope])
               Transaction.run(fn -> Repo.rollback(:nested_rejection) end)
               flunk("the outer callback must not continue")
             end)

    refute_received {:invalidated, _identifier}

    Transaction.run(fn ->
      AfterCommit.invalidate(:record, project.project.id, [scope])
    end)

    assert_received {:invalidated, identifier}
    assert Repo.get!(Oban.Job, identifier)
    refute_received {:invalidated, _identifier}
  end

  test "durable replay reuses the immediate broadcast identifier without inserting another job" do
    project = project()
    scope = "test:#{project.project.id}"
    Phoenix.PubSub.subscribe(Fyrlet.PubSub, scope)

    Transaction.run(fn ->
      AfterCommit.invalidate(:record, project.project.id, [scope])
    end)

    assert_received {:invalidated, identifier}
    before = Repo.aggregate(Oban.Job, :count)
    assert :ok = Fyrlet.InvalidationWorker.perform(Repo.get!(Oban.Job, identifier))
    assert_received {:invalidated, ^identifier}
    assert Repo.aggregate(Oban.Job, :count) == before
    refute_received {:invalidated, _identifier}
  end

  test "run notifications and generic invalidations compose without a deduplication collision" do
    alice = user(project())

    run = %{
      id: Ecto.UUID.generate(),
      project_id: alice.actor.project_id,
      subject_id: alice.actor.subject_id
    }

    scopes = Fyrlet.Runs.Notify.scopes(run.project_id, run.subject_id, run.id)
    generic_scope = "test:#{run.project_id}"
    for scope <- [generic_scope | scopes], do: Phoenix.PubSub.subscribe(Fyrlet.PubSub, scope)
    before = Repo.aggregate(Oban.Job, :count)

    Transaction.run(fn ->
      Fyrlet.Runs.Notify.mark(run)
      Transaction.run(fn -> Fyrlet.Runs.Notify.mark(run) end)
      AfterCommit.invalidate(run.id, run.project_id, [generic_scope])
      Fyrlet.Runs.Notify.emit([:fyrlet, :test, :commit], %{}, %{outcome: :run_committed})
      refute_received :run_committed
      refute_received {:invalidated, _identifier}
    end)

    assert_received :run_committed

    identifiers =
      for _index <- 1..3 do
        assert_received {:invalidated, identifier}
        identifier
      end

    assert identifiers |> Enum.frequencies() |> Map.values() |> Enum.sort() == [1, 2]
    assert Repo.aggregate(Oban.Job, :count) == before + 2
    jobs = identifiers |> Enum.uniq() |> Enum.map(&Repo.get!(Oban.Job, &1))
    assert Enum.any?(jobs, &(&1.args["scopes"] == scopes))
    assert Enum.any?(jobs, &(&1.args["scopes"] == [generic_scope]))
  end

  defp emit(outcome), do: AfterCommit.emit([:fyrlet, :test, :commit], %{}, %{outcome: outcome})
end
