# Feasibility

## Verdict

Local multi-exit is feasible on this Windows host. The VPNCheap client does not
need to be deployed to a server for this architecture.

Measured on 2026-10-20:

- 59 online nodes were readable from the DPAPI-bound catalog.
- Protocol split: 45 anytls, 14 hysteria2.
- Hysteria2 scan: 13 of 14 nodes produced healthy loopback exits.
- Those 13 exits produced 13 distinct public exit IP hashes.
- One JP hysteria2 node failed its TLS handshake.
- AnyTLS scan: 0 of 5 sampled nodes connected; all failed during session setup
  with `EOF` or a closed socket, then the local probe timed out.

This proves the transport path end to end for hysteria2: DPAPI catalog read,
minimal sing-box config, native service start, loopback mixed listener, HTTP
proxy request, and distinct public egress.

A supervisor/worker broker was then run with two exits from
2026-10-20T01:57Z. It stayed healthy for over an hour with a 15-second health
interval and a 5-minute catalog refresh. Killing one worker restarted only that
exit; the other exit stayed healthy, and the replacement worker returned to
healthy on the same port with a new PID. Runtime JSON and logs contained no node
addresses, passwords, proxy URLs, or 9Router tokens.

What is not proven yet: sustained concurrency across all 13 exits, provider
rate-limit behavior at that scale, and per-provider traffic distribution under
load. The 9Router adapter was applied live on 2026-10-20: it created and tested
two strict pools and bound one explicitly selected connection to each. A repeat
plan reports both pools and bindings as `exists`.

## Chosen Architecture

```text
VPNCheap app_state.json (Windows user DPAPI)
  -> read-only unprotect
  -> in-memory node catalog
  -> one minimal sing-box config per node
  -> one native sing-box service per exit
  -> 127.0.0.1:39001..39999 mixed inbound
  -> one 9Router proxy pool per port
  -> one or more provider connections bound to each pool
```

The probe deliberately bypasses `SingBoxConfigBuilder.Build()`. The builder
references VPNCheap rule-set files and remote rule sets, which fail outside the
installed application layout. The probe instead takes the node's own
`raw_outbound` object and wraps it in a minimal config with:

- a loopback `mixed` inbound;
- one node outbound;
- one `direct` outbound;
- `route.final` pointing at the node outbound;
- a local UDP DNS server;
- no rule sets.

This is enough for transport proof and removes an unnecessary dependency on the
VPNCheap rule-set layout.

## Why Multiple Pools

9Router stores one `proxyUrl` per proxy pool. It cannot accept a list of exits in
one pool. The workable mapping is:

```text
pool-vpn-01 -> http://127.0.0.1:39001
pool-vpn-02 -> http://127.0.0.1:39002
pool-vpn-03 -> http://127.0.0.1:39003
```

A provider connection carries `providerSpecificData.proxyPoolId`, so each
connection is bound to exactly one pool. To use several exits concurrently,
9Router needs several connections, each bound to a different pool. Adding the
same upstream account repeatedly may hit account, device, rate, or policy
limits; that is an operator decision, not a technical shortcut.

## Measured Capacity

The current catalog contains 14 hysteria2 nodes and 13 healthy exits. Treat this
as a dynamic pool, not a fixed inventory:

- nodes can rotate, expire, or change address;
- a node marked online can still fail a handshake;
- one bad node must not stop the other exits;
- 9Router's pool test has a short timeout, so publish only ports that already
  pass a local health check.

AnyTLS is not usable on this network today. Do not build the broker around it
without a separate diagnosis of the handshake failures.

One hysteria2 exit has shown local health latency between roughly 3.6 and 8.1
seconds. 9Router's pool test uses an 8-second timeout against
`https://google.com/`, so a port that is healthy but consistently slow can still
be marked `error`. Publish only exits with a comfortable latency margin, and
re-check immediately before creating a pool.

## Server Deployment

Direct deployment to a Linux server is not a drop-in operation:

- `app_state.json` payloads are DPAPI-bound to the current Windows user;
- `sing-box.dll` is a Windows native library loaded through P/Invoke;
- copying decrypted node credentials or DPAPI blobs to a server changes the
  credential boundary and may violate the provider's terms.

Supported options, in order of preference:

1. Run the broker and 9Router on the same Windows machine.
2. Run the broker on a Windows VM and connect 9Router over WireGuard or SSH.
3. Rebuild acquisition against the service API only after reviewing terms,
   device limits, and credential handling.

Never expose the loopback mixed ports directly to the public network. A mixed
inbound has no authentication.

