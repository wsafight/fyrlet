defmodule Fyrlet.Testing do
  @moduledoc """
  Helpers for testing code built on Fyrlet, such as plugins. Needs no test framework, so it
  is safe to ship; use it from `test/` with the Ecto sandbox.

      project = Fyrlet.Testing.project()
      alice = Fyrlet.Testing.user(project, "alice")
      {:ok, %{"run_id" => id}} = Fyrlet.Runtime.call(alice.actor, "my.run", %{}, key, capabilities: %{"runs" => 1})
      Fyrlet.Testing.drive(id)
  """
  import Ecto.Query
  alias Fyrlet.Repo
  alias Fyrlet.Runs.{Engine, Run, StateMachine, Step}

  @doc "A new project with its service key."
  def project do
    {:ok, project} = Fyrlet.Auth.create_project("test")
    project
  end

  @doc "A session for `external_id` in `project`: `%{session: .., actor: .., token: ..}`."
  def user(project, external_id \\ "alice") do
    {:ok, session} =
      Fyrlet.Auth.issue_session(project.service_key, %{"external_subject" => external_id})

    {:ok, actor} = Fyrlet.Auth.authenticate(session["token"], project.project.id)
    %{session: session, actor: actor, token: session["token"]}
  end

  def run(id), do: Repo.get!(Run, id)

  @doc "Reads an authorized subscription through the public runtime."
  def snapshot(actor, name, input \\ %{}) do
    with {:ok, subscription} <- Fyrlet.Runtime.prepare_subscription(actor, name, input),
         do: Fyrlet.Runtime.snapshot(actor, subscription)
  end

  @doc "Runs one claimed step, using the same engine as an Oban wake-up."
  defdelegate step(id), to: Engine, as: :run_once

  @doc "Runs one recovery scan, including lost leases and unresolved effects."
  defdelegate recover(), to: Fyrlet.Runs.Recovery, as: :scan

  @doc "The persisted effects for one test run, in insertion order."
  def effects(run_id) do
    Repo.all(
      from(effect in Fyrlet.Effects.Effect,
        where: effect.run_id == ^run_id,
        order_by: effect.inserted_at
      )
    )
  end

  @doc "The number of runs in the test database."
  def run_count, do: Repo.aggregate(Run, :count)

  @doc "Expires this test run's live leases so the recovery scanner can repair them."
  def expire_leases(run_id) do
    Repo.update_all(
      from(attempt in Fyrlet.Runs.Attempt,
        where: attempt.run_id == ^run_id and attempt.status == "leased"
      ),
      set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -5, :second)]
    )
  end

  @doc "Moves a test wait's deadline into the past and handles its timeout."
  def expire_wait(run_id) do
    step = wait_step(run_id)

    Repo.update_all(from(wait in Step, where: wait.id == ^step.id),
      set: [wait_deadline: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    Engine.expire_wait(run_id, step.id)
  end

  @doc "The run's wait step, if its plan has one."
  def wait_step(run_id),
    do: Repo.one(from(s in Step, where: s.run_id == ^run_id and s.type == "wait"))

  @doc "Moves a run forward until it is terminal, waiting, or has nothing to claim. Returns its status."
  def drive(id, options \\ []) do
    options = if is_integer(options), do: [limit: options], else: options
    limit = Keyword.get(options, :limit, 30)

    Enum.reduce_while(1..limit, run(id).status, fn _, _ ->
      before = run(id).version
      Engine.run_once(id)

      if Keyword.get(options, :effects, false) do
        for effect <- effects(id),
            effect.status == "pending",
            do: Fyrlet.Effects.dispatch(effect.id)
      end

      current = run(id)

      cond do
        current.status in StateMachine.terminal_states() -> {:halt, current.status}
        current.version == before -> {:halt, current.status}
        true -> {:cont, current.status}
      end
    end)
  end
end
