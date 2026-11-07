//! Subscription state machine: snapshots, deltas and the values handed to listeners.

use crate::client::Client;
use crate::delta::apply_delta;
use crate::errors::{APIError, Error};
use crate::phoenix::Connection;
use serde::de::DeserializeOwned;
use serde_json::Value;
use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};

/// The protocol version understood by this SDK.
pub const PROTOCOL_VERSION: i64 = 1;

/// The lifecycle of a subscription.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SubscriptionStatus {
    /// The initial connection is being established.
    Connecting,
    /// The subscription holds a current snapshot.
    Ready,
    /// The connection is being rebuilt; the previous data is retained.
    Recovering,
    /// Terminal: data is cleared and `error` explains why.
    Error,
    /// Terminal: the subscription or the client was closed.
    Closed,
}

impl SubscriptionStatus {
    /// The wire spelling of this status.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Connecting => "connecting",
            Self::Ready => "ready",
            Self::Recovering => "recovering",
            Self::Error => "error",
            Self::Closed => "closed",
        }
    }
}

impl std::fmt::Display for SubscriptionStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// What listeners see. Data is decoded JSON and must be treated as read-only; later deltas never
/// modify a previously delivered value.
#[derive(Debug, Clone, PartialEq)]
pub struct SubscriptionState {
    /// The current lifecycle status.
    pub status: SubscriptionStatus,
    /// The current view, retained while recovering and cleared on `error`/`closed`.
    pub data: Option<Value>,
    /// The terminal error, when the subscription failed.
    pub error: Option<APIError>,
    /// The generation confirmed by the current join.
    pub generation: Option<String>,
    /// The last applied sequence number.
    pub seq: i64,
}

impl Default for SubscriptionState {
    fn default() -> Self {
        Self {
            status: SubscriptionStatus::Connecting,
            data: None,
            error: None,
            generation: None,
            seq: 0,
        }
    }
}

impl SubscriptionState {
    /// Copies the current data into a value of your own record type.
    pub fn decode<T: DeserializeOwned>(&self) -> Result<T, Error> {
        let data = self.data.as_ref().ok_or_else(|| {
            Error::api(
                "PROTOCOL_ERROR",
                "The subscription has no data to decode",
                false,
            )
        })?;
        serde_json::from_value(data.clone()).map_err(|error| {
            Error::api(
                "PROTOCOL_ERROR",
                format!("Invalid subscription data: {error}"),
                false,
            )
        })
    }
}

/// The identity a client is bound to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Identity {
    /// The project the user token belongs to.
    pub project_id: String,
    /// The authenticated subject.
    pub subject_id: String,
}

impl Identity {
    /// Creates an identity.
    pub fn new(project_id: impl Into<String>, subject_id: impl Into<String>) -> Self {
        Self {
            project_id: project_id.into(),
            subject_id: subject_id.into(),
        }
    }
}

/// An acknowledgement to send for an applied snapshot or delta.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ack {
    /// The generation the acknowledgement belongs to.
    pub generation: String,
    /// The acknowledged sequence number.
    pub seq: i64,
}

/// One realtime subscription's mutable state. Public only for the crate's state-machine tests;
/// normally obtained through [`Client::subscribe`].
pub struct Entry {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) params: Value,
    pub(crate) want_delta: bool,

    pub(crate) state: SubscriptionState,
    pub(crate) listeners: Vec<(u64, Listener)>,
    pub(crate) next_listener: u64,
    pub(crate) conn: Option<Arc<Connection>>,
    pub(crate) join_failures: u32,
    pub(crate) delta: bool,
    pub(crate) rejoin: Option<u64>,
}

