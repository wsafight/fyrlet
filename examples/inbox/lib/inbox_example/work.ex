defmodule InboxExample.Work do
  @moduledoc "A durable approval task and a private append feed used by the SDK integration suite."
  @behaviour Fyrlet.Definition
  alias Fyrlet.{Error, Runs, Schema}
  alias Fyrlet.Features.Stream

  @text %{"type" => "string", "minLength" => 1, "maxLength" => 200}

  @impl true
  def contract do
    %{
      "operations" => %{
        "work.start" => Runs.operation(Schema.object(%{"text" => @text}, ["text"])),
        "work.post" => %{
          "kind" => "write",
          "input" => Schema.object(%{"text" => @text}, ["text"]),
          "output" => Schema.object(%{"cursor" => %{"type" => "string"}}, ["cursor"])
        }
      },
      "subscriptions" => %{
        "work.feed" => %{
          "capability" => "append",
          "mode" => "append",
          "max_items" => 3,
          "input" => Schema.object(%{}),
          "output" => %{
            "type" => "array",
            "maxItems" => 3,
            "items" => Schema.object(%{"text" => @text}, ["text"])
          }
        }
      }
    }
  end

  @impl true
  def authorize(_name, _actor, _input), do: :ok

  @impl true
  def scope(_name, actor, _input), do: "work:#{actor.project_id}:#{actor.subject_id}"

  @impl true
  def stream("work.feed", actor, _input), do: {:ok, "work.#{actor.subject_id}"}

  @impl true
  def execute("work.post", actor, input) do
    with {:ok, cursor} <- Stream.append(actor.project_id, "work.#{actor.subject_id}", [input]) do
      {:ok, %{"cursor" => cursor}, [scope("work.feed", actor, %{})]}
    end
  end

  @impl true
  def run("work.start", _actor, input) do
    {:ok,
     steps: [
       %{type: :step, name: "prepare", input: input},
       %{type: :wait, name: "approval", signal: "approve", timeout_ms: 60_000, on_timeout: :fail},
       %{type: :step, name: "finish", input: input}
     ]}
  end

  @impl true
  def definition_version(_name), do: "1"

  @impl true
  def implementation("work.start", "1"), do: __MODULE__
  def implementation(_name, _version), do: nil

  @impl true
  def step(_name, input, _context), do: {:ok, input}

  @impl true
  def run_authorize(_name, :start, _actor, _input), do: :ok

  def run_authorize(_name, _action, actor, %{"owner_subject_id" => owner}),
    do: if(actor.subject_id == owner, do: :ok, else: {:error, Error.forbidden()})
end
