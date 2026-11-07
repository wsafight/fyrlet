//! Inbox runs against a running Fyrlet server:
//!
//! ```text
//! FYRLET_ENDPOINT=http://127.0.0.1:4000 FYRLET_PROJECT_ID=... FYRLET_SERVICE_KEY=rtk_... \
//!   cargo run --example inbox -- "First note"
//! ```
//!
//! In a real application the `SessionService` runs on your backend and only the token reaches the
//! client.

use fyrlet::{Client, IssueSessionInput, Options, SessionService, SubscriptionState};
use serde::Deserialize;
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;

#[derive(Debug, Deserialize)]
struct Item {
    text: String,
}

fn main() -> Result<(), fyrlet::Error> {
    let endpoint = std::env::var("FYRLET_ENDPOINT").expect("FYRLET_ENDPOINT");
    let project_id = std::env::var("FYRLET_PROJECT_ID").expect("FYRLET_PROJECT_ID");
    let service_key = std::env::var("FYRLET_SERVICE_KEY").expect("FYRLET_SERVICE_KEY");

    let sessions = Arc::new(SessionService::new(&endpoint, &service_key)?);
    let issuer = sessions.clone();
    let client = Client::new(Options::new(endpoint, project_id, move |_force_refresh| {
        Ok(issuer
            .issue_session(IssueSessionInput::new("example-user").with_ttl_seconds(600))?
            .token)
    }))?;

    let recent = client.subscribe("inbox.recent", json!({"limit": 20}))?;
    let _listener = recent.on_change(render);

    let texts: Vec<String> = if std::env::args().len() > 1 {
        std::env::args().skip(1).collect()
    } else {
        vec!["Hello from Rust".to_string()]
    };
    for text in texts {
        client.call("inbox.add", json!({"text": text}))?;
    }
    std::thread::sleep(Duration::from_secs(1)); // let the delta arrive before exiting
    client.close();
    Ok(())
}

fn render(state: SubscriptionState) {
    let items: Vec<Item> = state.decode().unwrap_or_default();
    let texts: Vec<&str> = items.iter().map(|item| item.text.as_str()).collect();
    println!("{} {:?}", state.status, texts);
}
