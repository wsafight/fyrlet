defmodule Fyrlet.ErrorTest do
  use ExUnit.Case, async: true
  alias Fyrlet.Error

  test "error codes map to their documented HTTP statuses" do
    expectations = %{
      "UNAUTHENTICATED" => 401,
      "FORBIDDEN" => 403,
      "NOT_FOUND" => 404,
      "CONFLICT" => 409,
      "VALIDATION_FAILED" => 422,
      "LIMIT_EXCEEDED" => 429,
      "UNSUPPORTED_VERSION" => 400
    }

    for {code, status} <- expectations do
      assert Error.status(Error.new(code, "message")) == status
    end
  end

  test "unknown and internal codes fall back to 500" do
    assert Error.status(Error.new("INTERNAL_ERROR", "boom")) == 500
    assert Error.status(Error.new("SOMETHING_NEW", "boom")) == 500
    assert Error.status(%Error{}) == 500
  end

  test "new/4 defaults details and retryability" do
    error = Error.new("CONFLICT", "retry")
    assert error.code == "CONFLICT"
    assert error.message == "retry"
    assert error.details == %{}
    refute error.retryable

    retryable = Error.new("LIMIT_EXCEEDED", "slow down", %{"retry_after" => 2}, true)
    assert retryable.details == %{"retry_after" => 2}
    assert retryable.retryable
  end

  test "to_map/1 produces the public error envelope" do
    error = Error.new("VALIDATION_FAILED", "bad input", %{"fields" => %{"$.x" => "required"}})

    assert Error.to_map(error) == %{
             "code" => "VALIDATION_FAILED",
             "message" => "bad input",
             "details" => %{"fields" => %{"$.x" => "required"}},
             "retryable" => false
           }
  end

  test "named constructors carry stable codes and messages" do
    assert Error.unauthorized().code == "UNAUTHENTICATED"
    assert Error.unauthorized().message == "A valid session is required"
    assert Error.not_found().code == "NOT_FOUND"
    assert Error.not_found().message == "The requested resource does not exist"
    assert Error.forbidden().code == "FORBIDDEN"
    assert Error.forbidden().message == "This operation is not permitted"

    for error <- [Error.unauthorized(), Error.not_found(), Error.forbidden()] do
      assert error.details == %{}
      refute error.retryable
    end
  end

  test "the struct is a raisable exception" do
    assert_raise Error, "stop", fn -> raise Error.new("INTERNAL_ERROR", "stop") end
  end
end
