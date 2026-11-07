defmodule Fyrlet.AfterCommit do
  @moduledoc """
  Collects invalidation broadcasts and telemetry for the managed outer transaction.
  Invalidation jobs are persisted in that transaction; immediate broadcasts and telemetry
  are released only after it commits. A rollback discards the pending work.
  """
  alias Fyrlet.InvalidationWorker
  require Logger

  @jobs :fyrlet_after_commit_jobs
  @events :fyrlet_after_commit_events

  def reset do
    Process.put(@jobs, %{})
    Process.put(@events, [])
  end

  def emit(event, measurements, metadata),
    do: Process.put(@events, [{event, measurements, metadata} | Process.get(@events, [])])

  def invalidate(key, project_id, scopes) do
    pending = Process.get(@jobs, %{})

    unless Map.has_key?(pending, key) do
      job =
        %{"scopes" => scopes, "project_id" => project_id}
        |> InvalidationWorker.new()
        |> Oban.insert!()

      Process.put(@jobs, Map.put(pending, key, job))
    end

    :ok
  end

  def flush do
    for {_key, job} <- Process.get(@jobs, %{}) do
      try do
        InvalidationWorker.broadcast(job)
      rescue
        _error -> Logger.warning("Invalidation broadcast failed; the durable job will retry")
      end
    end

    for {event, measurements, metadata} <- Enum.reverse(Process.get(@events, [])),
        do: :telemetry.execute(event, measurements, metadata)

    Process.delete(@jobs)
    Process.delete(@events)
    :ok
  end
end
