//! The Fyrlet client: authenticated operations plus recoverable realtime subscriptions.

use crate::errors::{
    as_api_error, channel_error, parse_wire_error, APIError, Error, OutcomeUnknownError,
};
use crate::phoenix::{self, Connection, FrameHandler};
use crate::subscription::{
    lock, Entry, Identity, Listener, Subscription, SubscriptionState, SubscriptionStatus,
};
use serde::de::DeserializeOwned;
use serde_json::{json, Map, Value};
use std::any::Any;
use std::collections::BTreeMap;
use std::io::Read;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use url::Url;
use uuid::Uuid;

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_JOIN_RETRIES: u32 = 10;
const RESPONSE_LIMIT: u64 = 16 << 20;

/// Returns a short-lived user session token beginning with `rts_`. With `force_refresh` set,
/// revalidate the host login and obtain a new session, or return an error with code
/// `UNAUTHENTICATED` to stop recovery.
pub type GetToken = Arc<dyn Fn(bool) -> Result<String, Error> + Send + Sync>;

/// Returns the backoff before reconnect attempt `attempt` (1-based).
pub type RetryDelay = Arc<dyn Fn(u32) -> Duration + Send + Sync>;

/// Generates idempotency keys and subscription IDs.
pub type NewId = Arc<dyn Fn() -> String + Send + Sync>;

/// Receives panics recovered from listeners.
pub type ListenerErrorHandler = Arc<dyn Fn(Box<dyn Any + Send>) + Send + Sync>;

/// Options configure a [`Client`].
#[derive(Clone)]
pub struct Options {
    /// HTTP(S) base URL of the Fyrlet server.
    pub endpoint: String,
    /// The project this client is bound to.
    pub project_id: String,
    /// Returns a short-lived user session token (`rts_...`).
    pub get_token: GetToken,
    /// Bounds each HTTP request and socket reply. Default 10 s.
    pub timeout: Duration,
    /// Returns the backoff before reconnect attempt n (1-based). Default 250 ms doubling to 30 s.
    pub retry_delay: Option<RetryDelay>,
    /// Request full snapshots only.
    pub disable_delta: bool,
    /// Optional capabilities to negotiate, as name -> version.
    pub capabilities: BTreeMap<String, u32>,
    /// Generates idempotency keys and subscription IDs. Default: random UUIDs.
    pub new_id: Option<NewId>,
    /// Receives panics recovered from listeners.
    pub on_listener_error: Option<ListenerErrorHandler>,
}

impl Options {
    /// Creates options with defaults and the required token callback.
    pub fn new<F>(endpoint: impl Into<String>, project_id: impl Into<String>, get_token: F) -> Self
    where
        F: Fn(bool) -> Result<String, Error> + Send + Sync + 'static,
    {
        Self {
            endpoint: endpoint.into(),
            project_id: project_id.into(),
            get_token: Arc::new(get_token),
            timeout: DEFAULT_TIMEOUT,
            retry_delay: None,
            disable_delta: false,
            capabilities: BTreeMap::new(),
            new_id: None,
            on_listener_error: None,
        }
    }
}

/// Options for one operation.
#[derive(Debug, Clone, Default)]
pub struct CallOptions {
    /// Reuses an idempotency key, for example when retrying after an unknown outcome.
    pub idempotency_key: Option<String>,
}

impl CallOptions {
    /// Creates empty call options.
    pub fn new() -> Self {
        Self::default()
    }

    /// Reuses an idempotency key.
    pub fn idempotency_key(key: impl Into<String>) -> Self {
        Self {
            idempotency_key: Some(key.into()),
        }
    }
}

/// The outcome of one operation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MutationStatus {
    /// A successful read.
    Completed,
    /// A write committed to the database.
    Committed,
    /// A Run or ingest was accepted for later execution.
    Accepted,
    /// A definite failure: nothing was written.
    Failed,
    /// The write was dispatched but its result was not seen. Use recovery.
    Unknown,
}

impl MutationStatus {
    /// The wire spelling of this status.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Completed => "completed",
            Self::Committed => "committed",
            Self::Accepted => "accepted",
            Self::Failed => "failed",
            Self::Unknown => "unknown",
        }
    }

    /// Parses a successful outcome. Returns `None` for anything else.
    pub fn from_outcome(outcome: &str) -> Option<Self> {
        match outcome {
            "completed" => Some(Self::Completed),
            "committed" => Some(Self::Committed),
            "accepted" => Some(Self::Accepted),
            _ => None,
        }
    }
}

impl std::fmt::Display for MutationStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// A snapshot of a [`Mutation`].
#[derive(Debug, Clone)]
pub struct MutationState {
    /// The current status.
    pub status: MutationStatus,
    /// The business result for a successful outcome.
    pub data: Option<Value>,
    /// The failure for a failed or unknown outcome.
    pub error: Option<Error>,
}

/// A stored receipt: `committed` or `accepted` with data, or `unknown`.
#[derive(Debug, Clone)]
pub struct RecoveryResult {
    /// The receipt status.
    pub status: MutationStatus,
    /// The original result, when a receipt was found.
    pub data: Option<Value>,
}

/// The outcome of one operation, kept so an unknown result can be recovered later.
pub struct Mutation {
    /// The idempotency key used for the original request.
    pub idempotency_key: String,
    state: Arc<Mutex<MutationState>>,
    lookup: Arc<dyn Fn() -> Result<RecoveryResult, Error> + Send + Sync>,
}

impl Mutation {
    /// The current outcome.
    pub fn state(&self) -> MutationState {
        lock(&self.state).clone()
    }

