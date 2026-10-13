# Security policy

Chillar has access to a brokerage account, so security reports are taken seriously.

## Reporting a vulnerability

Please **don't open a public issue**. Use GitHub's private vulnerability reporting
(Security → Report a vulnerability) on this repository. Include steps to reproduce and the impact.
You should get a response within 7 days.

Never include a real access token in a report. If you've shared one, revoke it on web.dhan.co.

## Scope

In scope: token handling and storage, order placement logic, network requests, the build and signing scripts.

Out of scope: Dhan's own APIs and web app (report those to Dhan), and attacks that need an
already-compromised user account on the Mac.

## Design principles

- Read-only by default; placing orders needs an explicit opt-in and a second confirmation click.
- Secrets live only in the Keychain; nothing sensitive is written to disk, logs or the UI.
- No dependencies and no servers other than `api.dhan.co`.
