defmodule Fyrlet.AppendTestDefinition do
  @moduledoc "A room feed delivered by append: posting appends to the stream inside the write transaction."
  @behaviour Fyrlet.Definition
  alias Fyrlet.{Error, Schema}
  alias Fyrlet.Features.Stream

  @impl true
  def contract do
    message = Schema.object(%{"text" => %{"type" => "string"}}, ["text"])
    room = Schema.object(%{"room" => %{"type" => "string", "minLength" => 1}}, ["room"])

    %{
      "operations" => %{
        "feed.post" => %{
          "kind" => "write",
          "input" =>
            Schema.object(
              %{
                "room" => %{"type" => "string", "minLength" => 1},
                "texts" => %{
                  "type" => "array",
                  "items" => %{"type" => "string"},
                  "maxItems" => 50
                }
              },
              ["room", "texts"]
            ),
          "output" => Schema.object(%{"cursor" => %{"type" => "string"}}, ["cursor"])
        },
        "feed.post_then_fail" => %{
          "kind" => "write",
          "input" => room,
          "output" => Schema.object(%{"cursor" => %{"type" => "string"}}, ["cursor"])
        }
      },
      "subscriptions" => %{
        "feed.recent" => %{
          "capability" => "append",
          "mode" => "append",
          "max_items" => 5,
          "input" => room,
          "output" => %{"type" => "array", "items" => message, "maxItems" => 5}
        },
        "feed.plain" => %{"input" => room, "output" => %{"type" => "array", "items" => message}}
      }
    }
  end

  @impl true
  def authorize(_name, actor, _input),
    do:
      if(Application.get_env(:fyrlet, :feed_deny) == actor.subject_id,
        do: {:error, Error.forbidden()},
        else: :ok
      )

  @impl true
  def scope(_name, actor, %{"room" => room}), do: "feed:#{actor.project_id}:#{room}"

  @impl true
  def stream("feed.recent", _actor, %{"room" => room}), do: {:ok, "feed.#{room}"}

  @impl true
  def execute("feed.post", actor, %{"room" => room, "texts" => texts}) do
    with {:ok, cursor} <-
           Stream.append(actor.project_id, "feed.#{room}", Enum.map(texts, &%{"text" => &1})) do
      {:ok, %{"cursor" => cursor}, [scope("feed.post", actor, %{"room" => room})]}
    end
  end

  def execute("feed.post_then_fail", actor, %{"room" => room}) do
    {:ok, _cursor} = Stream.append(actor.project_id, "feed.#{room}", [%{"text" => "never"}])
    {:error, Error.new("CONFLICT", "rolled back")}
  end

  def execute("feed.plain", _actor, _input), do: {:error, Error.not_found()}
end
