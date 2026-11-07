defmodule FlowExample.Definition do
  @moduledoc """
  A sequential flow runner with owner-scoped saved definitions, built on Fyrlet's public surface.

  A flow is a list of nodes: `http` (call a URL with a body) or `wait` (hold until a named
  event arrives or a timeout passes). Every node is a step of one run; every HTTP call is an
  effect, so retries, unknown outcomes, receipts, cancellation and recovery are Fyrlet's, and
  progress is watched through the built-in `fyrlet.run` subscription.

  Branching, loops and data passed between nodes are deliberately absent: they need dynamic
  planning (`advance/3`), which this application does not use.
  """
  @behaviour Fyrlet.Definition
  import Ecto.Query
  alias Fyrlet.{Error, Repo, Runs, Schema, Scope}
  alias FlowExample.Flow

  @name %{"type" => "string", "minLength" => 1, "maxLength" => 60}

  @node Schema.object(
          %{
            "type" => %{"type" => "string", "enum" => ["http", "wait"]},
            "name" => @name,
            "url" => %{"type" => "string", "maxLength" => 500},
            "body" => %{"type" => "string", "maxLength" => 4_000},
            "signal" => @name,
            "timeout_seconds" => %{"type" => "integer", "minimum" => 1, "maximum" => 604_800},
            "continue_on_timeout" => %{"type" => "boolean"}
          },
          ~w(type name)
        )

  @impl true
  def contract do
    input =
      Schema.object(
        %{
          "flow_id" => @name,
          "nodes" => %{"type" => "array", "items" => @node, "maxItems" => 20}
        },
        ~w(flow_id nodes)
      )

    saved =
      Schema.object(
        %{"flow_id" => @name, "nodes_json" => %{"type" => "string"}},
        ~w(flow_id nodes_json)
      )

    %{
      "operations" => %{
        "flow.save" => %{"kind" => "write", "input" => input, "output" => saved},
        "flow.start" =>
          Runs.operation(
            Schema.object(
              %{
                "flow_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 100},
                "nodes" => %{"type" => "array", "items" => @node, "maxItems" => 20}
              },
              ~w(flow_id nodes)
            ),
            on_conflict: :reject_if_active
          )
      },
      "subscriptions" => %{
        "flow.saved" => %{
          "input" => Schema.object(%{}),
          "output" => %{"type" => "array", "items" => saved, "maxItems" => 50}
        }
      }
    }
  end

  @impl true
  def authorize(_name, _actor, _input), do: :ok
  @impl true
  def data_scope(_action, _actor, _input), do: {:ok, project: :project_id, subject: :subject_id}

  @impl true
  def execute("flow.save", actor, input) do
    case run("flow.start", actor, input) do
      {:ok, _plan} ->
        record =
          %Flow{flow_id: input["flow_id"], nodes_json: Jason.encode!(input["nodes"])}
          |> Scope.stamp!(actor, __MODULE__, input)

        record =
          Repo.insert!(record,
            on_conflict: [set: [nodes_json: record.nodes_json, updated_at: DateTime.utc_now()]],
            conflict_target: [:project_id, :subject_id, :flow_id],
            returning: true
          )

        {:ok, serialize(record), [scope("flow.saved", actor, %{})]}

      {:error, error} ->
        {:error, error}
    end
  end

  def execute("flow.saved", actor, _input) do
    records =
      from(flow in Flow, order_by: [desc: flow.updated_at], limit: 50)
      |> Scope.all(actor, __MODULE__, %{})

    {:ok, Enum.map(records, &serialize/1), []}
  end

  def execute(_name, _actor, _input), do: {:error, Error.not_found()}
  @impl true
  def scope(_name, actor, _input),
    do: "projects:#{actor.project_id}:subjects:#{actor.subject_id}:flows"

  @impl true
  def run("flow.start", _actor, %{"nodes" => []}),
    do: {:error, Error.new("VALIDATION_FAILED", "A flow needs at least one node")}

  def run("flow.start", actor, %{"flow_id" => flow_id, "nodes" => nodes}) do
    steps = Enum.map(nodes, &to_step/1)

    if Enum.any?(steps, &match?({:error, _}, &1)),
      do: elem(Enum.find(steps, &match?({:error, _}, &1)), 1) |> then(&{:error, &1}),
      else: {:ok, steps: steps, business_key: "flow:#{actor.subject_id}:" <> flow_id}
  end

  defp to_step(%{"type" => "http", "name" => name} = node) do
    body = node["body"] || "{}"

    with true <- is_binary(node["url"]),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(body) do
      %{
        type: :step,
        name: slug(name),
        input: %{"url" => node["url"], "body" => body}
      }
    else
      _ ->
        {:error,
         Error.new("VALIDATION_FAILED", "http node #{name} needs a url and a JSON object body")}
    end
  end

  defp to_step(%{"type" => "wait", "name" => name} = node) do
    if is_binary(node["signal"]) and is_integer(node["timeout_seconds"]) do
      %{
        type: :wait,
        name: slug(name),
        signal: slug(node["signal"]),
        timeout_ms: node["timeout_seconds"] * 1_000,
        on_timeout: if(node["continue_on_timeout"], do: :continue, else: :fail)
      }
    else
      {:error,
       Error.new("VALIDATION_FAILED", "wait node #{name} needs a signal and timeout_seconds")}
    end
  end

  @impl true
  def step(name, input, _context) do
    {:effect,
     %{
       adapter: "http",
       key: "call",
       payload: %{"url" => input["url"], "body" => Jason.decode!(input["body"])}
     }}
    |> tap(fn _ -> name end)
  end

  defp serialize(flow), do: %{"flow_id" => flow.flow_id, "nodes_json" => flow.nodes_json}

  defp slug(text),
    do:
      text
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_.-]+/, "-")
      |> String.trim("-")
      |> then(&("n" <> &1))
      |> String.slice(0, 63)
end
