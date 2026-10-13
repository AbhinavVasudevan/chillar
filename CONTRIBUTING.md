# Contributing

Thanks for helping. Chillar touches people's trading accounts, so changes are reviewed with safety first.

## Setup

```sh
./scripts/create-signing-cert.sh   # once
./scripts/test.sh                  # unit tests, no account needed
./build.sh dev                     # UI build with the snapshot tool
build/Chillar.app/Contents/MacOS/Chillar --snapshot out.png --fixture Fixtures
```

You don't need a broker account for most work: `Fixtures/` has made-up data.

## Ground rules

- **Never commit real data:** no tokens, client IDs, real API responses or account screenshots. Fixtures must be made up.
- **No dependencies.** Apple frameworks only.
- **Network:** only through `HTTPClient`, only to the broker's API host.
- **Orders:** any code path that can place an order must stay behind the "Allow closing positions" setting
  and the two-step confirm, re-check the position and working orders immediately before sending, and use
  limit orders only.
- Keep the UI quiet and native: color is for P&L.

## Adding a broker

See [Adding a broker](README.md#adding-a-broker). Include fixture data and tests for the position mapping
(`Tests/ChillarTests.swift`), especially quantities, short positions and P&L/price derivation.

## Security issues

Please don't open public issues. See [SECURITY.md](SECURITY.md).
