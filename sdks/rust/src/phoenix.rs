//! A small Phoenix Channels v2 connection: one WebSocket, a reader thread, a heartbeat thread and
//! per-push reply deadline threads.

use crate::errors::{APIError, Error};
use base64::Engine as _;
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::io;
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};
use tungstenite::client::ClientRequestBuilder;
use tungstenite::protocol::WebSocketConfig;
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{Message, WebSocket};

use crate::subscription::lock;

/// The maximum number of frames accepted in one `{"batch": [...]}` wrapper.
pub const MAX_BATCH: usize = 64;
/// The maximum size of one inbound WebSocket message.
pub const MAX_MESSAGE_BYTES: usize = 4 << 20;

const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(30);
const READ_POLL_INTERVAL: Duration = Duration::from_millis(50);

/// One Phoenix v2 JSON frame.
#[derive(Debug, Clone, PartialEq)]
pub struct Frame {
    /// The join reference, a string or null.
    pub join_ref: Option<String>,
    /// The message reference, a string or null.
    pub reference: Option<String>,
    /// The channel topic.
    pub topic: String,
    /// The event name.
    pub event: String,
    /// The non-null object payload.
    pub payload: Map<String, Value>,
}

fn invalid_frame() -> Error {
    Error::api("PROTOCOL_ERROR", "Invalid Fyrlet transport frame", false)
}

/// Decodes one Phoenix frame or a `{"batch":[...]}` wrapper, validating every member.
pub fn decode_frames(raw: &[u8]) -> Result<Vec<Frame>, Error> {
    let value: Value = serde_json::from_slice(raw).map_err(|_| invalid_frame())?;
    let members: Vec<Value> = match value {
        Value::Object(mut object) => {
            if object.len() != 1 {
                return Err(invalid_frame());
            }
            match object.remove("batch") {
                Some(Value::Array(members)) => members,
                _ => return Err(invalid_frame()),
            }
        }
        other => vec![other],
    };
    if members.is_empty() || members.len() > MAX_BATCH {
        return Err(invalid_frame());
    }
    let mut frames = Vec::with_capacity(members.len());
    for member in members {
        let parts = member.as_array().ok_or_else(invalid_frame)?;
        if parts.len() != 5 {
            return Err(invalid_frame());
        }
        let join_ref = parse_reference(&parts[0])?;
        let reference = parse_reference(&parts[1])?;
        let topic = parts[2].as_str().ok_or_else(invalid_frame)?;
        let event = parts[3].as_str().ok_or_else(invalid_frame)?;
        let payload = parts[4].as_object().ok_or_else(invalid_frame)?.clone();
        frames.push(Frame {
            join_ref,
            reference,
            topic: topic.to_string(),
            event: event.to_string(),
            payload,
        });
    }
    Ok(frames)
}

fn parse_reference(value: &Value) -> Result<Option<String>, Error> {
    match value {
        Value::Null => Ok(None),
        Value::String(reference) => Ok(Some(reference.clone())),
        _ => Err(invalid_frame()),
    }
}

/// The authenticated socket URL for a base endpoint.
pub fn socket_url(endpoint: &str, project_id: &str) -> String {
    let base = if let Some(rest) = endpoint.strip_prefix("https") {
        format!("wss{rest}")
    } else if let Some(rest) = endpoint.strip_prefix("http") {
        format!("ws{rest}")
    } else {
        endpoint.to_string()
    };
    let query = url::form_urlencoded::Serializer::new(String::new())
        .append_pair("project_id", project_id)
        .append_pair("vsn", "2.0.0")
        .finish();
    format!("{base}/socket/websocket?{query}")
}

/// The bearer token encoded as a Phoenix `authToken` WebSocket subprotocol.
pub fn auth_protocol(token: &str) -> String {
    format!(
        "base64url.bearer.phx.{}",
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(token.as_bytes())
    )
}

/// A reply receives `"ok"`, `"error"` or `"timeout"` exactly once.
pub(crate) type Reply = Arc<dyn Fn(&str, Option<Map<String, Value>>) + Send + Sync>;

pub(crate) type FrameHandler = Arc<dyn Fn(&Arc<Connection>, Frame) + Send + Sync>;
pub(crate) type CloseHandler = Arc<dyn Fn(&Arc<Connection>, Option<APIError>) + Send + Sync>;

struct PendingState {
    pending: HashMap<String, Reply>,
    refs: u64,
    closed: bool,
}

/// One authenticated socket. Frame callbacks run on the reader thread, in order.
pub(crate) struct Connection {
    socket: Mutex<WebSocket<MaybeTlsStream<TcpStream>>>,
    timeout: Duration,
    on_frame: FrameHandler,
    on_close: CloseHandler,
    state: Mutex<PendingState>,
    ready: Condvar,
    closed: AtomicBool,
}

