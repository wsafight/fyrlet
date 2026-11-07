"""Runs against a real Fyrlet inbox server. Start it with scripts/integration_sdks.sh."""

import json
import os
import threading
import time
import uuid

import pytest

from fyrlet import ApiError, Client, OutcomeUnknownError, SessionService

ENDPOINT = os.environ.get("INTEGRATION_ENDPOINT")
FIXTURES = os.environ.get("INTEGRATION_FIXTURES")
pytestmark = pytest.mark.skipif(not (ENDPOINT and FIXTURES), reason="needs INTEGRATION_ENDPOINT / INTEGRATION_FIXTURES")


@pytest.fixture(scope="module")
def projects():
    with open(FIXTURES) as handle:
        return json.load(handle)


@pytest.fixture
def make_user(projects):
    clients = []

    def make(project=0, subject=None, **extra):
        subject = subject or str(uuid.uuid4())
        service = SessionService(ENDPOINT, projects[project]["service_key"])
        session = service.issue_session(subject, ttl_seconds=600)
        client = Client(ENDPOINT, projects[project]["project_id"], lambda force: session.token,
                        retry_delay=lambda attempt: 0.05, **extra)
        clients.append(client)
        return client, session, subject

    yield make
    for client in clients:
        client.close()


def until(predicate, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.02)
    raise AssertionError("condition not reached")


def ready(sub):
    until(lambda: sub.get_state().status == "ready")


def test_call_idempotency_conflict_and_contract(make_user):
    client, _, _ = make_user()
    key = str(uuid.uuid4())
    item = client.call("inbox.add", {"text": "hello"}, idempotency_key=key)
    assert item["text"] == "hello"
    assert client.call("inbox.add", {"text": "hello"}, idempotency_key=key) == item
    with pytest.raises(ApiError) as conflict:
        client.call("inbox.add", {"text": "changed"}, idempotency_key=key)
    assert (conflict.value.code, conflict.value.status) == ("CONFLICT", 409)
    assert len(client.call("inbox.history", {})["items"]) == 1
    updated = client.call("inbox.update", {"id": item["id"], "text": "new", "expected_version": item["version"]})
    with pytest.raises(ApiError) as stale:
        client.call("inbox.update", {"id": item["id"], "text": "late", "expected_version": item["version"]})
    assert stale.value.code == "CONFLICT" and updated["text"] == "new"
    assert "inbox.add" in json.dumps(client.contract())


def test_subscription_snapshot_delta_refresh_and_shared_devices(make_user):
    first, _, subject = make_user()
    second, _, _ = make_user(subject=subject)
    left, right = first.subscribe("inbox.recent", {}), second.subscribe("inbox.recent", {})
    ready(left)
    ready(right)
    seen = []
    left.on_change(lambda state: seen.append(state.status))
    item = first.call("inbox.add", {"text": "shared"})
    until(lambda: any(r["id"] == item["id"] for r in left.get_state().data or []))
    until(lambda: any(r["id"] == item["id"] for r in right.get_state().data or []))
    first.call("inbox.update", {"id": item["id"], "text": "edited", "expected_version": item["version"]})
    until(lambda: (left.get_state().data or [{}])[0].get("text") == "edited")
    before = left.get_state().seq
    left.refresh()
    until(lambda: left.get_state().seq > before)
    assert seen[0] == "ready"
    left.unsubscribe()
    assert left.get_state().status == "closed" and left.get_state().data is None
    with pytest.raises(ApiError):
        left.refresh()


def test_authorization_isolation_between_projects_and_users(make_user):
    owner, _, _ = make_user()
    other, _, _ = make_user()
    foreign, _, _ = make_user(project=1)
    owner.call("inbox.add", {"text": "private"})
    for client in (other, foreign):
        sub = client.subscribe("inbox.recent", {})
        ready(sub)
        assert sub.get_state().data == []
        assert client.call("inbox.history", {})["items"] == []


