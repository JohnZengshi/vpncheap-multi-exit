# Evidence Ledger

The retained REA evidence lives under the read-only source project:
`C:\Work\vpncheap-console\.rea`. This file records only conclusions and
reproduction commands. It does not contain node addresses, credentials, UUIDs,
subscription URLs, or full proxy URLs.

## Static Evidence

| Evidence ID | Source | Observation | Confidence |
| --- | --- | --- | --- |
| `ev_be1f4b1fc1a1020c772b729238e7104036a4d367a6cc74d98e131559bf5e8977` | `SingBoxConfigBuilder` managed inspection | `Build(XboardNode, SingBoxConfigOptions) -> string`; `MixedListenPort`, `EnableClashApi`, and `UseRemoteRuleSets` are configurable. | Observed managed metadata |
| `ev_85db7df8af3949967ddf3bc77493ae3eb4b956d12c6814c13be41069c404104e` | Interop inspection | Managed interop surface used by the probe. Preserve the build-local artifact SHA-256 and MVID. | Observed managed metadata |
| `ev_a5a6f95327999a52569a5f2985541add5d6aa6cb2a97c2aec4a83898fcea4326` | sing-box service inspection | Native service API shape and ownership boundaries. | Observed declaration; runtime behavior tested separately |
| `ev_5d0db41ab0a32144406e64c7ff546e6e502d85a46939413c66640990df9e30b7` | `VpncheapWindows.Core.dll` | Managed/native interop surface used for DPAPI unprotect. | Observed declaration |

Artifact identity:

- `VpncheapWindows.Core.dll` SHA-256:
  `225dedd1c5f0f660c79459b06792dd937260a31f11befe8a084b8ad9637c0edd`
- Managed MVID: `c5f081ea-8786-4024-a528-9b8393716c34`
- `sing-box.dll` SHA-256:
  `658189b221c65a39758e0c60e2df55e16c037d5f482469b1d41c6c435af469b3`
- sing-box version reported at runtime: `1.13.6`

## State And Config Observations

- VPNCheap state file:
  `C:\Users\ONE\AppData\Roaming\vpncheap\app_state.json`
- Bound catalog location:
  `xboard_node_catalogs_bound_v3.Accounts.<account>.PayloadToken`
- DPAPI associated data:
  `vpncheap-node-cache|schema=3|type=catalog|account=<UserId>|generation=<AccountGeneration>`
- Decrypted payload is a JSON array. Each node contains `id`, `name`,
  `protocol`, `address`, `port`, `country_code`, `groups`, `online`, and
  `raw_outbound`.
- Observed `raw_outbound` keys for hysteria2: `type`, `tag`, `server`,
  `server_port`, `password`, `up_mbps`, `down_mbps`, `tls`, `obfs`. Nested TLS
  keys observed: `enabled`, `insecure`, `server_name`.
- The probe does not call `SingBoxConfigBuilder.Build()`. That builder uses
  VPNCheap rule-set paths and remote rule sets, which fail outside the installed
  layout. The probe wraps `raw_outbound` in a minimal config with no rule sets.

## Runtime Observations

All runtime checks were performed on this Windows host with the current
Windows user. Node IDs are shown only as SHA-256 prefixes.

### Catalog

Command:

```powershell
pwsh -NoProfile -File .\scripts\recover-vpncheap-state.ps1
```

Observed:

- 59 online unique nodes.
- Protocol split: 45 anytls, 14 hysteria2.

### Hysteria2 Multi-Exit

Command:

```powershell
pwsh -NoProfile -File .\scripts\multiexit-probe.ps1 -MaxNodes 14 -MaxAttempts 14 -Protocol hysteria2 -PortBase 39401 -ProbeTimeoutSec 10
```

Observed:

- 13 of 14 nodes started and passed the local HTTP 204 health check.
- 13 distinct public exit IP hashes.
- One JP node failed with `schannel: failed to receive handshake` (curl exit 35)
  after 0.26 seconds.
- Healthy responses completed in roughly 0.2 to 3.4 seconds.
- Two-node run with `-RequireDistinctExitIps` passed:
  exit IP hashes `dbadf2e01d813bdd716f` and `d04a20ff5ed31797be19`.

### Long-Running Broker

Command:

```powershell
pwsh -NoProfile -File .\scripts\broker.ps1 -Action start -MaxExits 2 -Protocol hysteria2 -HealthIntervalSec 15 -ProbeTimeoutSec 25 -StartupTimeoutSec 45
pwsh -NoProfile -File .\scripts\broker.ps1 -Action status
```

Observed:

- Broker instance `a79c9408-ca42-481d-a692-b74ceaf0c6fe` started at
  `2026-10-20T01:57:03Z`.
- Two hysteria2 exits on ports 39001 and 39002 stayed healthy for over one hour.
- Health checks ran every 15 seconds; the catalog refreshed every 300 seconds
  (11 successful refreshes observed).
- Exit IP hashes remained distinct:
  `d04a20ff5ed31797be19` and `190bd88b7a4506791786`.
- A fresh request through each port returned HTTP 204 in 1.7 seconds and
  5.35 seconds respectively.
- One exit showed occasional health latency between 3.6 and 8.1 seconds.

Isolation test:

- Killed worker PID 19376 (port 39002).
- The supervisor restarted it as PID 19060 with `restartCount=1`.
- Port 39001 stayed healthy during the restart.
- Port 39002 returned to healthy on the same port after warm-up.

Redaction scan:

- Searched `runtime/*.json`, `runtime/workers/*.json`, and `runtime/logs/*.log`
  for IPv4 literals, `password`, `hysteria2://`, `x-9r-cli-token`, and
  `apiKey`.
