defmodule Fyrlet.Runs.Privacy do
  @moduledoc """
  Sensitive data in runs (temp spec §12).

    * **Redaction.** An operation lists `sensitive: ["recipient", "token"]`; any key with one of
      those names, at any depth, is shown as `"[redacted]"` wherever Fyrlet presents a run.
    * **Purging.** Erases the content of finished runs - inputs, outputs, signal payloads, effect
      requests and results - for one person on request, or for everything older than
      `config :fyrlet, runs: [payload_retention: seconds]`. Identifiers, states, timestamps,
      idempotency keys, request hashes and audit events stay, so de-duplication and the
      history of what happened keep working; only what was said is gone.
    * A run that is still active, or whose external effect is unresolved, is never purged:
      its payloads are what the work still needs.

  Encryption at rest is `Fyrlet.Vault`.
  """
  import Ecto.Query
  alias Fyrlet.{Auth, Repo}
  alias Fyrlet.Effects.Effect
  alias Fyrlet.Runs.{Engine, Limits, Run, Signal, Step, Store}

  @redacted "[redacted]"
  @gone %{"purged" => true}

  def redact(value, operation) do
    case sensitive(operation) do
      [] -> value
      keys -> scrub(value, keys)
    end
  end

  defp sensitive(operation) do
    case Fyrlet.Registry.fetch("operations", operation) do
      {:ok, _module, %{"sensitive" => keys}} when is_list(keys) -> keys
      _other -> []
    end
  end

  defp scrub(map, keys) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, if(k in keys, do: @redacted, else: scrub(v, keys))} end)

  defp scrub(list, keys) when is_list(list), do: Enum.map(list, &scrub(&1, keys))
  defp scrub(other, _keys), do: other

  @doc """
  Erases a person's run content. Active runs are cancelled first; any that cannot end yet
  (an executor still holds work) are reported in `still_active` and can be purged later.
  """
  def purge_subject(project_id, subject_id) do
    active =
      Repo.all(
        from(r in Run,
          where:
            r.project_id == ^project_id and r.subject_id == ^subject_id and
              r.status in ["pending", "running", "waiting", "cancelling"],
          select: r.id
        )
      )

    for id <- active, do: Engine.request_cancel(id)

    ids =
      Repo.all(
        from(r in Run,
          where:
            r.project_id == ^project_id and r.subject_id == ^subject_id and is_nil(r.purged_at),
          select: r.id
        )
      )

    results = Enum.map(ids, &purge_run/1)

    %{
      purged: Enum.count(results, &(&1 == :purged)),
      still_active: Enum.count(results, &(&1 == :active)),
      held: Enum.count(results, &(&1 == :held))
    }
  end

  @doc "Purges one finished run. Returns `:purged`, `:active` or `:held` (unresolved effect)."
  def purge_run(run_id) do
    Engine.transact(fn ->
      case Store.lock_run(run_id) do
        %Run{status: status} when status in ["pending", "running", "waiting", "cancelling"] ->
          :active

        %Run{} = run ->
          if unresolved_effect?(run.id), do: :held, else: erase(run)

        nil ->
          :gone
      end
    end)
  end

  @doc "Purges runs finished longer ago than the configured payload retention."
  def purge_expired(now) do
    with seconds when is_integer(seconds) <- Limits.get(:payload_retention) do
      cutoff = DateTime.add(now, -seconds, :second)

      ids =
        Repo.all(
          from(r in Run,
            where:
              r.status in ["completed", "failed", "cancelled", "expired"] and
                r.finished_at < ^cutoff and is_nil(r.purged_at),
            select: r.id,
            limit: ^Limits.get(:scan_batch)
          )
        )

      Enum.count(ids, &(purge_run(&1) == :purged))
    else
      _keep -> 0
    end
  end

  defp unresolved_effect?(run_id) do
    Repo.exists?(
      from(e in Effect,
        where: e.run_id == ^run_id and e.status in ["pending", "claimed", "accepted", "unknown"]
      )
    )
  end

  defp erase(%Run{} = run) do
    now = Auth.now()
    nodes = for node <- run.plan["nodes"] || [], do: Map.put(node, "input", %{})

    Repo.update_all(from(r in Run, where: r.id == ^run.id),
      set: [
        input: @gone,
        output: if(run.output, do: @gone),
        plan: Map.put(run.plan, "nodes", nodes),
        error: run.error && Map.put(run.error, "message", "[purged]"),
        purged_at: now,
        updated_at: now
      ]
    )

    Repo.update_all(from(s in Step, where: s.run_id == ^run.id),
      set: [input: @gone, output: @gone]
    )

    Repo.update_all(from(s in Signal, where: s.run_id == ^run.id), set: [payload: @gone])

    Repo.update_all(from(e in Effect, where: e.run_id == ^run.id),
      set: [payload: @gone, result: @gone]
    )

    Store.event(run.id, "run.purged", nil, %{})
    :purged
  end
end
