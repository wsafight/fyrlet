"""Subscription state machine: snapshots, deltas and the values handed to listeners."""

from __future__ import annotations

import threading
from dataclasses import dataclass, replace
from typing import Any, Callable, Literal

from .delta import InvalidDelta, apply_delta
from .errors import ApiError

PROTOCOL_VERSION = 1
Status = Literal["connecting", "ready", "recovering", "error", "closed"]


@dataclass(frozen=True)
class SubscriptionState:
    """What a listener sees. ``data`` must be treated as read-only."""

    status: Status = "connecting"
    data: Any = None
    error: ApiError | None = None
    generation: str | None = None
    seq: int = 0


Listener = Callable[[SubscriptionState], None]


class Entry:
    def __init__(self, id: str, name: str, params: Any, delta: bool) -> None:
        self.id = id
        self.name = name
        self.params = params
        self.want_delta = delta
        self.state = SubscriptionState()
        self.listeners: list[Listener] = []
        self.conn: Any = None
        self.join_failures = 0
        self._delta = False

    @property
    def topic(self) -> str:
        return f"subscription:{self.id}"

    def set_state(self, **changes: Any) -> None:
        self.state = replace(self.state, **changes)

    # Each method returns what the client must do next: an ACK tuple, "reconnect", or None.
    def apply_snapshot(self, snapshot: Any, identity: dict[str, str] | None, initial: bool) -> tuple[str, int] | None:
        if (
            not isinstance(snapshot, dict)
            or snapshot.get("protocol_version") != PROTOCOL_VERSION
            or snapshot.get("subscription_id") != self.id
            or identity is None
            or snapshot.get("project_id") != identity["project_id"]
            or snapshot.get("subject_id") != identity["subject_id"]
            or not isinstance(snapshot.get("generation"), str)
            or not isinstance(snapshot.get("seq"), int)
            or isinstance(snapshot.get("seq"), bool)
            or snapshot["seq"] < 1
            or "data" not in snapshot
        ):
            raise ApiError("PROTOCOL_ERROR", "Invalid subscription snapshot")
        if not initial and snapshot["generation"] != self.state.generation:
            return None
        if initial:
            self._delta = snapshot.get("delivery") == "delta-v1"
        if initial or snapshot["seq"] > self.state.seq:
            self.state = SubscriptionState("ready", snapshot["data"], None, snapshot["generation"], snapshot["seq"])
        return snapshot["generation"], snapshot["seq"]

    def apply_delta(self, payload: Any) -> tuple[str, int] | Literal["reconnect"] | None:
        if not isinstance(payload, dict):
            raise ApiError("PROTOCOL_ERROR", "Invalid subscription delta")
        if payload.get("g") != self.state.generation:
            return None
        seq, base = payload.get("s"), payload.get("b")
        if (
            not self._delta
            or not all(isinstance(n, int) and not isinstance(n, bool) for n in (seq, base))
            or seq < 2 or base < 1 or seq != base + 1
        ):
            raise ApiError("PROTOCOL_ERROR", "Invalid subscription delta sequence")
        if seq <= self.state.seq:
            return payload["g"], seq
        if base != self.state.seq:
            return "reconnect"
        try:
            data = apply_delta(self.state.data, payload.get("p"))
        except InvalidDelta:
            raise ApiError("PROTOCOL_ERROR", "Invalid subscription delta") from None
        self.state = SubscriptionState("ready", data, None, self.state.generation, seq)
        return payload["g"], seq


class Subscription:
    """Handle returned by ``Client.subscribe``. All methods are thread-safe."""

    def __init__(self, entry: Entry, lock: threading.RLock, refresh: Callable[[], None], unsubscribe: Callable[[], None],
                 dispatch: Callable[[Listener, SubscriptionState], None]) -> None:
        self._entry, self._lock, self._refresh, self._unsubscribe, self._dispatch = entry, lock, refresh, unsubscribe, dispatch

    def get_state(self) -> SubscriptionState:
        with self._lock:
            return self._entry.state

    def on_change(self, listener: Listener) -> Callable[[], None]:
        """Register a listener. It receives the current state first, then every change, on a
        dedicated dispatcher thread, so it may call back into the client without deadlocking."""
        with self._lock:
            self._entry.listeners.append(listener)
            self._dispatch(listener, self._entry.state)

        def stop() -> None:
            with self._lock:
                if listener in self._entry.listeners:
                    self._entry.listeners.remove(listener)

        return stop

    def refresh(self) -> None:
        """Ask the server for a fresh snapshot; data arrives through ``on_change``."""
        self._refresh()

    def unsubscribe(self) -> None:
        self._unsubscribe()
