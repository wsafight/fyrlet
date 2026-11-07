defmodule Fyrlet.SharedRooms do
  @moduledoc "In-memory rooms for shared-subscription tests: messages, members and a query counter."
  use Agent

  # Not linked to the test that starts it: observers outlive a test briefly and keep asking.
  def start do
    case Agent.start(fn -> %{rooms: %{}, queries: 0, contexts: []} end, name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  def reset, do: Agent.update(__MODULE__, fn _ -> %{rooms: %{}, queries: 0, contexts: []} end)

  def add_member(room, subject),
    do:
      Agent.update(
        __MODULE__,
        &update_in(
          &1,
          [:rooms, Access.key(room, %{messages: [], members: MapSet.new()}), :members],
          fn m -> MapSet.put(m, subject) end
        )
      )

  def remove_member(room, subject),
    do:
      Agent.update(
        __MODULE__,
        &update_in(
          &1,
          [:rooms, Access.key(room, %{messages: [], members: MapSet.new()}), :members],
          fn m -> MapSet.delete(m, subject) end
        )
      )

  def member?(room, subject),
    do:
      Agent.get(__MODULE__, fn s ->
        MapSet.member?(get_in(s, [:rooms, room, :members]) || MapSet.new(), subject)
      end)

  def post(room, text),
    do:
      Agent.update(
        __MODULE__,
        &update_in(
          &1,
          [:rooms, Access.key(room, %{messages: [], members: MapSet.new()}), :messages],
          fn m -> m ++ [%{"id" => Ecto.UUID.generate(), "text" => text}] end
        )
      )

  def messages(room),
    do: Agent.get(__MODULE__, fn s -> get_in(s, [:rooms, room, :messages]) || [] end)

  def count_query(context),
    do:
      Agent.update(__MODULE__, fn s ->
        %{s | queries: s.queries + 1, contexts: [context | s.contexts]}
      end)

  def queries, do: Agent.get(__MODULE__, & &1.queries)
  def contexts, do: Agent.get(__MODULE__, & &1.contexts)
end

defmodule Fyrlet.SharedTestDefinition do
  @moduledoc "A room feed shared across its members: one query per change, a membership check per member."
  @behaviour Fyrlet.Definition
  alias Fyrlet.{Error, Schema, SharedRooms}

  @impl true
  def contract do
    message =
      Schema.object(
        %{"id" => %{"type" => "string", "format" => "uuid"}, "text" => %{"type" => "string"}},
        ["id", "text"]
      )

    %{
      "operations" => %{},
      "subscriptions" => %{
        "room.recent" => %{
          "sharing" => "identical",
          "input" =>
            Schema.object(%{"room" => %{"type" => "string", "minLength" => 1}}, ["room"]),
          "output" => %{"type" => "array", "items" => message, "maxItems" => 100}
        }
      }
    }
  end

  @impl true
  def authorize(_name, actor, _input),
    do:
      if(Application.get_env(:fyrlet, :room_deny) == actor.subject_id,
        do: {:error, Error.forbidden()},
        else: :ok
      )

  @impl true
  def execute(_name, _actor, _input), do: {:error, Error.not_found()}

  @impl true
  def scope(_name, actor, %{"room" => room}), do: "room:#{actor.project_id}:#{room}"

  # Receives the trusted project and scope only: there is no person here to tailor the result to.
  @impl true
  def shared_query("room.recent", context, %{"room" => room}) do
    SharedRooms.count_query(context)
    {:ok, SharedRooms.messages(room), %{}}
  end

  @impl true
  def membership("room.recent", actor, %{"room" => room}),
    do: if(SharedRooms.member?(room, actor.subject_id), do: :member, else: :not_member)

  @impl true
  def policy_version(_name), do: Application.get_env(:fyrlet, :room_policy_version, "1")

  @impl true
  def definition_version(_name), do: Application.get_env(:fyrlet, :room_definition_version, "1")
end
