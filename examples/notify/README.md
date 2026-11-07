# Notify: notification center

English | [简体中文](README.zh-CN.md)

A standalone notification application with a `Notification` model, migrations, a Chinese-language web page and the real SDK. `notify.send` saves an in-app notification through a managed commit before dispatching an email Effect. `notify.inbox` is isolated by project and user; delivery, failure, cancellation and Run state update live. `event_id` is deduplicated per user, so different users may reuse the same event ID.

## Startup

Prepare the SDK using the [shared startup steps](../README.md), then migrate and issue a development session in `examples/notify`. To send real email, configure:

```sh
export RESEND_API_KEY='your Resend API key'
export MAIL_FROM='sender address on a verified domain'
mix fyrlet.migrate --create
PHX_SERVER=false mix run ../../scripts/example_session.exs alice
PHX_SERVER=true PORT=4180 mix phx.server
```

## Demo and delivery states

Open `http://127.0.0.1:4180/`, enter the project ID and user token, then fill in a recipient, subject and message to inspect Run and delivery state. Keys are used only by the server adapter. The default provider is `FyrletEffectEmail.Resend`: it sends with a stable idempotency key and reconciles by querying the provider ID. `accepted` means the provider accepted the request; `delivered` means the provider reported delivery. Timeouts and unconfirmed outcomes remain `unknown`.

## Verification and boundaries

`mix test` runs 8 domain tests. From the repository root, `DOMAIN_PORT=4182 DOMAIN_PROVIDER_PORT=4183 bash scripts/domains.sh notify` verifies live in-app updates, the email adapter and reconciliation after acceptance. `bash scripts/browser.sh notify` also checks desktop and two mobile viewports. The email package has 12 additional tests, including a local HTTP provider protocol test.

`bash scripts/mail_live.sh --check` checks real-delivery configuration; `bash scripts/mail_live.sh` sends an actual email. Explicitly configure `RESEND_API_KEY`, a verified `MAIL_FROM` and `MAIL_TO`. The tool submits a real Notify Run, reuses an idempotency key for repeated requests, waits for provider-confirmed delivery and completed in-app state, and writes `.local/mail-live/result.json`. After a timeout, inspect the Run in that report before sending again. Real delivery and bounces have not yet been verified. Multiple channels, templates and user preferences are outside the current implementation.
