defmodule FyrletWebhooks.Receiver do
  @moduledoc """
  Verifies and delivers one inbound webhook.

  A source is configured explicitly:

      config :fyrlet_webhooks, sources: %{
        "billing" => %{project_id: "...", secret: "...", handler: MyApp.BillingWebhook}
      }

  A request must carry `x-fyrlet-signature: t=<unix seconds>,v1=<hex hmac>`, where the hmac is
  `HMAC-SHA256(secret, "<t>.<raw body>")`. It is accepted only inside the tolerance window, and
  each `event_id` is accepted once per source, durably. The handler turns the verified payload
  into a signal for one wait node:

      def translate(payload), do: {:ok, %{event_id: ..., run_id: ..., wait_id: ..., name: ..., payload: %{...}}}

  This is a restricted principal: it can deliver a signal to a run of its own project and
  nothing else. It is fail-closed: an unknown source, a missing or blank secret, a bad or
  stale signature all refuse the request and nothing runs.
  """
  import Ecto.Query
  alias Fyrlet.{Auth, Error, Repo}

  defmodule Event do
    use Ecto.Schema
    @primary_key {:id, :binary_id, autogenerate: true}
    @foreign_key_type :binary_id
    schema "webhooks_events" do
      field(:project_id, :binary_id)
      field(:source, :string)
      field(:event_id, :string)
      field(:outcome, :string)
      field(:received_at, :utc_datetime_usec)
    end
  end

  @tolerance 300

  @doc "Sign a body the way a sender must. Used by tests and by senders written with Fyrlet."
  def sign(secret, timestamp, body) do
    mac = :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{body}")
    "t=#{timestamp},v1=" <> Base.encode16(mac, case: :lower)
  end

  def receive_event(source, signature_header, raw_body) do
    with {:ok, config} <- source(source),
         :ok <- verify(config.secret, signature_header, raw_body),
         {:ok, payload} <- decode(raw_body),
         {:ok, signal} <- translate(config, payload),
         {:ok, receipt} <- deliver(source, config, signal) do
      {:ok, receipt}
    end
  end

  defp source(name) do
    with %{project_id: project, secret: secret, handler: handler} = config
         when is_binary(project) and is_binary(secret) and byte_size(secret) >= 16 and
                is_atom(handler) <-
           Application.get_env(:fyrlet_webhooks, :sources, %{})[name] do
      {:ok, config}
    else
      _unconfigured -> {:error, Error.not_found()}
    end
  end

  defp verify(secret, header, body) when is_binary(header) and is_binary(body) do
    with %{"t" => t, "v1" => given} <- parse(header),
         {timestamp, ""} <- Integer.parse(t),
         true <- abs(System.os_time(:second) - timestamp) <= tolerance(),
         expected = sign(secret, timestamp, body),
         true <- Plug.Crypto.secure_compare(expected, "t=#{t},v1=#{given}") do
      :ok
    else
      _invalid -> {:error, Error.unauthorized()}
    end
  end

  defp verify(_secret, _header, _body), do: {:error, Error.unauthorized()}

  defp parse(header) do
    header
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn part ->
      case String.split(part, "=", parts: 2) do
        [k, v] -> [{String.trim(k), String.trim(v)}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp tolerance, do: Application.get_env(:fyrlet_webhooks, :tolerance_seconds, @tolerance)

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = payload} -> {:ok, payload}
      _other -> {:error, Error.new("VALIDATION_FAILED", "The webhook body must be a JSON object")}
    end
  end

  defp translate(config, payload) do
    case config.handler.translate(payload) do
      {:ok, %{event_id: event_id, run_id: run_id, wait_id: wait_id, name: name} = signal}
      when is_binary(event_id) and byte_size(event_id) in 1..200 and is_binary(run_id) and
             is_binary(wait_id) and is_binary(name) ->
        {:ok, Map.put_new(signal, :payload, %{})}

      {:error, %Error{} = error} ->
        {:error, error}

      _other ->
        {:error, Error.new("VALIDATION_FAILED", "The webhook could not be translated")}
    end
  end

  # Each event is accepted once, durably. The record and the signal commit together, so an
  # event that fails to become a signal can be sent again.
  defp deliver(source, config, signal) do
    Fyrlet.Transaction.run(fn ->
      case Repo.get_by(Event,
             project_id: config.project_id,
             source: source,
             event_id: signal.event_id
           ) do
        %Event{outcome: outcome} ->
          {:ok, %{"status" => "duplicate", "outcome" => outcome}}

        nil ->
          case Fyrlet.Runs.signal_from_integration(config.project_id, signal.run_id, %{
                 "wait_id" => signal.wait_id,
                 "name" => signal.name,
                 "payload" => signal.payload,
                 "idempotency_key" => "webhook:" <> source <> ":" <> signal.event_id
               }) do
            {:ok, receipt} ->
              Repo.insert!(%Event{
                project_id: config.project_id,
                source: source,
                event_id: signal.event_id,
                outcome: receipt["status"],
                received_at: Auth.now()
              })

              {:ok, %{"status" => "accepted", "outcome" => receipt["status"]}}

            {:error, error} ->
              Repo.rollback(error)
          end
      end
    end)
  end

  @doc "Removes dedupe records older than `before`."
  def prune(before), do: Repo.delete_all(from(e in Event, where: e.received_at < ^before))
end
