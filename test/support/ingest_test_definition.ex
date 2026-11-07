defmodule Fyrlet.IngestTestDefinition do
  @moduledoc "Ingests `{n, text}` items as inbox rows, so a handler's database writes can be observed."
  @behaviour Fyrlet.Definition
  alias Fyrlet.{Error, Schema}
  alias Fyrlet.Features.Ingest

  @impl true
  def contract do
    item =
      Schema.object(
        %{
          "n" => %{"type" => "integer", "minimum" => 0},
          "text" => %{"type" => "string", "maxLength" => 50}
        },
        ["n", "text"]
      )

    %{
      "operations" => %{"events.ingest" => Ingest.operation(item, max_items: 5)},
      "subscriptions" => %{}
    }
  end

  @impl true
  def authorize(_name, actor, _input) do
    if Application.get_env(:fyrlet, :ingest_deny) == actor.subject_id,
      do: {:error, Error.forbidden()},
      else: :ok
  end

  @impl true
  def execute(_name, _actor, _input), do: {:error, Error.not_found()}
  @impl true
  def scope(_name, _actor, _input), do: "ingest"

  @impl true
  def ingest("events.ingest", actor, %{"n" => n, "text" => text}) do
    Fyrlet.Repo.insert!(%InboxExample.Item{
      project_id: actor.project_id,
      subject_id: actor.subject_id,
      text: text,
      content_type: "text"
    })

    case Application.get_env(:fyrlet, :ingest_handler) do
      nil -> :ok
      fun -> fun.(n)
    end
  end
end
