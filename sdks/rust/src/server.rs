//! Session exchange for trusted backends. The service key must never reach a browser or app
//! binary.

use crate::client::{encode_path_segment, endpoint_url, http_json};
use crate::errors::Error;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::time::Duration;

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(10);

/// A short-lived user session issued by a trusted backend.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct UserSession {
    /// The user session token (`rts_...`).
    pub token: String,
    /// The project the session belongs to.
    #[serde(default)]
    pub project_id: String,
    /// The authenticated subject.
    #[serde(default)]
    pub subject_id: String,
    /// The session identifier used for revocation.
    #[serde(default)]
    pub session_id: String,
    /// The expiry timestamp supplied by the server.
    #[serde(default)]
    pub expires_at: String,
}

/// Describes the user to sign in.
#[derive(Debug, Clone, Serialize)]
pub struct IssueSessionInput {
    /// The application's verified login identifier.
    pub external_subject: String,
    /// Optional issuer label.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub issuer: Option<String>,
    /// Optional session lifetime in seconds.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ttl_seconds: Option<u64>,
}

impl IssueSessionInput {
    /// Creates input for one external subject.
    pub fn new(external_subject: impl Into<String>) -> Self {
        Self {
            external_subject: external_subject.into(),
            issuer: None,
            ttl_seconds: None,
        }
    }

    /// Sets the issuer label.
    pub fn with_issuer(mut self, issuer: impl Into<String>) -> Self {
        self.issuer = Some(issuer.into());
        self
    }

    /// Sets the requested session lifetime.
    pub fn with_ttl_seconds(mut self, ttl_seconds: u64) -> Self {
        self.ttl_seconds = Some(ttl_seconds);
        self
    }
}

/// Exchanges application logins for Fyrlet user sessions. Use it only on trusted backends.
pub struct SessionService {
    endpoint: String,
    service_key: String,
    timeout: Duration,
    agent: ureq::Agent,
}

impl SessionService {
    /// Creates a session service. The key must begin with `rtk_`.
    pub fn new(endpoint: &str, service_key: &str) -> Result<Self, Error> {
        Self::with_timeout(endpoint, service_key, DEFAULT_TIMEOUT)
    }

    /// Creates a session service with a custom request timeout.
    pub fn with_timeout(
        endpoint: &str,
        service_key: &str,
        timeout: Duration,
    ) -> Result<Self, Error> {
        if !service_key.starts_with("rtk_") {
            return Err(Error::api(
                "VALIDATION_FAILED",
                "expected a backend service key",
                false,
            ));
        }
        Ok(Self {
            endpoint: endpoint_url(endpoint)?,
            service_key: service_key.to_string(),
            timeout: if timeout.is_zero() {
                DEFAULT_TIMEOUT
            } else {
                timeout
            },
            agent: ureq::AgentBuilder::new().redirects(0).build(),
        })
    }

    fn headers(&self) -> Vec<(String, String)> {
        vec![(
            "authorization".to_string(),
            format!("Bearer {}", self.service_key),
        )]
    }

    /// Creates a session for an externally authenticated subject.
    pub fn issue_session(&self, input: IssueSessionInput) -> Result<UserSession, Error> {
        let body = serde_json::to_value(&input)
            .map_err(|error| Error::api("PROTOCOL_ERROR", error.to_string(), false))?;
        let envelope = http_json(
            &self.agent,
            "POST",
            &format!("{}/api/v1/sessions", self.endpoint),
            &self.headers(),
            Some(&body),
            self.timeout,
        )?;
        let session: UserSession =
            serde_json::from_value(envelope.data).map_err(|_| invalid_session_response())?;
        if session.token.is_empty() {
            return Err(invalid_session_response());
        }
        Ok(session)
    }

    /// Revokes one session of this project.
    pub fn revoke_session(&self, session_id: &str) -> Result<bool, Error> {
        let envelope = http_json(
            &self.agent,
            "DELETE",
            &format!(
                "{}/api/v1/sessions/{}",
                self.endpoint,
                encode_path_segment(session_id)
            ),
            &self.headers(),
            None,
            self.timeout,
        )?;
        match envelope.data {
            Value::Object(object) => Ok(object
                .get("revoked")
                .and_then(Value::as_bool)
                .unwrap_or(false)),
            _ => Err(invalid_revoke_response()),
        }
    }
}

fn invalid_session_response() -> Error {
    Error::api("PROTOCOL_ERROR", "Invalid session response", false)
}

fn invalid_revoke_response() -> Error {
    Error::api("PROTOCOL_ERROR", "Invalid revoke response", false)
}
