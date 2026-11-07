defmodule Fyrlet.RunsTestDefinition do
  @moduledoc """
  A run definition whose plan and step behaviour tests set through application env, so
  each test can describe exactly the work, failures and races it needs.

  `:run_plans` maps an operation to `fn actor, input -> {:ok, steps: [...]} end`;
  `:run_steps` maps a step name to `fn input, context -> {:ok, map} | {:error, e} end`.
  """
  @behaviour Fyrlet.Definition
  alias Fyrlet.{Error, Runs, Schema}

  @source %{"type" => "string", "maxLength" => 100}

  @impl true
  def contract do
    input = Schema.object(%{"source" => @source, "key" => %{"type" => "string"}})

    strict =
      Runs.operation(input,
        steps: %{
          "prepare" => %{
            "output" => Schema.object(%{"ok" => %{"type" => "boolean"}}, ["ok"])
          }
        },
        signals: %{
          "user_approval" => Schema.object(%{"approved" => %{"type" => "boolean"}}, ["approved"])
        }
      )

    %{
      "operations" => %{
        "runs.demo" => Runs.operation(input),
        "runs.exclusive" => Runs.operation(input, on_conflict: :reject_if_active),
        "runs.strict" => strict,
        "runs.dynamic" => Runs.operation(input, planning: :dynamic),
        "runs.private" => Runs.operation(input, sensitive: ["secret", "source"]),
        "runs.external" =>
          Runs.operation(input, executor: %{"default" => "gpu", "cpu_step" => "cpu"})
      },
      "subscriptions" => %{}
    }
  end

  @impl true
  def authorize(_name, _actor, _input), do: :ok
  @impl true
  def execute(_name, _actor, _input), do: {:ok, %{}, []}
  @impl true
  def scope(_name, _actor, _input), do: "test:runs"

  @impl true
  def run(name, actor, input) do
    case Application.get_env(:fyrlet, :run_plans, %{})[name] do
      nil -> {:ok, default_plan(input)}
      plan -> plan.(actor, input)
    end
  end

  defp default_plan(input) do
    [
      steps: [
        %{type: :step, name: "prepare", input: %{"source" => input["source"] || "none"}},
        %{
          type: :wait,
          name: "approval",
          signal: "user_approval",
          timeout_ms: 60_000,
          on_timeout: :fail
        },
        %{type: :step, name: "publish", input: %{}}
      ],
      business_key: input["key"]
    ]
  end

  @impl true
  def advance(name, state, event) do
    case Application.get_env(:fyrlet, :run_advance) do
      nil -> {:done, %{"decided_by" => name}}
      fun -> fun.(state, event)
    end
  end

  @impl true
  def plan_options(_name, _actor, input), do: [business_key: input["key"]]

  @impl true
  def step(name, input, context) do
    case Application.get_env(:fyrlet, :run_steps, %{})[name] do
      nil -> {:ok, %{name => true}}
      fun -> fun.(input, context)
    end
  end

  @impl true
  def run_authorize(name, action, actor, reference) do
    case Application.get_env(:fyrlet, :run_authorize) do
      nil ->
        if actor.subject_id == reference_owner(reference, actor),
          do: :ok,
          else: {:error, Error.forbidden()}

      fun ->
        fun.(name, action, actor, reference)
    end
  end

  # For :start the reference is the input, so the starter is by definition the actor.
  defp reference_owner(%{"owner_subject_id" => owner}, _actor), do: owner
  defp reference_owner(_input, actor), do: actor.subject_id

  @impl true
  def definition_version(_name), do: Application.get_env(:fyrlet, :run_test_version, "1")

  @impl true
  def implementation(name, version) do
    Application.get_env(:fyrlet, :run_test_impls, %{})[version] ||
      if version == definition_version(name), do: __MODULE__
  end
end
