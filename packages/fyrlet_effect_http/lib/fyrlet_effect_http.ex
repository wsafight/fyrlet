defmodule FyrletEffectHTTP do
  @moduledoc """
  Delivers an effect as an HTTP POST. Register it with `config :fyrlet, effect_adapters: %{"http" => FyrletEffectHTTP}`.

  Payload: `%{"url" => ..., "body" => map, "headers" => map}` (headers optional).

  Safety: only hosts listed in `config :fyrlet_effect_http, allowed_hosts: [...]` are
  contacted, over https unless `allow_http: true`; redirects are not followed; the
  credential is looked up by the effect's `secret_ref` in `effect_secrets` and never stored
  in the effect or logged. The effect's `operation_id` is sent as `Idempotency-Key`.

  Outcome mapping (what the framework may do next depends on it):

    * 2xx - succeeded; 202 - accepted (the receiver will confirm by receipt);
    * 4xx other than 408/429 - failed (the receiver refused it);
    * connection refused, 429, 503 - retryable (the request did not take effect);
    * timeout, 408, 5xx, anything else - unknown (it may have been processed).

  The receiver is declared to honour `Idempotency-Key` for `idempotency_window_seconds`
  (default 24 h); only declare that when it is true of the target.
  """
  @behaviour Fyrlet.Effects.Adapter

  @impl true
  def capabilities do
    %{
      "idempotency" => %{"window_seconds" => setting(:idempotency_window_seconds, 86_400)},
      "queryable" => false,
      "cancellable" => false,
      "acceptance" => "provider_accepted",
      "version" => "1"
    }
  end

  @impl true
  def dispatch(%{payload: payload} = effect) do
    with {:ok, uri} <- target(payload["url"]),
         {:ok, body} <- Jason.encode(payload["body"] || %{}) do
      request(uri, body, headers(effect, payload))
    else
      _invalid -> {:failed, "invalid or disallowed target"}
    end
  end

  defp target(url) when is_binary(url) do
    uri = URI.parse(url)
    allowed = setting(:allowed_hosts, [])

    cond do
      uri.host not in allowed -> :error
      uri.scheme == "https" -> {:ok, uri}
      uri.scheme == "http" and setting(:allow_http, false) -> {:ok, uri}
      true -> :error
    end
  end

  defp target(_url), do: :error

  defp headers(effect, payload) do
    secret = Application.get_env(:fyrlet, :effect_secrets, %{})[effect.secret_ref]

    extra =
      for {name, value} <- payload["headers"] || %{},
          is_binary(name) and is_binary(value),
          String.downcase(name) not in ["authorization", "idempotency-key", "host"],
          do: {String.to_charlist(name), String.to_charlist(value)}

    base = [{~c"idempotency-key", String.to_charlist(effect.operation_id)}]
    auth = if secret, do: [{~c"authorization", String.to_charlist("Bearer " <> secret)}], else: []
    base ++ auth ++ extra
  end

  defp request(uri, body, headers) do
    http_options = [
      timeout: setting(:timeout_ms, 10_000),
      connect_timeout: setting(:connect_timeout_ms, 3_000),
      autoredirect: false,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(uri.host)
      ]
    ]

    case :httpc.request(
           :post,
           {uri |> URI.to_string() |> String.to_charlist(), headers, ~c"application/json", body},
           http_options,
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _headers, _body}} -> classify(status)
      {:error, {:failed_connect, [_, {_, _, :econnrefused}]}} -> {:retryable, :connection_refused}
      {:error, _reason} -> :unknown
    end
  end

  @doc false
  def classify(status) when status in 200..201, do: {:succeeded, %{"status" => status}}
  def classify(202), do: {:accepted, "http-202"}
  def classify(status) when status in 203..299, do: {:succeeded, %{"status" => status}}
  def classify(status) when status in [429, 503], do: {:retryable, {:http, status}}
  def classify(408), do: :unknown
  def classify(status) when status in 400..499, do: {:failed, {:http, status}}
  def classify(_status), do: :unknown

  defp setting(key, default),
    do: Application.get_env(:fyrlet_effect_http, key, default)
end