    /// The business result, or the original error.
    pub fn result(&self) -> Result<Value, Error> {
        let state = self.state();
        match state.status {
            MutationStatus::Completed | MutationStatus::Committed | MutationStatus::Accepted => {
                Ok(state.data.unwrap_or(Value::Null))
            }
            _ => Err(state.error.unwrap_or_else(|| {
                Error::api("PROTOCOL_ERROR", "The operation has no result", false)
            })),
        }
    }

    /// Queries the stored receipt of an unknown write without executing it again.
    pub fn recover(&self) -> Result<MutationState, Error> {
        let mut state = lock(&self.state);
        if state.status != MutationStatus::Unknown {
            return Ok(state.clone());
        }
        let found = (self.lookup)()?;
        if found.status != MutationStatus::Unknown {
            *state = MutationState {
                status: found.status,
                data: found.data,
                error: None,
            };
        }
        Ok(state.clone())
    }
}

/// A client bound to one project and one user. Cloning shares the same connection and state.
#[derive(Clone)]
pub struct Client {
    inner: Arc<ClientInner>,
}

struct ClientInner {
    opts: Options,
    endpoint: String,
    declared: BTreeMap<String, u32>,
    agent: ureq::Agent,
    events: crate::subscription::Dispatcher,
    token_mu: Mutex<()>,
    mu: Mutex<ClientState>,
    timer_seq: AtomicU64,
}

struct ClientState {
    entries: BTreeMap<String, Arc<Mutex<Entry>>>,
    conn: Option<Arc<Connection>>,
    identity: Option<Identity>,
    token: Option<String>,
    epoch: u64,
    connecting_epoch: Option<u64>,
    retries: u32,
    retry_timer: Option<u64>,
    closed: bool,
}

impl ClientState {
    fn new() -> Self {
        Self {
            entries: BTreeMap::new(),
            conn: None,
            identity: None,
            token: None,
            epoch: 0,
            connecting_epoch: None,
            retries: 0,
            retry_timer: None,
            closed: false,
        }
    }
}

impl Client {
    /// Validates the options and returns a client. No network access happens until first use.
    pub fn new(mut options: Options) -> Result<Self, Error> {
        let endpoint = endpoint_url(&options.endpoint)?;
        if options.project_id.is_empty() {
            return Err(Error::api(
                "VALIDATION_FAILED",
                "project_id is required",
                false,
            ));
        }
        for (name, version) in &options.capabilities {
            if !valid_capability_name(name) || *version < 1 {
                return Err(Error::api(
                    "VALIDATION_FAILED",
                    "capabilities must be names with a positive integer version",
                    false,
                ));
            }
        }
        if options.timeout.is_zero() {
            options.timeout = DEFAULT_TIMEOUT;
        }
        if options.new_id.is_none() {
            options.new_id = Some(Arc::new(|| Uuid::new_v4().to_string()));
        }
        let declared = options.capabilities.clone();
        let agent = ureq::AgentBuilder::new().redirects(0).build();
        Ok(Self {
            inner: Arc::new(ClientInner {
                opts: options,
                endpoint,
                declared,
                agent,
                events: crate::subscription::Dispatcher::new(),
                token_mu: Mutex::new(()),
                mu: Mutex::new(ClientState::new()),
                timer_seq: AtomicU64::new(0),
            }),
        })
    }

    // ---- operations ----------------------------------------------------------------------------

    /// Runs an operation and returns its business result.
    ///
    /// The SDK generates an idempotency key. After a network interruption the outcome of a write
    /// is unknown and the error is an [`Error::OutcomeUnknown`] carrying the key for recovery.
    pub fn call(&self, name: &str, input: Value) -> Result<Value, Error> {
        self.call_with(name, input, CallOptions::default())
    }

    /// [`call`](Self::call) with explicit options.
    pub fn call_with(
        &self,
        name: &str,
        input: Value,
        options: CallOptions,
    ) -> Result<Value, Error> {
        self.mutate_with(name, input, options).result()
    }

    /// [`call`](Self::call) decoding the result into `T`.
    pub fn call_into<T: DeserializeOwned>(&self, name: &str, input: Value) -> Result<T, Error> {
        self.call_into_with(name, input, CallOptions::default())
    }

    /// [`call_into`](Self::call_into) with explicit options.
    pub fn call_into_with<T: DeserializeOwned>(
        &self,
        name: &str,
        input: Value,
        options: CallOptions,
    ) -> Result<T, Error> {
        let data = self.call_with(name, input, options)?;
        serde_json::from_value(data).map_err(|error| {
            Error::api(
                "PROTOCOL_ERROR",
                format!("Invalid operation result: {error}"),
                false,
            )
        })
    }

    /// Starts an operation and returns its lifecycle without failing itself; inspect the returned
    /// [`Mutation`].
    pub fn mutate(&self, name: &str, input: Value) -> Mutation {
        self.mutate_with(name, input, CallOptions::default())
    }