/// Opens a socket. Redirects are not followed.
pub(crate) fn dial(
    endpoint: &str,
    project_id: &str,
    token: &str,
    timeout: Duration,
    on_frame: FrameHandler,
    on_close: CloseHandler,
) -> Result<Arc<Connection>, Error> {
    let target = socket_url(endpoint, project_id);
    let uri = target
        .parse::<tungstenite::http::Uri>()
        .map_err(|_| Error::api("NETWORK_ERROR", "The service could not be reached", true))?;
    let request = ClientRequestBuilder::new(uri)
        .with_sub_protocol("phoenix")
        .with_sub_protocol(auth_protocol(token));
    let config = WebSocketConfig::default().max_message_size(Some(MAX_MESSAGE_BYTES));
    let (mut socket, _response) =
        tungstenite::client::connect_with_config(request, Some(config), 0).map_err(dial_failure)?;
    match socket.get_mut() {
        MaybeTlsStream::Plain(stream) => {
            let _ = stream.set_read_timeout(Some(READ_POLL_INTERVAL));
            let _ = stream.set_write_timeout(Some(timeout));
        }
        MaybeTlsStream::Rustls(stream) => {
            let _ = stream.get_ref().set_read_timeout(Some(READ_POLL_INTERVAL));
            let _ = stream.get_ref().set_write_timeout(Some(timeout));
        }
        _ => {}
    }
    let connection = Arc::new(Connection {
        socket: Mutex::new(socket),
        timeout,
        on_frame,
        on_close,
        state: Mutex::new(PendingState {
            pending: HashMap::new(),
            refs: 0,
            closed: false,
        }),
        ready: Condvar::new(),
        closed: AtomicBool::new(false),
    });
    let reader = connection.clone();
    std::thread::Builder::new()
        .name("fyrlet-reader".to_string())
        .spawn(move || reader.read_loop())
        .expect("failed to spawn the socket reader");
    let heartbeat = connection.clone();
    std::thread::Builder::new()
        .name("fyrlet-heartbeat".to_string())
        .spawn(move || heartbeat.heartbeat_loop())
        .expect("failed to spawn the heartbeat");
    Ok(connection)
}

fn dial_failure(error: tungstenite::Error) -> Error {
    if let tungstenite::Error::Http(response) = &error {
        let status = response.status().as_u16();
        if status == 401 || status == 403 {
            return Error::Api(
                APIError::new("UNAUTHENTICATED", "The socket rejected the session", false)
                    .with_status(status),
            );
        }
    }
    Error::api("NETWORK_ERROR", "The service could not be reached", true)
}

impl Connection {
    fn next_ref(&self) -> String {
        let mut state = lock(&self.state);
        state.refs += 1;
        state.refs.to_string()
    }

    fn register(self: &Arc<Self>, reference: &str, reply: Reply) -> bool {
        {
            let mut state = lock(&self.state);
            if state.closed {
                return false;
            }
            state.pending.insert(reference.to_string(), reply);
        }
        let connection = self.clone();
        let reference = reference.to_string();
        let timeout = self.timeout;
        std::thread::spawn(move || {
            std::thread::sleep(timeout);
            let pending = {
                let mut state = lock(&connection.state);
                state.pending.remove(&reference)
            };
            if let Some(reply) = pending {
                reply("timeout", None);
            }
        });
        true
    }

    fn unregister(&self, reference: &str) {
        lock(&self.state).pending.remove(reference);
    }

    fn send(self: &Arc<Self>, parts: Value) -> Result<(), Error> {
        let encoded = serde_json::to_string(&parts)
            .map_err(|error| Error::api("PROTOCOL_ERROR", error.to_string(), false))?;
        let result = {
            let mut socket = lock(&self.socket);
            socket.send(Message::Text(encoded.into()))
        };
        if let Err(_error) = result {
            let failure = APIError::new("NETWORK_ERROR", "The connection was interrupted", true);
            self.shutdown(Some(failure.clone()), true);
            return Err(Error::Api(failure));
        }
        Ok(())
    }

    /// Sends an event; the reply receives `"ok"`, `"error"` or `"timeout"` exactly once.
    pub(crate) fn push(
        self: &Arc<Self>,
        topic: &str,
        event: &str,
        payload: Value,
        reply: Reply,
    ) -> Result<(), Error> {
        let reference = self.next_ref();
        if !self.register(&reference, reply) {
            return Err(Error::api(
                "NETWORK_ERROR",
                "The connection was interrupted",
                true,
            ));
        }
        if let Err(error) = self.send(json!([Value::Null, reference, topic, event, payload])) {
            self.unregister(&reference);
            return Err(error);
        }
        Ok(())
    }

