defmodule Fyrlet.Runs.Definition do
  @moduledoc """
  Built-in subscriptions that expose runs. Registered automatically when the `runs`
  capability is enabled; listed in the contract only while it is enabled.
  """
  @behaviour Fyrlet.Definition
  import Ecto.Query
  alias Fyrlet.{Error, Repo, Schema}
  alias Fyrlet.Runs.{Notify, Run, View}

  @status ~w(pending running waiting completed failed cancelling cancelled expired)
  @text %{"type" => "string"}
  @nullable_text %{"anyOf" => [%{"type" => "string"}, %{"type" => "null"}]}
  @nullable_time %{
    "anyOf" => [%{"type" => "string", "format" => "date-time"}, %{"type" => "null"}]
  }
  @id %{"type" => "string", "format" => "uuid"}

  def summary_schema do
    Schema.object(
      %{
        "id" => @id,
        "operation" => @text,
        "status" => %{"type" => "string", "enum" => @status},
        "wait_reason" => @nullable_text,
        "version" => %{"type" => "integer", "minimum" => 1},
        "created_at" => %{"type" => "string", "format" => "date-time"},
        "finished_at" => @nullable_time
      },
      ~w(id operation status wait_reason version created_at finished_at)
    )
  end

  def detail_schema do
    step =
      Schema.object(
        %{
          "id" => @id,
          "seq" => %{"type" => "integer", "minimum" => 0},
          "type" => %{"type" => "string", "enum" => ["step", "wait"]},
          "name" => @text,
          "status" => @text,
          "attempt" => %{"type" => "integer", "minimum" => 0},
          "wait_deadline" => @nullable_time,
          "error_code" => @nullable_text
        },
        ~w(id seq type name status attempt wait_deadline error_code)
      )

    event =
      Schema.object(
        %{
          "seq" => %{"type" => "integer", "minimum" => 1},
          "type" => @text,
          "step_id" => @nullable_text,
          "at" => %{"type" => "string", "format" => "date-time"},
          "payload_json" => @nullable_text
        },
        ~w(seq type step_id at payload_json)
      )

    effect =
      Schema.object(
        %{
          "id" => @id,
          "key" => @text,
          "adapter" => @text,
          "status" => @text,
          "policy" => @text,
          "attempts" => %{"type" => "integer", "minimum" => 0},
          "resolution_required" => %{"type" => "boolean"},
          "external_ref" => @nullable_text
        },
        ~w(id key adapter status policy attempts resolution_required external_ref)
      )

    properties =
      Map.merge(summary_schema()["properties"], %{
        "current_step" => %{"type" => "integer", "minimum" => 0},
        "expires_at" => %{"type" => "string", "format" => "date-time"},
        "cancel_deadline" => @nullable_time,
        "cancellation_outcome" => @nullable_text,
        "error_code" => @nullable_text,
        "error_message" => @nullable_text,
        "output_json" => @nullable_text,
        "steps" => %{"type" => "array", "items" => step, "maxItems" => 100},
        "effects" => %{"type" => "array", "items" => effect, "maxItems" => 100},
        "events" => %{"type" => "array", "items" => event, "maxItems" => 100},
        "events_truncated" => %{"type" => "boolean"}
      })

    Schema.object(properties, Map.keys(properties))
  end

  @impl true
  def contract do
    %{
      "operations" => %{},
      "subscriptions" => %{
        "fyrlet.run" => %{
          "capability" => "runs",
          "input" => Schema.object(%{"run_id" => @id}, ["run_id"]),
          "output" => detail_schema()
        },
        "fyrlet.runs.recent" => %{
          "capability" => "runs",
          "input" =>
            Schema.object(%{
              "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50, "default" => 20}
            }),
          "output" => %{"type" => "array", "items" => summary_schema(), "maxItems" => 50}
        }
      }
    }
  end

  @impl true
  def authorize("fyrlet.run", actor, %{"run_id" => run_id}) do
    case Repo.get(Run, run_id) do
      %Run{project_id: project} = run when project == actor.project_id ->
        Fyrlet.Runs.authorize_run(actor, run, :view)

      _other ->
        {:error, Error.not_found()}
    end
  end

  def authorize(_name, _actor, _input), do: :ok

  @impl true
  def execute("fyrlet.run", actor, %{"run_id" => run_id}) do
    case Repo.get(Run, run_id) do
      %Run{project_id: project} = run when project == actor.project_id ->
        {:ok, View.build(run), []}

      _other ->
        {:error, Error.not_found()}
    end
  end

  def execute("fyrlet.runs.recent", actor, %{"limit" => limit}) do
    # Visibility is applied in the query, before the page is cut: the default policy
    # lets a subject see the runs it started.
    runs =
      Repo.all(
        from(run in Run,
          where: run.project_id == ^actor.project_id and run.subject_id == ^actor.subject_id,
          order_by: [desc: run.inserted_at, desc: run.id],
          limit: ^limit
        )
      )

    {:ok, Enum.map(runs, &View.summary/1), []}
  end

  @impl true
  def scope("fyrlet.run", actor, %{"run_id" => run_id}),
    do: "projects:#{actor.project_id}:runs:#{run_id}"

  def scope("fyrlet.runs.recent", actor, _input),
    do: "projects:#{actor.project_id}:subjects:#{actor.subject_id}:runs"

  @doc false
  def scopes_for(run), do: Notify.scopes(run.project_id, run.subject_id, run.id)
end