    /// [`mutate`](Self::mutate) with explicit options.
    pub fn mutate_with(&self, name: &str, input: Value, options: CallOptions) -> Mutation {
        let key = options.idempotency_key.unwrap_or_else(|| self.new_id());
        let body = json!({"input": normalize_input(input)});
        let lookup: Arc<dyn Fn() -> Result<RecoveryResult, Error> + Send + Sync> = {
            let client = self.clone();
            let operation = name.to_string();
            let body = body.clone();
            let key = key.clone();
            Arc::new(move || client.recover_internal(&operation, &body, &key))
        };
        if let Err(error) = self.assert_open() {
            return failed_mutation(&key, &lookup, error);
        }
        let mut sent = false;
        let mut perform = |token: &str| -> Result<Envelope, Error> {
            sent = true;
            let result = self.http_request(
                "POST",
                &operation_path(name),
                token,
                Some(&body),
                Some(&key),
            );
            if let Err(error) = &result {
                let api = error.api_error();
                if api.status >= 400
                    && api.status < 500
                    && api.code != "PROTOCOL_ERROR"
                    && api.code != "HTTP_ERROR"
                {
                    // A definite rejection by the server means nothing was written.
                    sent = false;
                }
            }
            result
        };
        let result = self.execute(&mut perform);
        drop(perform);
        match result {
            Ok(envelope) => match envelope
                .outcome
                .as_deref()
                .and_then(MutationStatus::from_outcome)
            {
                Some(status) => Mutation {
                    idempotency_key: key,
                    state: Arc::new(Mutex::new(MutationState {
                        status,
                        data: if envelope.has_data {
                            Some(envelope.data)
                        } else {
                            None
                        },
                        error: None,
                    })),
                    lookup,
                },
                None => {
                    let error = Error::api("PROTOCOL_ERROR", "Invalid operation outcome", false);
                    if sent {
                        unknown_mutation(&key, &lookup, name, as_api_error(error))
                    } else {
                        failed_mutation(&key, &lookup, error)
                    }
                }
            },
            Err(error) => {
                if sent {
                    let cause = as_api_error(error);
                    unknown_mutation(&key, &lookup, name, cause)
                } else {
                    failed_mutation(&key, &lookup, error)
                }
            }
        }
    }

    /// Looks up the stored receipt of a write without executing it.
    pub fn recover(
        &self,
        name: &str,
        input: Value,
        idempotency_key: &str,
    ) -> Result<RecoveryResult, Error> {
        self.assert_open()?;
        let body = json!({"input": normalize_input(input)});
        self.recover_internal(name, &body, idempotency_key)
    }

    /// The business contract this server exports.
    pub fn contract(&self) -> Result<Value, Error> {
        let envelope =
            self.execute(|token| self.http_request("GET", "/api/v1/contract", token, None, None))?;
        Ok(envelope.data)
    }

    fn recover_internal(
        &self,
        name: &str,
        body: &Value,
        idempotency_key: &str,
    ) -> Result<RecoveryResult, Error> {
        let envelope = self.execute(|token| {
            self.http_request(
                "POST",
                &format!("{}/recover", operation_path(name)),
                token,
                Some(body),
                Some(idempotency_key),
            )
        })?;
        match envelope.outcome.as_deref() {
            Some("unknown") if envelope.data.is_null() => Ok(RecoveryResult {
                status: MutationStatus::Unknown,
                data: None,
            }),
            Some("committed") => Ok(RecoveryResult {
                status: MutationStatus::Committed,
                data: Some(envelope.data),
            }),
            Some("accepted") => Ok(RecoveryResult {
                status: MutationStatus::Accepted,
                data: Some(envelope.data),
            }),
            _ => Err(Error::api(
                "PROTOCOL_ERROR",
                "Invalid recovery outcome",
                false,
            )),
        }
    }

    // ---- subscriptions -------------------------------------------------------------------------

    /// Starts a realtime subscription. Observe it with [`Subscription::on_change`].
    pub fn subscribe(&self, name: &str, params: Value) -> Result<Subscription, Error> {
        let mut state = lock(&self.inner.mu);
        if state.closed {
            return Err(closed_error());
        }
        let id = self.new_id();
        if state.entries.contains_key(&id) {
            return Err(Error::api(
                "VALIDATION_FAILED",
                "new_id returned a duplicate subscription ID",
                false,
            ));
        }
        let params = if params.is_null() { json!({}) } else { params };
        let entry = Arc::new(Mutex::new(Entry::new(
            id.clone(),
            name,
            params,
            !self.inner.opts.disable_delta,
        )));
        state.entries.insert(id.clone(), entry.clone());
        match state.conn.clone() {
            Some(conn) => {
                let epoch = state.epoch;
                self.attach_locked(&mut state, entry.clone(), conn, epoch);
            }
            None => self.start_locked(&mut state, false),
        }
        Ok(Subscription {
            client: self.clone(),
            entry,
            id,
        })
    }

    /// Explicitly rebuilds the connection and the retained subscriptions.
    pub fn reconnect(&self) -> Result<(), Error> {
        let mut state = lock(&self.inner.mu);
        if state.closed {
            return Err(closed_error());
        }
        self.detach_locked(&mut state);
        self.recovering_locked(&mut state);
        let epoch = state.epoch;
        let retained = !state.entries.is_empty();
        drop(state);
        if !retained {
            return Ok(());
        }
        match self.connect(true, epoch) {
            Ok(()) => Ok(()),
            Err(error) => {
                self.connection_failed(error.clone(), epoch);
                Err(error)
            }
        }
    }

    /// Releases subscriptions, timers and connections. The client cannot be reused.
    pub fn close(&self) {
        let mut state = lock(&self.inner.mu);
        if state.closed {
            return;
        }
        state.closed = true;
        self.detach_locked(&mut state);
        let entries: Vec<_> = state.entries.values().cloned().collect();
        for entry in entries {
            let mut entry = lock(&entry);
            entry.state = SubscriptionState {
                status: SubscriptionStatus::Closed,
                data: None,
                error: None,
                generation: None,
                seq: 0,
            };
            self.emit(&entry);
            entry.listeners.clear();
        }
        state.entries.clear();
        state.token = None;
        drop(state);
        self.inner.events.stop();
    }

    // ---- authorization -------------------------------------------------------------------------

