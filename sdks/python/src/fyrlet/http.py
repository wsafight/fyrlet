"""Minimal JSON-over-HTTP helper built on the standard library."""

from __future__ import annotations

import json
import socket
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

from .errors import ApiError, error_from_payload


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    # Never follow redirects: they could forward bearer credentials to another host.
    def redirect_request(self, *args: Any, **kwargs: Any) -> None:  # noqa: D401
        return None


_opener = urllib.request.build_opener(_NoRedirect)


def endpoint_url(endpoint: str) -> str:
    url = urllib.parse.urlsplit(endpoint)
    if url.scheme not in ("http", "https") or not url.hostname or url.username or url.password or url.query or url.fragment:
        raise ValueError("endpoint must be an HTTP(S) base URL without credentials, query or fragment")
    return endpoint.rstrip("/")


def request(
    method: str,
    url: str,
    headers: dict[str, str],
    body: Any = None,
    *,
    timeout: float,
) -> dict[str, Any]:
    """Perform a request and return the decoded response envelope.

    Raises ``ApiError`` for transport failures, malformed envelopes and server errors.
    """
    data = None if body is None else json.dumps(body, separators=(",", ":")).encode()
    all_headers = {"accept": "application/json", **headers}
    if data is not None:
        all_headers.setdefault("content-type", "application/json")
    req = urllib.request.Request(url, data=data, method=method, headers=all_headers)
    status = 0
    try:
        with _opener.open(req, timeout=timeout) as response:
            status = response.status
            raw = response.read()
    except urllib.error.HTTPError as error:
        status = error.code
        raw = error.read()
    except (socket.timeout, TimeoutError):
        raise ApiError("TIMEOUT", "The request timed out", retryable=True) from None
    except urllib.error.URLError as error:
        if isinstance(error.reason, (socket.timeout, TimeoutError)):
            raise ApiError("TIMEOUT", "The request timed out", retryable=True) from None
        raise ApiError("NETWORK_ERROR", "The service could not be reached", retryable=True) from None
    except OSError:
        raise ApiError("NETWORK_ERROR", "The service could not be reached", retryable=True) from None

    try:
        envelope = json.loads(raw)
    except ValueError:
        raise ApiError("PROTOCOL_ERROR", "Expected a JSON response", status=status) from None
    if not isinstance(envelope, dict):
        raise ApiError("PROTOCOL_ERROR", "Expected a response envelope", status=status)
    request_id = envelope.get("request_id") if isinstance(envelope.get("request_id"), str) else None
    if not 200 <= status < 300 or "error" in envelope:
        if "error" in envelope:
            raise error_from_payload(envelope["error"], status, request_id)
        raise ApiError("HTTP_ERROR", "The request was rejected", status=status, request_id=request_id)
    if "data" not in envelope:
        raise ApiError("PROTOCOL_ERROR", "Missing response data", status=status)
    return envelope
