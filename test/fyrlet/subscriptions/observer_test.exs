defmodule Fyrlet.ObserverTest do
  use Fyrlet.DataCase, async: false
  alias Fyrlet.Subscriptions.Observer

  defmodule Definition do
    def authorize(_name, _actor, _parameters), do: :ok

    def execute(_name, actor, parameters) do
      if actor.subject_id == parameters.blocked_subject do
        send(parameters.owner, {:loading, self()})

        receive do
          :release -> :ok
        after
          5_000 -> raise "Test subscription was not released"
        end
      end

      {:ok, [], []}
    end
  end

  test "one blocked initial query does not serialize other sessions through the supervisor" do
    project = project()
    alice = user(project, "alice")
    bob = user(project, "bob")

    subscription = %{
      module: Definition,
      name: "test.parallel",
      parameters: %{owner: self(), blocked_subject: alice.actor.subject_id},
      specification: %{"shared" => true, "output" => %{"type" => "array"}},
      scope: "test:parallel:#{project.project.id}"
    }

    first = Task.async(fn -> Observer.attach(alice.actor, subscription, "snapshot") end)
    assert_receive {:loading, blocked_observer}
    on_exit(fn -> send(blocked_observer, :release) end)
    second = Task.async(fn -> Observer.attach(bob.actor, subscription, "snapshot") end)
    assert {:ok, other_observer, _revision, "[]"} = Task.await(second, 500)
    refute blocked_observer == other_observer
    send(blocked_observer, :release)
    assert {:ok, ^blocked_observer, _revision, "[]"} = Task.await(first, 500)
  end

  test "hibernating observers wake for refresh and recheck revoked sessions" do
    previous = Application.fetch_env!(:fyrlet, :observer_hibernate_after)
    Application.put_env(:fyrlet, :observer_hibernate_after, 10)
    on_exit(fn -> Application.put_env(:fyrlet, :observer_hibernate_after, previous) end)
    project = project()
    alice = user(project, "alice")

    subscription = %{
      module: Definition,
      name: "test.hibernate",
      parameters: %{owner: self(), blocked_subject: nil},
      specification: %{"shared" => true, "output" => %{"type" => "array"}},
      scope: "test:hibernate:#{project.project.id}"
    }

    assert {:ok, observer, revision, "[]"} =
             Observer.attach(alice.actor, subscription, "snapshot")

    Observer.ready(observer, revision)
    assert_hibernating(observer)
    Observer.refresh(observer)
    assert_receive {:observer_update, ^observer, ^revision, :snapshot, "[]"}, 500
    Observer.ready(observer, revision)
    assert_hibernating(observer)

    Repo.update_all(
      from(session in Fyrlet.Session, where: session.id == ^alice.actor.session_id),
      set: [revoked_at: Auth.now()]
    )

    Observer.refresh(observer)
    assert_receive {:observer_error, ^observer, %Error{code: "UNAUTHENTICATED"}}, 500
  end

  defp assert_hibernating(observer, attempts \\ 100) do
    case Process.info(observer, :current_function) do
      {:current_function, function}
      when function in [{:erlang, :hibernate, 3}, {:gen_server, :loop_hibernate, 4}] ->
        :ok

      _state ->
        assert attempts > 0,
               inspect(Process.info(observer, [:current_function, :status, :message_queue_len]))

        Process.sleep(10)
        assert_hibernating(observer, attempts - 1)
    end
  end

  describe "attach checks, loads, then checks again" do
    alias Fyrlet.Subscriptions.Observer

    defp subscription(name) do
      {:ok, _module, specification} = Fyrlet.Registry.fetch("subscriptions", name)

      %{
        module: Fyrlet.TestDefinition,
        name: name,
        parameters: %{},
        specification: specification,
        scope: "attach-test:" <> Ecto.UUID.generate()
      }
    end

    setup do
      Application.put_env(:fyrlet, :load_probe, self())
      on_exit(fn -> Application.delete_env(:fyrlet, :load_probe) end)
      %{alice: user(project(), "alice")}
    end

    test "authorization comes before the data is loaded", %{alice: alice} do
      # Authorization rejects this subscription; the application's loader must not run for it.
      assert {:error, %{code: "FORBIDDEN"}} =
               Observer.attach(alice.actor, subscription("test.denied_sub"), "snapshot")

      refute_received :loaded
    end

    test "a session revoked while the data was loading gets nothing", %{alice: alice} do
      assert {:error, %{code: "UNAUTHENTICATED"}} =
               Observer.attach(alice.actor, subscription("test.revoking_feed"), "snapshot")
    end

    test "a live session is attached with exactly one load and two session checks", %{
      alice: alice
    } do
      checks = :counters.new(1, [])
      id = {:checks, make_ref()}

      :telemetry.attach(
        id,
        [:fyrlet, :repo, :query],
        fn _, _, meta, _ ->
          if meta.query =~ ~s(FROM "sessions"), do: :counters.add(checks, 1, 1)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      assert {:ok, _observer, 1, encoded} =
               Observer.attach(alice.actor, subscription("test.counting_feed"), "snapshot")

      assert Jason.decode!(encoded) == "counted"
      assert_received :loaded
      refute_received :loaded
      # Before the data is read and after it; the join's own check precedes `attach`.
      assert :counters.get(checks, 1) == 2
    end
  end
end