    fn execute<F>(&self, mut perform: F) -> Result<Envelope, Error>
    where
        F: FnMut(&str) -> Result<Envelope, Error>,
    {
        let token = match self.authorize(false, None) {
            Ok(token) => token,
            Err(error) => return Err(self.auth_failure(error)),
        };
        let mut result = perform(&token);
        let auth_rejected = result.as_ref().err().is_some_and(|error| {
            let api = error.api_error();
            api.status == 401 || api.code == "UNAUTHENTICATED"
        });
        if auth_rejected && self.assert_open().is_ok() {
            result = match self.authorize(true, Some(&token)) {
                Ok(fresh) => perform(&fresh),
                Err(error) => Err(error),
            };
        }
        result.map_err(|error| self.auth_failure(error))
    }

    fn auth_failure(&self, error: Error) -> Error {
        let api = error.api_error().clone();
        if api.code == "UNAUTHENTICATED" || api.code == "FORBIDDEN" {
            self.fail_all(api);
        }
        error
    }

    fn authorize(&self, force: bool, stale: Option<&str>) -> Result<String, Error> {
        let _refresh_guard = lock(&self.inner.token_mu);
        let token = {
            let state = lock(&self.inner.mu);
            if state.closed {
                return Err(closed_error());
            }
            state.token.clone()
        };
        if let Some(token) = &token {
            // Another caller already refreshed past the token this one failed with.
            if !force || stale.is_some_and(|stale| token != stale) {
                return Ok(token.clone());
            }
        }
        let mut fresh = self.user_token(force)?;
        let identity = match self.identity_for(&fresh) {
            Ok(identity) => identity,
            Err(error) if !force && error.api_error().status == 401 => {
                fresh = self.user_token(true)?;
                self.identity_for(&fresh)?
            }
            Err(error) => return Err(error),
        };
        let mut state = lock(&self.inner.mu);
        if state.closed {
            return Err(closed_error());
        }
        if identity.project_id != self.inner.opts.project_id
            || state
                .identity
                .as_ref()
                .is_some_and(|current| identity.subject_id != current.subject_id)
        {
            return Err(Error::api(
                "FORBIDDEN",
                "Create a new client when changing accounts",
                false,
            ));
        }
        state.identity = Some(identity);
        state.token = Some(fresh.clone());
        Ok(fresh)
    }

    fn user_token(&self, force: bool) -> Result<String, Error> {
        let token = (self.inner.opts.get_token)(force)?;
        self.assert_open()?;
        if !token.starts_with("rts_") {
            return Err(Error::api(
                "UNAUTHENTICATED",
                "GetToken must return a user session token",
                false,
            ));
        }
        Ok(token)
    }

    fn identity_for(&self, token: &str) -> Result<Identity, Error> {
        let envelope = self.http_request("GET", "/api/v1/identity", token, None, None)?;
        let data = envelope.data.as_object().ok_or_else(invalid_identity)?;
        let project_id = data
            .get("project_id")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .ok_or_else(invalid_identity)?;
        let subject_id = data
            .get("subject_id")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .ok_or_else(invalid_identity)?;
        Ok(Identity::new(project_id, subject_id))
    }

    // ---- connection management ----------------------------------------------------------------

    fn start_locked(&self, state: &mut ClientState, force: bool) {
        let epoch = state.epoch;
        if state.connecting_epoch == Some(epoch) {
            return;
        }
        state.connecting_epoch = Some(epoch);
        let client = self.clone();
        std::thread::Builder::new()
            .name("fyrlet-connect".to_string())
            .spawn(move || {
                if let Err(error) = client.connect(force, epoch) {
                    client.connection_failed(error, epoch);
                }
            })
            .expect("failed to spawn the connection worker");
    }

    fn connect(&self, force: bool, epoch: u64) -> Result<(), Error> {
        let result = self.connect_inner(force, epoch);
        let mut state = lock(&self.inner.mu);
        if state.connecting_epoch == Some(epoch) {
            state.connecting_epoch = None;
        }
        result
    }

    fn connect_inner(&self, force: bool, epoch: u64) -> Result<(), Error> {
        let token = self.authorize(force, None)?;
        {
            let state = lock(&self.inner.mu);
            if self.stale_locked(&state, epoch) {
                return Ok(());
            }
        }
        let on_frame: FrameHandler = {
            let client = self.clone();
            Arc::new(move |connection, frame| client.on_frame(connection, frame))
        };
        let on_close: crate::phoenix::CloseHandler = {
            let client = self.clone();
            Arc::new(move |connection, failure| client.on_close(connection, failure))
        };
        let connection = phoenix::dial(
            &self.inner.endpoint,
            &self.inner.opts.project_id,
            &token,
            self.inner.opts.timeout,
            on_frame,
            on_close,
        )?;
        let mut state = lock(&self.inner.mu);
        if self.stale_locked(&state, epoch) {
            drop(state);
            connection.close();
            return Ok(());
        }
        state.conn = Some(connection.clone());
        let entries: Vec<_> = state.entries.values().cloned().collect();
        for entry in entries {
            if lock(&entry).state.status != SubscriptionStatus::Error {
                self.attach_locked(&mut state, entry, connection.clone(), epoch);
            }
        }
        Ok(())
    }

    fn stale_locked(&self, state: &ClientState, epoch: u64) -> bool {
        state.closed || state.epoch != epoch || state.entries.is_empty() || state.conn.is_some()
    }

