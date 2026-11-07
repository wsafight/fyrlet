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

  @doc """
  Broadcasts a job that was not persisted once the managed transaction commits, with the
  committed change when there is one. Only valid inside `Fyrlet.Transaction.run/1`; a rollback
  discards it.
  """
  def broadcast_later({%Oban.Job{} = job, change}) do
    Process.put(@jobs, Map.put(Process.get(@jobs, %{}), {:transient, job.id}, {job, change}))
    :ok
  end

  def flush do
    for {_key, pending} <- Process.get(@jobs, %{}) do
      try do
        case pending do
          {%Oban.Job{} = job, change} -> InvalidationWorker.broadcast(job, change)
          %Oban.Job{} = job -> InvalidationWorker.broadcast(job)
        end
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
