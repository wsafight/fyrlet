defmodule Fyrlet.Runs.Dynamic do
  @moduledoc """
  Decides the next node of a dynamically planned run (temp spec §3.2).

  `advance/3` sees only persisted facts - the run's input and the outputs of finished nodes -
  plus the event that just happened, and does no I/O. Its decision is validated like a static
  plan node and bounded by the same limits.
  """
  import Ecto.Query
  require Logger
  alias Fyrlet.{Error, Repo}
  alias Fyrlet.Runs.{Limits, Plan, Resolver, Step}

  def decide(run, event) do
    case Resolver.implementation(run) do
      nil ->
        {:error, error("DEFINITION_UNAVAILABLE", "The definition cannot plan the next node")}

      module ->
        count = Repo.aggregate(from(s in Step, where: s.run_id == ^run.id), :count)

        if count >= Limits.get(:max_nodes) do
          {:error,
           error("TOO_MANY_NODES", "The run would exceed #{Limits.get(:max_nodes)} nodes")}
        else
          ask(module, run, event)
        end
    end
  end

  defp ask(module, run, event) do
    decision =
      try do
        module.advance(run.operation, state(run), event)
      rescue
        exception ->
          Fyrlet.Runs.Dynamic.log(exception)
          {:error, Error.new("ADVANCE_CRASHED", "advance/3 raised")}
      end

    specification =
      case Fyrlet.Registry.fetch("operations", run.operation) do
        {:ok, _module, specification} -> specification
        _unknown -> %{}
      end

    case decision do
      {:done, output} when is_map(output) ->
        case Plan.payload(output, "run output") do
          {:ok, checked} -> {:done, checked}
          {:error, e} -> {:error, error("INVALID_ADVANCE", e.message)}
        end

      {:done, _other} ->
        {:error, error("INVALID_ADVANCE", "The run output must be an object")}

      other ->
        case Plan.decision_node(other, specification) do
          {:ok, node} -> {:node, node}
          {:error, %Error{code: code, message: message}} -> {:error, error(code, message)}
        end
    end
  end

  defp state(run) do
    outputs =
      Repo.all(
        from(s in Step,
          where: s.run_id == ^run.id and s.status in ["succeeded", "satisfied", "timed_out"],
          order_by: s.seq,
          select: %{name: s.name, output: s.output}
        )
      )

    %{
      run_id: run.id,
      operation: run.operation,
      input: run.input,
      outputs: outputs,
      project_id: run.project_id,
      initiator_subject_id: run.subject_id
    }
  end

  @doc false
  def log(exception), do: Logger.error("advance/3 raised #{inspect(exception.__struct__)}")

  defp error(code, message), do: %{"code" => code, "message" => message}
end
