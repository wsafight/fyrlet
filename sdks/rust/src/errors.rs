//! Errors reported by the Fyrlet SDK.

use serde_json::{Map, Value};
use std::fmt;

/// A failure reported by the server or detected by the SDK.
#[derive(Debug, Clone, PartialEq)]
pub struct APIError {
    /// Stable machine-readable error code, such as `CONFLICT` or `NETWORK_ERROR`.
    pub code: String,
    /// Human-readable message.
    pub message: String,
    /// Optional structured details supplied by the server.
    pub details: Option<Map<String, Value>>,
    /// Whether retrying later may succeed.
    pub retryable: bool,
    /// HTTP status code, or `0` when the failure did not come from an HTTP response.
    pub status: u16,
    /// Server request identifier, when one was supplied.
    pub request_id: Option<String>,
}

impl APIError {
    /// Creates an error without an HTTP status.
    pub fn new(code: impl Into<String>, message: impl Into<String>, retryable: bool) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            details: None,
            retryable,
            status: 0,
            request_id: None,
        }
    }

    /// Sets the HTTP status code.
    pub fn with_status(mut self, status: u16) -> Self {
        self.status = status;
        self
    }

    /// Sets the request identifier.
    pub fn with_request_id(mut self, request_id: Option<String>) -> Self {
        self.request_id = request_id;
        self
    }
}

impl fmt::Display for APIError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "fyrlet: {}: {}", self.code, self.message)
    }
}

impl std::error::Error for APIError {}

/// Means a write was dispatched but its result is unknown. Use
/// [`Client::recover`](crate::Client::recover) with [`idempotency_key`](Self::idempotency_key)
/// before deciding to submit it again.
#[derive(Debug, Clone)]
pub struct OutcomeUnknownError {
    /// The operation whose result is unknown.
    pub operation: String,
    /// The idempotency key used for the original request.
    pub idempotency_key: String,
    /// The underlying transport or protocol failure.
    pub cause: APIError,
}

impl OutcomeUnknownError {
    /// Creates an unknown-outcome error.
    pub fn new(
        operation: impl Into<String>,
        idempotency_key: impl Into<String>,
        cause: APIError,
    ) -> Self {
        Self {
            operation: operation.into(),
            idempotency_key: idempotency_key.into(),
            cause,
        }
    }
}

impl fmt::Display for OutcomeUnknownError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "fyrlet: the outcome of {} is unknown: {}",
            self.operation, self.cause
        )
    }
}

impl std::error::Error for OutcomeUnknownError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.cause)
    }
}

/// All errors surfaced by the SDK.
#[derive(Debug, Clone)]
pub enum Error {
    /// A failure reported by the server or detected by the SDK.
    Api(APIError),
    /// A write was dispatched but its result could not be established.
    ///
    /// Boxed so a `Result<T, Error>` stays small.
    OutcomeUnknown(Box<OutcomeUnknownError>),
}

impl Error {
    /// Creates a plain API error.
    pub fn api(code: impl Into<String>, message: impl Into<String>, retryable: bool) -> Self {
        Self::Api(APIError::new(code, message, retryable))
    }

    /// The stable machine-readable error code. An unknown outcome reports the code of its cause.
    pub fn code(&self) -> &str {
        match self {
            Self::Api(error) => &error.code,
            Self::OutcomeUnknown(error) => &error.cause.code,
        }
    }

    /// Whether retrying later may succeed. An unknown outcome is never retryable on its own.
    pub fn is_retryable(&self) -> bool {
        match self {
            Self::Api(error) => error.retryable,
            Self::OutcomeUnknown(_) => false,
        }
    }

    /// The API error behind this failure. For an unknown outcome this is its cause.
    pub fn api_error(&self) -> &APIError {
        match self {
            Self::Api(error) => error,
            Self::OutcomeUnknown(error) => &error.cause,
        }
    }

