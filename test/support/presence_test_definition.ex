defmodule Fyrlet.PresenceTestDefinition do
  @moduledoc "A chat room's presence: who is here and whether they are typing."
  @behaviour Fyrlet.Definition
  alias Fyrlet.{Error, Schema}

  @impl true
  def contract do
    %{
      "operations" => %{},
      "subscriptions" => %{},
      "presence" => %{
        "room.presence" => %{
          "input" =>
            Schema.object(%{"room" => %{"type" => "string", "minLength" => 1}}, ["room"]),
          "meta" =>
            Schema.object(%{
              "typing" => %{"type" => "boolean", "default" => false},
              "status" => %{"type" => "string", "maxLength" => 16}
            })
        },
        "lobby.presence" => %{"input" => Schema.object(%{})}
      }
    }
  end

  # `:presence_deny` holds a list of subject ids that may not enter.
  @impl true
  def authorize(_name, actor, _input) do
    if actor.subject_id in Application.get_env(:fyrlet, :presence_deny, []),
      do: {:error, Error.forbidden()},
      else: :ok
  end

  @impl true
  def execute(_name, _actor, _input), do: {:error, Error.not_found()}

  @impl true
  def scope(_name, _actor, %{"room" => room}), do: "room:" <> room
  def scope(_name, _actor, _input), do: "lobby"
end
