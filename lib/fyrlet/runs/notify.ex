defmodule Fyrlet.Runs.Notify do
  @moduledoc """
  Tells subscribers a run changed: a durable invalidation job is inserted in the same
  transaction as the change, and broadcast immediately after it commits.
  """
  alias Fyrlet.InvalidationWorker
  require Logger
  @key :fyrlet_run_notify

  def scopes(project_id, subject_id, run_id) do
    [
      "projects:#{project_id}:subjects:#{subject_id}:runs",
      "projects:#{project_id}:runs:#{run_id}"
    ]
  end

  @events :fyrlet_run_events

  def reset do
    Process.put(@events, [])
    Process.put(@key, %{})
  end

  @doc "Queues a telemetry event; it is emitted only if the transaction commits."
  def emit(event, measurements, metadata),
    do: Process.put(@events, [{event, measurements, metadata} | Process.get(@events, [])])

  @doc "Call inside the transaction that changes the run. One job per run per transaction."
  def mark(run) do
    pending = Process.get(@key, %{})

    if Map.has_key?(pending, run.id) do
      :ok
    else
      job =
        %{
          "scopes" => scopes(run.project_id, run.subject_id, run.id),
          "project_id" => run.project_id
        }
        |> InvalidationWorker.new()
        |> Oban.insert!()

      Process.put(@key, Map.put(pending, run.id, job))
      :ok
    end
  end

  @doc "Call after the transaction committed."
  def flush do
    for {_id, job} <- Process.get(@key, %{}) do
      try do
        InvalidationWorker.broadcast(job)
      rescue
        _error -> Logger.warning("Run notification failed; the durable job will retry")
      end
    end

    for {event, measurements, metadata} <- Enum.reverse(Process.get(@events, [])),
        do: :telemetry.execute(event, measurements, metadata)

    Process.delete(@key)
    Process.delete(@events)
    :ok
  end
end