impl Entry {
    /// Creates a subscription entry in the `connecting` state. Primarily useful for tests.
    #[doc(hidden)]
    pub fn new(
        id: impl Into<String>,
        name: impl Into<String>,
        params: Value,
        want_delta: bool,
    ) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            params,
            want_delta,
            state: SubscriptionState::default(),
            listeners: Vec::new(),
            next_listener: 0,
            conn: None,
            join_failures: 0,
            delta: false,
            rejoin: None,
        }
    }

    /// The current state.
    pub fn state(&self) -> &SubscriptionState {
        &self.state
    }

    /// The channel topic for this subscription.
    pub(crate) fn topic(&self) -> String {
        format!("subscription:{}", self.id)
    }

    /// Validates and applies an initial or later snapshot. Returns the acknowledgement to send.
    pub fn apply_snapshot(
        &mut self,
        payload: &Value,
        identity: Option<&Identity>,
        initial: bool,
    ) -> Result<Option<Ack>, Error> {
        let payload = payload.as_object().ok_or_else(invalid_snapshot)?;
        let generation = payload
            .get("generation")
            .and_then(Value::as_str)
            .ok_or_else(invalid_snapshot)?;
        let seq = payload
            .get("seq")
            .and_then(as_integer)
            .ok_or_else(invalid_snapshot)?;
        let version = payload.get("protocol_version").and_then(as_integer);
        let identity = identity.ok_or_else(invalid_snapshot)?;
        let subscription_id = payload.get("subscription_id").and_then(Value::as_str);
        let project_id = payload.get("project_id").and_then(Value::as_str);
        let subject_id = payload.get("subject_id").and_then(Value::as_str);
        if version != Some(PROTOCOL_VERSION)
            || subscription_id != Some(self.id.as_str())
            || project_id != Some(identity.project_id.as_str())
            || subject_id != Some(identity.subject_id.as_str())
            || seq < 1
            || !payload.contains_key("data")
        {
            return Err(invalid_snapshot());
        }

        if !initial && Some(generation) != self.state.generation.as_deref() {
            return Ok(None);
        }
        if initial {
            self.delta = payload.get("delivery").and_then(Value::as_str) == Some("delta-v1");
        }
        if initial || seq > self.state.seq {
            self.state = SubscriptionState {
                status: SubscriptionStatus::Ready,
                data: data_value(payload.get("data")),
                error: None,
                generation: Some(generation.to_string()),
                seq,
            };
        }
        Ok(Some(Ack {
            generation: generation.to_string(),
            seq,
        }))
    }

    /// Applies a delta. Returns the acknowledgement to send, `Ok(None)` for a stale generation, or
    /// an error with code `RECONNECT` when a sequence gap requires a full resnapshot.
    pub fn apply_delta(&mut self, payload: &Value) -> Result<Option<Ack>, Error> {
        let payload = payload
            .as_object()
            .ok_or_else(|| Error::api("PROTOCOL_ERROR", "Invalid subscription delta", false))?;
        let generation = match (
            self.state.generation.as_deref(),
            payload.get("g").and_then(Value::as_str),
        ) {
            (Some(current), Some(generation)) if current == generation => generation.to_string(),
            // A stale generation, or a delta before the initial snapshot, is ignored.
            _ => return Ok(None),
        };
        let seq = payload.get("s").and_then(as_integer);
        let base = payload.get("b").and_then(as_integer);
        let (seq, base) = match (seq, base) {
            (Some(seq), Some(base)) if self.delta && seq >= 2 && base >= 1 && seq == base + 1 => {
                (seq, base)
            }
            _ => {
                return Err(Error::api(
                    "PROTOCOL_ERROR",
                    "Invalid subscription delta sequence",
                    false,
                ))
            }
        };
        if seq <= self.state.seq {
            return Ok(Some(Ack { generation, seq }));
        }
        if base != self.state.seq {
            return Err(Error::api("RECONNECT", "sequence gap", true));
        }
        let current = self.state.data.clone().unwrap_or(Value::Null);
        let patch = payload.get("p").cloned().unwrap_or(Value::Null);
        let data = apply_delta(&current, &patch)
            .map_err(|_| Error::api("PROTOCOL_ERROR", "Invalid subscription delta", false))?;
        self.state = SubscriptionState {
            status: SubscriptionStatus::Ready,
            data: Some(Value::Array(data)),
            error: None,
            generation: Some(generation.clone()),
            seq,
        };
        Ok(Some(Ack { generation, seq }))
    }
}

fn invalid_snapshot() -> Error {
    Error::api("PROTOCOL_ERROR", "Invalid subscription snapshot", false)
}

fn data_value(value: Option<&Value>) -> Option<Value> {
    match value {
        None | Some(Value::Null) => None,
        Some(value) => Some(value.clone()),
    }
}

