defmodule Fyrlet.Runs.Executor do
  @moduledoc """
  The external executor protocol (temp spec §3.7), without HTTP.

  An executor claims a step, keeps its lease alive, reports one result, and can ask whether
  the run was cancelled. Every call carries the lease id and execution epoch it was given;
  a lease that has expired, been replaced or been cancelled cannot change anything. The
  framework never runs or hosts the executor's code.
  """
  import Ecto.Query
  alias Fyrlet.{Auth, Error, Repo}
  alias Fyrlet.Runs.{Attempt, Engine, Limits, Plan, Run, Step, Store}

  @max_wait_seconds 25

  def claim(executor, queues) when is_list(queues) do
    case Engine.claim_external(executor, queues) do
      {:ok, work} -> {:ok, work}
      :none -> {:ok, nil}
    end
  end

  @doc "Extends a lease. Once a cancel is accepted the lease is not extended and `cancel` is true."
  def heartbeat(executor, attempt_id, lease_id, epoch) do
    Engine.transact(fn ->
      with {:ok, run, attempt} <- held(executor, attempt_id, lease_id, epoch) do
        if run.status == "cancelling" do
          {:ok,
           %{
             "cancel" => true,
             "lease_expires_at" => DateTime.to_iso8601(attempt.lease_expires_at)
           }}
        else
          expires = DateTime.add(Auth.now(), Limits.get(:lease_seconds), :second)

          Repo.update_all(from(a in Attempt, where: a.id == ^attempt.id),
            set: [lease_expires_at: expires]
          )

          {:ok, %{"cancel" => false, "lease_expires_at" => DateTime.to_iso8601(expires)}}
        end
      end
    end)
  end

  @doc "Whether the executor should stop. With `wait` seconds it holds the request open (long poll)."
  def status(executor, attempt_id, lease_id, epoch, wait \\ 0) do
    deadline = System.monotonic_time(:millisecond) + min(wait, @max_wait_seconds) * 1000
    poll(executor, attempt_id, lease_id, epoch, deadline)
  end

  defp poll(executor, attempt_id, lease_id, epoch, deadline) do
    case held(executor, attempt_id, lease_id, epoch) do
      {:ok, %Run{status: "cancelling"}, _attempt} ->
        {:ok, %{"cancel" => true, "lease_valid" => true}}

      {:ok, _run, _attempt} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:ok, %{"cancel" => false, "lease_valid" => true}}
        else
          Process.sleep(200)
          poll(executor, attempt_id, lease_id, epoch, deadline)
        end

      {:error, _lost} ->
        # A lease that is gone is as good as a cancel: the executor must stop.
        {:ok, %{"cancel" => true, "lease_valid" => false}}
    end
  end

  @doc """
  Reports the outcome of an attempt: `%{"status" => "succeeded", "output" => map}` or
  `%{"status" => "failed", "error" => %{"code", "message", "retryable"}}`.
  The same report twice is acknowledged; a different one for the same attempt conflicts.
  """
  def report(executor, attempt_id, lease_id, epoch, report) do
    with {:ok, result} <- result(report),
         %Attempt{} = attempt <- Repo.get(Attempt, attempt_id) || {:error, Error.not_found()},
         :ok <- owned(executor, attempt),
         hash = hash(report) do
      cond do
        attempt.status != "leased" and attempt.result_hash == hash ->
          {:ok, %{"status" => "duplicate"}}

        attempt.status != "leased" and not is_nil(attempt.result_hash) ->
          {:error,
           Error.new("CONFLICT", "A different result was already reported for this attempt")}

        true ->
          commit(attempt, lease_id, epoch, result, hash)
      end
    end
  end

  defp commit(attempt, lease_id, epoch, result, hash) do
    run = Repo.get!(Run, attempt.run_id)
    step = Repo.get!(Step, attempt.step_id)

    if attempt.lease_id != lease_id or attempt.execution_epoch != epoch do
      {:error, lease_lost()}
    else
      case Engine.commit_result(
             %{run: run, step: step, attempt: attempt, result_hash: hash, enforce_lease: true},
             result
           ) do
        :stale -> {:error, lease_lost()}
        _applied -> {:ok, %{"status" => "accepted"}}
      end
    end
  end

  # ---- internals ----------------------------------------------------------------------

  defp held(executor, attempt_id, lease_id, epoch) do
    with %Attempt{} = probe <- Repo.get(Attempt, attempt_id) || {:error, Error.not_found()},
         :ok <- owned(executor, probe),
         %Run{} = run <- Store.lock_run(probe.run_id),
         %Attempt{} = attempt <-
           Repo.one(from(a in Attempt, where: a.id == ^attempt_id, lock: "FOR UPDATE")) do
      # A lease that has run out is gone even if recovery has not replaced it yet: it cannot be
      # extended, and what the executor reports under it is only audited.
      if attempt.status == "leased" and attempt.lease_id == lease_id and
           attempt.execution_epoch == epoch and run.execution_epoch == epoch and
           run.status not in ["completed", "failed", "cancelled", "expired"] and
           DateTime.compare(attempt.lease_expires_at, Auth.now()) == :gt do
        {:ok, run, attempt}
      else
        {:error, lease_lost()}
      end
    end
  end

  defp owned(executor, %Attempt{executor_id: id}) when id == executor.id do
    :ok
  end

  defp owned(_executor, _attempt), do: {:error, Error.not_found()}

  defp result(%{"status" => "succeeded", "output" => output}) when is_map(output),
    do: {:ok, {:ok, output}}

  defp result(%{"status" => "succeeded"}), do: {:ok, {:ok, %{}}}

  defp result(%{"status" => "failed", "error" => %{"code" => code, "message" => message} = error})
       when is_binary(code) and is_binary(message) do
    {:ok,
     {:error,
      Error.new(
        String.slice(code, 0, 80),
        String.slice(message, 0, 500),
        %{},
        error["retryable"] == true
      )}}
  end

  defp result(_report),
    do:
      {:error,
       Error.new(
         "VALIDATION_FAILED",
         "A report needs status succeeded|failed with output or error"
       )}

  defp hash(report),
    do: report |> Plan.payload("report") |> elem(1) |> then(&:crypto.hash(:sha256, canonical(&1)))

  defp canonical(map) when is_map(map),
    do: [
      "{",
      map
      |> Enum.sort()
      |> Enum.map(fn {k, v} -> [Jason.encode!(k), ":", canonical(v)] end)
      |> Enum.intersperse(","),
      "}"
    ]

  defp canonical(list) when is_list(list),
    do: ["[", list |> Enum.map(&canonical/1) |> Enum.intersperse(","), "]"]

  defp canonical(value), do: Jason.encode!(value)

  defp lease_lost,
    do: Error.new("LEASE_LOST", "The lease is no longer valid; stop working on this attempt")
end
