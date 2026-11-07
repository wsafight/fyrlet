defmodule Fyrlet.Diagnostics do
  @moduledoc """
  Bounded aggregate queries for trusted server code. A project UUID scopes every query;
  `:all` is reserved for installation operators. HTTP callers must be authenticated and
  their project selected by the host, never from an untrusted request parameter.
  """
  import Ecto.Query
  alias Fyrlet.Repo
  alias Fyrlet.Effects.Effect
  alias Fyrlet.Runs.{Limits, Run, Step}
  @active ~w(pending running waiting cancelling)

  def cluster do
    %{
      "node" => to_string(node()),
      "configured" => Enum.map(Application.get_env(:fyrlet, :cluster_nodes, []), &to_string/1),
      "connected" => Enum.map(Node.list(), &to_string/1)
    }
  end

  def runs(scope, now, stuck_cutoff) do
    by_status =
      from(r in Run, group_by: r.status, select: {r.status, count(r.id)})
      |> in_project(scope)
      |> Repo.all()
      |> Map.new()

    oldest =
      from(r in Run, where: r.status == "pending", select: min(r.inserted_at))
      |> in_project(scope)
      |> Repo.one()

    stuck =
      from(r in Run, where: r.status in @active and r.updated_at < ^stuck_cutoff)
      |> in_project(scope)
      |> Repo.aggregate(:count)

    overdue =
      from(s in Step,
        join: r in Run,
        on: r.id == s.run_id and r.current_step_seq == s.seq,
        where: s.status == "waiting" and s.wait_deadline <= ^now and r.status == "waiting"
      )
      |> in_project(scope, :run)
      |> Repo.aggregate(:count)

    unavailable =
      from(r in Run, where: r.status == "waiting" and r.wait_reason == "definition_unavailable")
      |> in_project(scope)
      |> Repo.aggregate(:count)

    %{
      "by_status" => by_status,
      "stuck" => stuck,
      "oldest_pending_age_seconds" => if(oldest, do: DateTime.diff(now, oldest), else: 0),
      "waits_overdue" => overdue,
      "definition_unavailable" => unavailable
    }
  end

  def effects(scope, now, overdue_cutoff) do
    by_status =
      from(e in Effect, group_by: e.status, select: {e.status, count(e.id)})
      |> in_project(scope)
      |> Repo.all()
      |> Map.new()

    unresolved =
      from(e in Effect, where: e.resolution_required or e.status == "unknown")
      |> in_project(scope)
      |> Repo.aggregate(:count)

    overdue =
      from(e in Effect,
        where:
          (e.status == "pending" and e.next_attempt_at < ^overdue_cutoff) or
            (e.status == "claimed" and e.lease_expires_at < ^now)
      )
      |> in_project(scope)
      |> Repo.aggregate(:count)

    %{"by_status" => by_status, "unresolved" => unresolved, "overdue" => overdue}
  end

  def limits(scope) do
    pending_limit = Limits.get(:max_pending_per_project)
    concurrent_limit = Limits.get(:max_concurrent_per_project)

    counts =
      from(r in Run,
        where: r.status in @active,
        group_by: [r.project_id, r.status],
        select: {r.project_id, r.status, count(r.id)}
      )
      |> in_project(scope)
      |> Repo.all()

    usage =
      Enum.reduce(counts, %{}, fn {project, status, count}, acc ->
        Map.update(acc, project, usage(status, count), fn current ->
          Map.merge(current, usage(status, count), fn _key, a, b -> a + b end)
        end)
      end)

    near =
      Enum.count(usage, fn {_project, used} ->
        Map.get(used, :pending, 0) >= pending_limit * 0.8 or
          Map.get(used, :active, 0) >= concurrent_limit * 0.8
      end)

    base = %{
      "pending_limit" => pending_limit,
      "concurrent_limit" => concurrent_limit,
      "projects_near_limit" => near
    }

    case scope do
      :all ->
        base

      project ->
        used = Map.get(usage, project, %{})

        Map.merge(base, %{
          "pending" => Map.get(used, :pending, 0),
          "concurrent" => Map.get(used, :active, 0)
        })
    end
  end

  defp usage("pending", count), do: %{pending: count}
  defp usage(_status, count), do: %{active: count}

  def plugins(:all) do
    degraded = for %{status: status} = entry <- Fyrlet.Plugins.load(), status != :ok, do: entry
    %{"degraded" => length(degraded)}
  end

  def plugins(_project), do: %{}

  defp in_project(query, :all), do: query
  defp in_project(query, project_id), do: where(query, [x], x.project_id == ^project_id)

  defp in_project(query, :all, :run), do: query
  defp in_project(query, project_id, :run), do: where(query, [_s, r], r.project_id == ^project_id)
end
