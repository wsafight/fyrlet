"""The Fyrlet client: authenticated operations plus recoverable realtime subscriptions."""

from __future__ import annotations

import queue
import re
import threading
import urllib.parse
import uuid
from dataclasses import dataclass
from typing import Any, Callable, Literal

from .errors import ApiError, OutcomeUnknownError, as_api_error, channel_error
from .http import endpoint_url, request
from .phoenix import Connection
from .subscription import PROTOCOL_VERSION, Entry, Listener, Subscription, SubscriptionState

# Consecutive retryable join failures of one subscription before it is reported as failed.
MAX_JOIN_RETRIES = 10
_CAPABILITY = re.compile(r"^[a-z][a-z0-9_.-]*$")

MutationStatus = Literal["pending", "completed", "committed", "accepted", "failed", "unknown"]


@dataclass(frozen=True)
class MutationState:
    status: MutationStatus
    data: Any = None
    error: BaseException | None = None


@dataclass(frozen=True)
class RecoveryResult:
    """``status`` is ``committed`` or ``accepted`` with the original ``data``, or ``unknown``."""

    status: Literal["committed", "accepted", "unknown"]
    data: Any = None


class Mutation:
    """The outcome of one operation, kept so an unknown result can be recovered later."""

    def __init__(self, idempotency_key: str, state: MutationState, lookup: Callable[[], RecoveryResult]) -> None:
        self.idempotency_key = idempotency_key
        self._state = state
        self._lookup = lookup
        self._lock = threading.Lock()

    @property
    def state(self) -> MutationState:
        return self._state

    def result(self) -> Any:
        """The business result, or the original error."""
        if self._state.status in ("completed", "committed", "accepted"):
            return self._state.data
        raise self._state.error or ApiError("PROTOCOL_ERROR", "The operation has no result")

    def recover(self) -> MutationState:
        """Query the stored receipt of an ``unknown`` write without executing it again."""
        with self._lock:
            if self._state.status != "unknown":
                return self._state
            found = self._lookup()
            if found.status != "unknown":
                self._state = MutationState(found.status, found.data)
            return self._state


def _normalize_capabilities(value: Any) -> dict[str, int]:
    if value is None:
        return {}
    entries = [(name, 1) for name in value] if not isinstance(value, dict) else list(value.items())
    result: dict[str, int] = {}
    for name, version in entries:
        if not isinstance(name, str) or not _CAPABILITY.match(name) or not isinstance(version, int) or version < 1:
            raise ValueError("capabilities must be names (or name -> positive integer version)")
        result[name] = version
    return result


