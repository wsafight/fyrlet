defmodule FyrletEffectEmail.Provider do
  @moduledoc """
  The vendor side of `FyrletEffectEmail`: one module per mail service.

  `capabilities/0` states what the service actually promises, because it decides what the
  framework may do after an uncertain outcome:

    * `"idempotency"` - `nil`, or `%{"window_seconds" => n}` if the service de-duplicates
      sends that carry the same `idempotency_key` for that long. Declare it only when true;
      otherwise an unknown outcome pauses for a human instead of resending;
    * `"queryable"` - `true` if `status/2` can report delivery or bounce for a message id.

  `deliver/2` must be honest about certainty:

    * `{:accepted, provider_message_id}` - the service took the message (not "delivered");
    * `{:rejected, reason}` - the service refused it for good (bad address, policy);
    * `{:transient, reason}` - the service refused it **and** nothing was sent (for example
      a 429 or 503 returned before queueing). Use it only when that is certain;
    * `:unknown` - anything else: timeouts, dropped connections, unparsable answers.

  `reason` ends up in the effect's `last_error`; keep recipient addresses and message
  content out of it.
  """
  @type message :: %{required(String.t()) => term()}
  @type context :: %{idempotency_key: String.t(), secret: String.t() | nil}

  @callback capabilities() :: map()
  @callback deliver(message(), context()) ::
              {:accepted, String.t()} | {:rejected, term()} | {:transient, term()} | :unknown
  @callback status(provider_message_id :: String.t(), context()) ::
              {:delivered, term()} | {:bounced, term()} | :pending | :not_found | :unknown
  @optional_callbacks status: 2
end
