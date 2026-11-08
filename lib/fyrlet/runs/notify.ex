defmodule Fyrlet.Runs.Notify do
  @moduledoc """
  Tells subscribers a run changed: one notice per run per transaction, delivered like an
  ordinary write (durable job, pg_notify, or immediate broadcast) and flushed after commit.
  """
  alias Fyrlet.AfterCommit

  def scopes(project_id, subject_id, run_id) do
    [
      "projects:#{project_id}:subjects:#{subject_id}:runs",
      "projects:#{project_id}:runs:#{run_id}"
    ]
  end

  defdelegate reset(), to: AfterCommit

  @doc "Queues a telemetry event; it is emitted only if the transaction commits."
  defdelegate emit(event, measurements, metadata), to: AfterCommit

  @doc "Call inside the transaction that changes the run. One job per run per transaction."
  def mark(run) do
    AfterCommit.invalidate(
      {:run, run.id},
      run.project_id,
      scopes(run.project_id, run.subject_id, run.id)
    )
  end

  @doc "Call after the transaction committed."
  defdelegate flush(), to: AfterCommit
end