    fn attach_locked(
        &self,
        _state: &mut ClientState,
        entry: Arc<Mutex<Entry>>,
        connection: Arc<Connection>,
        epoch: u64,
    ) {
        let (topic, payload) = {
            let mut entry_guard = lock(&entry);
            entry_guard.conn = Some(connection.clone());
            let payload = self.join_payload(&entry_guard);
            (entry_guard.topic(), payload)
        };
        let reply: phoenix::Reply = {
            let client = self.clone();
            let entry = entry.clone();
            let connection = connection.clone();
            Arc::new(move |status: &str, response: Option<Map<String, Value>>| {
                client.joined(&entry, &connection, epoch, status, response);
            })
        };
        let _ = connection.join(&topic, payload, reply);
    }

    fn joined(
        &self,
        entry: &Arc<Mutex<Entry>>,
        connection: &Arc<Connection>,
        epoch: u64,
        status: &str,
        response: Option<Map<String, Value>>,
    ) {
        let mut state = lock(&self.inner.mu);
        if !self.current_locked(&state, entry, connection, epoch) {
            return;
        }
        match status {
            "ok" => {
                state.retries = 0;
                lock(entry).join_failures = 0;
                let payload = Value::Object(response.unwrap_or_default());
                self.receive_locked(&mut state, entry, connection, "snapshot", &payload, true);
            }
            "error" => {
                let error = channel_error(&Value::Object(response.unwrap_or_default()));
                if error.code == "UNAUTHENTICATED" {
                    self.transport_failed_locked(&mut state, connection);
                    return;
                }
                let retry = {
                    let entry = lock(entry);
                    let retry = error.retryable && entry.join_failures < MAX_JOIN_RETRIES;
                    if retry {
                        self.set_recovering(entry);
                    }
                    retry
                };
                if retry {
                    self.schedule_rejoin_locked(&mut state, entry, connection, epoch);
                } else {
                    self.fail(entry, error);
                }
            }
            _ => self.transport_failed_locked(&mut state, connection),
        }
    }

    fn set_recovering(&self, mut entry: std::sync::MutexGuard<'_, Entry>) {
        entry.join_failures += 1;
        entry.state.status = SubscriptionStatus::Recovering;
        entry.state.error = None;
        self.emit(&entry);
    }

    fn schedule_rejoin_locked(
        &self,
        _state: &mut ClientState,
        entry: &Arc<Mutex<Entry>>,
        connection: &Arc<Connection>,
        epoch: u64,
    ) {
        let token = self.next_timer();
        let delay = {
            let mut entry_guard = lock(entry);
            entry_guard.rejoin = Some(token);
            self.delay(entry_guard.join_failures)
        };
        let client = self.clone();
        let entry = entry.clone();
        let connection = connection.clone();
        std::thread::spawn(move || {
            std::thread::sleep(delay);
            let mut state = lock(&client.inner.mu);
            let rejoin = {
                let mut entry_guard = lock(&entry);
                if entry_guard.rejoin == Some(token) {
                    entry_guard.rejoin = None;
                    true
                } else {
                    false
                }
            };
            if rejoin && client.current_locked(&state, &entry, &connection, epoch) {
                client.attach_locked(&mut state, entry.clone(), connection.clone(), epoch);
            }
        });
    }

    fn current_locked(
        &self,
        state: &ClientState,
        entry: &Arc<Mutex<Entry>>,
        connection: &Arc<Connection>,
        epoch: u64,
    ) -> bool {
        if state.closed
            || state.epoch != epoch
            || state
                .conn
                .as_ref()
                .map_or(true, |current| !Arc::ptr_eq(current, connection))
        {
            return false;
        }
        let id = {
            let entry_guard = lock(entry);
            if entry_guard
                .conn
                .as_ref()
                .map_or(true, |current| !Arc::ptr_eq(current, connection))
            {
                return false;
            }
            entry_guard.id.clone()
        };
        state
            .entries
            .get(&id)
            .is_some_and(|current| Arc::ptr_eq(current, entry))
    }

    fn join_payload(&self, entry: &Entry) -> Value {
        let mut payload = json!({
            "protocol_version": crate::subscription::PROTOCOL_VERSION,
            "name": entry.name,
            "params": entry.params,
        });
        if !self.inner.declared.is_empty() {
            payload["capabilities"] = serde_json::to_value(&self.inner.declared).unwrap();
        }
        if entry.want_delta {
            payload["delivery"] = Value::String("delta-v1".to_string());
        }
        payload
    }

    fn on_frame(&self, connection: &Arc<Connection>, frame: crate::phoenix::Frame) {
        let mut state = lock(&self.inner.mu);
        if state.closed
            || state
                .conn
                .as_ref()
                .map_or(true, |current| !Arc::ptr_eq(current, connection))
        {
            return;
        }
        let Some(id) = frame.topic.strip_prefix("subscription:") else {
            return;
        };
        let Some(entry) = state.entries.get(id).cloned() else {
            return;
        };
        {
            let entry_guard = lock(&entry);
            if entry_guard
                .conn
                .as_ref()
                .map_or(true, |current| !Arc::ptr_eq(current, connection))
            {
                return;
            }
        }
        match frame.event.as_str() {
            "snapshot" | "delta" => {
                let payload = Value::Object(frame.payload);
                self.receive_locked(
                    &mut state,
                    &entry,
                    connection,
                    frame.event.as_str(),
                    &payload,
                    false,
                );
            }
            "status" => {
                let error = channel_error(&Value::Object(frame.payload));
                if error.code == "UNAUTHENTICATED" {
                    for entry in state.entries.values() {
                        lock(entry).state.data = None;
                    }
                    self.transport_failed_locked(&mut state, connection);
                } else if error.retryable {
                    self.transport_failed_locked(&mut state, connection);
                } else {
                    self.fail(&entry, error);
                }
            }
            "phx_error" => self.transport_failed_locked(&mut state, connection),
            "phx_close" => self.fail(
                &entry,
                APIError::new(
                    "SUBSCRIPTION_CLOSED",
                    "The server closed the subscription",
                    false,
                ),
            ),
            _ => {}
        }
    }

