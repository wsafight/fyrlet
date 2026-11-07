defmodule Fyrlet.InvalidationModeTest do
  use Fyrlet.DataCase, async: false
  use Oban.Testing, repo: Fyrlet.Repo

  setup do
    project = project()
    alice = user(project, "alice")

    Phoenix.PubSub.subscribe(
      Fyrlet.PubSub,
      "test:#{alice.actor.project_id}:#{alice.actor.subject_id}:records"
    )

    previous = Application.fetch_env!(:fyrlet, :durable_invalidation)
    on_exit(fn -> Application.put_env(:fyrlet, :durable_invalidation, previous) end)
    %{alice: alice}
  end

  test "durable mode persists a fallback job whose id is the broadcast identifier", %{
    alice: alice
  } do
    Application.put_env(:fyrlet, :durable_invalidation, true)

    assert {:ok, _item} = add(alice.actor)

    identifier = received_identifier()
    assert identifier > 0
    assert Repo.get!(Oban.Job, identifier).worker == "Fyrlet.InvalidationWorker"
  end

  test "default mode broadcasts after commit without persisting a job", %{alice: alice} do
    Application.put_env(:fyrlet, :durable_invalidation, false)

    assert {:ok, _item} = add(alice.actor)

    identifier = received_identifier()
    assert identifier < 0
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "a rolled-back write broadcasts nothing in either mode", %{alice: alice} do
    for durable <- [true, false] do
      Application.put_env(:fyrlet, :durable_invalidation, durable)

      assert {:error, _error} =
               Fyrlet.Runtime.call(alice.actor, "records.add", %{}, Ecto.UUID.generate())

      refute_receive {:invalidated, _identifier, _change}, 50
      refute_receive {:invalidated, _identifier}, 0
    end
  end

  describe "writes nested in a larger transaction" do
    test "default mode broadcasts once, only after the outer commit", %{alice: alice} do
      Application.put_env(:fyrlet, :durable_invalidation, false)

      assert {:ok, _item} =
               Fyrlet.Transaction.run(fn ->
                 result = add(alice.actor)
                 refute_received {:invalidated, _identifier, _change}
                 refute_received {:invalidated, _identifier}
                 result
               end)

      identifier = received_identifier()
      assert identifier < 0
      refute_receive {:invalidated, _other, _change}, 50
      refute_receive {:invalidated, _other}, 0
    end

    test "default mode broadcasts nothing when the outer transaction rolls back", %{alice: alice} do
      Application.put_env(:fyrlet, :durable_invalidation, false)

      assert {:error, :rejected} =
               Fyrlet.Transaction.run(fn ->
                 assert {:ok, _item} = add(alice.actor)
                 Repo.rollback(:rejected)
               end)

      refute_receive {:invalidated, _identifier, _change}, 50
      refute_receive {:invalidated, _identifier}, 0
    end

    test "default mode keeps the durable job when the outer commit is not managed", %{
      alice: alice
    } do
      Application.put_env(:fyrlet, :durable_invalidation, false)

      # A plain Repo.transaction never flushes pending broadcasts, so the job is the only notice.
      assert {:ok, {:ok, _item}} = Repo.transaction(fn -> add(alice.actor) end)

      assert [%Oban.Job{worker: "Fyrlet.InvalidationWorker"}] = Repo.all(Oban.Job)
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :fyrlet)
      identifier = received_identifier()
      assert identifier > 0
    end
  end

  test "transient identifiers are unique and never collide with database job ids" do
    ids = for _ <- 1..1000, do: Fyrlet.InvalidationWorker.transient(["s"], 1).id
    assert length(Enum.uniq(ids)) == 1000
    assert Enum.all?(ids, &(&1 < 0))
  end

  test "the environment variable is parsed strictly" do
    assert Fyrlet.RuntimeConfig.settings(:test, &env(&1, "true"))[:durable_invalidation] == true
    assert Fyrlet.RuntimeConfig.settings(:test, &env(&1, "0"))[:durable_invalidation] == false

    refute Keyword.has_key?(
             Fyrlet.RuntimeConfig.settings(:test, fn _ -> nil end),
             :durable_invalidation
           )

    assert_raise RuntimeError, ~r/FYRLET_DURABLE_INVALIDATION/, fn ->
      Fyrlet.RuntimeConfig.settings(:test, &env(&1, "maybe"))
    end
  end

  defp received_message do
    assert_receive message
    assert elem(message, 0) == :invalidated
    message
  end

  defp received_identifier, do: received_message() |> elem(1)

  defp env("FYRLET_DURABLE_INVALIDATION", value), do: value
  defp env(_name, _value), do: nil
end