def test_lost_response_is_unknown_then_recovered_without_a_second_write(make_user, monkeypatch):
    client, _, subject = make_user()
    from fyrlet import client as module
    real, writes = module.request, []

    def lossy(method, url, headers, body=None, *, timeout):
        envelope = real(method, url, headers, body, timeout=timeout)
        if url.endswith("/operations/inbox.add"):
            writes.append(1)
            raise ApiError("NETWORK_ERROR", "Injected response loss", retryable=True)
        return envelope

    monkeypatch.setattr(module, "request", lossy)
    mutation = client.mutate("inbox.add", {"text": "lost"})
    assert mutation.state.status == "unknown" and isinstance(mutation.state.error, OutcomeUnknownError)
    with pytest.raises(OutcomeUnknownError):
        mutation.result()
    state = mutation.recover()
    assert state.status == "committed" and state.data["text"] == "lost"
    assert len(writes) == 1
    monkeypatch.undo()
    assert len(client.call("inbox.history", {})["items"]) == 1
    other, _, _ = make_user()  # a stranger cannot see the receipt
    assert other.recover("inbox.add", {"text": "lost"}, idempotency_key=mutation.idempotency_key).status == "unknown"


def test_token_refresh_on_expired_session_and_revocation(projects, make_user):
    service = SessionService(ENDPOINT, projects[0]["service_key"])
    subject = str(uuid.uuid4())
    old = service.issue_session(subject)
    assert service.revoke_session(old.session_id)
    calls = []

    def get_token(force):
        calls.append(force)
        return service.issue_session(subject).token if force else old.token

    client = Client(ENDPOINT, projects[0]["project_id"], get_token)
    try:
        assert client.call("inbox.history", {})["items"] == []
        assert calls == [False, True]
        # Subscriptions end with an error once the session is revoked and no new one can be issued.
        revoked = service.issue_session(subject)

        def refused(force):
            if force:
                raise ApiError("UNAUTHENTICATED", "logged out")
            return revoked.token

        dead = Client(ENDPOINT, projects[0]["project_id"], refused)
        sub = dead.subscribe("inbox.recent", {})
        ready(sub)
        service.revoke_session(revoked.session_id)
        until(lambda: sub.get_state().status == "error")
        assert sub.get_state().data is None and sub.get_state().error.code == "UNAUTHENTICATED"
        dead.close()
    finally:
        client.close()


def test_account_switch_is_rejected(projects):
    service = SessionService(ENDPOINT, projects[0]["service_key"])
    first = service.issue_session(str(uuid.uuid4()))
    second = service.issue_session(str(uuid.uuid4()))
    # After A's session is revoked the refresh yields B's identity on the same client.
    client = Client(ENDPOINT, projects[0]["project_id"], lambda force: second.token if force else first.token)
    try:
        client.call("inbox.history", {})
        service.revoke_session(first.session_id)
        with pytest.raises(ApiError) as caught:
            client.call("inbox.history", {})
        assert caught.value.code == "FORBIDDEN"
    finally:
        client.close()


def test_subscription_recovers_after_connection_loss_and_close_releases(make_user):
    client, _, _ = make_user()
    sub = client.subscribe("inbox.recent", {})
    ready(sub)
    item = client.call("inbox.add", {"text": "before"})
    until(lambda: sub.get_state().data)
    states = []
    sub.on_change(lambda s: states.append(s.status))
    first_generation = sub.get_state().generation
    client._conn._ws.close()  # simulate a dropped socket
    until(lambda: "recovering" in states)
    ready(sub)
    state = sub.get_state()
    assert state.generation != first_generation
    assert [r["id"] for r in state.data] == [item["id"]]
    client.close()
    assert sub.get_state().status == "closed"
    assert threading.active_count() < 20
    with pytest.raises(ApiError) as closed:
        client.call("inbox.history", {})
    assert closed.value.code == "CLIENT_CLOSED"


def test_listener_errors_do_not_break_the_client(make_user):
    errors = []
    client, _, _ = make_user(on_listener_error=errors.append)
    sub = client.subscribe("inbox.recent", {})

    def bad(_):
        raise RuntimeError("boom")

    sub.on_change(bad)
    ready(sub)
    until(lambda: errors)
