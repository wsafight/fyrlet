import json

import pytest

from fyrlet.delta import InvalidDelta, apply_delta
from fyrlet.errors import ApiError, OutcomeUnknownError, channel_error
from fyrlet.http import endpoint_url
from fyrlet.phoenix import auth_protocol, decode_frames, socket_url
from fyrlet.subscription import Entry


def rec(id, **fields):
    return {"id": id, **fields}


def test_delta_changes_fields_and_clears_without_mutating_input():
    view = [rec("a", text="x", note="n"), rec("b", text="y")]
    out = apply_delta(view, {"c": [["a", {"text": "z"}, ["note"]]]})
    assert out == [rec("a", text="z"), rec("b", text="y")]
    assert view[0] == rec("a", text="x", note="n")
    assert out[1] is view[1]


def test_delta_null_is_not_a_deletion():
    assert apply_delta([rec("a", t=1)], {"c": [["a", {"t": None}]]}) == [rec("a", t=None)]


def test_delta_add_remove_reorder():
    view = [rec("a"), rec("b")]
    out = apply_delta(view, {"r": ["a"], "a": [rec("c")], "o": ["c", "b"]})
    assert [r["id"] for r in out] == ["c", "b"]


@pytest.mark.parametrize(
    "patch",
    [
        {"x": []},
        {"r": ["missing"], "o": ["a"]},
        {"a": [rec("a")], "o": ["a"]},
        {"c": [["a", {"id": "a"}]]},
        {"c": [["a", {"t": 1}, ["t"]]]},
        {"c": [["a", {"t": 1}], ["a", {"t": 2}]]},
        {"r": ["a"]},  # membership changed without an order
        {"c": [["zzz", {"t": 1}]]},
    ],
)
def test_delta_rejects_invalid_patches(patch):
    with pytest.raises(InvalidDelta):
        apply_delta([rec("a", t=0)], patch)


def test_frames_single_and_batch_validation():
    frame = [None, "1", "t", "e", {}]
    assert decode_frames(json.dumps(frame)) == [tuple(frame)]
    assert len(decode_frames(json.dumps({"batch": [frame, frame]}))) == 2
    for bad in ([], {"batch": []}, {"batch": [frame] * 65}, {"batch": [frame], "x": 1}, [1, 2], [None, None, "t", "e", []]):
        with pytest.raises(ValueError):
            decode_frames(json.dumps(bad))


def test_socket_url_and_auth_protocol():
    assert socket_url("https://x.test", "p1") == "wss://x.test/socket/websocket?project_id=p1&vsn=2.0.0"
    assert auth_protocol("rts_abc") == "base64url.bearer.phx.cnRzX2FiYw"


def test_endpoint_validation():
    assert endpoint_url("http://localhost:4000/") == "http://localhost:4000"
    for bad in ("ftp://x", "http://u:p@x", "http://x?a=1", "http://x#f", "nope"):
        with pytest.raises(ValueError):
            endpoint_url(bad)


def test_errors():
    err = channel_error({"error": {"code": "CONFLICT", "message": "m", "retryable": False}, "status": 409})
    assert (err.code, err.status) == ("CONFLICT", 409)
    assert channel_error({"nope": 1}).code == "PROTOCOL_ERROR"
    unknown = OutcomeUnknownError("op", "key", ApiError("TIMEOUT", "t", retryable=True))
    assert (unknown.outcome, unknown.idempotency_key, unknown.retryable, unknown.code) == ("unknown", "key", False, "TIMEOUT")


def snapshot(**over):
    base = {"protocol_version": 1, "subscription_id": "s", "project_id": "p", "subject_id": "u",
            "generation": "g1", "seq": 1, "data": [rec("a")], "delivery": "delta-v1"}
    return {**base, **over}


IDENTITY = {"project_id": "p", "subject_id": "u"}


def test_entry_snapshot_delta_flow():
    entry = Entry("s", "inbox.recent", {}, True)
    assert entry.apply_snapshot(snapshot(), IDENTITY, True) == ("g1", 1)
    assert entry.state.status == "ready"
    assert entry.apply_delta({"g": "g1", "b": 1, "s": 2, "p": {"c": [["a", {"t": 1}]]}}) == ("g1", 2)
    assert entry.state.data == [rec("a", t=1)] and entry.state.seq == 2
    # duplicate is re-acknowledged, other generation ignored, gap asks for a reconnect
    assert entry.apply_delta({"g": "g1", "b": 1, "s": 2, "p": {}}) == ("g1", 2)
    assert entry.apply_delta({"g": "old", "b": 1, "s": 2, "p": {}}) is None
    assert entry.apply_delta({"g": "g1", "b": 3, "s": 4, "p": {}}) == "reconnect"


def test_entry_rejects_foreign_snapshots_and_bad_deltas():
    entry = Entry("s", "n", {}, True)
    for over in ({"subject_id": "other"}, {"subscription_id": "x"}, {"seq": 0}, {"protocol_version": 2}):
        with pytest.raises(ApiError) as caught:
            entry.apply_snapshot(snapshot(**over), IDENTITY, True)
        assert caught.value.code == "PROTOCOL_ERROR"
    entry.apply_snapshot(snapshot(delivery="snapshot"), IDENTITY, True)
    with pytest.raises(ApiError):  # deltas were not negotiated
        entry.apply_delta({"g": "g1", "b": 1, "s": 2, "p": {}})
