# Changelog

## 1.0.0 (2026-10-13)

First public release.

- Live F&O P&L in the macOS menu bar, colored for profit and loss, on a white pill.
- Compact positions panel: strike, CE/PE, expiry, qty, avg → LTP, % move, P&L; booked/open, day high/low, funds.
- Dhan adapter: positions, funds, optional live LTP (Data APIs), self-renewing session.
- Market-hours-aware refresh: 1s while open, 30s around open and close, 15 min after hours; instant on panel open and wake.
- Optional, off-by-default, **experimental** exit orders: limit only (≤3% from current price), two-step confirm with price, quantity and working-order re-checks that fail closed, tagged orders with post-timeout lookup, and live tracking until filled or rejected.
- Security: Keychain-only token, App Sandbox, hardened runtime, host-pinned HTTPS with redirects refused and no disk cache.
- Opens at login by default.
