defmodule Fyrlet.SessionChecksTest do
  use Fyrlet.DataCase, async: false
  alias Fyrlet.SessionChecks

  setup do
    previous = Application.fetch_env!(:fyrlet, :batch_session_checks)
    Application.put_env(:fyrlet, :batch_session_checks, true)
    on_exit(fn -> Application.put_env(:fyrlet, :batch_session_checks, previous) end)
    %{alice: user(project())}
  end

  test "queued checks share one fresh query without caching its result", %{alice: alice} do
    worker = SessionChecks.server(alice.actor)
    handler = attach()
    :sys.suspend(worker)
    on_exit(fn -> :sys.resume(worker) end)

    references =
      for _index <- 1..20 do
        reference = make_ref()
        send(worker, {:"$gen_call", {self(), reference}, {:revalidate, alice.actor}})
        reference
      end

    :sys.resume(worker)

    for reference <- references do
      assert_receive {^reference, {:ok, actor}}
      assert actor == alice.actor
    end

    assert_receive {:batch, %{requests: 20, sessions: 1}}
    refute_receive {:batch, _measurements}
    :telemetry.detach(handler)
    assert {:ok, _result} = Auth.revoke_own_session(alice.actor)
    assert {:error, %Error{code: "UNAUTHENTICATED"}} = Auth.revalidate(alice.actor)
  end

  test "large groups split into bounded queries", %{alice: alice} do
    worker = SessionChecks.server(alice.actor)
    attach()
    :sys.suspend(worker)
    on_exit(fn -> :sys.resume(worker) end)

    references =
      for _index <- 1..257 do
        reference = make_ref()
        send(worker, {:"$gen_call", {self(), reference}, {:revalidate, alice.actor}})
        reference
      end

    :sys.resume(worker)

    for reference <- references, do: assert_receive({^reference, {:ok, _actor}})
    assert_receive {:batch, %{requests: 128, sessions: 1}}
    assert_receive {:batch, %{requests: 128, sessions: 1}}
    assert_receive {:batch, %{requests: 1, sessions: 1}}
    refute_receive {:batch, _measurements}
  end

  test "a check arriving after a query starts is validated by a later query", %{alice: alice} do
    worker = alice.actor |> SessionChecks.server() |> Process.whereis()
    owner = self()
    handler = "session-race-#{Ecto.UUID.generate()}"

    :telemetry.attach(
      handler,
      [:fyrlet, :auth, :batch],
      fn _event, _measurements, _metadata, owner ->
        send(owner, {:queried, self()})
        receive do: (:release -> :ok)
      end,
      owner
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      send(worker, :release)
    end)

    first = Task.async(fn -> Auth.revalidate(alice.actor) end)
    assert_receive {:queried, ^worker}
    assert {:ok, _result} = Auth.revoke_own_session(alice.actor)
    reference = make_ref()
    send(worker, {:"$gen_call", {self(), reference}, {:revalidate, alice.actor}})
    :telemetry.detach(handler)
    send(worker, :release)
    assert {:ok, _actor} = Task.await(first)
    assert_receive {^reference, {:error, %Error{code: "UNAUTHENTICATED"}}}
  end

  test "batched checks enforce identity, expiry and missing sessions", %{alice: alice} do
    assert {:error, %Error{code: "UNAUTHENTICATED"}} =
             Auth.revalidate(%{alice.actor | project_id: Ecto.UUID.generate()})

    assert {:error, %Error{code: "UNAUTHENTICATED"}} =
             Auth.revalidate(%{alice.actor | subject_id: Ecto.UUID.generate()})

    assert {:error, %Error{code: "UNAUTHENTICATED"}} =
             Auth.revalidate(%{alice.actor | session_id: Ecto.UUID.generate()})

    Repo.update_all(from(session in Fyrlet.Session, where: session.id == ^alice.actor.session_id),
      set: [expires_at: DateTime.add(Auth.now(), -1, :second)]
    )

    assert {:error, %Error{code: "UNAUTHENTICATED"}} = Auth.revalidate(alice.actor)
  end

  test "locked checks and caller transactions bypass the batch worker", %{alice: alice} do
    attach()

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               assert {:ok, _actor} = Auth.revalidate(alice.actor)
               assert {:ok, _actor} = Auth.revalidate(alice.actor, true)
               :ok
             end)

    refute_receive {:batch, _measurements}
  end

  defp attach do
    handler = "session-batch-#{Ecto.UUID.generate()}"

    :telemetry.attach(
      handler,
      [:fyrlet, :auth, :batch],
      fn _event, measurements, _metadata, owner -> send(owner, {:batch, measurements}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    handler
  end
end
