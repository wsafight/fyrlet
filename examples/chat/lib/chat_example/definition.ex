defmodule ChatExample.Definition do
  @moduledoc "Authenticated conversations, invitation-based membership, assignment, handoff and bounded live messages."
  @behaviour Fyrlet.Definition
  import Ecto.Query
  alias Fyrlet.{Error, Repo, Schema}
  alias Fyrlet.Features.Stream
  alias ChatExample.{Member, Message, Room}
  @id %{"type" => "string", "format" => "uuid"}
  @text %{"type" => "string", "minLength" => 1, "maxLength" => 4000}
  @nullable_id %{"anyOf" => [@id, %{"type" => "null"}]}

  @impl true
  def contract do
    message =
      Schema.object(
        %{"id" => @id, "author" => @id, "text" => @text, "at" => %{"type" => "string"}},
        ~w(id author text at)
      )

    room =
      Schema.object(
        %{
          "id" => @id,
          "title" => @text,
          "status" => %{"type" => "string"},
          "assigned_subject_id" => @nullable_id,
          "code" => %{"type" => "string"},
          "members" => %{
            "type" => "array",
            "items" => Schema.object(%{"subject_id" => @id}, ["subject_id"]),
            "maxItems" => 50
          }
        },
        ~w(id title status assigned_subject_id)
      )

    reference = Schema.object(%{"room_id" => @id}, ["room_id"])

    operations = %{
      "chat.create" => operation("write", Schema.object(%{"title" => @text}, ["title"]), room),
      "chat.join" =>
        operation(
          "write",
          Schema.object(
            %{"code" => %{"type" => "string", "minLength" => 20, "maxLength" => 100}},
            ["code"]
          ),
          room
        ),
      "chat.get" => operation("read", reference, room),
      "chat.post" =>
        operation(
          "write",
          Schema.object(%{"room_id" => @id, "text" => @text}, ~w(room_id text)),
          message
        ),
      "chat.assign" =>
        operation(
          "write",
          Schema.object(%{"room_id" => @id, "subject_id" => @id}, ~w(room_id subject_id)),
          room
        ),
      "chat.handoff" => operation("write", reference, room),
      "chat.close" => operation("write", reference, room),
      "chat.rename" =>
        operation(
          "write",
          Schema.object(%{"room_id" => @id, "title" => @text}, ~w(room_id title)),
          room
        ),
      "chat.leave" =>
        operation(
          "write",
          reference,
          Schema.object(%{"left" => %{"type" => "boolean"}}, ["left"])
        ),
      "chat.history" =>
        operation(
          "read",
          Schema.object(
            %{
              "room_id" => @id,
              "cursor" => @id,
              "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50, "default" => 20}
            },
            ["room_id"]
          ),
          Schema.object(
            %{
              "items" => %{"type" => "array", "items" => message, "maxItems" => 50},
              "next_cursor" => @nullable_id
            },
            ~w(items next_cursor)
          )
        )
    }

    %{
      "operations" => operations,
      "subscriptions" => %{
        "chat.rooms" => %{
          "input" => Schema.object(%{}),
          "output" => %{"type" => "array", "items" => room, "maxItems" => 50}
        },
        "chat.room" => %{"sharing" => "identical", "input" => reference, "output" => room},
        "chat.room.private" => %{"input" => reference, "output" => room},
        "chat.messages" => %{
          "capability" => "append",
          "mode" => "append",
          "max_items" => 100,
          "input" => reference,
          "output" => %{"type" => "array", "items" => message, "maxItems" => 100}
        },
        "chat.messages.snapshot" => %{
          "input" => reference,
          "output" => %{"type" => "array", "items" => message, "maxItems" => 100}
        }
      }
    }
  end

  defp operation(kind, input, output), do: %{"kind" => kind, "input" => input, "output" => output}

  @impl true
  def authorize(_name, actor, %{"room_id" => room_id}),
    do:
      if(member?(actor.project_id, room_id, actor.subject_id),
        do: :ok,
        else: {:error, Error.forbidden()}
      )

  def authorize(_name, _actor, _input), do: :ok

  @impl true
  def scope(_name, actor, %{"room_id" => id}), do: room_scope(actor.project_id, id)
  def scope(_name, actor, _input), do: list_scope(actor.project_id, actor.subject_id)

  @impl true
  def stream("chat.messages", _actor, %{"room_id" => id}), do: {:ok, "chat.#{id}"}

  @impl true
  def definition_version(_name), do: "1"

  @impl true
  def membership(_name, actor, %{"room_id" => id}),
    do: if(member?(actor.project_id, id, actor.subject_id), do: :member, else: :not_member)

  @impl true
  def shared_query("chat.room", context, %{"room_id" => id}) do
    case Repo.get_by(Room, id: id, project_id: context.project_id) do
      nil -> {:error, Error.not_found()}
      room -> {:ok, Map.delete(serialize(room), "code"), %{}}
    end
  end

  @impl true
  def execute("chat.create", actor, %{"title" => title}) do
    room =
      Repo.insert!(%Room{
        project_id: actor.project_id,
        title: title,
        code: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
      })

    Repo.insert!(%Member{
      project_id: actor.project_id,
      room_id: room.id,
      subject_id: actor.subject_id
    })

    {:ok, serialize(room), scopes(room)}
  end

  def execute("chat.join", actor, %{"code" => code}) do
    room =
      Repo.one(
        from(room in Room,
          where: room.project_id == ^actor.project_id and room.code == ^code,
          lock: "FOR UPDATE"
        )
      )

    cond do
      is_nil(room) ->
        {:error, Error.not_found()}

      room.status == "closed" ->
        {:error, Error.new("CONFLICT", "The conversation is closed")}

      length(members(room)) >= 50 and not member?(actor.project_id, room.id, actor.subject_id) ->
        {:error, Error.new("LIMIT_EXCEEDED", "The conversation is full")}

      true ->
        Repo.insert!(
          %Member{project_id: actor.project_id, room_id: room.id, subject_id: actor.subject_id},
          on_conflict: :nothing,
          conflict_target: [:room_id, :subject_id]
        )

        {:ok, serialize(room), scopes(room)}
    end
  end

  def execute("chat.rooms", actor, _input) do
    rooms =
      Repo.all(
        from(room in Room,
          join: member in Member,
          on: member.room_id == room.id and member.project_id == room.project_id,
          where: room.project_id == ^actor.project_id and member.subject_id == ^actor.subject_id,
          order_by: [desc: room.updated_at, desc: room.id],
          limit: 50,
          select: room
        )
      )

    {:ok, Enum.map(rooms, &serialize/1), []}
  end

  def execute("chat.get", actor, %{"room_id" => id}) do
    with {:ok, room} <- load_room(actor, id),
         do:
           {:ok,
            Map.put(serialize(room), "members", Enum.map(members(room), &%{"subject_id" => &1})),
            []}
  end

  def execute("chat.room.private", actor, %{"room_id" => id}) do
    with {:ok, room} <- load_room(actor, id), do: {:ok, Map.delete(serialize(room), "code"), []}
  end

  def execute("chat.messages.snapshot", actor, %{"room_id" => id}) do
    with {:ok, _room} <- load_room(actor, id) do
      rows =
        Repo.all(
          from(message in Message,
            where: message.project_id == ^actor.project_id and message.room_id == ^id,
            order_by: [desc: message.inserted_at, desc: message.id],
            limit: 100
          )
        )

      {:ok, rows |> Enum.reverse() |> Enum.map(&serialize_message/1), []}
    end
  end

  def execute("chat.post", actor, %{"room_id" => id, "text" => text}) do
    with {:ok, room} <- load_room(actor, id), :ok <- open?(room) do
      message =
        Repo.insert!(%Message{
          project_id: actor.project_id,
          room_id: room.id,
          subject_id: actor.subject_id,
          text: text
        })

      item = serialize_message(message)
      {:ok, _cursor} = Stream.append(actor.project_id, "chat.#{id}", [item])
      {:ok, item, scopes(room)}
    end
  end

  def execute("chat.history", actor, %{"room_id" => id, "limit" => limit} = input) do
    with {:ok, _room} <- load_room(actor, id),
         {:ok, query} <- history_query(actor.project_id, id, input["cursor"]) do
      rows =
        Repo.all(
          from(message in query,
            order_by: [desc: message.inserted_at, desc: message.id],
            limit: ^(limit + 1)
          )
        )

      page = Enum.take(rows, limit)
      next_cursor = if length(rows) > limit, do: List.last(page).id, else: nil

      {:ok,
       %{
         "items" => page |> Enum.reverse() |> Enum.map(&serialize_message/1),
         "next_cursor" => next_cursor
       }, []}
    end
  end

  def execute("chat.leave", actor, %{"room_id" => id}) do
    with {:ok, room} <- load_room(actor, id) do
      affected = scopes(room)

      Repo.delete_all(
        from(member in Member,
          where:
            member.project_id == ^actor.project_id and member.room_id == ^id and
              member.subject_id == ^actor.subject_id
        )
      )

      if room.assigned_subject_id == actor.subject_id,
        do: Repo.update!(Ecto.Changeset.change(room, assigned_subject_id: nil))

      {:ok, %{"left" => true}, affected}
    end
  end

  def execute(name, actor, %{"room_id" => id} = input)
      when name in ["chat.assign", "chat.handoff", "chat.close", "chat.rename"] do
    with {:ok, room} <- load_room(actor, id) do
      assigned = if name == "chat.handoff", do: actor.subject_id, else: input["subject_id"]

      if name == "chat.assign" and not member?(actor.project_id, id, assigned) do
        {:error, Error.forbidden()}
      else
        changes =
          case name do
            "chat.assign" -> [assigned_subject_id: assigned]
            "chat.handoff" -> [assigned_subject_id: assigned, status: "human"]
            "chat.close" -> [status: "closed"]
            "chat.rename" -> [title: input["title"]]
          end

        room = Repo.update!(Ecto.Changeset.change(room, changes))
        {:ok, serialize(room), scopes(room)}
      end
    end
  end

  defp load_room(actor, id) do
    query = from(room in Room, where: room.id == ^id and room.project_id == ^actor.project_id)
    query = if Repo.in_transaction?(), do: from(room in query, lock: "FOR UPDATE"), else: query

    case Repo.one(query) do
      nil ->
        {:error, Error.not_found()}

      room ->
        if member?(actor.project_id, id, actor.subject_id),
          do: {:ok, room},
          else: {:error, Error.forbidden()}
    end
  end

  defp member?(project, room, subject),
    do:
      Repo.exists?(
        from(member in Member,
          where:
            member.project_id == ^project and member.room_id == ^room and
              member.subject_id == ^subject
        )
      )

  defp members(room),
    do:
      Repo.all(
        from(member in Member,
          where: member.project_id == ^room.project_id and member.room_id == ^room.id,
          order_by: member.inserted_at,
          select: member.subject_id
        )
      )

  defp open?(%{status: "closed"}),
    do: {:error, Error.new("CONFLICT", "The conversation is closed")}

  defp open?(_room), do: :ok

  defp scopes(room),
    do: [
      room_scope(room.project_id, room.id)
      | Enum.map(members(room), &list_scope(room.project_id, &1))
    ]

  defp room_scope(project, room), do: "chat:#{project}:rooms:#{room}"
  defp list_scope(project, subject), do: "chat:#{project}:subjects:#{subject}"

  defp serialize(room),
    do: %{
      "id" => room.id,
      "title" => room.title,
      "status" => room.status,
      "assigned_subject_id" => room.assigned_subject_id,
      "code" => room.code
    }

  defp serialize_message(message),
    do: %{
      "id" => message.id,
      "author" => message.subject_id,
      "text" => message.text,
      "at" => DateTime.to_iso8601(message.inserted_at)
    }

  defp history_query(project, room, nil),
    do:
      {:ok,
       from(message in Message,
         where: message.project_id == ^project and message.room_id == ^room
       )}

  defp history_query(project, room, cursor) do
    case Repo.get_by(Message, id: cursor, project_id: project, room_id: room) do
      nil ->
        {:error, Error.not_found()}

      previous ->
        {:ok,
         from(message in Message,
           where:
             message.project_id == ^project and message.room_id == ^room and
               (message.inserted_at < ^previous.inserted_at or
                  (message.inserted_at == ^previous.inserted_at and message.id < ^previous.id))
         )}
    end
  end
end
