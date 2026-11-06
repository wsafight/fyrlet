defmodule Fyrlet.ObserverTest do
  use Fyrlet.DataCase, async: false
  alias Fyrlet.Observer

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
    if Process.info(observer, :current_function) ==
         {:current_function, {:gen_server, :loop_hibernate, 4}} do
      :ok
    else
      assert attempts > 0,
             inspect(Process.info(observer, [:current_function, :status, :message_queue_len]))

      Process.sleep(10)
      assert_hibernating(observer, attempts - 1)
    end
  end
end
