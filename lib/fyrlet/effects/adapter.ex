defmodule Fyrlet.Effects.Adapter do
  @moduledoc """
  Delivers an effect to an external system.

  `capabilities/0` must state how the receiver behaves, because it decides what the
  framework may do after an uncertain outcome:

    * `"idempotency"` - `nil`, or `%{"window_seconds" => n}` when the receiver de-duplicates
      requests carrying the same key (`effect.operation_id`) for that long;
    * `"queryable"` - the receiver can be asked what became of a request (`query/1`);
    * `"cancellable"` - `cancel/1` can withdraw a request that was accepted;
    * `"acceptance"` - `"provider_accepted"` when success only means the provider took the
      request (an email accepted is not an email delivered), or `"final"`.

  Results of `dispatch/1`:

    * `{:succeeded, result}` - done, as far as this adapter can know;
    * `{:accepted, external_ref}` - taken, final outcome arrives by receipt or query;
    * `{:failed, reason}` - definitely not done;
    * `{:retryable, reason}` - definitely **not** done and safe to send again. Use it only
      when the adapter can be certain no effect happened;
    * `:unknown` - the outcome cannot be known (timeout, lost response).
  """
  @callback capabilities() :: map()
  @callback dispatch(effect :: map()) ::
              {:succeeded, term()}
              | {:accepted, String.t()}
              | {:failed, term()}
              | {:retryable, term()}
              | :unknown
  @callback query(effect :: map()) ::
              {:succeeded, term()} | {:failed, term()} | :pending | :not_found | :unknown
  @callback cancel(effect :: map()) :: :ok | {:error, term()}
  @optional_callbacks query: 1, cancel: 1

  @doc "The registered adapter module for a name."
  def fetch(name) do
    case Application.get_env(:fyrlet, :effect_adapters, %{})[name] do
      nil -> :error
      module -> {:ok, module}
    end
  end
end
