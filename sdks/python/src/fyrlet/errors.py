"""Error types shared by the HTTP and socket transports."""

from __future__ import annotations

from typing import Any


class ApiError(Exception):
    """A failure reported by the server or detected by the SDK."""

    def __init__(
        self,
        code: str,
        message: str,
        *,
        details: dict[str, Any] | None = None,
        retryable: bool = False,
        status: int = 0,
        request_id: str | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}
        self.retryable = retryable
        self.status = status
        self.request_id = request_id

    def __repr__(self) -> str:
        return f"ApiError(code={self.code!r}, message={self.message!r}, status={self.status})"


class OutcomeUnknownError(ApiError):
    """A write was dispatched but its result is unknown.

    Use ``Client.recover`` with ``idempotency_key`` before deciding to submit it again.
    """

    outcome = "unknown"

    def __init__(self, operation: str, idempotency_key: str, cause: BaseException) -> None:
        base = as_api_error(cause)
        super().__init__(
            base.code,
            "The operation outcome is unknown",
            details=base.details,
            retryable=False,
            status=base.status,
            request_id=base.request_id,
        )
        self.operation = operation
        self.idempotency_key = idempotency_key
        self.__cause__ = cause


def as_api_error(error: BaseException) -> ApiError:
    if isinstance(error, ApiError):
        return error
    return ApiError("NETWORK_ERROR", "The service could not be reached", retryable=True)


def error_from_payload(error: Any, status: int = 0, request_id: str | None = None) -> ApiError:
    if isinstance(error, dict) and isinstance(error.get("code"), str) and isinstance(error.get("message"), str):
        details = error.get("details")
        return ApiError(
            error["code"],
            error["message"],
            details=details if isinstance(details, dict) else None,
            retryable=error.get("retryable") is True,
            status=status,
            request_id=request_id,
        )
    return ApiError("PROTOCOL_ERROR", "Invalid error response", status=status, request_id=request_id)


def channel_error(payload: Any) -> ApiError:
    """Convert a Phoenix channel error reply into an ``ApiError``."""
    if isinstance(payload, dict) and isinstance(payload.get("error"), dict):
        status = payload.get("status")
        return error_from_payload(payload["error"], status if isinstance(status, int) else 0)
    return ApiError("PROTOCOL_ERROR", "The server returned an invalid channel response")
