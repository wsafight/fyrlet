defmodule Fyrlet.Runtime do
  import Ecto.Query
  require Logger
  alias Fyrlet.{Auth, Error, Idempotency, Registry, Repo, Schema}

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

  def snapshot(actor, subscription) do
    with {:ok, snapshot} <- snapshot_with_metadata(actor, subscription) do
      {:ok, snapshot.data}
    end
  end

  def snapshot_with_metadata(actor, subscription) do
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
             {:ok, data, _scopes} <-
               subscription.module.execute(
                 subscription.name,
                 current_actor,
                 subscription.parameters
               ),
             {:ok, checked} <- validate_output(subscription.specification["output"], data),
             {:ok, _actor} <- Auth.revalidate(current_actor) do
          encoded = Jason.encode!(checked)
          bytes = byte_size(encoded)

          if bytes <= Application.fetch_env!(:fyrlet, :max_snapshot_bytes) do
            {:ok, %{data: checked, bytes: bytes, fingerprint: :crypto.hash(:sha256, encoded)}}
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
                execute_write(module, name, current_actor, input, specification, key, input_hash)
              else
                if cached.input_hash == input_hash,
                  do: {cached.result["data"], nil},
                  else:
                    Repo.rollback(
                      Error.new("CONFLICT", "The idempotency key was used with different input")
                    )
              end

            nil ->
              execute_write(module, name, current_actor, input, specification, key, input_hash)
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

  defp execute_write(module, name, actor, input, specification, key, input_hash) do
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
        |> Fyrlet.InvalidationWorker.new()
        |> Oban.insert()
        |> unwrap!()
      end

    {checked, job}
  end

  defp notify_after_commit(job) do
    Fyrlet.InvalidationWorker.broadcast(job)
  rescue
    _error -> Logger.warning("Immediate invalidation failed; the durable job will retry")
  catch
    _kind, _reason ->
      Logger.warning("Immediate invalidation failed; the durable job will retry")
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
