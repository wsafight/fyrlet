defmodule AgentExample.Definition do
  @moduledoc "A deterministic assistant with two finite text tools and mandatory human approval."
  @behaviour Fyrlet.Definition
  import Ecto.Query
  alias Fyrlet.{Error, Repo, Runs, Schema, Scope}
  alias AgentExample.Task

  @impl true
  def contract do
    input =
      Schema.object(
        %{
          "goal" => %{"type" => "string", "minLength" => 1, "maxLength" => 4000},
          "tool" => %{"type" => "string", "enum" => ["word_count", "excerpt"]}
        },
        ~w(goal tool)
      )

    task =
      Schema.object(
        %{
          "id" => %{"type" => "string"},
          "run_id" => %{"type" => "string"},
          "goal" => %{"type" => "string"},
          "tool" => %{"type" => "string"},
          "result_json" => %{"type" => "string"},
          "status" => %{"type" => "string"}
        },
        ~w(id run_id goal tool result_json status)
      )

    %{
      "operations" => %{
        "agent.start" =>
          Runs.operation(input,
            signals: %{
              "approval" => Schema.object(%{"approved" => %{"type" => "boolean"}}, ["approved"])
            }
          )
      },
      "subscriptions" => %{
        "agent.tasks" => %{
          "input" => Schema.object(%{}),
          "output" => %{"type" => "array", "items" => task, "maxItems" => 50}
        }
      }
    }
  end

  @impl true
  def authorize(_name, _actor, _input), do: :ok
  @impl true
  def data_scope(_action, _actor, _input), do: {:ok, project: :project_id, subject: :subject_id}
  @impl true
  def scope(_name, actor, _input), do: Runs.scope(actor)

  @impl true
  def execute("agent.tasks", actor, _input) do
    rows =
      from(task in Task, order_by: [desc: task.inserted_at], limit: 50)
      |> Scope.all(actor, __MODULE__, %{})

    {:ok, Enum.map(rows, &serialize(&1, actor)), []}
  end

  @impl true
  def run("agent.start", _actor, input) do
    {:ok,
     steps: [
       %{type: :step, name: "prepare", input: input},
       %{
         type: :wait,
         name: "approval",
         signal: "approval",
         timeout_ms: 3_600_000,
         on_timeout: :fail
       },
       %{type: :step, name: "finish", input: %{}}
     ]}
  end

  @impl true
  def step("prepare", input, context) do
    result =
      case input["tool"] do
        "word_count" ->
          %{
            "words" => length(String.split(input["goal"], ~r/\s+/u, trim: true)),
            "characters" => String.length(input["goal"])
          }

        "excerpt" ->
          %{"excerpt" => String.slice(input["goal"], 0, 160)}
      end

    {:ok, result,
     commit: fn ->
       Repo.insert!(%Task{
         project_id: context.project_id,
         subject_id: context.initiator_subject_id,
         run_id: context.run_id,
         goal: input["goal"],
         tool: input["tool"],
         result_json: Jason.encode!(result)
       })
     end}
  end

  def step("finish", _input, context) do
    decision = Enum.find(context.outputs, &(&1.name == "approval"))
    approved = get_in(decision.output, ["payload", "approved"]) == true
    status = if approved, do: "approved", else: "rejected"

    {:ok, %{"approved" => approved},
     commit: fn ->
       Repo.update_all(from(task in Task, where: task.run_id == ^context.run_id),
         set: [status: status, updated_at: DateTime.utc_now()]
       )
     end}
  end

  @impl true
  def run_authorize(_name, :start, _actor, _input), do: :ok

  def run_authorize(_name, _action, actor, %{"owner_subject_id" => owner}),
    do: if(actor.subject_id == owner, do: :ok, else: {:error, Error.forbidden()})

  defp serialize(task, actor) do
    status =
      case Runs.get(actor, task.run_id) do
        {:ok, %{"status" => terminal}} when terminal in ["failed", "cancelled", "expired"] ->
          terminal

        _active ->
          task.status
      end

    %{
      "id" => task.id,
      "run_id" => task.run_id,
      "goal" => task.goal,
      "tool" => task.tool,
      "result_json" => task.result_json,
      "status" => status
    }
  end
end