class Client:
    """Thread-safe client bound to one project and one user.

    ``get_token(force_refresh)`` returns a short-lived user session token (``rts_...``). With
    ``force_refresh`` set, revalidate the host login and obtain a new session, or raise
    ``ApiError("UNAUTHENTICATED", ...)`` to stop recovery.
    """

    def __init__(
        self,
        endpoint: str,
        project_id: str,
        get_token: Callable[[bool], str],
        *,
        timeout: float = 10.0,
        retry_delay: Callable[[int], float] | None = None,
        delta: bool = True,
        capabilities: Any = None,
        create_id: Callable[[], str] | None = None,
        on_listener_error: Callable[[BaseException], None] | None = None,
    ) -> None:
        if not project_id:
            raise ValueError("project_id is required")
        self._endpoint = endpoint_url(endpoint)
        self._project_id = project_id
        self._get_token = get_token
        self._timeout = timeout
        self._retry_delay = retry_delay
        self._delta = delta
        self._declared = _normalize_capabilities(capabilities)
        self._create_id = create_id or (lambda: str(uuid.uuid4()))
        self._on_listener_error = on_listener_error

        self._lock = threading.RLock()
        self._token_lock = threading.Lock()
        self._entries: dict[str, Entry] = {}
        self._conn: Connection | None = None
        self._identity: dict[str, str] | None = None
        self._token: str | None = None
        self._epoch = 0
        self._connecting_epoch: int | None = None
        self._retries = 0
        self._retry_timer: threading.Timer | None = None
        self._rejoin_timers: dict[str, threading.Timer] = {}
        self._closed = False
        self._events: queue.Queue[tuple[Listener, SubscriptionState] | None] = queue.Queue()
        self._dispatcher: threading.Thread | None = None

    def __enter__(self) -> "Client":
        return self

    def __exit__(self, *_: Any) -> None:
        self.close()

    # ---- operations ---------------------------------------------------------------------

    def call(self, name: str, input: Any = None, *, idempotency_key: str | None = None, timeout: float | None = None) -> Any:
        """Run an operation and return its business result.

        The SDK generates an idempotency key. After a network interruption the outcome of a write is
        unknown: ``OutcomeUnknownError`` carries the key for ``recover``. Reuse that key explicitly
        if you decide to submit the write again.
        """
        return self.mutate(name, input, idempotency_key=idempotency_key, timeout=timeout).result()

    def mutate(self, name: str, input: Any = None, *, idempotency_key: str | None = None, timeout: float | None = None) -> Mutation:
        """Like ``call`` but never raises for a failed operation; inspect ``Mutation.state``."""
        self._assert_open()
        key = idempotency_key or self._create_id()
        body = {"input": {} if input is None else input}
        sent = {"value": False}

        def perform(token: str) -> dict[str, Any]:
            sent["value"] = True
            try:
                return self._http("POST", self._operation_path(name), token, body, key, timeout)
            except ApiError as error:
                # A definite rejection by the server means nothing was written.
                if 400 <= error.status < 500 and error.code not in ("PROTOCOL_ERROR", "HTTP_ERROR"):
                    sent["value"] = False
                raise

        lookup = lambda: self._recover(name, body, key, timeout)  # noqa: E731
        try:
            envelope = self._execute(perform)
            outcome = envelope.get("outcome")
            if outcome not in ("completed", "committed", "accepted"):
                raise ApiError("PROTOCOL_ERROR", "Invalid operation outcome")
            return Mutation(key, MutationState(outcome, envelope["data"]), lookup)
        except ApiError as error:
            if sent["value"]:
                return Mutation(key, MutationState("unknown", error=OutcomeUnknownError(name, key, error)), lookup)
            return Mutation(key, MutationState("failed", error=error), lookup)

    def recover(self, name: str, input: Any = None, *, idempotency_key: str, timeout: float | None = None) -> RecoveryResult:
        """Look up the stored receipt of a write without executing it."""
        self._assert_open()
        return self._recover(name, {"input": {} if input is None else input}, idempotency_key, timeout)

    def contract(self) -> dict[str, Any]:
        """The business contract this server exports."""
        return self._execute(lambda token: self._http("GET", "/api/v1/contract", token))["data"]

    @staticmethod
    def _operation_path(name: str) -> str:
        return f"/api/v1/operations/{urllib.parse.quote(name, safe='')}"

    def _recover(self, name: str, body: dict[str, Any], key: str, timeout: float | None) -> RecoveryResult:
        envelope = self._execute(
            lambda token: self._http("POST", self._operation_path(name) + "/recover", token, body, key, timeout)
        )
        if envelope.get("outcome") == "unknown" and envelope.get("data") is None:
            return RecoveryResult("unknown")
        outcome = envelope.get("outcome")
        if outcome not in ("committed", "accepted"):
            raise ApiError("PROTOCOL_ERROR", "Invalid recovery outcome")
        return RecoveryResult(outcome, envelope["data"])

    def _http(
        self, method: str, path: str, token: str, body: Any = None, key: str | None = None, timeout: float | None = None
    ) -> dict[str, Any]:
        headers = {"authorization": f"Bearer {token}", "x-project-id": self._project_id}
        if key:
            headers["idempotency-key"] = key
        if self._declared:
            headers["x-fyrlet-capabilities"] = ", ".join(f"{n}={v}" for n, v in self._declared.items())
        return request(method, self._endpoint + path, headers, body, timeout=timeout or self._timeout)

    def _execute(self, perform: Callable[[str], dict[str, Any]]) -> dict[str, Any]:
        """Authorize, run ``perform`` and refresh the token at most once on an authentication failure."""
        token = self._authorize(False)
        try:
            try:
                return perform(token)
            except ApiError as error:
                if error.status != 401 and error.code != "UNAUTHENTICATED":
                    raise
                self._assert_open()
                return perform(self._authorize(True, stale=token))
        except ApiError as error:
            if error.code in ("UNAUTHENTICATED", "FORBIDDEN"):
                self._fail_all(error)
            raise

    def _authorize(self, force: bool, stale: str | None = None) -> str:
        with self._token_lock:
            with self._lock:
                self._assert_open()
                token = self._token
            # Another thread already refreshed past the token this caller failed with.
            if token and (not force or (stale is not None and token != stale)):
                return token
            fresh = self._user_token(force)
            try:
                identity = self._identity_for(fresh)
            except ApiError as error:
                if force or error.status != 401:
                    raise
                fresh = self._user_token(True)
                identity = self._identity_for(fresh)
            with self._lock:
                self._assert_open()
                if identity["project_id"] != self._project_id or (
                    self._identity and identity["subject_id"] != self._identity["subject_id"]
                ):
                    raise ApiError("FORBIDDEN", "Create a new client when changing accounts")
                self._identity = identity
                self._token = fresh
            return fresh

    def _user_token(self, force: bool) -> str:
        token = self._get_token(force)
        self._assert_open()
        if not isinstance(token, str) or not token.startswith("rts_"):
            raise ApiError("UNAUTHENTICATED", "get_token must return a user session token")
        return token

    def _identity_for(self, token: str) -> dict[str, str]:
        data = self._http("GET", "/api/v1/identity", token)["data"]
        if not isinstance(data, dict) or not isinstance(data.get("project_id"), str) or not isinstance(data.get("subject_id"), str):
            raise ApiError("PROTOCOL_ERROR", "Invalid identity response")
        return {"project_id": data["project_id"], "subject_id": data["subject_id"]}

    # ---- subscriptions ------------------------------------------------------------------

    def subscribe(self, name: str, params: Any = None) -> Subscription:
        """Start a realtime subscription. Observe it with ``Subscription.on_change``."""
        with self._lock:
            self._assert_open()
            identifier = self._create_id()
            if identifier in self._entries:
                raise ValueError("create_id returned a duplicate subscription ID")
            entry = Entry(identifier, name, {} if params is None else params, self._delta)
            self._entries[identifier] = entry
            conn, epoch = self._conn, self._epoch
            if conn:
                self._attach(entry, conn, epoch)
            else:
                self._start(False)
        return Subscription(
            entry, self._lock,
            lambda: self._refresh(entry),
            lambda: self._unsubscribe(entry),
            self._dispatch,
        )

    def _refresh(self, entry: Entry) -> None:
        with self._lock:
            conn = entry.conn
            if entry.state.status != "ready" or conn is None:
                raise ApiError("NOT_READY", "The subscription is not ready")
        done = threading.Event()
        result: list[Any] = []

        def reply(status: str, response: Any) -> None:
            result.append((status, response))
            done.set()

        conn.push(entry.topic, "refresh", {}, reply)
        done.wait(self._timeout + 1)
        status, response = result[0] if result else ("timeout", None)
        if status == "ok":
            return
        if status == "error":
            raise channel_error(response)
        raise ApiError("TIMEOUT", "refresh was not acknowledged", retryable=True)

    def _unsubscribe(self, entry: Entry) -> None:
        with self._lock:
            if self._entries.pop(entry.id, None) is None:
                return
            self._cancel_rejoin(entry)
            conn, entry.conn = entry.conn, None
            if conn:
                conn.leave(entry.topic)
            entry.set_state(status="closed", data=None, error=None)
            self._emit(entry)
            entry.listeners.clear()
            if not self._entries:
                self._detach()

    def reconnect(self) -> None:
        """Explicitly rebuild the connection and retained subscriptions."""
        with self._lock:
            self._assert_open()
            self._detach()
            self._recovering()
            epoch = self._epoch
            if not self._entries:
                return
        try:
            self._connect(True, epoch)
        except Exception as error:  # noqa: BLE001
            with self._lock:
                self._connection_failed(error, epoch)
            raise

    def close(self) -> None:
        """Release subscriptions, timers and connections. The client cannot be reused."""
        with self._lock:
            if self._closed:
                return
            self._closed = True
            self._detach()
            for entry in self._entries.values():
                entry.set_state(status="closed", data=None, error=None)
                self._emit(entry)
                entry.listeners.clear()
            self._entries.clear()
            self._token = None
        self._events.put(None)

    # ---- connection management (callers hold ``self._lock`` unless noted) --------------

    def _start(self, force: bool) -> None:
        epoch = self._epoch
        if self._connecting_epoch == epoch:
            return
        self._connecting_epoch = epoch

        def run() -> None:
            try:
                self._connect(force, epoch)
            except Exception as error:  # noqa: BLE001
                with self._lock:
                    self._connection_failed(error, epoch)

        threading.Thread(target=run, name="fyrlet-connect", daemon=True).start()

    def _connect(self, force: bool, epoch: int) -> None:
        """Runs on a worker thread without the lock held."""
        try:
            token = self._authorize(force)
            with self._lock:
                if self._closed or self._epoch != epoch or not self._entries or self._conn:
                    return
            conn = Connection(
                self._endpoint, self._project_id, token, timeout=self._timeout,
                on_frame=self._on_frame, on_close=self._on_close,
            )
            with self._lock:
                if self._closed or self._epoch != epoch or not self._entries:
                    conn.close()
                    return
                self._conn = conn
                for entry in list(self._entries.values()):
                    if entry.state.status != "error":
                        self._attach(entry, conn, epoch)
        finally:
            with self._lock:
                if self._connecting_epoch == epoch:
                    self._connecting_epoch = None

    def _join_payload(self, entry: Entry) -> dict[str, Any]:
        payload: dict[str, Any] = {"protocol_version": PROTOCOL_VERSION, "name": entry.name, "params": entry.params}
        if self._declared:
            payload["capabilities"] = self._declared
        if entry.want_delta:
            payload["delivery"] = "delta-v1"
        return payload

    def _current(self, entry: Entry, conn: Connection, epoch: int) -> bool:
        return not self._closed and self._epoch == epoch and entry.conn is conn and entry.id in self._entries

    def _attach(self, entry: Entry, conn: Connection, epoch: int) -> None:
        entry.conn = conn

        def joined(status: str, response: Any) -> None:
            with self._lock:
                if not self._current(entry, conn, epoch):
                    return
                if status == "ok":
                    self._retries = 0
                    entry.join_failures = 0
                    self._receive(entry, conn, "snapshot", response, True)
                    return
                if status != "error":
                    self._transport_failed(conn)
                    return
                error = channel_error(response)
                if error.code == "UNAUTHENTICATED":
                    self._transport_failed(conn)
                elif error.retryable and entry.join_failures < MAX_JOIN_RETRIES:
                    # For example the observer was briefly unavailable: retry this subscription only.
                    entry.join_failures += 1
                    entry.set_state(status="recovering", error=None)
                    self._emit(entry)
                    self._schedule_rejoin(entry, conn, epoch)
                else:
                    self._fail(entry, error)

        try:
            conn.join(entry.topic, self._join_payload(entry), joined)
        except ApiError:
            pass  # the connection already reported its failure

    def _schedule_rejoin(self, entry: Entry, conn: Connection, epoch: int) -> None:
        self._cancel_rejoin(entry)

        def rejoin() -> None:
            with self._lock:
                self._rejoin_timers.pop(entry.id, None)
                if self._current(entry, conn, epoch):
                    self._attach(entry, conn, epoch)

        timer = threading.Timer(self._delay(entry.join_failures), rejoin)
        timer.daemon = True
        self._rejoin_timers[entry.id] = timer
        timer.start()

    def _cancel_rejoin(self, entry: Entry) -> None:
        timer = self._rejoin_timers.pop(entry.id, None)
        if timer:
            timer.cancel()

    def _delay(self, attempt: int) -> float:
        if self._retry_delay:
            return self._retry_delay(attempt)
        return min(0.25 * 2 ** min(attempt - 1, 7), 30.0)

    def _on_frame(self, conn: Connection, topic: str, event: str, payload: dict[str, Any]) -> None:
        with self._lock:
            if conn is not self._conn or self._closed:
                return
            entry = self._entries.get(topic.partition(":")[2]) if topic.startswith("subscription:") else None
            if entry is None or entry.conn is not conn:
                return
            if event in ("snapshot", "delta"):
                self._receive(entry, conn, event, payload)
            elif event == "status":
                error = channel_error(payload)
                if error.code == "UNAUTHENTICATED":
                    for item in self._entries.values():
                        item.set_state(data=None)
                    self._transport_failed(conn)
                elif error.retryable:
                    self._transport_failed(conn)
                else:
                    self._fail(entry, error)
            elif event == "phx_error":
                self._transport_failed(conn)
            elif event == "phx_close":
                self._fail(entry, ApiError("SUBSCRIPTION_CLOSED", "The server closed the subscription"))

    def _on_close(self, conn: Connection, failure: ApiError | None) -> None:
        with self._lock:
            if conn is not self._conn or self._closed:
                return
            if failure is not None and not failure.retryable:
                self._fail_all(failure)
            else:
                self._transport_failed(conn)

    def _receive(self, entry: Entry, conn: Connection, event: str, payload: Any, initial: bool = False) -> None:
        before = entry.state
        try:
            result = entry.apply_snapshot(payload, self._identity, initial) if event == "snapshot" else entry.apply_delta(payload)
        except ApiError as error:
            self._fail(entry, error)
            return
        if entry.state is not before:
            self._emit(entry)
        if result == "reconnect":
            self._transport_failed(conn)
        elif result:
            try:
                conn.notify(entry.topic, "ack", {"g": result[0], "s": result[1]})
            except ApiError:
                pass

    def _transport_failed(self, conn: Connection) -> None:
        if conn is not self._conn or self._closed:
            return
        self._detach()
        self._recovering()
        self._schedule_retry()

    def _connection_failed(self, error: BaseException, epoch: int) -> None:
        if self._closed or self._epoch != epoch:
            return
        failure = as_api_error(error)
        if not failure.retryable:
            self._fail_all(failure)
        else:
            self._recovering()
            self._schedule_retry()

    def _schedule_retry(self) -> None:
        if self._closed or self._retry_timer or not self._entries:
            return
        self._retries += 1

        def retry() -> None:
            with self._lock:
                self._retry_timer = None
                if self._closed or not self._entries:
                    return
                self._start(True)

        timer = threading.Timer(self._delay(self._retries), retry)
        timer.daemon = True
        self._retry_timer = timer
        timer.start()

    def _recovering(self) -> None:
        for entry in self._entries.values():
            if entry.state.status != "error":
                entry.set_state(status="recovering", error=None)
                self._emit(entry)

    def _fail_all(self, error: ApiError) -> None:
        with self._lock:
            self._detach()
            self._token = None
            for entry in self._entries.values():
                self._fail(entry, error)

    def _fail(self, entry: Entry, error: ApiError) -> None:
        self._cancel_rejoin(entry)
        conn, entry.conn = entry.conn, None
        if conn:
            conn.leave(entry.topic)
        entry.set_state(status="error", data=None, error=error)
        self._emit(entry)

    def _detach(self) -> None:
        self._epoch += 1
        self._connecting_epoch = None
        if self._retry_timer:
            self._retry_timer.cancel()
            self._retry_timer = None
        conn, self._conn = self._conn, None
        for entry in self._entries.values():
            self._cancel_rejoin(entry)
            entry.conn = None
        if conn:
            conn.close()

    # ---- listener dispatch --------------------------------------------------------------

    def _emit(self, entry: Entry) -> None:
        for listener in list(entry.listeners):
            self._dispatch(listener, entry.state)

    def _dispatch(self, listener: Listener, state: SubscriptionState) -> None:
        if self._dispatcher is None:
            self._dispatcher = threading.Thread(target=self._drain, name="fyrlet-listeners", daemon=True)
            self._dispatcher.start()
        self._events.put((listener, state))

    def _drain(self) -> None:
        while (item := self._events.get()) is not None:
            try:
                item[0](item[1])
            except Exception as error:  # noqa: BLE001 - listener bugs must not break the client
                try:
                    if self._on_listener_error:
                        self._on_listener_error(error)
                except Exception:  # noqa: BLE001
                    pass

    def _assert_open(self) -> None:
        if self._closed:
            raise ApiError("CLIENT_CLOSED", "The client is closed")
