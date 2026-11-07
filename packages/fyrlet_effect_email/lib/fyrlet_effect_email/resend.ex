defmodule FyrletEffectEmail.Resend do
  @moduledoc """
  Resend email provider. Uses the effect's secret as the API key, a stable idempotency key
  (Resend retains keys for 24 hours), and GET /emails/:id for delivery reconciliation.
  Configure `FyrletEffectEmail` with `provider: FyrletEffectEmail.Resend`.
  `:resend_url`, `:timeout_ms`, and `:connect_timeout_ms` can be set on
  `:fyrlet_effect_email`; plain HTTP is refused unless `:allow_http` is explicitly true.
  """
  @behaviour FyrletEffectEmail.Provider

  @impl true
  def capabilities, do: %{"idempotency" => %{"window_seconds" => 86_400}, "queryable" => true}

  @impl true
  def deliver(message, context) do
    case request(:post, "/emails", message, context) do
      {:ok, status, %{"id" => id}} when status in 200..299 and is_binary(id) ->
        {:accepted, id}

      {:ok, 429, _body} ->
        {:transient, "resend rate limit"}

      {:ok, status, _body} when status in 400..499 and status != 408 ->
        {:rejected, "resend HTTP #{status}"}

      _other ->
        :unknown
    end
  end

  @impl true
  def status(id, context) do
    case request(:get, "/emails/" <> URI.encode(id, &URI.char_unreserved?/1), nil, context) do
      {:ok, 200, %{"last_event" => event}} when event in ["delivered", "opened", "clicked"] ->
        {:delivered, event}

      {:ok, 200, %{"last_event" => event}}
      when event in ["bounced", "failed", "canceled", "suppressed"] ->
        {:bounced, event}

      {:ok, 200, %{"last_event" => event}}
      when event in ["sent", "queued", "scheduled", "delivery_delayed"] ->
        :pending

      {:ok, 404, _body} ->
        :not_found

      _other ->
        :unknown
    end
  end

  defp request(method, path, body, %{secret: secret} = context)
       when is_binary(secret) and secret != "" do
    base = Application.get_env(:fyrlet_effect_email, :resend_url, "https://api.resend.com")
    uri = URI.parse(base)

    if uri.scheme == "https" or
         (uri.scheme == "http" and Application.get_env(:fyrlet_effect_email, :allow_http, false)) do
      headers = [
        {~c"authorization", String.to_charlist("Bearer " <> secret)},
        {~c"idempotency-key", String.to_charlist(context.idempotency_key)}
      ]

      url = String.to_charlist(String.trim_trailing(base, "/") <> path)

      request =
        if method == :get,
          do: {url, headers},
          else: {url, headers, ~c"application/json", Jason.encode!(body)}

      options = [
        timeout: Application.get_env(:fyrlet_effect_email, :timeout_ms, 10_000),
        connect_timeout: Application.get_env(:fyrlet_effect_email, :connect_timeout_ms, 3_000),
        autoredirect: false,
        ssl: [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          server_name_indication: String.to_charlist(uri.host)
        ]
      ]

      case :httpc.request(method, request, options, body_format: :binary) do
        {:ok, {{_, status, _}, _headers, response}} ->
          case Jason.decode(response) do
            {:ok, decoded} -> {:ok, status, decoded}
            _invalid -> :unknown
          end

        _error ->
          :unknown
      end
    else
      :unknown
    end
  end

  defp request(_method, _path, _body, _context), do: :unknown
end
