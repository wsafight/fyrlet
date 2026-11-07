"""Session exchange for trusted backends. Never use this in a browser or app binary."""

from __future__ import annotations

import urllib.parse
from dataclasses import dataclass
from typing import Any

from .http import endpoint_url, request


@dataclass(frozen=True)
class UserSession:
    token: str
    project_id: str
    subject_id: str
    session_id: str
    expires_at: str


class SessionService:
    def __init__(self, endpoint: str, service_key: str, *, timeout: float = 10.0) -> None:
        if not service_key.startswith("rtk_"):
            raise ValueError("Expected a backend service key")
        self._endpoint = endpoint_url(endpoint)
        self._headers = {"authorization": f"Bearer {service_key}"}
        self._timeout = timeout

    def issue_session(
        self, external_subject: str, *, issuer: str | None = None, ttl_seconds: int | None = None
    ) -> UserSession:
        body: dict[str, Any] = {"external_subject": external_subject}
        if issuer is not None:
            body["issuer"] = issuer
        if ttl_seconds is not None:
            body["ttl_seconds"] = ttl_seconds
        data = request("POST", f"{self._endpoint}/api/v1/sessions", self._headers, body, timeout=self._timeout)["data"]
        return UserSession(**{name: data[name] for name in UserSession.__dataclass_fields__})

    def revoke_session(self, session_id: str) -> bool:
        path = urllib.parse.quote(session_id, safe="")
        data = request("DELETE", f"{self._endpoint}/api/v1/sessions/{path}", self._headers, timeout=self._timeout)["data"]
        return bool(data.get("revoked"))
