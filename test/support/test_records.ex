defmodule Fyrlet.TestRecords do
  @moduledoc "Minimal persistent operations and indexed replacements for framework tests."
  @behaviour Fyrlet.Definition
  import Ecto.Query
  alias Fyrlet.{Auth, Error, Repo, Schema, TestRecord}

  @impl true
  def contract do
    identifier = %{"type" => "string", "format" => "uuid"}
    text = %{"type" => "string", "minLength" => 1, "maxLength" => 16_384}
    version = %{"type" => "integer", "minimum" => 1}
    content_type = %{"type" => "string", "enum" => ["text", "link", "code"]}

    properties = %{
      "id" => identifier,
      "text" => text,
      "content_type" => content_type,
      "version" => version,
      "inserted_at" => %{"type" => "string", "format" => "date-time"},
      "updated_at" => %{"type" => "string", "format" => "date-time"}
    }

    record = Schema.object(properties, Map.keys(properties))
    list = %{"type" => "array", "items" => record, "maxItems" => 100}

    parameters =
      Schema.object(%{
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100, "default" => 50}
      })

    operation = fn kind, input, output ->
      %{"kind" => kind, "input" => input, "output" => output}
    end

    %{
      "operations" => %{
        "records.add" =>
          operation.(
            "write",
            Schema.object(
              %{"text" => text, "content_type" => Map.put(content_type, "default", "text")},
              ["text"]
            ),
            record
          ),
        "records.update" =>
          operation.(
            "write",
            Schema.object(%{"id" => identifier, "text" => text, "expected_version" => version}, [
              "id",
              "text",
              "expected_version"
            ]),
            record
          ),
        "records.delete" =>
          operation.(
            "write",
            Schema.object(%{"id" => identifier, "expected_version" => version}, [
              "id",
              "expected_version"
            ]),
            Schema.object(%{"id" => identifier, "deleted" => %{"type" => "boolean"}}, [
              "id",
              "deleted"
            ])
          ),
        "records.list" =>
          operation.("read", parameters, Schema.object(%{"items" => list}, ["items"]))
      },
      "subscriptions" => %{
        "records.recent" => %{"input" => parameters, "output" => list, "shared" => true}
      }
    }
  end

  @impl true
  def authorize(_name, _actor, _input), do: :ok

  @impl true
  def scope(_name, actor, _input),
    do: "test:#{actor.project_id}:#{actor.subject_id}:records"

  @impl true
  def execute("records.add", actor, input) do
    record =
      Repo.insert!(%TestRecord{
        project_id: actor.project_id,
        subject_id: actor.subject_id,
        text: input["text"],
        content_type: input["content_type"]
      })

    {:ok, serialize(record), [scope("records.recent", actor, %{})]}
  end

  def execute(name, actor, input) when name in ["records.update", "records.delete"] do
    record =
      Repo.one(from(record in owned(actor), where: record.id == ^input["id"], lock: "FOR UPDATE"))

    cond do
      is_nil(record) ->
        {:error, Error.not_found()}

      record.version != input["expected_version"] ->
        {:error, Error.new("CONFLICT", "The record version changed")}

      name == "records.delete" ->
        Repo.delete!(record)
        {:ok, %{"id" => record.id, "deleted" => true}, [scope("records.recent", actor, %{})]}

      true ->
        updated =
          record
          |> Ecto.Changeset.change(
            text: input["text"],
            version: record.version + 1,
            updated_at: Auth.now()
          )
          |> Repo.update!()

        {:ok, serialize(updated), [scope("records.recent", actor, %{})]}
    end
  end

  def execute(name, actor, input) when name in ["records.list", "records.recent"] do
    records =
      Repo.all(
        from(record in owned(actor),
          order_by: [desc: record.inserted_at, desc: record.id],
          limit: ^input["limit"]
        )
      )
      |> Enum.map(&serialize/1)

    {:ok, if(name == "records.list", do: %{"items" => records}, else: records), []}
  end

  @impl true
  def change(name, actor, input, record) do
    %{
      "kind" => name,
      "project_id" => actor.project_id,
      "subject_id" => actor.subject_id,
      "record" => record,
      "previous_version" => input["expected_version"] || 0
    }
  end

  @impl true
  def update_subscription(_name, actor, _parameters, view, change) do
    record = change["record"]
    old = view.records[record["id"]]

    if change["kind"] == "records.update" and change["project_id"] == actor.project_id and
         change["subject_id"] == actor.subject_id and is_map(old) and
         old["version"] == change["previous_version"] and
         old["inserted_at"] == record["inserted_at"],
       do: {:replace, record["id"], record},
       else: :reload
  end

  defp owned(actor),
    do:
      from(record in TestRecord,
        where: record.project_id == ^actor.project_id and record.subject_id == ^actor.subject_id
      )

  defp serialize(record) do
    %{
      "id" => record.id,
      "text" => record.text,
      "content_type" => record.content_type,
      "version" => record.version,
      "inserted_at" => DateTime.to_iso8601(record.inserted_at),
      "updated_at" => DateTime.to_iso8601(record.updated_at)
    }
  end
end