- No matches.

9Router live apply (2026-10-20):

- Created `vpncheap-39001` for port 39001 and `vpncheap-39002` for port 39002.
- Both pools were changed from `strictProxy=false` to `strictProxy=true` and
  tested as `active`.
- Connection `fd0ba669-98e8-490d-a67a-d388403eb2d3` (`codex`) was rebound from
  the original `vpncheap` pool to `vpncheap-39001`.
- Connection `86e2d8e5-aa7b-422d-9e9e-39552d9f0a90` (`claude`) was rebound from
  the original `vpncheap` pool to `vpncheap-39002`.
- The rebind required `-AllowRebind` and an explicit connection-to-pool
  mapping. The previous pool ID was written to the local ledger for rollback.
- Re-running the planner with the same mapping produced two `exists` pool
  actions and two `exists` binding actions, with no conflicts or pending
  updates.
- The original `vpncheap` pool remains present and active with zero bound
  connections, so no provider connection currently routes through it.

Broker startup:

- Scheduled task `vpncheap-multi-exit-broker` is running under the current
  interactive user.
- Trigger is at user logon; multiple instances are ignored; restart count is
  999 with a one-minute interval; execution time limit is unlimited.
- Task last result `267009` (`0x41301`) is the Windows "task is currently
  running" status, not a failure.

### AnyTLS

Command:

```powershell
pwsh -NoProfile -File .\scripts\multiexit-probe.ps1 -MaxNodes 1 -MaxAttempts 5 -Protocol anytls -PortBase 39301 -ProbeTimeoutSec 8
```

Observed:

- 0 of 5 sampled nodes connected.
- sing-box reported `failed to create session: EOF` or a closed socket for each
  node.
- Every local health request then timed out at 8 seconds.
- This is a network/protocol observation, not proof that all anytls nodes are
  permanently dead.

### 9Router API

Observed:

- `GET /api/proxy-pools?isActive=true&includeUsage=true` without auth: HTTP 401.
- Same request with the local `x-9r-cli-token` header: HTTP 200.
- `GET /api/providers` with the same header: HTTP 200.
- Provider connections: 8.
- Live pools: 3.
- `vpncheap`: active, `strictProxy=true`, test status `active`, zero bound
  connections.
- `vpncheap-39001`: active, `strictProxy=true`, test status `active`, one bound
  connection.
- `vpncheap-39002`: active, `strictProxy=true`, test status `active`, one bound
  connection.
- Connections bound to a pool: 2.

Command:

```powershell
pwsh -NoProfile -File .\scripts\9router-inventory.ps1 -ShowNames
```

The inventory script reads `machine-id` and `auth/cli-secret` to derive the
token in memory. It never prints the token, proxy URLs, or credentials.

## Provider Binding Correction

After the earlier rebind evidence above, the operator explicitly prohibited
changing provider proxies. Observed on 2026-10-20:

- `vpncheap-39001`: active, `strictProxy=true`, test status `active`, zero bound
  connections.
- `vpncheap-39002`: active, `strictProxy=true`, test status `active`, zero bound
  connections.
- `vpncheap`: active, `strictProxy=true`, test status `active`, two bound
  connections.
- `codex` connection `fd0ba669-98e8-490d-a67a-d388403eb2d3`:
  `proxyPoolId=3728b7ab-0674-4c8d-8dca-163eb019742e` (`vpncheap`).
- `claude` connection `86e2d8e5-aa7b-422d-9e9e-39552d9f0a90`:
  `proxyPoolId=3728b7ab-0674-4c8d-8dca-163eb019742e` (`vpncheap`).

The managed-binding list in the local ledger is now empty. The pools and their
rollback metadata remain.

## Pool Names Matched To Nodes (2026-10-20)

After restarting the broker, `runtime/status.json` recorded the VPNCheap node
name for each exit:

- Port 39001: `HK-香港2-UDP`, node hash prefix `79f638a89e49f904`.
- Port 39002: `HK-香港3-UDP`, node hash prefix `cba70e1e6c51ae1d`.

The two 9Router pools were renamed with `PUT /api/proxy-pools/:id`, sending only
the `name` field:

- `vpncheap-HK-香港2-UDP`: pool ID
  `153bcddc-d985-4c09-8499-162b1a911622`, URL unchanged at
  `http://127.0.0.1:39001`.
- `vpncheap-HK-香港3-UDP`: pool ID
  `734bcd1f-aa73-4504-af79-b6af456f4927`, URL unchanged at
  `http://127.0.0.1:39002`.

Verification after the rename:

- Both pools remained `isActive=true`, `strictProxy=true`, test status `active`,
  with zero bound connections.
- Connections `fd0ba669-98e8-490d-a67a-d388403eb2d3` and
  `86e2d8e5-aa7b-422d-9e9e-39552d9f0a90` still use the original
  `vpncheap` pool `3728b7ab-0674-4c8d-8dca-163eb019742e`.
- Planner reported two `exists` actions, no warnings, no conflicts, and a dry
  run reported zero pools to create or update.
- Proxy health checks through both ports returned HTTP 204.

## Unknowns

- Sustained concurrency across 13 exits, and whether the provider rate-limits or
  flags this pattern.
- Whether 9Router schedules multiple provider connections fairly enough to use
  all pools concurrently.
- How often VPNCheap rotates, expires, or invalidates cached node tokens.
- Whether the anytls failures are local network policy, server-side blocking, or
  a protocol/config mismatch.
- Whether hysteria2 QUIC remains stable across other networks and over long
  periods.
- Whether the provider's terms permit this local multi-session pattern.
- Whether 9Router background workers rewrite `testStatus` or `lastError` during
  an external apply.
