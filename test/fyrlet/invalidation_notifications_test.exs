defmodule Fyrlet.InvalidationNotificationsTest do
  use Fyrlet.DataCase, async: false
  alias Fyrlet.{InvalidationNotifications, InvalidationWorker}

  setup do
    previous = Application.get_env(:fyrlet, :postgres_invalidation)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:fyrlet, :postgres_invalidation),
        else: Application.put_env(:fyrlet, :postgres_invalidation, previous)
    end)

    :ok
  end

  test "notifications are opt-in and the environment setting is strict" do
    Application.delete_env(:fyrlet, :postgres_invalidation)
    assert InvalidationNotifications.child_specs() == []
    Application.put_env(:fyrlet, :postgres_invalidation, true)
    assert InvalidationNotifications.child_specs() == [InvalidationNotifications]

    for {raw, expected} <- [{"true", true}, {"0", false}] do
      settings =
        Fyrlet.RuntimeConfig.settings(:test, fn
          "FYRLET_POSTGRES_INVALIDATION" -> raw
          _name -> nil
        end)

      assert settings[:postgres_invalidation] == expected
    end

    assert_raise RuntimeError, fn ->
      Fyrlet.RuntimeConfig.settings(:test, fn
        "FYRLET_POSTGRES_INVALIDATION" -> "maybe"
        _name -> nil
      end)
    end
  end

  test "decoding rejects malformed identifiers, scopes and oversized messages" do
    assert {:ok, %Oban.Job{id: -12}} =
             InvalidationNotifications.decode(~s({"id":-12,"scopes":["scope"]}))

    for payload <- [
          "not-json",
          ~s({"id":1,"scopes":["scope"]}),
          ~s({"id":-1,"scopes":[]}),
          ~s({"id":-1,"scopes":[1]}),
          ~s({"id":-1,"scopes":[""]}),
          String.duplicate("x", 8_000)
        ],
        do: assert(InvalidationNotifications.decode(payload) == :error)
  end

  test "a committed database notification reaches local subscribers and rollback sends nothing" do
    start_supervised!(InvalidationNotifications)
    scope = "notify-test:#{Ecto.UUID.generate()}"
    Phoenix.PubSub.subscribe(Fyrlet.PubSub, scope)
    committed = InvalidationWorker.transient([scope], "project")
    rolled_back = InvalidationWorker.transient([scope], "project")

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, :ok} =
               Repo.transaction(fn ->
                 :ok = InvalidationNotifications.enqueue(committed)
                 refute_receive {:invalidated, _identifier}, 25
                 :ok
               end)
    end)

    assert_receive {:invalidated, identifier}, 2_000
    assert identifier == committed.id

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      assert {:error, :rejected} =
               Repo.transaction(fn ->
                 :ok = InvalidationNotifications.enqueue(rolled_back)
                 Repo.rollback(:rejected)
               end)
    end)

    refute_receive {:invalidated, _identifier}
  end

  test "oversized payloads do not call pg_notify" do
    job = InvalidationWorker.transient([String.duplicate("x", 8_000)], "project")
    assert InvalidationNotifications.enqueue(job) == :too_large
  end

  test "a listener ignores malformed notifications and continues receiving valid notices" do
    listener = start_supervised!(InvalidationNotifications)
    scope = "notify-test:#{Ecto.UUID.generate()}"
    Phoenix.PubSub.subscribe(Fyrlet.PubSub, scope)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      Repo.query!("SELECT pg_notify($1, $2)", ["fyrlet_invalidation_v1", "not-json"])
      :ok = InvalidationNotifications.enqueue(InvalidationWorker.transient([scope], "project"))
    end)

    assert_receive {:invalidated, _identifier}, 2_000
    assert Process.alive?(listener)
  end
end
