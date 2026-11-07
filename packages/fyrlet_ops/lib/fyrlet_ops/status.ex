defmodule FyrletOps.Status do
  @moduledoc """
  Operational view of runs and effects: a bounded status snapshot, threshold alerts, and
  notification when an alert starts or stops firing. Settings (all optional):

      config :fyrlet_ops,
        stuck_after_seconds: 300,
        thresholds: %{"queue.age_seconds" => 120},
        alert_handlers: [MyApp.PagerHandler]

  Nothing here changes state. `status/1` runs a handful of grouped counts over indexed
  columns - it reads no payloads - so it is safe to poll. Handlers get `{:firing, alert}`
  when an alert starts and `{:resolved, alert}` when it stops, not on every scan, and a
  handler that crashes is logged and skipped. Alerts never contain run or effect IDs, so
  they can be forwarded to a paging service as they are.

  The same transitions are emitted as `[:fyrlet, :ops, :alert]` telemetry
  (`%{firing: 1 | 0}`, metadata `name`, `severity`) and every evaluation as
  `[:fyrlet, :ops, :status]` gauges, for whatever reporter the host already runs.
  """
  alias Fyrlet.{Auth, Diagnostics}
  require Logger

  @state_key {__MODULE__, :firing}

  # name => {severity, default threshold}. An alert fires when its value is above the threshold.
  @alerts %{
    "runs.stuck" => {"warning", 0},
    "queue.age_seconds" => {"warning", 120},
    "waits.overdue" => {"warning", 0},
    "definitions.unavailable" => {"critical", 0},
    "effects.unresolved" => {"critical", 0},
    "effects.overdue" => {"warning", 0},
    "plugins.degraded" => {"warning", 0},
    "projects.near_limit" => {"warning", 0}
  }

  @doc """
  The status snapshot: `:all` for the whole installation (operators only), or a project ID
  for one project's own view.
  """
  def status(scope \\ :all) do
    now = Auth.now()
    stuck_cutoff = DateTime.add(now, -setting(:stuck_after_seconds, 300), :second)

    %{
      "at" => DateTime.to_iso8601(now),
      "runs" => Diagnostics.runs(scope, now, stuck_cutoff),
      "effects" => Diagnostics.effects(scope, now, stuck_cutoff),
      "limits" => Diagnostics.limits(scope),
      "plugins" => Diagnostics.plugins(scope)
    }
  end

  @doc "The alerts that are firing for a status snapshot."
  def alerts(status) do
    values = values(status)

    for {name, {severity, default}} <- @alerts,
        threshold = threshold(name, default),
        value = Map.get(values, name),
        value > threshold do
      %{
        "name" => name,
        "severity" => severity,
        "value" => value,
        "threshold" => threshold,
        "message" => "#{name} is #{value} (limit #{threshold})"
      }
    end
    |> Enum.sort_by(& &1["name"])
  end

  @doc """
  Evaluates the whole installation and notifies handlers about alerts that started or
  stopped since the last evaluation. Called by the recovery scan; safe to call anywhere.
  """
  def evaluate do
    snapshot = status(:all)
    firing = alerts(snapshot)
    previous = :persistent_term.get(@state_key, %{})
    current = Map.new(firing, &{&1["name"], &1})

    :telemetry.execute(
      [:fyrlet, :ops, :status],
      %{
        alerts: length(firing),
        stuck_runs: get_in(snapshot, ["runs", "stuck"]),
        queue_age_seconds: get_in(snapshot, ["runs", "oldest_pending_age_seconds"]),
        unresolved_effects: get_in(snapshot, ["effects", "unresolved"])
      },
      %{}
    )

    for {name, alert} <- current, not Map.has_key?(previous, name), do: notify(:firing, alert)

    for {name, alert} <- previous, not Map.has_key?(current, name), do: notify(:resolved, alert)

    :persistent_term.put(@state_key, current)
    {:ok, firing}
  end

  @doc false
  def reset, do: :persistent_term.erase(@state_key)

  # ---- alerts -----------------------------------------------------------------------------

  defp values(status) do
    %{
      "runs.stuck" => status["runs"]["stuck"],
      "queue.age_seconds" => status["runs"]["oldest_pending_age_seconds"],
      "waits.overdue" => status["runs"]["waits_overdue"],
      "definitions.unavailable" => status["runs"]["definition_unavailable"],
      "effects.unresolved" => status["effects"]["unresolved"],
      "effects.overdue" => status["effects"]["overdue"],
      "plugins.degraded" => get_in(status, ["plugins", "degraded"]) || 0,
      "projects.near_limit" => status["limits"]["projects_near_limit"]
    }
  end

  defp threshold(name, default) do
    case setting(:thresholds, %{})[name] do
      value when is_number(value) and value >= 0 -> value
      _other -> default
    end
  end

  defp notify(kind, alert) do
    :telemetry.execute(
      [:fyrlet, :ops, :alert],
      %{firing: if(kind == :firing, do: 1, else: 0)},
      %{name: alert["name"], severity: alert["severity"]}
    )

    for handler <- setting(:alert_handlers, []) do
      try do
        handler.handle_alert(kind, alert)
      rescue
        exception ->
          Logger.error(
            "Ops alert handler #{inspect(handler)} failed: #{inspect(exception.__struct__)}"
          )
      catch
        _kind, _reason -> Logger.error("Ops alert handler #{inspect(handler)} failed")
      end
    end

    :ok
  end

  defp setting(key, default), do: Application.get_env(:fyrlet_ops, key, default)
end
