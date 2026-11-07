defmodule FyrletWebhooks.TestDefinition do
  @moduledoc "A run that does a step, waits for a `paid` signal, then does another step."
  @behaviour Fyrlet.Definition
  alias Fyrlet.{Runs, Schema}

  @impl true
  def contract do
    %{
      "operations" => %{"webhooks.demo" => Runs.operation(Schema.object(%{}))},
      "subscriptions" => %{}
    }
  end

  @impl true
  def authorize(_name, _actor, _input), do: :ok
  @impl true
  def execute(_name, _actor, _input), do: {:ok, %{}, []}
  @impl true
  def scope(_name, _actor, _input), do: "webhooks-test"

  @impl true
  def run("webhooks.demo", _actor, _input) do
    {:ok,
     steps: [
       %{type: :step, name: "a", input: %{}},
       %{type: :wait, name: "w", signal: "paid", timeout_ms: 60_000},
       %{type: :step, name: "b", input: %{}}
     ]}
  end

  @impl true
  def step(_name, _input, _context), do: {:ok, %{}}
end
