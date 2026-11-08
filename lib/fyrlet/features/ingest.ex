defmodule Fyrlet.Features.Ingest do
  @moduledoc """
  Batch ingestion (temp spec §7.1, `fyrlet_ingest`).

  A definition declares an `ingest` operation and implements `ingest/3`:

      "events.ingest" => Fyrlet.Features.Ingest.operation(item_schema, max_items: 100)

      def ingest("events.ingest", actor, data), do: :ok | {:error, %Fyrlet.Error{}}

  Delivery semantics, stated once:

    * **Acceptance is durable.** `submit/5` returns after the items are stored; processing
      follows asynchronously and is retried until it succeeds or the item is dead.
    * **Per-item errors.** Each item has its own result. By default valid items are accepted
      even when others are not; with `"atomic" => true` one invalid item rejects the whole batch.
    * **De-duplication.** An item's `key` is unique per subject and operation. Sending a batch
      again is harmless: a repeated key reports `duplicate` with the item's current state, and
      the same key with different data is a `conflict` for that item.
    * **Back-pressure.** Too many unprocessed items for the project makes `submit/5` refuse with
      a retryable `LIMIT_EXCEEDED`; nothing from that request is stored.
    * **Exactly-once for database effects.** `ingest/3` runs inside the transaction that marks
      the item done, so its database writes and the item's completion commit together or not at
      all. External side effects do not belong here - use a run with an effect.
  """
  import Ecto.Query
  alias Fyrlet.{Auth, Error, Repo, Schema}
  alias Fyrlet.Runs.{Limits, Plan}

  defmodule Batch do
    use Ecto.Schema
    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id
    schema "fyrlet_ingest_batches" do
      field(:project_id, :binary_id)
      field(:subject_id, :binary_id)
      field(:operation, :string)
      field(:atomic, :boolean, default: false)
      field(:total, :integer)
      timestamps(type: :utc_datetime_usec)
    end
  end

  defmodule Item do
    use Ecto.Schema
    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id
    schema "fyrlet_ingest_items" do
      field(:batch_id, :binary_id)
      field(:project_id, :binary_id)
      field(:subject_id, :binary_id)
      field(:operation, :string)
      field(:seq, :integer)
      field(:item_key, :string)
      field(:payload_hash, :binary)
      field(:payload, Fyrlet.EncryptedMap)
      field(:status, :string)
      field(:attempts, :integer, default: 0)
      field(:error, :map)
      field(:processed_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end
  end

  @prune_batch 5_000

  @doc """
  Deletes finished items (and batches left empty) once they are older than their project's
  retention (`Fyrlet.Retention`, key `ingest_seconds`). Pending items are never deleted.
  Returns the number of items and batches removed.
  """
  def prune(now \\ Auth.now()) do
    overrides = Fyrlet.Retention.overrides(:ingest_seconds)

    explicit =
      for {project_id, seconds} <- overrides, is_integer(seconds), reduce: {0, 0} do
        acc ->
          add(acc, prune_where(dynamic([x], x.project_id == ^project_id), cutoff(now, seconds)))
      end

    case Fyrlet.Retention.default(:ingest_seconds) do
      seconds when is_integer(seconds) ->
        others = Map.keys(overrides)

        add(
          explicit,
          prune_where(dynamic([x], x.project_id not in ^others), cutoff(now, seconds))
        )

      _keep_forever ->
        explicit
    end
  end

  defp cutoff(now, seconds), do: DateTime.add(now, -seconds, :second)
  defp add({a, b}, {c, d}), do: {a + c, b + d}

  defp prune_where(condition, cutoff) do
    items =
      from(i in Item,
        where: ^condition,
        where: i.status != "pending" and i.processed_at < ^cutoff,
        select: i.id,
        limit: ^Fyrlet.Pruning.batch_size(@prune_batch)
      )

    {item_count, _rows} =
      Fyrlet.Pruning.delete_all(from(i in Item, where: i.id in subquery(items)))

    batches =
      from(b in Batch,
        as: :batch,
        where: ^condition,
        where: b.inserted_at < ^cutoff,
        where: not exists(from(i in Item, where: i.batch_id == parent_as(:batch).id)),
        select: b.id,
        limit: ^Fyrlet.Pruning.batch_size(@prune_batch)
      )

    {batch_count, _rows} =
      Fyrlet.Pruning.delete_all(from(b in Batch, where: b.id in subquery(batches)))

    if (item_count == @prune_batch or batch_count == @prune_batch) and Fyrlet.Pruning.available?(),
      do: add({item_count, batch_count}, prune_where(condition, cutoff)),
      else: {item_count, batch_count}
  end

  defmodule Worker do
    @moduledoc false
    use Oban.Worker, queue: :fyrlet, max_attempts: 3

    @impl true
    def perform(%Oban.Job{args: %{"batch_id" => batch_id}}) do
      Fyrlet.Features.Ingest.process(batch_id)
      :ok
    end
  end

  @key ~r/^[\x21-\x7e]{1,200}$/
  @max_attempts 5

  @doc "Builds an `ingest` operation specification for items shaped like `item_schema`."
  def operation(item_schema, options \\ []) do
    max = Keyword.get(options, :max_items, 100)

    item =
      Schema.object(
        %{
          "key" => %{"type" => "string", "minLength" => 1, "maxLength" => 200},
          "data" => item_schema
        },
        [
          "key",
          "data"
        ]
      )

    %{
      "kind" => "ingest",
      "input" =>
        Schema.object(
          %{
            "items" => %{"type" => "array", "items" => item, "maxItems" => min(max, 100)},
            "atomic" => %{"type" => "boolean"}
          },
          ["items"]
        ),
      "output" => result_schema(),
      "item_schema" => item_schema,
      "max_items" => min(max, 100)
    }
  end

  def result_schema do
    result =
      Schema.object(
        %{
          "index" => %{"type" => "integer", "minimum" => 0},
          "key" => %{"type" => "string"},
          "status" => %{"type" => "string"},
          "error" => %{"anyOf" => [%{"type" => "string"}, %{"type" => "null"}]}
        },
        ~w(index key status error)
      )

    Schema.object(
      %{
        "batch_id" => %{
          "anyOf" => [%{"type" => "string", "format" => "uuid"}, %{"type" => "null"}]
        },
        "accepted" => %{"type" => "integer", "minimum" => 0},
        "results" => %{"type" => "array", "items" => result, "maxItems" => 100}
      },
      ~w(batch_id accepted results)
    )
  end

  # ---- accepting ----------------------------------------------------------------------

  @doc "Validates and durably stores a batch. Returns `{:ok, result}` or `{:error, error}`."
  def submit(actor, name, input, specification, module) do
    with {:ok, items, atomic} <- envelope(input, specification) do
      checked = items |> Enum.with_index() |> Enum.map(&check(&1, specification, name))
      decide(actor, name, module, atomic, checked)
    end
  end

  defp envelope(%{"items" => items} = input, specification) when is_list(items) do
    max = specification["max_items"] || 100

    cond do
      items == [] ->
        {:error, Error.new("VALIDATION_FAILED", "A batch needs at least one item")}

      length(items) > max ->
        {:error, Error.new("VALIDATION_FAILED", "A batch may hold at most #{max} items")}

      Map.get(input, "atomic", false) not in [true, false] ->
        {:error, Error.new("VALIDATION_FAILED", "atomic must be a boolean")}

      true ->
        {:ok, items, input["atomic"] == true}
    end
  end

  defp envelope(_input, _specification),
    do: {:error, Error.new("VALIDATION_FAILED", "A batch needs a list of items")}

  defp decide(actor, name, module, atomic, checked) do
    cond do
      atomic and Enum.any?(checked, &match?({:invalid, _, _}, &1)) ->
        {:error,
         Error.new("VALIDATION_FAILED", "The batch was rejected because an item is invalid", %{
           "items" => report(checked)
         })}

      true ->
        store(actor, name, module, atomic, checked)
    end
  end

  defp check({%{"key" => key, "data" => data}, index}, specification, _name)
       when is_binary(key) do
    cond do
      not Regex.match?(@key, key) ->
        {:invalid, index, {key, "invalid key"}}

      true ->
        with {:ok, checked} <- Schema.validate(specification["item_schema"], data),
             {:ok, payload} <- Plan.payload(checked, "item") do
          {:ok, index, key, payload}
        else
          {:error, %Error{message: message}} -> {:invalid, index, {key, message}}
        end
    end
  end

  defp check({_malformed, index}, _specification, _name),
    do: {:invalid, index, {"", "an item needs a string key and data"}}

  defp report(checked) do
    for entry <- checked do
      case entry do
        {:invalid, index, {key, message}} ->
          %{"index" => index, "key" => key, "status" => "invalid", "error" => message}

        {:ok, index, key, _payload} ->
          %{"index" => index, "key" => key, "status" => "valid", "error" => nil}
      end
    end
  end

  defp store(actor, name, _module, atomic, checked) do
    valid = for {:ok, _, _, _} = entry <- checked, do: entry

    Repo.transaction(fn ->
      lock(actor.project_id)
      room!(actor.project_id, length(valid))

      batch =
        Repo.insert!(%Batch{
          project_id: actor.project_id,
          subject_id: actor.subject_id,
          operation: name,
          atomic: atomic,
          total: length(checked)
        })

      results = Enum.map(checked, &accept(&1, batch, actor, name))
      accepted = Enum.count(results, &(&1["status"] == "accepted"))

      if accepted > 0 do
        Oban.insert!(Worker.new(%{"batch_id" => batch.id}))
      end

      %{"batch_id" => batch.id, "accepted" => accepted, "results" => results}
    end)
  end

  defp accept({:invalid, index, {key, message}}, _batch, _actor, _name),
    do: %{"index" => index, "key" => key, "status" => "invalid", "error" => message}

  defp accept({:ok, index, key, payload}, batch, actor, name) do
    hash = Auth.hash(Jason.encode!(payload))

    case Repo.get_by(Item,
           project_id: actor.project_id,
           subject_id: actor.subject_id,
           operation: name,
           item_key: key
         ) do
      %Item{payload_hash: ^hash} = existing ->
        %{
          "index" => index,
          "key" => key,
          "status" => "duplicate",
          "error" => nil,
          "state" => existing.status
        }
        |> Map.delete("state")
        |> Map.put("status", "duplicate:" <> existing.status)

      %Item{} ->
        %{
          "index" => index,
          "key" => key,
          "status" => "conflict",
          "error" => "key already used with different data"
        }

      nil ->
        Repo.insert!(%Item{
          batch_id: batch.id,
          project_id: actor.project_id,
          subject_id: actor.subject_id,
          operation: name,
          seq: index,
          item_key: key,
          payload_hash: hash,
          payload: payload,
          status: "pending"
        })

        %{"index" => index, "key" => key, "status" => "accepted", "error" => nil}
    end
  end

  defp lock(project_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", ["ingest:" <> project_id])
  end

  defp room!(project_id, incoming) do
    pending =
      Repo.aggregate(
        from(i in Item, where: i.project_id == ^project_id and i.status == "pending"),
        :count
      )

    if pending + incoming > Limits.get(:ingest_max_pending),
      do:
        Repo.rollback(
          Error.new(
            "LIMIT_EXCEEDED",
            "Too many items are waiting to be processed; retry later",
            %{},
            true
          )
        )
  end

  # ---- processing ---------------------------------------------------------------------

  @doc "Processes the pending items of a batch. Each item is its own transaction."
  def process(batch_id) do
    ids =
      Repo.all(
        from(i in Item,
          where: i.batch_id == ^batch_id and i.status == "pending",
          order_by: i.seq,
          select: i.id
        )
      )

    results = Enum.map(ids, &process_item/1)

    if Enum.any?(results, &(&1 == :retry)) do
      Repo.transaction(fn ->
        Oban.insert!(Worker.new(%{"batch_id" => batch_id}, schedule_in: 5))
      end)
    end

    :ok
  end

  defp process_item(id) do
    outcome =
      Repo.transaction(fn ->
        case Repo.one(
               from(i in Item,
                 where: i.id == ^id and i.status == "pending",
                 lock: "FOR UPDATE SKIP LOCKED"
               )
             ) do
          nil ->
            :skipped

          item ->
            {:ok, module, _spec} = Fyrlet.Registry.fetch("operations", item.operation)

            actor = %Fyrlet.Actor{
              project_id: item.project_id,
              subject_id: item.subject_id,
              session_id: "ingest",
              expires_at: Auth.now()
            }

            case module.ingest(item.operation, actor, item.payload) do
              :ok ->
                Repo.update_all(from(i in Item, where: i.id == ^id),
                  set: [status: "done", processed_at: Auth.now(), attempts: item.attempts + 1]
                )

                :done

              {:error, %Error{} = error} ->
                Repo.rollback({:failed, error})
            end
        end
      end)

    case outcome do
      {:ok, result} -> result
      {:error, {:failed, error}} -> record_failure(id, error)
      {:error, _other} -> :retry
    end
  rescue
    exception ->
      require Logger
      Logger.error("Ingest handler raised #{inspect(exception.__struct__)}")
      record_failure(id, Error.new("INGEST_CRASHED", "The handler raised", %{}, true))
  end

  defp record_failure(id, error) do
    item = Repo.get!(Item, id)
    attempts = item.attempts + 1
    final = not error.retryable or attempts >= @max_attempts

    Repo.update_all(from(i in Item, where: i.id == ^id),
      set: [
        status: if(final, do: "dead", else: "pending"),
        attempts: attempts,
        error: Error.to_map(error),
        processed_at: if(final, do: Auth.now())
      ]
    )

    if final, do: :dead, else: :retry
  end

  # ---- reading ------------------------------------------------------------------------

  def batch(actor, batch_id) do
    with {:ok, _} <- Ecto.UUID.cast(batch_id),
         %Batch{project_id: project, subject_id: subject} = batch
         when project == actor.project_id and subject == actor.subject_id <-
           Repo.get(Batch, batch_id) do
      items =
        Repo.all(from(i in Item, where: i.batch_id == ^batch.id, order_by: i.seq, limit: 100))

      {:ok,
       %{
         "batch_id" => batch.id,
         "total" => batch.total,
         "items" =>
           for i <- items do
             %{
               "index" => i.seq,
               "key" => i.item_key,
               "status" => i.status,
               "attempts" => i.attempts,
               "error" => i.error && i.error["code"]
             }
           end
       }}
    else
      _other -> {:error, Error.not_found()}
    end
  end

  @doc "Puts items that were in flight when a node died back in the queue (they never committed)."
  def recover(_now), do: 0
end
