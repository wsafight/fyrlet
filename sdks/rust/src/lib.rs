//! The Fyrlet Rust client: authenticated operations plus recoverable realtime subscriptions over
//! Phoenix Channels.
//!
//! The client is blocking and thread-based, mirroring the Go SDK. Create one [`Client`] per project
//! and user, call operations with [`Client::call`], and observe subscriptions with
//! [`Subscription::on_change`]. HTTP requests and socket replies are bounded by [`Options::timeout`].
//!
//! # Example
//!
//! ```no_run
//! use fyrlet::{Client, Options};
//! use serde_json::json;
//!
//! # fn main() -> Result<(), fyrlet::Error> {
//! let client = Client::new(Options::new(
//!     "http://127.0.0.1:4000",
//!     "project-id",
//!     |_force_refresh| Ok("rts_token".to_string()),
//! ))?;
//! let created = client.call("inbox.add", json!({"text": "Hello"}))?;
//! # let _ = created;
//! client.close();
//! # Ok(())
//! # }
//! ```

mod client;
mod delta;
mod errors;
mod phoenix;
mod server;
mod subscription;

#[cfg(test)]
mod tests;

pub use client::{
    endpoint_url, CallOptions, Client, GetToken, ListenerErrorHandler, Mutation, MutationState,
    MutationStatus, NewId, Options, RecoveryResult, RetryDelay,
};
pub use delta::{apply_delta, InvalidDelta, MAX_ITEMS};
pub use errors::{channel_error, APIError, Error, OutcomeUnknownError};
pub use phoenix::{auth_protocol, decode_frames, socket_url, Frame, MAX_BATCH, MAX_MESSAGE_BYTES};
pub use server::{IssueSessionInput, SessionService, UserSession};
pub use subscription::{
    Ack, Entry, Identity, ListenerGuard, Subscription, SubscriptionState, SubscriptionStatus,
    PROTOCOL_VERSION,
};
