defmodule Fyrlet.Runs.Plan do
  @moduledoc """
  Validates the sequential plan a definition's `run/3` returns, and normalises it to the
  JSON-safe shape persisted with the run.
  """
  alias Fyrlet.{Error, Schema}
  alias Fyrlet.Runs.Limits

  @name ~r/^[a-z][a-z0-9_.-]{0,63}$/
  @max_wait_ms 30 * 24 * 3_600_000

  @doc """
  Returns `{:ok, plan}` where `plan` has `"nodes"`, `"business_key"`, `"ttl_seconds"`
  and `"total_wait_ms"`, or `{:error, %Fyrlet.Error{}}`.
  """
  def build(module, name, actor, input, %{"planning" => "dynamic"} = specification),
    do: build_dynamic(module, name, actor, input, specification)

  def build(module, name, actor, input, specification) do
    case module.run(name, actor, input) do
      {:ok, options} when is_list(options) -> normalise(options, specification)
      {:error, %Error{} = error} -> {:error, error}
      _other -> invalid("run/3 must return {:ok, steps: [...]} or {:error, error}")
    end
  end

  # Dynamic planning: the definition's `advance/3` supplies the first node now and every later
  # one when the previous node finishes. Nothing about the future is promised at creation.
  defp build_dynamic(module, name, actor, input, specification) do
    state = %{
      operation: name,
      input: input,
      outputs: [],
      project_id: actor.project_id,
      initiator_subject_id: actor.subject_id
    }

    options =
      if function_exported?(module, :plan_options, 3),
        do: module.plan_options(name, actor, input),
        else: []

    with {:ok, first} <- first_decision(module, name, state),
         {:ok, node} <- decision_node(first, specification),
         {:ok, key} <- business_key(options[:business_key]),
         {:ok, ttl} <- ttl(options[:ttl_seconds]) do
      {:ok,
       %{
         "mode" => "dynamic",
         "nodes" => [Map.put(node, "seq", 0)],
         "business_key" => key,
         "ttl_seconds" => ttl,
         "total_wait_ms" => if(node["type"] == "wait", do: node["timeout_ms"], else: 0)
       }}
    end
  end

  defp first_decision(module, name, state) do
    {:ok, module.advance(name, state, :start)}
  rescue
    _exception -> invalid("advance/3 raised while planning the first node")
  end

  @doc "Turns an `advance/3` decision into a validated node, or an error."
  def decision_node({:step, name, input}, specification),
    do: node(%{type: :step, name: name, input: input}, specification)

  def decision_node({:wait, wait}, specification) when is_map(wait),
    do: node(Map.put(wait, :type, :wait), specification)

  def decision_node({:done, _output}, _specification),
    do: invalid("A run needs at least one node before it can be done")

  def decision_node({:error, %Error{} = error}, _specification), do: {:error, error}
  def decision_node(_other, _specification), do: invalid("advance/3 returned an unknown decision")

  defp normalise(options, specification) do
    with {:ok, steps} <- fetch_steps(options),
         {:ok, nodes} <- nodes(steps, specification),
         {:ok, key} <- business_key(options[:business_key]),
         {:ok, ttl} <- ttl(options[:ttl_seconds]) do
      total_wait =
        nodes
        |> Enum.filter(&(&1["type"] == "wait"))
        |> Enum.map(& &1["timeout_ms"])
        |> Enum.sum()

      {:ok,
       %{
         "nodes" => nodes,
         "business_key" => key,
         "ttl_seconds" => ttl,
         "total_wait_ms" => total_wait
       }}
    end
  end

  defp fetch_steps(options) do
    case options[:steps] do
      steps when is_list(steps) and steps != [] ->
        if length(steps) <= Limits.get(:max_nodes),
          do: {:ok, steps},
          else: invalid("A run may have at most #{Limits.get(:max_nodes)} nodes")

      _other ->
        invalid("A run needs a non-empty list of steps")
    end
  end

  defp nodes(steps, specification) do
    steps
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {step, index}, {:ok, acc} ->
      case node(step, specification) do
        {:ok, node} -> {:cont, {:ok, [Map.put(node, "seq", index) | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp node(%{type: type} = step, specification) when type in [:step, "step"],
    do: work_node(step, specification)

  defp node(%{type: type} = step, specification) when type in [:wait, "wait"],
    do: wait_node(step, specification)

  defp node(_other, _specification), do: invalid("Each node needs type :step or :wait")

  defp work_node(step, specification) do
    with {:ok, name} <- node_name(step[:name]),
         {:ok, input} <- payload(step[:input] || %{}, "input of #{name}"),
         {:ok, input} <- contract(specification, ["steps", name, "input"], input, name),
         {:ok, attempts} <- attempts(step[:max_attempts]) do
      {:ok,
       %{
         "type" => "step",
         "name" => name,
         "input" => input,
         "max_attempts" => attempts,
         "queue" => queue(specification, name)
       }}
    end
  end

  # `executor: %{"default" => "queue", "step_name" => "other"}` sends steps to an external queue.
  defp queue(specification, name) do
    case specification["executor"] do
      %{} = routes -> routes[name] || routes["default"]
      _none -> nil
    end
  end

  defp wait_node(step, _specification) do
    with {:ok, name} <- node_name(step[:name]),
         {:ok, signal} <- node_name(step[:signal]),
         {:ok, timeout} <- timeout(step[:timeout_ms]),
         {:ok, action} <- timeout_action(step[:on_timeout]) do
      {:ok,
       %{
         "type" => "wait",
         "name" => name,
         "signal" => signal,
         "timeout_ms" => timeout,
         "on_timeout" => action
       }}
    end
  end

  defp node_name(name) when is_binary(name) do
    if Regex.match?(@name, name),
      do: {:ok, name},
      else: invalid("Invalid node name #{inspect(name)}")
  end

  defp node_name(_name), do: invalid("A node needs a name")

  defp timeout(value) when is_integer(value) and value > 0 and value <= @max_wait_ms,
    do: {:ok, value}

  defp timeout(_value), do: invalid("A wait needs timeout_ms between 1 and #{@max_wait_ms}")

  defp timeout_action(nil), do: {:ok, "fail"}
  defp timeout_action(action) when action in [:fail, "fail"], do: {:ok, "fail"}
  defp timeout_action(action) when action in [:continue, "continue"], do: {:ok, "continue"}
  defp timeout_action(_action), do: invalid("on_timeout must be :fail or :continue")

  defp attempts(nil), do: {:ok, Limits.get(:max_attempts)}
  defp attempts(value) when is_integer(value) and value in 1..10, do: {:ok, value}
  defp attempts(_value), do: invalid("max_attempts must be between 1 and 10")

  defp business_key(nil), do: {:ok, nil}

  defp business_key(key) when is_binary(key) and byte_size(key) in 1..200, do: {:ok, key}
  defp business_key(_key), do: invalid("business_key must be 1 to 200 bytes")

  defp ttl(nil), do: {:ok, Limits.get(:default_ttl)}

  defp ttl(seconds) when is_integer(seconds) and seconds > 0 do
    if seconds <= Limits.get(:max_ttl),
      do: {:ok, seconds},
      else: invalid("ttl_seconds cannot exceed #{Limits.get(:max_ttl)}")
  end

  defp ttl(_seconds), do: invalid("ttl_seconds must be a positive integer")

  @doc "Normalises a value to JSON types and enforces the payload size bound."
  def payload(value, label) do
    json = Jason.encode!(value)

    if byte_size(json) <= Limits.get(:payload_max_bytes),
      do: {:ok, Jason.decode!(json)},
      else: invalid("The #{label} exceeds #{Limits.get(:payload_max_bytes)} bytes")
  rescue
    _error -> invalid("The #{label} must be JSON-serialisable")
  end

  @doc "Validates against a declared schema at `path` of the operation contract, if any."
  def contract(specification, path, value, label) do
    case get_in(specification, path) do
      nil ->
        {:ok, value}

      schema ->
        case Schema.validate(schema, value) do
          {:ok, checked} -> {:ok, checked}
          {:error, _error} -> invalid("The #{label} does not match its contract")
        end
    end
  end

  defp invalid(message), do: {:error, Error.new("VALIDATION_FAILED", message)}
end
