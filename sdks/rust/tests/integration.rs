//! Runs against a real Fyrlet inbox server. Start it with `scripts/integration_sdks.sh rust`.
//! Every test returns early when `INTEGRATION_ENDPOINT` or `INTEGRATION_FIXTURES` is unset.

use fyrlet::{
    Client, Error, IssueSessionInput, Options, SessionService, Subscription, SubscriptionStatus,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use uuid::Uuid;

#[derive(Debug, Clone, Deserialize)]
struct Project {
    #[serde(rename = "project_id")]
    project_id: String,
    #[serde(rename = "service_key")]
    service_key: String,
}

#[derive(Debug, Clone, Deserialize)]
struct Item {
    id: String,
    text: String,
    version: i64,
}

struct Harness {
    endpoint: String,
    projects: Vec<Project>,
}

impl Harness {
    fn setup() -> Option<Self> {
        let endpoint = std::env::var("INTEGRATION_ENDPOINT").ok()?;
        let fixtures = std::env::var("INTEGRATION_FIXTURES").ok()?;
        let raw = std::fs::read_to_string(&fixtures)
            .unwrap_or_else(|error| panic!("cannot read {fixtures}: {error}"));
        let projects: Vec<Project> = serde_json::from_str(&raw)
            .unwrap_or_else(|error| panic!("invalid fixtures {fixtures}: {error}"));
        if endpoint.is_empty() || projects.is_empty() {
            return None;
        }
        Some(Self { endpoint, projects })
    }

    fn service(&self, index: usize) -> SessionService {
        SessionService::new(&self.endpoint, &self.projects[index].service_key)
            .expect("a valid service key")
    }

    fn session(&self, index: usize, subject: &str) -> (SessionService, fyrlet::UserSession) {
        let service = self.service(index);
        let session = service
            .issue_session(IssueSessionInput::new(subject).with_ttl_seconds(600))
            .expect("a session");
        (service, session)
    }

    fn client(&self, index: usize, token: String) -> TestUser {
        let client = Client::new(Options::new(
            self.endpoint.clone(),
            self.projects[index].project_id.clone(),
            move |_force_refresh| Ok(token.clone()),
        ))
        .expect("a client");
        TestUser { client }
    }
}

struct TestUser {
    client: Client,
}

impl Drop for TestUser {
    fn drop(&mut self) {
        self.client.close();
    }
}

fn user_name(prefix: &str) -> String {
    format!("{prefix}-{}", Uuid::new_v4())
}

fn until(what: &str, mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if condition() {
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    panic!("condition not reached: {what}");
}

fn ready(subscription: &Subscription) {
    until("subscription ready", || {
        subscription.state().status == SubscriptionStatus::Ready
    });
}

fn items(subscription: &Subscription) -> Vec<Item> {
    subscription.state().decode().unwrap_or_default()
}

fn has(items: &[Item], id: &str, text: &str) -> bool {
    items.iter().any(|item| item.id == id && item.text == text)
}

#[test]
fn call_idempotency_conflict_and_contract() {
    let Some(harness) = Harness::setup() else {
        return;
    };
    let (_, session) = harness.session(0, &user_name("user"));
    let user = harness.client(0, session.token);
    let key = format!("key-{}", Uuid::new_v4());
    let input = json!({"text": "hello"});

    let first: Item = user
        .client
        .call_into_with(
            "inbox.add",
            input.clone(),
            fyrlet::CallOptions::idempotency_key(key.clone()),
        )
        .expect("first add");
    let again: Item = user
        .client
        .call_into_with(
            "inbox.add",
            input.clone(),
            fyrlet::CallOptions::idempotency_key(key.clone()),
        )
        .expect("replay");
    assert_eq!(first.id, again.id);

    let conflict = user
        .client
        .call_with(
            "inbox.add",
            json!({"text": "changed"}),
            fyrlet::CallOptions::idempotency_key(key.clone()),
        )
        .expect_err("a conflicting input");
    assert_eq!(conflict.code(), "CONFLICT");
    assert_eq!(conflict.api_error().status, 409);

    let history: Value = user
        .client
        .call("inbox.history", Value::Null)
        .expect("history");
    assert_eq!(history["items"].as_array().map(Vec::len), Some(1));

    user.client
        .call(
            "inbox.update",
            json!({"id": first.id, "text": "new", "expected_version": first.version}),
        )
        .expect("update");
    let stale = user
        .client
        .call(
            "inbox.update",
            json!({"id": first.id, "text": "late", "expected_version": first.version}),
        )
        .expect_err("a stale version");
    assert_eq!(stale.code(), "CONFLICT");

    let contract = user.client.contract().expect("contract");
    assert!(contract.to_string().contains("inbox.add"));
}

#[test]
fn subscription_snapshot_delta_refresh_and_shared_devices() {
    let Some(harness) = Harness::setup() else {
        return;
    };
    let subject = user_name("shared");
    let (_, first) = harness.session(0, &subject);
    let (_, second) = harness.session(0, &subject);
    let left_client = harness.client(0, first.token);
    let right_client = harness.client(0, second.token);

    let left = left_client
        .client
        .subscribe("inbox.recent", json!({"limit": 20}))
        .expect("left subscription");
    let right = right_client
        .client
        .subscribe("inbox.recent", json!({"limit": 20}))
        .expect("right subscription");
    ready(&left);
    ready(&right);

    let seen = Arc::new(Mutex::new(Vec::new()));
    let recorder = seen.clone();
    let _guard = left.on_change(move |state| recorder.lock().unwrap().push(state.status));

    let created: Item = left_client
        .client
        .call_into("inbox.add", json!({"text": "shared"}))
        .expect("add");
    until("left sees the item", || {
        has(&items(&left), &created.id, "shared")
    });
    until("right sees the item", || {
        has(&items(&right), &created.id, "shared")
    });

    left_client
        .client
        .call(
            "inbox.update",
            json!({"id": created.id, "text": "edited", "expected_version": created.version}),
        )
        .expect("update");
    until("delta applied", || {
        items(&left).iter().any(|item| item.text == "edited")
    });

    let before = left.state().seq;
    left.refresh().expect("refresh");
    until("refresh snapshot", || left.state().seq > before);
    until("listener saw the current state", || {
        !seen.lock().unwrap().is_empty()
    });
    assert_eq!(seen.lock().unwrap()[0], SubscriptionStatus::Ready);

    left.unsubscribe();
    assert_eq!(left.state().status, SubscriptionStatus::Closed);
    assert!(left.state().data.is_none());
    assert_eq!(left.refresh().unwrap_err().code(), "NOT_READY");
}

#[test]
fn authorization_isolation() {
    let Some(harness) = Harness::setup() else {
        return;
    };
    let (_, owner) = harness.session(0, &user_name("owner"));
    let owner = harness.client(0, owner.token);
    owner
        .client
        .call("inbox.add", json!({"text": "private"}))
        .expect("add");

    for index in 0..harness.projects.len().min(2) {
        let (_, session) = harness.session(index, &user_name("other"));
        let other = harness.client(index, session.token);
        let subscription = other
            .client
            .subscribe("inbox.recent", Value::Null)
            .expect("subscription");
        ready(&subscription);
        assert!(
            items(&subscription).is_empty(),
            "subscription leaked another user's data"
        );
        let history: Value = other
            .client
            .call("inbox.history", Value::Null)
            .expect("history");
        assert!(history["items"]
            .as_array()
            .map_or(true, |items| items.is_empty()));
    }
}

#[test]
fn token_refresh_and_revocation() {
    let Some(harness) = Harness::setup() else {
        return;
    };
    let service = harness.service(0);
    let subject = user_name("refresh");
    let old = service
        .issue_session(IssueSessionInput::new(subject.clone()).with_ttl_seconds(600))
        .expect("old session");
    assert!(service.revoke_session(&old.session_id).expect("revoke"));

    let calls = Arc::new(Mutex::new(Vec::new()));
    let service = Arc::new(service);
    let recorder = calls.clone();
    let issuer = service.clone();
    let issuer_subject = subject.clone();
    let old_token = old.token.clone();
    let client = Client::new(Options::new(
        harness.endpoint.clone(),
        harness.projects[0].project_id.clone(),
        move |force| {
            recorder.lock().unwrap().push(force);
            if force {
                Ok(issuer
                    .issue_session(
                        IssueSessionInput::new(issuer_subject.clone()).with_ttl_seconds(600),
                    )?
                    .token)
            } else {
                Ok(old_token.clone())
            }
        },
    ))
    .expect("client");
    client
        .call("inbox.history", Value::Null)
        .expect("a refreshed call");
    assert_eq!(*calls.lock().unwrap(), vec![false, true]);
    client.close();

    let live = service
        .issue_session(IssueSessionInput::new(subject).with_ttl_seconds(600))
        .expect("live session");
    let live_token = live.token.clone();
    let dead = Client::new(Options::new(
        harness.endpoint.clone(),
        harness.projects[0].project_id.clone(),
        move |force| {
            if force {
                Err(Error::api("UNAUTHENTICATED", "logged out", false))
            } else {
                Ok(live_token.clone())
            }
        },
    ))
    .expect("client");
    let subscription = dead
        .subscribe("inbox.recent", Value::Null)
        .expect("subscription");
    ready(&subscription);
    service
        .revoke_session(&live.session_id)
        .expect("revoke live session");
    until("terminal error", || {
        subscription.state().status == SubscriptionStatus::Error
    });
    let state = subscription.state();
    assert!(state.data.is_none());
    assert_eq!(
        state.error.map(|error| error.code),
        Some("UNAUTHENTICATED".to_string())
    );
    dead.close();
}

#[test]
fn account_switch_is_rejected() {
    let Some(harness) = Harness::setup() else {
        return;
    };
    let service = harness.service(0);
    let a = service
        .issue_session(IssueSessionInput::new(user_name("a")).with_ttl_seconds(600))
        .expect("a");
    let b = service
        .issue_session(IssueSessionInput::new(user_name("b")).with_ttl_seconds(600))
        .expect("b");
    let a_token = a.token.clone();
    let b_token = b.token.clone();
    let client = Client::new(Options::new(
        harness.endpoint.clone(),
        harness.projects[0].project_id.clone(),
        move |force| {
            Ok(if force {
                b_token.clone()
            } else {
                a_token.clone()
            })
        },
    ))
    .expect("client");
    client
        .call("inbox.history", Value::Null)
        .expect("first call");
    service.revoke_session(&a.session_id).expect("revoke a");
    let error = client
        .call("inbox.history", Value::Null)
        .expect_err("the account changed");
    assert_eq!(error.code(), "FORBIDDEN");
    client.close();
}

#[test]
fn reconnect_and_close_release_resources() {
    let Some(harness) = Harness::setup() else {
        return;
    };
    let (_, session) = harness.session(0, &user_name("reconnect"));
    let user = harness.client(0, session.token);
    let subscription = user
        .client
        .subscribe("inbox.recent", Value::Null)
        .expect("subscription");
    ready(&subscription);
    let created: Item = user
        .client
        .call_into("inbox.add", json!({"text": "before"}))
        .expect("add");
    until("item arrives", || items(&subscription).len() == 1);

    let generation = subscription.state().generation.clone().expect("generation");
    user.client.reconnect().expect("reconnect");
    ready(&subscription);
    until("new generation", || {
        subscription.state().generation.as_deref() != Some(generation.as_str())
    });
    let current = items(&subscription);
    assert_eq!(current.len(), 1);
    assert_eq!(current[0].id, created.id);

    user.client.close();
    assert_eq!(subscription.state().status, SubscriptionStatus::Closed);
    assert_eq!(
        user.client
            .call("inbox.history", Value::Null)
            .unwrap_err()
            .code(),
        "CLIENT_CLOSED"
    );
    let subscribe_error = user
        .client
        .subscribe("inbox.recent", Value::Null)
        .err()
        .expect("a closed client");
    assert_eq!(subscribe_error.code(), "CLIENT_CLOSED");
}
