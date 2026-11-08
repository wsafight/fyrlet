defmodule Fyrlet.AfterCommit do
  @moduledoc """
  Collects invalidation broadcasts and telemetry for the managed outer transaction.
  Notices are durable jobs, transactional pg_notify, or immediate broadcasts, chosen like
  ordinary writes; broadcasts and telemetry are released only after the transaction commits.
  A rollback discards the pending work.
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
      Process.put(@jobs, Map.put(pending, key, job(project_id, scopes)))
    end

    :ok
  end

  # The same delivery modes as ordinary writes in `Fyrlet.Runtime`: a durable Oban job when
  # configured, or when the surrounding transaction is not managed (nothing would flush an
  # immediate broadcast); otherwise a transient broadcast, with transactional pg_notify when
  # enabled. De-duplication above still means at most one notice per key per transaction.
  defp job(project_id, scopes) do
    durable = fn ->
      %{"scopes" => scopes, "project_id" => project_id}
      |> InvalidationWorker.new()
      |> Oban.insert!()
    end

    cond do
      Application.get_env(:fyrlet, :durable_invalidation, false) ->
        durable.()

      Fyrlet.InvalidationNotifications.enabled?() ->
        job = InvalidationWorker.transient(scopes, project_id)

        case Fyrlet.InvalidationNotifications.enqueue(job) do
          :ok -> job
          :too_large -> durable.()
        end

      not Fyrlet.Transaction.managed?() ->
        durable.()

      true ->
        InvalidationWorker.transient(scopes, project_id)
    end
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
