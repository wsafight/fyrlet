"""A small Phoenix Channels v2 connection: one WebSocket, a reader thread and a maintenance thread."""

from __future__ import annotations

import base64
import json
import threading
import time
import urllib.parse
from typing import Any, Callable

from websockets.exceptions import WebSocketException
from websockets.sync.client import connect

from .errors import ApiError

Frame = tuple[Any, Any, str, str, dict[str, Any]]
HEARTBEAT_SECONDS = 30.0
MAX_BATCH = 64


def decode_frames(raw: str | bytes) -> list[Frame]:
    """Decode one Phoenix frame or a ``{"batch": [...]}`` wrapper, validating every member."""
    decoded = json.loads(raw)
    if isinstance(decoded, dict) and list(decoded) == ["batch"]:
        frames = decoded["batch"]
    else:
        frames = [decoded]
    if not isinstance(frames, list) or not 0 < len(frames) <= MAX_BATCH:
        raise ValueError("Invalid Fyrlet transport frame")
    for frame in frames:
        if not (
            isinstance(frame, list) and len(frame) == 5
            and (frame[0] is None or isinstance(frame[0], str))
            and (frame[1] is None or isinstance(frame[1], str))
            and isinstance(frame[2], str) and isinstance(frame[3], str)
            and isinstance(frame[4], dict)
        ):
            raise ValueError("Invalid Fyrlet transport frame")
    return [tuple(frame) for frame in frames]  # type: ignore[misc]


def socket_url(endpoint: str, project_id: str) -> str:
    base = "ws" + endpoint[len("http"):] + "/socket/websocket"
    return base + "?" + urllib.parse.urlencode({"project_id": project_id, "vsn": "2.0.0"})


def auth_protocol(token: str) -> str:
    return "base64url.bearer.phx." + base64.urlsafe_b64encode(token.encode()).decode().rstrip("=")


Reply = Callable[[str, Any], None]


class Connection:
    """One authenticated socket. ``on_frame`` and ``on_close`` run on the reader thread, in order."""

    def __init__(
        self,
        endpoint: str,
        project_id: str,
        token: str,
        *,
        timeout: float,
        on_frame: Callable[["Connection", str, str, dict[str, Any]], None],
        on_close: Callable[["Connection", ApiError | None], None],
    ) -> None:
        self._on_frame = on_frame
        self._on_close = on_close
        self._send_lock = threading.Lock()
        self._lock = threading.Lock()
        self._pending: dict[str, tuple[Reply, float]] = {}
        self._refs = 0
        self.closed = threading.Event()
        try:
            self._ws = connect(
                socket_url(endpoint, project_id),
                subprotocols=["phoenix", auth_protocol(token)],  # type: ignore[list-item]
                open_timeout=timeout,
                close_timeout=1,
                max_size=4 * 1024 * 1024,
                additional_headers={"user-agent": "fyrlet-python"},
            )
        except (OSError, WebSocketException, TimeoutError) as error:
            raise ApiError("NETWORK_ERROR", "The service could not be reached", retryable=True) from error
        self._timeout = timeout
        threading.Thread(target=self._read, name="fyrlet-reader", daemon=True).start()
        threading.Thread(target=self._maintain, name="fyrlet-heartbeat", daemon=True).start()

    # -- outbound ----------------------------------------------------------------------

    def _next_ref(self) -> str:
        with self._lock:
            self._refs += 1
            return str(self._refs)

    def _send(self, frame: list[Any]) -> None:
        try:
            with self._send_lock:
                self._ws.send(json.dumps(frame, separators=(",", ":")))
        except (OSError, WebSocketException) as error:
            self._shutdown(ApiError("NETWORK_ERROR", "The connection was interrupted", retryable=True))
            raise ApiError("NETWORK_ERROR", "The connection was interrupted", retryable=True) from error

    def push(self, topic: str, event: str, payload: dict[str, Any], on_reply: Reply, *, join_ref: str | None = None) -> None:
        """Send an event; ``on_reply(status, response)`` gets ``ok``, ``error`` or ``timeout``."""
        ref = self._next_ref()
        with self._lock:
            self._pending[ref] = (on_reply, time.monotonic() + self._timeout)
        try:
            self._send([join_ref, ref, topic, event, payload])
        except ApiError:
            with self._lock:
                self._pending.pop(ref, None)
            raise

    def join(self, topic: str, payload: dict[str, Any], on_reply: Reply) -> None:
        # The join ref doubles as the first message ref, mirroring Phoenix's client.
        ref = self._next_ref()
        with self._lock:
            self._pending[ref] = (on_reply, time.monotonic() + self._timeout)
        self._send([ref, ref, topic, "phx_join", payload])

    def notify(self, topic: str, event: str, payload: dict[str, Any]) -> None:
        """Fire-and-forget event with no ref, such as ``ack``."""
        self._send([None, None, topic, event, payload])

    def leave(self, topic: str) -> None:
        try:
            self._send([None, self._next_ref(), topic, "phx_leave", {}])
        except ApiError:
            pass

    def close(self) -> None:
        self._shutdown(None, notify=False)

    # -- loops -------------------------------------------------------------------------

    def _read(self) -> None:
        failure: ApiError | None = ApiError("NETWORK_ERROR", "The connection was interrupted", retryable=True)
        try:
            for raw in self._ws:
                try:
                    frames = decode_frames(raw)
                except ValueError:
                    failure = ApiError("PROTOCOL_ERROR", "Invalid transport frame")
                    break
                for _, ref, topic, event, payload in frames:
                    if event == "phx_reply" and ref is not None:
                        with self._lock:
                            waiter = self._pending.pop(ref, None)
                        if waiter:
                            status = payload.get("status")
                            waiter[0](status if isinstance(status, str) else "error", payload.get("response"))
                    else:
                        self._on_frame(self, topic, event, payload)
        except (OSError, WebSocketException):
            pass
        self._shutdown(failure)

    def _maintain(self) -> None:
        last_beat = time.monotonic()
        while not self.closed.wait(0.25):
            now = time.monotonic()
            with self._lock:
                expired = [ref for ref, (_, deadline) in self._pending.items() if deadline <= now]
                waiters = [self._pending.pop(ref)[0] for ref in expired]
            for waiter in waiters:
                waiter("timeout", None)
            if now - last_beat >= HEARTBEAT_SECONDS:
                last_beat = now
                try:
                    self.push("phoenix", "heartbeat", {}, self._heartbeat_reply)
                except ApiError:
                    return

    def _heartbeat_reply(self, status: str, _response: Any) -> None:
        if status == "timeout":
            self._shutdown(ApiError("NETWORK_ERROR", "Heartbeat timed out", retryable=True))

    def _shutdown(self, failure: ApiError | None, *, notify: bool = True) -> None:
        with self._lock:
            if self.closed.is_set():
                return
            self.closed.set()
            waiters = [waiter for waiter, _ in self._pending.values()]
            self._pending.clear()
        try:
            self._ws.close()
        except Exception:  # noqa: BLE001 - closing is best effort
            pass
        for waiter in waiters:
            waiter("timeout", None)
        if notify:
            self._on_close(self, failure)