    fn receive_locked(
        &self,
        state: &mut ClientState,
        entry: &Arc<Mutex<Entry>>,
        connection: &Arc<Connection>,
        event: &str,
        payload: &Value,
        initial: bool,
    ) {
        let before = lock(entry).state.clone();
        let outcome = {
            let mut entry_guard = lock(entry);
            if event == "snapshot" {
                entry_guard.apply_snapshot(payload, state.identity.as_ref(), initial)
            } else {
                entry_guard.apply_delta(payload)
            }
        };
        match outcome {
            Err(error) if error.code() == "RECONNECT" => {
                self.transport_failed_locked(state, connection);
            }
            Err(error) => {
                self.fail(entry, error.api_error().clone());
            }
            Ok(ack) => {
                let current = {
                    let entry_guard = lock(entry);
                    let current = entry_guard.state.clone();
                    let changed = current.seq != before.seq
                        || current.status != before.status
                        || current.generation != before.generation;
                    if changed {
                        self.emit(&entry_guard);
                    }
                    current
                };
                let _ = current;
                if let Some(ack) = ack {
                    let topic = lock(entry).topic();
                    let _ = connection.notify(
                        &topic,
                        "ack",
                        json!({"g": ack.generation, "s": ack.seq}),
                    );
                }
            }
        }
    }

    fn on_close(&self, connection: &Arc<Connection>, failure: Option<APIError>) {
        let mut state = lock(&self.inner.mu);
        if state.closed
            || state
                .conn
                .as_ref()
                .map_or(true, |current| !Arc::ptr_eq(current, connection))
        {
            return;
        }
        match failure {
            Some(failure) if !failure.retryable => {
                self.fail_all_locked(&mut state, failure);
            }
            _ => self.transport_failed_locked(&mut state, connection),
        }
    }

    fn transport_failed_locked(&self, state: &mut ClientState, connection: &Arc<Connection>) {
        if state.closed
            || state
                .conn
                .as_ref()
                .map_or(true, |current| !Arc::ptr_eq(current, connection))
        {
            return;
        }
        self.detach_locked(state);
        self.recovering_locked(state);
        self.schedule_retry_locked(state);
    }

    fn connection_failed(&self, error: Error, epoch: u64) {
        let mut state = lock(&self.inner.mu);
        if state.closed || state.epoch != epoch {
            return;
        }
        let failure = as_api_error(error);
        if !failure.retryable {
            self.fail_all_locked(&mut state, failure);
            return;
        }
        // A foreign error, such as a failing GetToken, counts as a retryable network failure.
        self.recovering_locked(&mut state);
        self.schedule_retry_locked(&mut state);
    }

    fn schedule_retry_locked(&self, state: &mut ClientState) {
        if state.closed || state.retry_timer.is_some() || state.entries.is_empty() {
            return;
        }
        state.retries += 1;
        let attempt = state.retries;
        let token = self.next_timer();
        state.retry_timer = Some(token);
        let delay = self.delay(attempt);
        let client = self.clone();
        std::thread::spawn(move || {
            std::thread::sleep(delay);
            let mut state = lock(&client.inner.mu);
            if state.retry_timer == Some(token) {
                state.retry_timer = None;
                if !state.closed && !state.entries.is_empty() {
                    client.start_locked(&mut state, true);
                }
            }
        });
    }

    fn recovering_locked(&self, state: &mut ClientState) {
        for entry in state.entries.values() {
            let mut entry = lock(entry);
            if entry.state.status != SubscriptionStatus::Error {
                entry.state.status = SubscriptionStatus::Recovering;
                entry.state.error = None;
                self.emit(&entry);
            }
        }
    }

    fn fail_all(&self, error: APIError) {
        let mut state = lock(&self.inner.mu);
        self.fail_all_locked(&mut state, error);
    }

    fn fail_all_locked(&self, state: &mut ClientState, error: APIError) {
        self.detach_locked(state);
        state.token = None;
        let entries: Vec<_> = state.entries.values().cloned().collect();
        for entry in entries {
            self.fail(&entry, error.clone());
        }
    }

    fn fail(&self, entry: &Arc<Mutex<Entry>>, error: APIError) {
        let (connection, topic) = {
            let mut entry = lock(entry);
            entry.rejoin = None;
            let connection = entry.conn.take();
            (connection, entry.topic())
        };
        if let Some(connection) = connection {
            connection.leave(&topic);
        }
        let mut entry = lock(entry);
        entry.state.status = SubscriptionStatus::Error;
        entry.state.data = None;
        entry.state.error = Some(error);
        self.emit(&entry);
    }

    fn detach_locked(&self, state: &mut ClientState) {
        state.epoch += 1;
        state.connecting_epoch = None;
        state.retry_timer = None;
        let connection = state.conn.take();
        let entries: Vec<_> = state.entries.values().cloned().collect();
        for entry in entries {
            let mut entry = lock(&entry);
            entry.rejoin = None;
            entry.conn = None;
        }
        if let Some(connection) = connection {
            connection.close();
        }
    }

    fn delay(&self, attempt: u32) -> Duration {
        if let Some(retry_delay) = &self.inner.opts.retry_delay {
            return retry_delay(attempt.max(1));
        }
        let shift = attempt.saturating_sub(1).min(7);
        let delay = Duration::from_millis(250u64 << shift);
        delay.min(Duration::from_secs(30))
    }