    pub(crate) fn join(
        self: &Arc<Self>,
        topic: &str,
        payload: Value,
        reply: Reply,
    ) -> Result<(), Error> {
        let reference = self.next_ref();
        if !self.register(&reference, reply) {
            return Err(Error::api(
                "NETWORK_ERROR",
                "The connection was interrupted",
                true,
            ));
        }
        if let Err(error) = self.send(json!([reference, reference, topic, "phx_join", payload])) {
            self.unregister(&reference);
            return Err(error);
        }
        Ok(())
    }

    /// Sends an event without a ref, such as `ack`.
    pub(crate) fn notify(
        self: &Arc<Self>,
        topic: &str,
        event: &str,
        payload: Value,
    ) -> Result<(), Error> {
        self.send(json!([Value::Null, Value::Null, topic, event, payload]))
    }

    pub(crate) fn leave(self: &Arc<Self>, topic: &str) {
        let reference = self.next_ref();
        let _ = self.send(json!([
            Value::Null,
            reference,
            topic,
            "phx_leave",
            json!({})
        ]));
    }

    pub(crate) fn close(self: &Arc<Self>) {
        self.shutdown(None, false);
    }

    fn read_loop(self: Arc<Self>) {
        let mut failure = APIError::new("NETWORK_ERROR", "The connection was interrupted", true);
        'read: loop {
            let message = {
                let mut socket = lock(&self.socket);
                socket.read()
            };
            let message = match message {
                Ok(message) => message,
                Err(tungstenite::Error::Io(error))
                    if matches!(
                        error.kind(),
                        io::ErrorKind::WouldBlock
                            | io::ErrorKind::TimedOut
                            | io::ErrorKind::Interrupted
                    ) =>
                {
                    if error.kind() == io::ErrorKind::WouldBlock {
                        std::thread::sleep(Duration::from_millis(1));
                    }
                    continue;
                }
                Err(_) => break,
            };
            let raw = match message {
                Message::Text(text) => text.as_str().as_bytes().to_vec(),
                Message::Binary(bytes) => bytes.to_vec(),
                Message::Close(_) => break,
                Message::Ping(_) | Message::Pong(_) | Message::Frame(_) => continue,
            };
            let frames = match decode_frames(&raw) {
                Ok(frames) => frames,
                Err(_) => {
                    failure = APIError::new("PROTOCOL_ERROR", "Invalid transport frame", false);
                    break;
                }
            };
            for frame in frames {
                if frame.event == "phx_reply" {
                    if let Some(reference) = &frame.reference {
                        let pending = lock(&self.state).pending.remove(reference);
                        if let Some(reply) = pending {
                            let status = frame
                                .payload
                                .get("status")
                                .and_then(Value::as_str)
                                .filter(|status| !status.is_empty())
                                .unwrap_or("error");
                            let response = frame
                                .payload
                                .get("response")
                                .and_then(Value::as_object)
                                .cloned();
                            reply(status, response);
                        }
                        continue;
                    }
                }
                (self.on_frame)(&self, frame);
            }
            if self.closed.load(Ordering::SeqCst) {
                break 'read;
            }
        }
        self.shutdown(Some(failure), true);
    }

    fn heartbeat_loop(self: Arc<Self>) {
        let mut last = Instant::now();
        loop {
            {
                let state = lock(&self.state);
                if state.closed {
                    return;
                }
                let wait = HEARTBEAT_INTERVAL.saturating_sub(last.elapsed());
                let (state, _) = match self.ready.wait_timeout(state, wait) {
                    Ok(result) => result,
                    Err(error) => error.into_inner(),
                };
                if state.closed {
                    return;
                }
            }
            if last.elapsed() < HEARTBEAT_INTERVAL {
                continue;
            }
            last = Instant::now();
            let connection = self.clone();
            let reply: Reply = Arc::new(move |status, _| {
                if status == "timeout" {
                    connection.shutdown(
                        Some(APIError::new("NETWORK_ERROR", "Heartbeat timed out", true)),
                        true,
                    );
                }
            });
            if self.push("phoenix", "heartbeat", json!({}), reply).is_err() {
                return;
            }
        }
    }

    fn shutdown(self: &Arc<Self>, failure: Option<APIError>, notify: bool) {
        let waiters: Vec<Reply> = {
            let mut state = lock(&self.state);
            if state.closed {
                return;
            }
            state.closed = true;
            self.closed.store(true, Ordering::SeqCst);
            self.ready.notify_all();
            state.pending.drain().map(|(_, reply)| reply).collect()
        };
        {
            let mut socket = lock(&self.socket);
            let _ = socket.close(None);
        }
        for reply in waiters {
            std::thread::spawn(move || reply("timeout", None));
        }
        if notify {
            let connection = self.clone();
            let on_close = self.on_close.clone();
            std::thread::spawn(move || on_close(&connection, failure));
        }
    }
}