## 9Router Authentication

The admin API is not open on localhost. An unauthenticated
`GET /api/proxy-pools` returned HTTP 401.

The packaged 9Router server accepts a local CLI token in the
`x-9r-cli-token` header. The token is derived from:

```text
sha256(machine-id + "9r-cli-auth" + auth/cli-secret).substring(0, 16)
```

With that token, read-only pool and provider inventory returned HTTP 200. The
broker should compute the token in memory at startup, never print it, never put
it in a command line, and never persist it.

The current live state is:

- 8 provider connections;
- 3 proxy pools: the original `vpncheap` pool plus `vpncheap-39001` and
  `vpncheap-39002`;
- all three pools are active, `strictProxy=true`, and report test status
  `active`;
- `codex` is bound to `vpncheap-39001`, and `claude` is bound to
  `vpncheap-39002`;
- the original `vpncheap` pool has no bound connection and is retained as an
  unbound fallback object, not an active traffic route.

`strictProxy=true` is deliberate: if a bound loopback exit fails, 9Router should
fail the request instead of silently bypassing the pool and using direct
network egress. The adapter remains read-only by default and requires exact
connection-to-pool mappings plus `-AllowRebind` before changing an existing
binding.

The broker is installed as the scheduled task
`vpncheap-multi-exit-broker`. It starts at user logon, runs hidden, ignores new
instances, and restarts after failure.

## Implementation Phases

### P0: Transport Proof

Status: complete.

- Read the catalog through DPAPI.
- Build a minimal per-node config.
- Start one native service per node.
- Verify HTTP 204 through the loopback port.
- Verify a public IP through the loopback port.
- Compare exit IP hashes across nodes.

### P1: Local Broker

Status: complete at two exits.

Implemented:

- owns a stable port range;
- starts one worker process per exit;
- keeps node credentials inside the worker;
- refreshes the catalog on a schedule;
- health-checks each port;
- quarantines nodes after repeated failures;
- restarts a failed worker with backoff;
- exposes a redacted local status endpoint.

Verified:

- two exits stayed healthy for more than 30 minutes (over one hour observed);
- killing one worker did not affect the other exit;
- the killed worker was restarted and returned to healthy on the same port;
- no node secret appeared in logs or status output;
- the restarted worker rebound the port, so the closed worker released it.

Still open at this stage: simultaneous health across more than two exits.

### P2: 9Router Adapter

Status: complete and applied live on 2026-10-20.

The implemented sequence is:

1. Read pools and connections.
2. Refuse to change an existing binding unless the exact connection and target
   pool are supplied with `-BindConnectionPool` and `-AllowRebind`.
3. Propose one pool per healthy port.
4. Reuse a matching pool by name and URL, and propose a strict/active update
   when needed.
5. On `-Apply`, create missing pools through `POST /api/proxy-pools`, update
   strict/active state, test selected pools, then bind only the named
   connections.
6. Re-read state and record every create, update, and rebind in a local ledger.

Do not write the live SQLite database while 9Router is running.

Acceptance:

- both new pools test `active` - passed;
- each bound connection shows the expected `proxyPoolId` - passed;
- a second plan reports both pools and bindings as `exists` - passed;
- the two broker exits return distinct public exit IP hashes - passed;
- traffic distribution through the two provider connections at scale remains
  an operational check.

### P3: Operations

- Scheduled task with logon trigger, hidden execution, single-instance policy,
  unlimited runtime, and restart-on-failure - implemented.
- Log rotation and recurring redaction tests - open.
- Catalog refresh, node replacement, and port ownership monitoring - partially
  implemented; sustained validation is open.
- Port and firewall audit - open.
- Monitoring for healthy-exit count and handshake error rate - open.

## Go / No-Go

Go for a hysteria2-based local broker.

No-Go for an anytls-based broker on this network until the handshake failures
are explained. No-Go for copying the DPAPI state or Windows native library to a
Linux server.

The remaining risk is operational, not architectural: account limits, node
churn, UDP blocking on other networks, and 9Router scheduling behavior.

## Related Documents

- `FEASIBILITY.zh-CN.md`: Chinese feasibility and delivery proposal.
- `docs/vpncheap-internals.md`: state format, node model, native service API.
- `docs/architecture.md`: broker, worker, port, and auth design.
- `docs/9router-integration.md`: pool and connection mapping.
- `docs/delivery-plan.md`: interfaces, milestones, acceptance, rollback.
- `docs/security-risks.md`: credential, exposure, account, and operational risk.
