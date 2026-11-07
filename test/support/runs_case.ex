defmodule Fyrlet.RunsCase do
  @moduledoc "Shared helpers for run tests: starting, driving and manipulating time."
  use ExUnit.CaseTemplate

  using do
    quote do
      use Fyrlet.DataCase, async: false
      use Oban.Testing, repo: Fyrlet.Repo
      import Fyrlet.RunsCase
      alias Fyrlet.Runs
      alias Fyrlet.Runs.{Attempt, Engine, Event, Grant, Recovery, Run, Signal, Step}
    end
  end

  setup do
    previous = Application.get_env(:fyrlet, :runs, [])
    Application.put_env(:fyrlet, :runs, retry_base_seconds: 0, retry_max_seconds: 0)

    on_exit(fn ->
      Application.put_env(:fyrlet, :runs, previous)

      for key <- [
            :run_plans,
            :run_steps,
            :run_advance,
            :vault,
            :run_faults,
            :run_authorize,
            :run_test_version,
            :run_test_impls
          ],
          do: Application.delete_env(:fyrlet, key)
    end)

    :ok
  end

  import Ecto.Query
  alias Fyrlet.Repo
  alias Fyrlet.Runs
  alias Fyrlet.Runs.{Attempt, Engine, Event, Run, Step}

  def caps, do: %{"runs" => 1}
  def key, do: Ecto.UUID.generate()

  def start_run(actor, operation \\ "runs.demo", input \\ %{}, idempotency_key \\ nil) do
    Fyrlet.Runtime.call(actor.actor, operation, input, idempotency_key || key(),
      capabilities: caps()
    )
  end

  def start_run!(actor, operation \\ "runs.demo", input \\ %{}) do
    {:ok, %{"run_id" => id}} = start_run(actor, operation, input)
    id
  end

  def run(id), do: Repo.get!(Run, id)
  def status(id), do: run(id).status
  def steps(id), do: Repo.all(from(s in Step, where: s.run_id == ^id, order_by: s.seq))
  def step_statuses(id), do: Enum.map(steps(id), &{&1.name, &1.status})

  def attempts(id),
    do: Repo.all(from(a in Attempt, where: a.run_id == ^id, order_by: [a.inserted_at, a.attempt]))

  def events(id), do: Repo.all(from(e in Event, where: e.run_id == ^id, order_by: e.seq))
  def event_types(id), do: Enum.map(events(id), & &1.type)
  def wait_step(id), do: Enum.find(steps(id), &(&1.type == "wait"))

  @doc "Drives a run until it stops moving on its own (terminal, waiting, or nothing to claim)."
  def drive(id, limit \\ 30) do
    Enum.reduce_while(1..limit, status(id), fn _, _ ->
      before = run(id).version
      Engine.run_once(id)
      current = run(id)

      cond do
        current.status in Fyrlet.Runs.StateMachine.terminal_states() -> {:halt, current.status}
        current.version == before -> {:halt, current.status}
        true -> {:cont, current.status}
      end
    end)
  end

  def signal(actor, id, name \\ "user_approval", payload \\ %{}, key \\ nil) do
    wait = wait_step(id)

    Runs.signal(actor, id, %{
      "wait_id" => wait.id,
      "name" => name,
      "payload" => payload,
      "idempotency_key" => key || key()
    })
  end

  def expire_leases(id) do
    past = DateTime.add(Fyrlet.Auth.now(), -5, :second)

    Repo.update_all(from(a in Attempt, where: a.run_id == ^id and a.status == "leased"),
      set: [lease_expires_at: past]
    )
  end

  def age(id, seconds) do
    past = DateTime.add(Fyrlet.Auth.now(), -seconds, :second)
    Repo.update_all(from(r in Run, where: r.id == ^id), set: [updated_at: past])
  end

  def set_run(id, fields), do: Repo.update_all(from(r in Run, where: r.id == ^id), set: fields)

  def put_runs(options),
    do:
      Application.put_env(
        :fyrlet,
        :runs,
        Keyword.merge(Application.get_env(:fyrlet, :runs, []), options)
      )

  @doc "Runs `fun` in its own process (so an injected crash does not take the test down)."
  def spawn_executor(fun) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.put(:inject, true)
        send(parent, {:result, self(), fun.()})
      end)

    {pid, ref}
  end

  def await_executor({pid, ref}, timeout \\ 5_000) do
    receive do
      {:result, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        {:ok, result}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:crashed, reason}
    after
      timeout -> :timeout
    end
  end

  @doc "Installs a fault hook that only affects processes started with spawn_executor/1."
  def inject(hook) do
    Application.put_env(:fyrlet, :run_faults, fn point ->
      if Process.get(:inject), do: hook.(point), else: :ok
    end)
  end

  def pause_at(point) do
    test = self()

    inject(fn
      ^point ->
        send(test, {:paused, self(), point})
        receive do: (:continue -> :ok)

      _other ->
        :ok
    end)
  end
end