    /// Returns the unknown-outcome payload when this is one.
    pub fn outcome_unknown(&self) -> Option<&OutcomeUnknownError> {
        match self {
            Self::OutcomeUnknown(error) => Some(error.as_ref()),
            Self::Api(_) => None,
        }
    }
}

impl From<APIError> for Error {
    fn from(error: APIError) -> Self {
        Self::Api(error)
    }
}

impl From<OutcomeUnknownError> for Error {
    fn from(error: OutcomeUnknownError) -> Self {
        Self::OutcomeUnknown(Box::new(error))
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Api(error) => error.fmt(f),
            Self::OutcomeUnknown(error) => error.fmt(f),
        }
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Api(error) => Some(error),
            Self::OutcomeUnknown(error) => Some(error.as_ref()),
        }
    }
}

/// Converts any error into an [`APIError`], treating foreign errors as network failures.
pub(crate) fn as_api_error(error: Error) -> APIError {
    match error {
        Error::Api(error) => error,
        Error::OutcomeUnknown(error) => error.cause,
    }
}

/// An error field from an HTTP or channel response.
#[derive(Debug, Clone, Default)]
pub(crate) struct WireError {
    pub code: Option<String>,
    pub message: Option<String>,
    pub details: Option<Map<String, Value>>,
    pub retryable: bool,
}

impl WireError {
    pub(crate) fn into_error(self, status: u16, request_id: Option<String>) -> APIError {
        match (self.code, self.message) {
            (Some(code), Some(message)) => APIError {
                code,
                message,
                details: self.details,
                retryable: self.retryable,
                status,
                request_id,
            },
            _ => APIError {
                code: "PROTOCOL_ERROR".to_string(),
                message: "Invalid error response".to_string(),
                details: None,
                retryable: false,
                status,
                request_id,
            },
        }
    }
}

/// Parses a wire error object. Returns `None` when the value is `null` or absent; a non-object
/// value is reported as an invalid error response.
pub(crate) fn parse_wire_error(value: &Value) -> Result<Option<WireError>, APIError> {
    match value {
        Value::Null => Ok(None),
        Value::Object(object) => {
            let code = match object.get("code") {
                None | Some(Value::Null) => None,
                Some(Value::String(code)) => Some(code.clone()),
                Some(_) => {
                    return Err(APIError::new(
                        "PROTOCOL_ERROR",
                        "Invalid error response",
                        false,
                    ))
                }
            };
            let message = match object.get("message") {
                None | Some(Value::Null) => None,
                Some(Value::String(message)) => Some(message.clone()),
                Some(_) => {
                    return Err(APIError::new(
                        "PROTOCOL_ERROR",
                        "Invalid error response",
                        false,
                    ))
                }
            };
            let details = object.get("details").and_then(Value::as_object).cloned();
            let retryable = object
                .get("retryable")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            Ok(Some(WireError {
                code,
                message,
                details,
                retryable,
            }))
        }
        _ => Err(APIError::new(
            "PROTOCOL_ERROR",
            "Invalid error response",
            false,
        )),
    }
}

/// Converts a Phoenix error reply into an [`APIError`].
pub fn channel_error(payload: &Value) -> APIError {
    if let Some(error) = payload.get("error").filter(|value| value.is_object()) {
        let status = payload.get("status").and_then(number_to_u16).unwrap_or(0);
        let wire = match parse_wire_error(error) {
            Ok(Some(wire)) => wire,
            _ => {
                return APIError::new("PROTOCOL_ERROR", "Invalid error response", false)
                    .with_status(status)
            }
        };
        return wire.into_error(status, None);
    }
    APIError::new(
        "PROTOCOL_ERROR",
        "The server returned an invalid channel response",
        false,
    )
}

fn number_to_u16(value: &Value) -> Option<u16> {
    if let Some(number) = value.as_u64() {
        return u16::try_from(number).ok();
    }
    let number = value.as_f64()?;
    if number.is_finite() && number.fract() == 0.0 && number >= 0.0 && number <= u16::MAX as f64 {
        Some(number as u16)
    } else {
        None
    }
}