    fn next_timer(&self) -> u64 {
        self.inner.timer_seq.fetch_add(1, Ordering::SeqCst) + 1
    }

    fn new_id(&self) -> String {
        match &self.inner.opts.new_id {
            Some(new_id) => new_id(),
            None => Uuid::new_v4().to_string(),
        }
    }

    // ---- listener dispatch ---------------------------------------------------------------------

    pub(crate) fn dispatch(&self, listener: Listener, state: SubscriptionState) {
        let handler = self.inner.opts.on_listener_error.clone();
        self.inner.events.post(Box::new(move || {
            let outcome = catch_unwind(AssertUnwindSafe(|| listener(state)));
            if let Err(payload) = outcome {
                if let Some(handler) = handler {
                    let _ = catch_unwind(AssertUnwindSafe(|| handler(payload)));
                }
            }
        }));
    }

    fn emit(&self, entry: &Entry) {
        if entry.listeners.is_empty() {
            return;
        }
        let state = entry.state.clone();
        for (_, listener) in &entry.listeners {
            self.dispatch(listener.clone(), state.clone());
        }
    }

    // ---- internals -----------------------------------------------------------------------------

    pub(crate) fn refresh(&self, entry: &Arc<Mutex<Entry>>) -> Result<(), Error> {
        let (connection, topic) = {
            let entry = lock(entry);
            if entry.state.status != SubscriptionStatus::Ready {
                return Err(not_ready());
            }
            let connection = entry.conn.clone().ok_or_else(not_ready)?;
            (connection, entry.topic())
        };
        let (sender, receiver) = mpsc::channel();
        let sender = Mutex::new(sender);
        let reply: phoenix::Reply = Arc::new(move |status: &str, response| {
            let _ = lock(&sender).send((status.to_string(), response));
        });
        connection.push(&topic, "refresh", json!({}), reply)?;
        let (status, response) = receiver
            .recv_timeout(self.inner.opts.timeout + Duration::from_secs(1))
            .unwrap_or_else(|_| ("timeout".to_string(), None));
        match status.as_str() {
            "ok" => Ok(()),
            "error" => Err(Error::Api(channel_error(&Value::Object(
                response.unwrap_or_default(),
            )))),
            _ => Err(Error::api("TIMEOUT", "refresh was not acknowledged", true)),
        }
    }

    pub(crate) fn unsubscribe(&self, _entry: &Arc<Mutex<Entry>>, id: &str) {
        let mut state = lock(&self.inner.mu);
        let entry = match state.entries.remove(id) {
            Some(entry) => entry,
            None => return,
        };
        let (connection, topic, generation, seq) = {
            let mut entry = lock(&entry);
            entry.rejoin = None;
            let connection = entry.conn.take();
            let generation = entry.state.generation.clone();
            let seq = entry.state.seq;
            (connection, entry.topic(), generation, seq)
        };
        if let Some(connection) = connection {
            connection.leave(&topic);
        }
        {
            let mut entry = lock(&entry);
            entry.state = SubscriptionState {
                status: SubscriptionStatus::Closed,
                data: None,
                error: None,
                generation,
                seq,
            };
            self.emit(&entry);
            entry.listeners.clear();
        }
        if state.entries.is_empty() {
            self.detach_locked(&mut state);
        }
    }

    fn assert_open(&self) -> Result<(), Error> {
        let state = lock(&self.inner.mu);
        if state.closed {
            return Err(closed_error());
        }
        Ok(())
    }

    fn http_request(
        &self,
        method: &str,
        path: &str,
        token: &str,
        body: Option<&Value>,
        key: Option<&str>,
    ) -> Result<Envelope, Error> {
        let mut headers = vec![
            ("authorization".to_string(), format!("Bearer {token}")),
            (
                "x-project-id".to_string(),
                self.inner.opts.project_id.clone(),
            ),
        ];
        if let Some(key) = key {
            headers.push(("idempotency-key".to_string(), key.to_string()));
        }
        if !self.inner.declared.is_empty() {
            let capabilities = self
                .inner
                .declared
                .iter()
                .map(|(name, version)| format!("{name}={version}"))
                .collect::<Vec<_>>()
                .join(", ");
            headers.push(("x-fyrlet-capabilities".to_string(), capabilities));
        }
        http_json(
            &self.inner.agent,
            method,
            &format!("{}{}", self.inner.endpoint, path),
            &headers,
            body,
            self.inner.opts.timeout,
        )
    }
}

fn normalize_input(input: Value) -> Value {
    if input.is_null() {
        json!({})
    } else {
        input
    }
}

fn failed_mutation(
    key: &str,
    lookup: &Arc<dyn Fn() -> Result<RecoveryResult, Error> + Send + Sync>,
    error: Error,
) -> Mutation {
    Mutation {
        idempotency_key: key.to_string(),
        state: Arc::new(Mutex::new(MutationState {
            status: MutationStatus::Failed,
            data: None,
            error: Some(error),
        })),
        lookup: lookup.clone(),
    }
}

fn unknown_mutation(
    key: &str,
    lookup: &Arc<dyn Fn() -> Result<RecoveryResult, Error> + Send + Sync>,
    operation: &str,
    cause: APIError,
) -> Mutation {
    Mutation {
        idempotency_key: key.to_string(),
        state: Arc::new(Mutex::new(MutationState {
            status: MutationStatus::Unknown,
            data: None,
            error: Some(Error::OutcomeUnknown(Box::new(OutcomeUnknownError::new(
                operation, key, cause,
            )))),
        })),
        lookup: lookup.clone(),
    }
}

