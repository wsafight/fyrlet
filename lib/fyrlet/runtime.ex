defmodule Fyrlet.Runtime do
  import Ecto.Query
  require Logger
  alias Fyrlet.{Auth, CommittedChange, Error, Idempotency, Registry, Repo, Schema, View}

  def call(actor, name, input, idempotency_key \\ nil) do
    started = System.monotonic_time()

    result =
      safely(fn ->
        with {:ok, module, specification} <- Registry.fetch("operations", name),
             {:ok, normalized} <- Schema.validate(specification["input"], input) do
          if specification["kind"] == "write" do
            write(actor, module, name, normalized, specification, idempotency_key)
          else
            with {:ok, current_actor} <- Auth.revalidate(actor),
                 :ok <- module.authorize(name, current_actor, normalized),
                 {:ok, data, _scopes} <- module.execute(name, current_actor, normalized),
                 {:ok, checked} <- validate_output(specification["output"], data),
                 {:ok, _actor} <- Auth.revalidate(current_actor) do
              {:ok, checked}
            end
          end
        end
      end)

    :telemetry.execute(
      [:fyrlet, :operation, :stop],
      %{duration: System.monotonic_time() - started},
      %{name: name, result: elem(result, 0)}
    )

    result
  end

  def prepare_subscription(actor, name, parameters) do
    safely(fn ->
      with {:ok, module, specification} <- Registry.fetch("subscriptions", name),
           {:ok, normalized} <- Schema.validate(specification["input"], parameters),
           {:ok, current_actor} <- Auth.revalidate(actor),
           :ok <- module.authorize(name, current_actor, normalized) do
        {:ok,
         %{
           module: module,
           name: name,
           parameters: normalized,
           specification: specification,
           scope: module.scope(name, current_actor, normalized)
         }}
      end
    end)
  end

  # Full, non-incremental result of a subscription. Production delivery goes through
  # Observer and view/4; this is the reference the incremental tests compare against.
  def snapshot(actor, subscription) do
    with {:ok, view} <- view(actor, subscription), do: {:ok, View.data(view)}
  end

  def view(actor, subscription, previous \\ nil, change \\ nil) do
    safely(fn ->
      started = System.monotonic_time()

      result =
        with {:ok, current_actor} <- Auth.revalidate(actor),
             :ok <-
               subscription.module.authorize(
                 subscription.name,
                 current_actor,
                 subscription.parameters
               ),
             {:ok, snapshot} <-
               subscription_view(current_actor, subscription, previous, change),
             {:ok, _actor} <- Auth.revalidate(current_actor) do
          if snapshot.bytes <= Application.fetch_env!(:fyrlet, :max_snapshot_bytes) do
            {:ok, snapshot}
          else
            {:error, Error.new("LIMIT_EXCEEDED", "The snapshot exceeds the response size limit")}
          end
        end

      :telemetry.execute(
        [:fyrlet, :subscription, :query],
        %{duration: System.monotonic_time() - started},
        %{name: subscription.name, result: elem(result, 0)}
      )

      result
    end)
  end

  defp write(actor, module, name, input, specification, key) do
    if not is_binary(key) or byte_size(key) not in 1..200 do
      {:error,
       Error.new("VALIDATION_FAILED", "A write requires an Idempotency-Key of 1 to 200 bytes")}
    else
      nested = Repo.in_transaction?()

      result =
        Repo.transaction(fn ->
          current_actor = unwrap!(Auth.revalidate(actor, true))
          unwrap_authorization!(module.authorize(name, current_actor, input))
          lock_key = Enum.join([actor.project_id, actor.subject_id, name, key], ":")
          Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [lock_key])
          input_hash = Auth.hash(IO.iodata_to_binary(canonical(input)))

          query =
            from(result in Idempotency,
              where:
                result.project_id == ^actor.project_id and result.subject_id == ^actor.subject_id and
                  result.operation == ^name and result.key == ^key
            )

          case Repo.one(query) do
            %Idempotency{} = cached ->
              if DateTime.compare(cached.expires_at, Auth.now()) != :gt do
                Repo.delete!(cached)

                execute_write(
                  module,
                  name,
                  current_actor,
                  input,
                  specification,
                  key,
                  input_hash,
                  nested
                )
              else
                if cached.input_hash == input_hash,
                  do: {cached.result["data"], nil},
                  else:
                    Repo.rollback(
                      Error.new("CONFLICT", "The idempotency key was used with different input")
                    )
              end

            nil ->
              execute_write(
                module,
                name,
                current_actor,
                input,
                specification,
                key,
                input_hash,
                nested
              )
          end
        end)

      case result do
        {:ok, {data, job}} ->
          if job && not nested, do: notify_after_commit(job)
          {:ok, data}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp execute_write(module, name, actor, input, specification, key, input_hash, nested) do
    {data, scopes} =
      case module.execute(name, actor, input) do
        {:ok, data, scopes} -> {data, scopes}
        {:error, error} -> Repo.rollback(error)
      end

    checked = unwrap!(validate_output(specification["output"], data))

    Repo.insert!(%Idempotency{
      project_id: actor.project_id,
      subject_id: actor.subject_id,
      operation: name,
      key: key,
      input_hash: input_hash,
      result: %{"data" => checked},
      expires_at:
        DateTime.add(Auth.now(), Application.fetch_env!(:fyrlet, :idempotency_ttl), :second)
    })

    job =
      if scopes != [] do
        %{"scopes" => Enum.uniq(scopes), "project_id" => actor.project_id}
        |> Fyrlet.InvalidationWorker.new(fallback_options(nested))
        |> Oban.insert()
        |> unwrap!()
      end

    change =
      if function_exported?(module, :change, 4),
        do: module.change(name, actor, input, checked)

    change =
      if not is_nil(change) do
        %CommittedChange{
          change: change,
          output: checked,
          schema: specification["output"],
          bytes: byte_size(Jason.encode!(checked))
        }
      end

    {checked, if(job, do: {job, change})}
  end

  # Outside a caller transaction the immediate broadcast is the primary path, so the
  # durable job only needs to run if it failed. Delaying it lets Oban stage jobs in
  # batches instead of fetching one per write; nested writes keep it immediate.
  defp fallback_options(true), do: []

  defp fallback_options(false) do
    case Application.fetch_env!(:fyrlet, :invalidation_fallback_delay) do
      seconds when is_integer(seconds) and seconds > 0 -> [schedule_in: seconds]
      _immediate -> []
    end
  end

  defp notify_after_commit({job, change}) do
    Fyrlet.InvalidationWorker.broadcast(job, change)
  rescue
    _error -> Logger.warning("Immediate invalidation failed; the durable job will retry")
  catch
    _kind, _reason ->
      Logger.warning("Immediate invalidation failed; the durable job will retry")
  end

  defp subscription_view(actor, subscription, previous, change) do
    updated =
      if match?(%View{records: records} when is_map(records), previous) and not is_nil(change) and
           function_exported?(subscription.module, :update_subscription, 5) do
        subscription.module.update_subscription(
          subscription.name,
          actor,
          subscription.parameters,
          previous,
          change_body(change)
        )
      else
        :reload
      end

    schema = subscription.specification["output"]

    case updated do
      {:replace, identifier, record} when is_binary(identifier) ->
        if schema["type"] == "array" and Map.has_key?(previous.records, identifier) and
             is_map(record) and record["id"] == identifier do
          with {:ok, checked, record_bytes} <-
                 validate_replacement(schema["items"], record, change) do
            {:ok, View.replace(previous, identifier, checked, record_bytes)}
          end
        else
          {:error, Error.new("INTERNAL_ERROR", "Invalid subscription replacement")}
        end

      {:reset, data, context} ->
        with {:ok, checked} <- validate_output(schema, data) do
          {:ok, View.reset(previous, checked, context)}
        end

      {:context, context} ->
        {:ok, %{previous | context: context, patch: %{}, unchanged: true}}

      :unchanged ->
        {:ok, %{previous | patch: %{}, unchanged: true}}

      :reload ->
        with {:ok, data, context} <- load_subscription(actor, subscription),
             {:ok, checked} <- validate_output(schema, data) do
          {:ok, View.reset(previous, checked, context)}
        end
    end
  end

  defp load_subscription(actor, subscription) do
    if function_exported?(subscription.module, :load_subscription, 3) do
      subscription.module.load_subscription(subscription.name, actor, subscription.parameters)
    else
      with {:ok, data, _scopes} <-
             subscription.module.execute(subscription.name, actor, subscription.parameters),
           do: {:ok, data, %{}}
    end
  end

  defp change_body(%CommittedChange{change: change}), do: change
  defp change_body(change), do: change

  defp validate_replacement(schema, record, %CommittedChange{
         schema: schema,
         output: record,
         bytes: bytes
       }),
       do: {:ok, record, bytes}

  defp validate_replacement(schema, record, _change) do
    with {:ok, checked} <- validate_output(schema, record),
         do: {:ok, checked, byte_size(Jason.encode!(checked))}
  end

  defp validate_output(schema, data) do
    case Schema.validate(schema, data) do
      {:ok, checked} ->
        {:ok, checked}

      {:error, _error} ->
        {:error, Error.new("INTERNAL_ERROR", "The operation returned an invalid response")}
    end
  end

  defp safely(callback) do
    callback.()
  rescue
    error ->
      Logger.error("Business execution failed: #{inspect(error.__struct__)}")
      {:error, Error.new("INTERNAL_ERROR", "The operation could not be completed")}
  end

  defp canonical(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, entry} -> [Jason.encode!(key), ":", canonical(entry)] end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end

  defp canonical(value) when is_list(value),
    do: ["[", Enum.intersperse(Enum.map(value, &canonical/1), ","), "]"]

  defp canonical(value), do: Jason.encode!(value)
  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, error}), do: Repo.rollback(error)
  defp unwrap_authorization!(:ok), do: :ok
  defp unwrap_authorization!({:error, error}), do: Repo.rollback(error)
end