/// Converts a JSON number to an integer, accepting integral floats within the JavaScript safe range
/// (mirrors the Go SDK's `integer` helper).
pub(crate) fn as_integer(value: &Value) -> Option<i64> {
    let number = value.as_number()?;
    if let Some(value) = number.as_i64() {
        return Some(value);
    }
    if let Some(value) = number.as_u64() {
        return i64::try_from(value).ok();
    }
    let value = number.as_f64()?;
    if value.is_finite() && value.fract() == 0.0 && value.abs() <= 9_007_199_254_740_992.0 {
        Some(value as i64)
    } else {
        None
    }
}

/// A boxed listener invoked by the dedicated dispatcher thread.
pub(crate) type Listener = Arc<dyn Fn(SubscriptionState) + Send + Sync>;

/// A handle to one realtime subscription. All methods are safe for concurrent use.
#[derive(Clone)]
pub struct Subscription {
    pub(crate) client: Client,
    pub(crate) entry: Arc<Mutex<Entry>>,
    pub(crate) id: String,
}

impl Subscription {
    /// The current state.
    pub fn state(&self) -> SubscriptionState {
        lock(&self.entry).state.clone()
    }

    /// Registers a listener. It receives the current state first, then every change, serially on a
    /// dedicated dispatcher thread, so it may call back into the client. Dropping the returned
    /// guard removes the listener.
    pub fn on_change<F>(&self, listener: F) -> ListenerGuard
    where
        F: Fn(SubscriptionState) + Send + Sync + 'static,
    {
        let listener: Listener = Arc::new(listener);
        let (state, id) = {
            let mut entry = lock(&self.entry);
            let id = entry.next_listener;
            entry.next_listener += 1;
            entry.listeners.push((id, listener.clone()));
            (entry.state.clone(), id)
        };
        self.client.dispatch(listener, state);
        ListenerGuard {
            entry: self.entry.clone(),
            id,
        }
    }

    /// Asks the server for a fresh snapshot. It returns once the server accepted the request; the
    /// data arrives through [`on_change`](Self::on_change).
    pub fn refresh(&self) -> Result<(), Error> {
        self.client.refresh(&self.entry)
    }

    /// Ends this subscription. It is safe to call more than once.
    pub fn unsubscribe(&self) {
        self.client.unsubscribe(&self.entry, &self.id);
    }
}

/// Removes a listener when dropped.
pub struct ListenerGuard {
    entry: Arc<Mutex<Entry>>,
    id: u64,
}

impl Drop for ListenerGuard {
    fn drop(&mut self) {
        let mut entry = lock(&self.entry);
        entry.listeners.retain(|(id, _)| *id != self.id);
    }
}

/// A FIFO job queue drained by one dedicated thread.
pub(crate) struct Dispatcher {
    inner: Arc<DispatcherInner>,
}

struct DispatcherInner {
    state: Mutex<DispatcherState>,
    ready: Condvar,
}

struct DispatcherState {
    queue: VecDeque<Box<dyn FnOnce() + Send + 'static>>,
    closed: bool,
}

impl Dispatcher {
    pub(crate) fn new() -> Self {
        let inner = Arc::new(DispatcherInner {
            state: Mutex::new(DispatcherState {
                queue: VecDeque::new(),
                closed: false,
            }),
            ready: Condvar::new(),
        });
        let worker = inner.clone();
        std::thread::Builder::new()
            .name("fyrlet-listeners".to_string())
            .spawn(move || run_dispatcher(worker))
            .expect("failed to spawn the listener dispatcher");
        Self { inner }
    }

    pub(crate) fn post(&self, job: Box<dyn FnOnce() + Send + 'static>) {
        let mut state = lock(&self.inner.state);
        if !state.closed {
            state.queue.push_back(job);
            self.inner.ready.notify_one();
        }
    }

    pub(crate) fn stop(&self) {
        let mut state = lock(&self.inner.state);
        state.closed = true;
        self.inner.ready.notify_all();
    }
}

fn run_dispatcher(inner: Arc<DispatcherInner>) {
    loop {
        let job = {
            let mut state = lock(&inner.state);
            loop {
                if let Some(job) = state.queue.pop_front() {
                    break Some(job);
                }
                if state.closed {
                    break None;
                }
                state = match inner.ready.wait(state) {
                    Ok(state) => state,
                    Err(error) => error.into_inner(),
                };
            }
        };
        match job {
            Some(job) => job(),
            None => return,
        }
    }
}

pub(crate) fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|error| error.into_inner())
}