fn operation_path(name: &str) -> String {
    format!("/api/v1/operations/{}", encode_path_segment(name))
}

pub(crate) fn encode_path_segment(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~') {
            encoded.push(byte as char);
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    encoded
}

fn valid_capability_name(name: &str) -> bool {
    let mut characters = name.chars();
    match characters.next() {
        Some(first) if first.is_ascii_lowercase() => {}
        _ => return false,
    }
    characters.all(|character| {
        character.is_ascii_lowercase()
            || character.is_ascii_digit()
            || matches!(character, '_' | '.' | '-')
    })
}

fn closed_error() -> Error {
    Error::api("CLIENT_CLOSED", "The client is closed", false)
}

fn not_ready() -> Error {
    Error::api("NOT_READY", "The subscription is not ready", false)
}

fn invalid_identity() -> Error {
    Error::api("PROTOCOL_ERROR", "Invalid identity response", false)
}

/// Validates an HTTP(S) base URL and strips trailing slashes.
pub fn endpoint_url(endpoint: &str) -> Result<String, Error> {
    let url = Url::parse(endpoint).map_err(|_| {
        Error::api(
            "VALIDATION_FAILED",
            "endpoint must be an HTTP(S) base URL without credentials, query or fragment",
            false,
        )
    })?;
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(Error::api(
            "VALIDATION_FAILED",
            "endpoint must be an HTTP(S) base URL without credentials, query or fragment",
            false,
        ));
    }
    Ok(endpoint.trim_end_matches('/').to_string())
}

/// A decoded HTTP response envelope.
pub(crate) struct Envelope {
    pub data: Value,
    pub has_data: bool,
    pub outcome: Option<String>,
}

/// Performs one JSON request with a per-request timeout. Redirects are handled by the agent.
pub(crate) fn http_json(
    agent: &ureq::Agent,
    method: &str,
    url: &str,
    headers: &[(String, String)],
    body: Option<&Value>,
    timeout: Duration,
) -> Result<Envelope, Error> {
    let mut request = agent.request(method, url).timeout(timeout);
    request = request.set("accept", "application/json");
    if body.is_some() {
        request = request.set("content-type", "application/json");
    }
    for (name, value) in headers {
        request = request.set(name, value);
    }
    let result = match body {
        Some(body) => {
            let encoded = serde_json::to_vec(body)
                .map_err(|error| Error::api("PROTOCOL_ERROR", error.to_string(), false))?;
            request.send_bytes(&encoded)
        }
        None => request.call(),
    };
    let (status, response) = match result {
        Ok(response) => (response.status(), response),
        Err(ureq::Error::Status(status, response)) => (status, response),
        Err(ureq::Error::Transport(transport)) => return Err(transport_error(&transport)),
    };
    let mut raw = Vec::new();
    response
        .into_reader()
        .take(RESPONSE_LIMIT)
        .read_to_end(&mut raw)
        .map_err(read_error)?;
    let value: Value = serde_json::from_slice(&raw).map_err(|_| {
        Error::Api(
            APIError::new("PROTOCOL_ERROR", "Expected a JSON response", false).with_status(status),
        )
    })?;
    let object = value.as_object().ok_or_else(|| {
        Error::Api(
            APIError::new("PROTOCOL_ERROR", "Expected a JSON response", false).with_status(status),
        )
    })?;
    let request_id = object
        .get("request_id")
        .and_then(Value::as_str)
        .map(str::to_string);
    let (data, has_data) = match object.get("data") {
        Some(data) => (data.clone(), true),
        None => (Value::Null, false),
    };
    let outcome = object
        .get("outcome")
        .and_then(Value::as_str)
        .map(str::to_string);
    let wire_error = match object.get("error") {
        Some(error) => parse_wire_error(error).map_err(|error| {
            Error::Api(
                error
                    .with_status(status)
                    .with_request_id(request_id.clone()),
            )
        })?,
        None => None,
    };
    if !(200..300).contains(&status) || wire_error.is_some() {
        if let Some(error) = wire_error {
            return Err(Error::Api(error.into_error(status, request_id)));
        }
        return Err(Error::Api(
            APIError::new("HTTP_ERROR", "The request was rejected", false)
                .with_status(status)
                .with_request_id(request_id),
        ));
    }
    if !has_data {
        return Err(Error::Api(
            APIError::new("PROTOCOL_ERROR", "Missing response data", false).with_status(status),
        ));
    }
    Ok(Envelope {
        data,
        has_data,
        outcome,
    })
}

fn transport_error(transport: &ureq::Transport) -> Error {
    if transport_is_timeout(transport) {
        return Error::api("TIMEOUT", "The request timed out", true);
    }
    Error::api("NETWORK_ERROR", "The service could not be reached", true)
}

fn transport_is_timeout(transport: &ureq::Transport) -> bool {
    let mut source: Option<&(dyn std::error::Error + 'static)> =
        std::error::Error::source(transport);
    while let Some(error) = source {
        if let Some(io_error) = error.downcast_ref::<std::io::Error>() {
            if matches!(
                io_error.kind(),
                std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
            ) {
                return true;
            }
        }
        source = std::error::Error::source(error);
    }
    transport
        .message()
        .map(|message| message.to_ascii_lowercase().contains("timed out"))
        .unwrap_or(false)
}

fn read_error(error: std::io::Error) -> Error {
    if matches!(
        error.kind(),
        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
    ) {
        Error::api("TIMEOUT", "The request timed out", true)
    } else {
        Error::api("NETWORK_ERROR", "The response was interrupted", true)
    }
}
