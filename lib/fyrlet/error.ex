defmodule Fyrlet.Error do
  defexception [:code, :message, details: %{}, retryable: false]

  @type t :: %__MODULE__{}

  def new(code, message, details \\ %{}, retryable \\ false) do
    %__MODULE__{code: code, message: message, details: details, retryable: retryable}
  end

  def unauthorized, do: new("UNAUTHENTICATED", "A valid session is required")
  def not_found, do: new("NOT_FOUND", "The requested resource does not exist")
  def forbidden, do: new("FORBIDDEN", "This operation is not permitted")

  def status(%__MODULE__{code: code}) do
    case code do
      "UNAUTHENTICATED" -> 401
      "FORBIDDEN" -> 403
      "NOT_FOUND" -> 404
      "CONFLICT" -> 409
      "EFFECT_UNKNOWN" -> 409
      "LEASE_LOST" -> 409
      "EFFECT_CONFLICT" -> 409
      "VALIDATION_FAILED" -> 422
      "LIMIT_EXCEEDED" -> 429
      "UNSUPPORTED_VERSION" -> 400
      "UNSUPPORTED_CAPABILITY" -> 400
      "UNAVAILABLE" -> 503
      _other -> 500
    end
  end

  def to_map(%__MODULE__{} = error) do
    %{
      "code" => error.code,
      "message" => error.message,
      "details" => error.details,
      "retryable" => error.retryable
    }
  end
end
