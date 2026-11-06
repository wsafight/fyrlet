defmodule Fyrlet.Example.Inbox do
  @behaviour Fyrlet.Definition
  import Ecto.Query
  alias Fyrlet.{Error, InboxItem, Repo, Schema, View}
  @reserve_size 8

  @impl true
  def contract do
    item =
      Schema.object(
        %{
          "id" => %{"type" => "string", "format" => "uuid"},
          "text" => %{"type" => "string", "minLength" => 1, "maxLength" => 16_384},
          "content_type" => %{"type" => "string", "enum" => ["text", "link", "code"]},
          "archived" => %{"type" => "boolean"},
          "version" => %{"type" => "integer", "minimum" => 1},
          "inserted_at" => %{"type" => "string", "format" => "date-time"},
          "updated_at" => %{"type" => "string", "format" => "date-time"}
        },
        ["id", "text", "content_type", "archived", "version", "inserted_at", "updated_at"]
      )

    text = %{"type" => "string", "minLength" => 1, "maxLength" => 16_384}
    identifier = %{"type" => "string", "format" => "uuid"}
    version = %{"type" => "integer", "minimum" => 1}
    list = %{"type" => "array", "items" => item, "maxItems" => 100}

    list_input = %{
      "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100, "default" => 50},
      "include_archived" => %{"type" => "boolean", "default" => false}
    }

    %{
      "operations" => %{
        "inbox.add" => %{
          "kind" => "write",
          "input" =>
            Schema.object(
              %{
                "text" => text,
                "content_type" => %{
                  "type" => "string",
                  "enum" => ["text", "link", "code"],
                  "default" => "text"
                }
              },
              ["text"]
            ),
          "output" => item
        },
        "inbox.update" => %{
          "kind" => "write",
          "input" =>
            Schema.object(%{"id" => identifier, "text" => text, "expected_version" => version}, [
              "id",
              "text",
              "expected_version"
            ]),
          "output" => item
        },
        "inbox.archive" => %{
          "kind" => "write",
          "input" =>
            Schema.object(
              %{
                "id" => identifier,
                "expected_version" => version,
                "archived" => %{"type" => "boolean", "default" => true}
              },
              ["id", "expected_version"]
            ),
          "output" => item
        },
        "inbox.delete" => %{
          "kind" => "write",
          "input" =>
            Schema.object(%{"id" => identifier, "expected_version" => version}, [
              "id",
              "expected_version"
            ]),
          "output" =>
            Schema.object(%{"id" => identifier, "deleted" => %{"type" => "boolean"}}, [
              "id",
              "deleted"
            ])
        },
        "inbox.history" => %{
          "kind" => "read",
          "input" =>
            Schema.object(
              Map.put(list_input, "cursor", %{"type" => "string", "maxLength" => 2048})
            ),
          "output" =>
            Schema.object(
              %{
                "items" => list,
                "next_cursor" => %{"anyOf" => [%{"type" => "string"}, %{"type" => "null"}]}
              },
              ["items", "next_cursor"]
            )
        }
      },
      "subscriptions" => %{
        "inbox.recent" => %{
          "input" => Schema.object(list_input),
          "output" => list,
          "shared" => true
        }
      }
    }
  end

  @impl true
  def authorize(_name, _actor, _input), do: :ok

  @impl true
  def change(name, actor, input, record)
      when name in ["inbox.add", "inbox.update", "inbox.archive", "inbox.delete"] do
    %{
      "kind" => name,
      "project_id" => actor.project_id,
      "subject_id" => actor.subject_id,
      "record" => record,
      "previous_version" => Map.get(input, "expected_version", 0)
    }
  end

  def change(_name, _actor, _input, _record), do: nil

  @impl true
  def load_subscription("inbox.recent", actor, parameters) do
    count = parameters["limit"] + @reserve_size

    records =
      actor |> visible(parameters) |> limit(^count) |> Repo.all() |> Enum.map(&serialize/1)

    {data, reserve} = Enum.split(records, parameters["limit"])
    {:ok, data, %{reserve: Map.new(reserve, &{&1["id"], &1}), complete: length(records) < count}}
  end

  @impl true
  def update_subscription(
        "inbox.recent",
        actor,
        parameters,
        %View{} = view,
        %{
          "project_id" => project,
          "subject_id" => subject,
          "record" => record,
          "previous_version" => previous
        } = change
      )
      when project == actor.project_id and subject == actor.subject_id do
    old = Map.get(view.records, record["id"])
    reserved = get_in(view.context, [:reserve, record["id"]])

    cond do
      change["kind"] == "inbox.update" and is_map(old) and old["version"] == previous and
        old["inserted_at"] == record["inserted_at"] and old["archived"] == record["archived"] ->
        {:replace, record["id"], record}

      change["kind"] == "inbox.update" and is_map(reserved) and reserved["version"] == previous and
        reserved["inserted_at"] == record["inserted_at"] and
          reserved["archived"] == record["archived"] ->
        {:context, put_in(view.context, [:reserve, record["id"]], record)}

      change["kind"] == "inbox.update" and old == nil and reserved == nil and
          below_window?(view, record, parameters) ->
        :unchanged

      true ->
        update_membership(actor, parameters, view, change, old || reserved)
    end
  end

  def update_subscription(_name, _actor, _parameters, _records, _change), do: :reload

  defp below_window?(view, record, parameters) do
    if length(view.order) == parameters["limit"] and is_binary(record["inserted_at"]) do
      reserve = Map.get(view.context, :reserve, %{})

      tail =
        if map_size(reserve) > 0,
          do: reserve |> Map.values() |> Enum.min_by(&{&1["inserted_at"], &1["id"]}),
          else: Map.fetch!(view.records, List.last(view.order))

      {record["inserted_at"], record["id"]} < {tail["inserted_at"], tail["id"]}
    else
      false
    end
  end

  defp update_membership(actor, parameters, view, change, old) do
    record = change["record"]
    identifier = record["id"]
    current = Repo.one(from(item in owned(actor), where: item.id == ^identifier))
    current = if current, do: serialize(current)

    valid =
      if change["kind"] == "inbox.delete",
        do: current == nil,
        else: current == record

    version_matches =
      if old,
        do: old["version"] == change["previous_version"],
        else: change["kind"] in ["inbox.add", "inbox.delete"]

    if valid and version_matches and Map.has_key?(view.context, :reserve) do
      records = view.records |> Map.merge(view.context.reserve) |> Map.delete(identifier)

      records =
        if current && (parameters["include_archived"] or not current["archived"]),
          do: Map.put(records, identifier, current),
          else: records

      ordered = records |> Map.values() |> Enum.sort_by(&{&1["inserted_at"], &1["id"]}, :desc)
      {data, reserve} = Enum.split(ordered, parameters["limit"])

      if not view.context.complete and length(reserve) == 0 do
        :reload
      else
        context = %{
          reserve: reserve |> Enum.take(@reserve_size) |> Map.new(&{&1["id"], &1}),
          complete: view.context.complete and length(reserve) <= @reserve_size
        }

        {:reset, data, context}
      end
    else
      :reload
    end
  end

  @impl true
  def scope(_name, actor, _parameters),
    do: "projects:#{actor.project_id}:subjects:#{actor.subject_id}:inbox"

  @impl true
  def execute("inbox.add", actor, input) do
    item =
      Repo.insert!(%InboxItem{
        project_id: actor.project_id,
        subject_id: actor.subject_id,
        text: input["text"],
        content_type: input["content_type"]
      })

    {:ok, serialize(item), [scope("inbox.recent", actor, %{})]}
  end

  def execute("inbox.update", actor, input), do: update_item(actor, input, text: input["text"])

  def execute("inbox.archive", actor, input),
    do: update_item(actor, input, archived: input["archived"])

  def execute("inbox.delete", actor, input) do
    query =
      from(item in owned(actor),
        where: item.id == ^input["id"] and item.version == ^input["expected_version"],
        select: item
      )

    case Repo.delete_all(query) do
      {1, [item]} ->
        {:ok, %{"id" => item.id, "deleted" => true}, [scope("inbox.recent", actor, %{})]}

      {0, []} ->
        missing_or_conflict(actor, input["id"])
    end
  end

  def execute("inbox.recent", actor, input) do
    records = actor |> visible(input) |> limit(^input["limit"]) |> Repo.all()
    {:ok, Enum.map(records, &serialize/1), []}
  end

  def execute("inbox.history", actor, input) do
    with {:ok, cursor} <- decode_cursor(input["cursor"]) do
      query = visible(actor, input)

      query =
        if cursor,
          do:
            from(item in query,
              where:
                item.inserted_at < ^cursor.time or
                  (item.inserted_at == ^cursor.time and item.id < ^cursor.id)
            ),
          else: query

      records = Repo.all(from(item in query, limit: ^(input["limit"] + 1)))
      page = Enum.take(records, input["limit"])

      next_cursor =
        if length(records) > input["limit"], do: encode_cursor(List.last(page)), else: nil

      {:ok, %{"items" => Enum.map(page, &serialize/1), "next_cursor" => next_cursor}, []}
    end
  end

  defp update_item(actor, input, fields) do
    query =
      from(item in owned(actor),
        where: item.id == ^input["id"] and item.version == ^input["expected_version"],
        select: item
      )

    case Repo.update_all(query,
           set: fields ++ [updated_at: Fyrlet.Auth.now()],
           inc: [version: 1]
         ) do
      {1, [item]} -> {:ok, serialize(item), [scope("inbox.recent", actor, %{})]}
      {0, []} -> missing_or_conflict(actor, input["id"])
    end
  end

  defp missing_or_conflict(actor, identifier) do
    if Repo.exists?(from(item in owned(actor), where: item.id == ^identifier)) do
      {:error, Error.new("CONFLICT", "The record was changed; refresh before retrying")}
    else
      {:error, Error.not_found()}
    end
  end

  defp owned(actor),
    do:
      from(item in InboxItem,
        where: item.project_id == ^actor.project_id and item.subject_id == ^actor.subject_id
      )

  defp visible(actor, input) do
    query = owned(actor)

    query =
      if input["include_archived"], do: query, else: from(item in query, where: not item.archived)

    from(item in query, order_by: [desc: item.inserted_at, desc: item.id])
  end

  defp serialize(item) do
    %{
      "id" => item.id,
      "text" => item.text,
      "content_type" => item.content_type,
      "archived" => item.archived,
      "version" => item.version,
      "inserted_at" => DateTime.to_iso8601(item.inserted_at),
      "updated_at" => DateTime.to_iso8601(item.updated_at)
    }
  end

  defp encode_cursor(item),
    do:
      Jason.encode!(%{"time" => DateTime.to_iso8601(item.inserted_at), "id" => item.id})
      |> Base.url_encode64(padding: false)

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(value) do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         {:ok, %{"time" => time, "id" => identifier}}
         when is_binary(time) and is_binary(identifier) <- Jason.decode(decoded),
         {:ok, timestamp, _offset} <- DateTime.from_iso8601(time),
         {:ok, uuid} <- Ecto.UUID.cast(identifier) do
      {:ok, %{time: timestamp, id: uuid}}
    else
      _invalid -> {:error, Error.new("VALIDATION_FAILED", "The history cursor is invalid")}
    end
  end
end
