# Security And Risk

## Credential Handling

- DPAPI tokens are user-scoped. Do not copy `app_state.json` or decrypted node
  JSON to another machine.
- Never commit node addresses, passwords, UUIDs, short IDs, subscription URLs,
  or full proxy URLs.
- Logs must be redacted by default.
- The scripts in this repository hash node IDs, exit IPs, and native errors by
  default.
- A crash dump or verbose sing-box log may contain node credentials. Protect
  local artifacts accordingly.

## Network Exposure

- Bind mixed inbounds to `127.0.0.1` only.
- A local HTTP/SOCKS listener without authentication is usable by any process
  that can reach it.
- If 9Router is remote, use an SSH tunnel or WireGuard. Avoid a public reverse
  proxy unless it has authentication and source-address restrictions.
- Windows Firewall should block the port range from non-loopback interfaces.

## Account And ToS Risk

- Multi-exit use may conflict with VPN provider terms.
- The provider may enforce device limits, concurrent-session limits, or abuse
  detection.
- Many simultaneous provider connections through different exits can increase
  rate-limit and fraud-detection risk.
- IP reputation may vary by node and change during refresh.

This repository documents technical feasibility; it does not provide legal or
provider-policy approval.

## 9Router Risk

- Do not write the live SQLite database while 9Router is running.
- Use API calls for changes.
- The local admin API accepts an `x-9r-cli-token` derived from `machine-id` and
  `auth/cli-secret`. Treat both files as local admin credentials. Never print,
  persist, or pass the derived token on a command line.
- Refuse non-loopback 9Router URLs in broker and inventory scripts.
- Keep the original `vpncheap` pool as an unbound retained object.
- Do not change an existing connection binding unless the exact
  connection-to-pool mapping is reviewed and `-AllowRebind` is supplied.
- Pools created for this adapter use `strictProxy=true` so a dead loopback exit
  cannot silently fall back to direct egress.
- Proxy pool tests mutate `testStatus` and `lastError`, so even a "test" is a
  write.
- API keys for provider connections are credentials. Never print them in logs
  or diffs.
- The apply ledger contains local object IDs and previous binding IDs, not
  provider API keys. Protect it with the same user ACL as the 9Router data
  directory.

## Operational Risk

- Port reuse can send traffic to a stale pool.
- Worker crashes can orphan local listeners or leave dead pools active.
- The scheduled task uses an interactive-logon trigger, so the broker and its
  loopback exits are available only while that user session is active.
- Node catalogs can rotate or expire.
- Hysteria2 often uses UDP/QUIC; networks that block UDP may fail even when
  TCP proxy types work. Conversely, on this host hysteria2 worked while all
  five sampled anytls nodes failed their session handshake.
- A public IP can differ by destination or DNS resolution. Use the same public
  IP service for all exits when comparing uniqueness.
