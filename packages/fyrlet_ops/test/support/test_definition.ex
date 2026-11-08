defmodule FyrletOps.TestDefinition do
  @moduledoc "A run that parks on a wait node, so tests can create runs in a known state."
  @behaviour Fyrlet.Definition
  alias Fyrlet.{Runs, Schema}

  @impl true
  def contract do
    %{
      "operations" => %{"ops.hold" => Runs.operation(Schema.object(%{}))},
      "subscriptions" => %{}
    }
  end

  @impl true
  def authorize(_name, _actor, _input), do: :ok
  @impl true
  def execute(_name, _actor, _input), do: {:ok, %{}, []}
  @impl true
  def scope(_name, _actor, _input), do: "ops-test"

  @impl true
  def run("ops.hold", _actor, _input),
    do: {:ok, steps: [%{type: :wait, name: "hold", signal: "go", timeout_ms: 86_400_000}]}

  @impl true
  def definition_version(_name), do: "1"

  @impl true
  def implementation("ops.hold", "1"), do: __MODULE__
  def implementation(_name, _version), do: nil

  @impl true
  def step(_name, _input, _context), do: {:ok, %{}}
end
