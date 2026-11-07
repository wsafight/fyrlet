defmodule FyrletEffectEmail do
  @moduledoc """
  Delivers an effect as an email through a provider you configure. Register it with
  `config :fyrlet, effect_adapters: %{"email" => FyrletEffectEmail}`.

  This module owns what must not depend on the vendor: validating the message, refusing
  header injection, restricting senders and recipients, and mapping provider answers to
  outcomes the framework can reason about. Talking to the vendor is the provider's job
  (`FyrletEffectEmail.Provider`), so Fyrlet carries no vendor SDK or credentials format.

      config :fyrlet_effect_email,
        provider: MyApp.Mailer,
        allowed_senders: ["noreply@example.com"],
        allowed_recipient_domains: nil,   # or ["example.com"] to confine a staging system
        max_recipients: 50

  Payload: `%{"from" => addr, "to" => [addr], "subject" => text, "text" => body,
  "html" => body, "reply_to" => addr}`. At least one of `text`/`html` is required. Custom
  headers are not accepted: they are the usual route to header injection, and the provider
  adds the ones it needs.

  What "success" means - the part that is easy to get wrong:

    * the provider taking the message is `:accepted`, **not** delivered. The effect stays
      `accepted` until a receipt (`POST /api/v1/effects/:id/receipts`, e.g. from the
      provider's delivery or bounce webhook) or, if the provider can be queried, a
      reconcile says `delivered` or `bounced`;
    * a bounce is a `failed` outcome that arrives after acceptance; it never turns an
      earlier success into silence, and it does not cause a resend;
    * a timeout or lost response is `unknown` - the mail may have gone out - and is not
      retried unless the provider declares an idempotency window and the key is reused.
  """
  @behaviour Fyrlet.Effects.Adapter

  @address ~r/\A[^\s@<>",;()\[\]\\]{1,64}@[^\s@<>",;()\[\]\\]{1,255}\.[^\s@<>",;()\[\]\\]{2,63}\z/
  @max_subject 998
  @max_body_bytes 256 * 1024

  @impl true
  def capabilities do
    provider = provider()
    declared = provider && provider.capabilities()

    %{
      "idempotency" => declared && declared["idempotency"],
      "queryable" => queryable?(provider, declared),
      "cancellable" => false,
      "acceptance" => "provider_accepted",
      "version" => "1"
    }
  end

  @impl true
  def dispatch(effect) do
    with {:ok, provider} <- configured(),
         {:ok, message} <- validate(effect.payload) do
      deliver(provider, message, effect)
    else
      {:error, reason} -> {:failed, reason}
    end
  end

  @impl true
  def query(effect) do
    provider = provider()
    declared = provider && provider.capabilities()

    if queryable?(provider, declared) and is_binary(effect.external_ref) do
      try do
        map_status(provider.status(effect.external_ref, context(effect)))
      rescue
        _exception -> :unknown
      catch
        _kind, _reason -> :unknown
      end
    else
      :unknown
    end
  end

  # ---- delivery -------------------------------------------------------------------------

  # The provider is third-party code and may fail after the message left; anything it raises
  # is therefore "unknown", never "failed".
  defp deliver(provider, message, effect) do
    case provider.deliver(message, context(effect)) do
      {:accepted, id} when is_binary(id) and id != "" -> {:accepted, id}
      {:rejected, reason} -> {:failed, reason}
      {:transient, reason} -> {:retryable, reason}
      _other -> :unknown
    end
  rescue
    _exception -> :unknown
  catch
    _kind, _reason -> :unknown
  end

  defp context(effect) do
    %{
      idempotency_key: effect.operation_id,
      secret: Application.get_env(:fyrlet, :effect_secrets, %{})[effect.secret_ref]
    }
  end

  defp map_status({:delivered, detail}),
    do: {:succeeded, %{"delivered" => true, "detail" => detail}}

  defp map_status({:bounced, detail}), do: {:failed, {:bounced, detail}}
  defp map_status(:pending), do: :pending
  defp map_status(:not_found), do: :not_found
  defp map_status(_other), do: :unknown

  # ---- validation -----------------------------------------------------------------------

  defp validate(payload) when is_map(payload) do
    with {:ok, from} <- sender(payload["from"]),
         {:ok, to} <- recipients(payload["to"]),
         {:ok, reply_to} <- reply_to(payload["reply_to"]),
         {:ok, subject} <- subject(payload["subject"]),
         {:ok, text, html} <- bodies(payload["text"], payload["html"]) do
      {:ok,
       %{"from" => from, "to" => to, "reply_to" => reply_to, "subject" => subject}
       |> put_present("text", text)
       |> put_present("html", html)}
    end
  end

  defp validate(_payload), do: {:error, "invalid email payload"}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp sender(address) do
    with {:ok, address} <- address(address, "from"),
         true <- address in setting(:allowed_senders, []) do
      {:ok, address}
    else
      {:error, _} = error -> error
      false -> {:error, "sender is not allowed"}
    end
  end

  defp recipients(list) when is_list(list) and list != [] do
    if length(list) > setting(:max_recipients, 50) do
      {:error, "too many recipients"}
    else
      Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
        with {:ok, address} <- address(item, "to"),
             :ok <- domain_allowed(address) do
          {:cont, {:ok, [address | acc]}}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, reversed} -> {:ok, reversed |> Enum.reverse() |> Enum.uniq()}
        error -> error
      end
    end
  end

  defp recipients(_other), do: {:error, "to must be a non-empty list of addresses"}

  defp reply_to(nil), do: {:ok, nil}
  defp reply_to(address), do: address(address, "reply_to")

  defp domain_allowed(address) do
    case setting(:allowed_recipient_domains, nil) do
      nil ->
        :ok

      domains ->
        [_, domain] = String.split(address, "@", parts: 2)

        if String.downcase(domain) in domains,
          do: :ok,
          else: {:error, "recipient domain is not allowed"}
    end
  end

  # A Regex `\z` anchors the end of the string, so a trailing newline (the classic injection)
  # cannot slip through; control characters are rejected explicitly as well.
  defp address(value, field) when is_binary(value) do
    if Regex.match?(@address, value) and not control?(value),
      do: {:ok, value},
      else: {:error, "#{field} is not a valid address"}
  end

  defp address(_value, field), do: {:error, "#{field} is not a valid address"}

  defp subject(value) when is_binary(value) do
    cond do
      value == "" -> {:error, "subject is required"}
      byte_size(value) > @max_subject -> {:error, "subject is too long"}
      control?(value) -> {:error, "subject contains control characters"}
      true -> {:ok, value}
    end
  end

  defp subject(_value), do: {:error, "subject is required"}

  defp bodies(text, html) do
    cond do
      is_nil(text) and is_nil(html) -> {:error, "text or html is required"}
      not valid_body?(text) or not valid_body?(html) -> {:error, "body is invalid or too large"}
      true -> {:ok, text, html}
    end
  end

  defp valid_body?(nil), do: true

  defp valid_body?(body),
    do:
      is_binary(body) and body != "" and byte_size(body) <= @max_body_bytes and
        String.valid?(body)

  defp control?(value), do: String.match?(value, ~r/[\x00-\x1F\x7F]/)

  # ---- configuration --------------------------------------------------------------------

  defp configured do
    case provider() do
      nil -> {:error, "no email provider is configured"}
      provider -> {:ok, provider}
    end
  end

  defp provider do
    case setting(:provider, nil) do
      module when is_atom(module) and not is_nil(module) ->
        if Code.ensure_loaded?(module), do: module, else: nil

      _other ->
        nil
    end
  end

  defp queryable?(nil, _declared), do: false

  defp queryable?(provider, declared) do
    declared["queryable"] == true and function_exported?(provider, :status, 2)
  end

  defp setting(key, default),
    do: Application.get_env(:fyrlet_effect_email, key, default)
end
