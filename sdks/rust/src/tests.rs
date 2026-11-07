//! In-crate unit tests for protocol helpers and the subscription state machine.

use crate::client::endpoint_url;
use crate::delta::apply_delta;
use crate::errors::{channel_error, Error, OutcomeUnknownError};
use crate::phoenix::{auth_protocol, decode_frames, socket_url};
use crate::subscription::{Entry, Identity, SubscriptionStatus};
use serde_json::{json, Value};

fn value(raw: &str) -> Value {
    serde_json::from_str(raw).expect("valid test JSON")
}

#[test]
fn delta_changes_and_clears_without_mutating_input() {
    let view = value(r#"[{"id":"a","text":"x","note":"n"},{"id":"b","text":"y"}]"#);
    let out = apply_delta(&view, &value(r#"{"c":[["a",{"text":"z"},["note"]]]}"#)).unwrap();
    assert_eq!(
        Value::Array(out),
        value(r#"[{"id":"a","text":"z"},{"id":"b","text":"y"}]"#)
    );
    assert_eq!(
        view,
        value(r#"[{"id":"a","text":"x","note":"n"},{"id":"b","text":"y"}]"#)
    );
}

#[test]
fn delta_null_is_not_deletion_and_reorder_works() {
    let out = apply_delta(
        &value(r#"[{"id":"a","t":1}]"#),
        &value(r#"{"c":[["a",{"t":null}]]}"#),
    )
    .unwrap();
    assert_eq!(Value::Array(out), value(r#"[{"id":"a","t":null}]"#));

    let out = apply_delta(
        &value(r#"[{"id":"a"},{"id":"b"}]"#),
        &value(r#"{"r":["a"],"a":[{"id":"c"}],"o":["c","b"]}"#),
    )
    .unwrap();
    assert_eq!(Value::Array(out), value(r#"[{"id":"c"},{"id":"b"}]"#));
}

#[test]
fn delta_rejects_invalid_patches() {
    for patch in [
        r#"{"x":[]}"#,
        r#"{"r":["missing"],"o":["a"]}"#,
        r#"{"a":[{"id":"a"}],"o":["a"]}"#,
        r#"{"c":[["a",{"id":"a"}]]}"#,
        r#"{"c":[["a",{"t":1},["t"]]]}"#,
        r#"{"c":[["a",{"t":1}],["a",{"t":2}]]}"#,
        r#"{"r":["a"]}"#,
        r#"{"c":[["zzz",{"t":1}]]}"#,
    ] {
        assert!(
            apply_delta(&value(r#"[{"id":"a","t":0}]"#), &value(patch)).is_err(),
            "accepted {patch}"
        );
    }
}

#[test]
fn decodes_single_and_batch_frames() {
    let frame = r#"[null,"1","t","e",{}]"#;
    let frames = decode_frames(frame.as_bytes()).unwrap();
    assert_eq!(frames.len(), 1);
    assert_eq!(frames[0].topic, "t");
    assert_eq!(frames[0].event, "e");
    assert!(frames[0].join_ref.is_none());
    assert_eq!(frames[0].reference.as_deref(), Some("1"));

    let batch = format!(r#"{{"batch":[{frame},{frame}]}}"#);
    assert_eq!(decode_frames(batch.as_bytes()).unwrap().len(), 2);
}

#[test]
fn rejects_invalid_frames() {
    let mut oversized = String::from(r#"{"batch":["#);
    for index in 0..65 {
        if index > 0 {
            oversized.push(',');
        }
        oversized.push_str(r#"[null,"1","t","e",{}]"#);
    }
    oversized.push_str("]}");

    for raw in [
        "[]",
        r#"{"batch":[]}"#,
        oversized.as_str(),
        r#"{"batch":[[null,"1","t","e",{}]],"x":1}"#,
        "[1,2]",
        r#"[null,null,"t","e",[]]"#,
        r#"[null,null,"t","e",null]"#,
        "nope",
    ] {
        assert!(decode_frames(raw.as_bytes()).is_err(), "accepted {raw}");
    }
}

#[test]
fn builds_socket_url_and_auth_protocol() {
    assert_eq!(
        socket_url("https://x.test", "p1"),
        "wss://x.test/socket/websocket?project_id=p1&vsn=2.0.0"
    );
    assert_eq!(auth_protocol("rts_abc"), "base64url.bearer.phx.cnRzX2FiYw");
}

#[test]
fn validates_endpoints() {
    assert_eq!(
        endpoint_url("http://localhost:4000/").unwrap(),
        "http://localhost:4000"
    );
    for bad in [
        "ftp://x",
        "http://u:p@x",
        "http://x?a=1",
        "http://x#f",
        "nope",
    ] {
        assert!(endpoint_url(bad).is_err(), "accepted {bad}");
    }
}

#[test]
fn parses_channel_and_unknown_outcome_errors() {
    let error = channel_error(&value(
        r#"{"error":{"code":"CONFLICT","message":"m"},"status":409}"#,
    ));
    assert_eq!(error.code, "CONFLICT");
    assert_eq!(error.status, 409);
    assert!(!error.retryable);
    assert_eq!(
        channel_error(&value(r#"{"nope":1}"#)).code,
        "PROTOCOL_ERROR"
    );

    let unknown = OutcomeUnknownError::new(
        "op",
        "key",
        crate::errors::APIError::new("TIMEOUT", "t", true),
    );
    assert_eq!(unknown.cause.code, "TIMEOUT");
    assert_eq!(unknown.idempotency_key, "key");
    let wrapped = Error::OutcomeUnknown(Box::new(unknown));
    assert_eq!(wrapped.code(), "TIMEOUT");
    assert!(!wrapped.is_retryable());
}

fn snapshot(overrides: &[(&str, Value)]) -> Value {
    let mut base = json!({
        "protocol_version": 1,
        "subscription_id": "s",
        "project_id": "p",
        "subject_id": "u",
        "generation": "g1",
        "seq": 1,
        "data": [{"id": "a"}],
        "delivery": "delta-v1"
    });
    let object = base.as_object_mut().expect("snapshot object");
    for (key, value) in overrides {
        object.insert((*key).to_string(), value.clone());
    }
    base
}

fn identity() -> Identity {
    Identity::new("p", "u")
}

fn entry() -> Entry {
    Entry::new("s", "n", json!({}), true)
}

#[test]
fn entry_snapshot_and_delta_flow() {
    let mut subject = entry();
    let ack = subject
        .apply_snapshot(&snapshot(&[]), Some(&identity()), true)
        .unwrap()
        .expect("ack");
    assert_eq!((ack.generation.as_str(), ack.seq), ("g1", 1));
    assert_eq!(subject.state().status, SubscriptionStatus::Ready);

    let ack = subject
        .apply_delta(&value(
            r#"{"g":"g1","b":1,"s":2,"p":{"c":[["a",{"t":1}]]}}"#,
        ))
        .unwrap()
        .expect("ack");
    assert_eq!(ack.seq, 2);
    assert_eq!(subject.state().seq, 2);
    assert_eq!(subject.state().data, Some(value(r#"[{"id":"a","t":1}]"#)));

    // A duplicate is re-acknowledged; another generation is ignored; a gap asks for a reconnect.
    let duplicate = subject
        .apply_delta(&value(r#"{"g":"g1","b":1,"s":2,"p":{}}"#))
        .unwrap();
    assert_eq!(duplicate.map(|ack| ack.seq), Some(2));
    let stale = subject
        .apply_delta(&value(r#"{"g":"old","b":1,"s":2,"p":{}}"#))
        .unwrap();
    assert!(stale.is_none());
    let gap = subject.apply_delta(&value(r#"{"g":"g1","b":3,"s":4,"p":{}}"#));
    assert_eq!(gap.unwrap_err().code(), "RECONNECT");
}

#[test]
fn entry_rejects_foreign_snapshots() {
    for overrides in [
        vec![("subject_id", json!("other"))],
        vec![("subscription_id", json!("x"))],
        vec![("seq", json!(0))],
        vec![("protocol_version", json!(2))],
    ] {
        let mut subject = entry();
        let error = subject
            .apply_snapshot(&snapshot(&overrides), Some(&identity()), true)
            .unwrap_err();
        assert_eq!(error.code(), "PROTOCOL_ERROR");
    }
}

#[test]
fn entry_rejects_unnegotiated_deltas() {
    let mut subject = entry();
    subject
        .apply_snapshot(
            &snapshot(&[("delivery", json!("snapshot"))]),
            Some(&identity()),
            true,
        )
        .unwrap();
    let error = subject
        .apply_delta(&value(r#"{"g":"g1","b":1,"s":2,"p":{}}"#))
        .unwrap_err();
    assert_eq!(error.code(), "PROTOCOL_ERROR");
}

#[derive(Debug, serde::Deserialize)]
struct Item {
    id: String,
    text: String,
}

#[test]
fn decodes_state_into_user_type() {
    let mut subject = entry();
    subject
        .apply_snapshot(
            &snapshot(&[("data", json!([{"id":"a","text":"hi"}]))]),
            Some(&identity()),
            true,
        )
        .unwrap();
    let items: Vec<Item> = subject.state().decode().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].id, "a");
    assert_eq!(items[0].text, "hi");
}
