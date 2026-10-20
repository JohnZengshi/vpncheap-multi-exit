# Delivery Plan

## Scope

In scope:

- a local Windows broker that turns selected VPNCheap nodes into loopback mixed
  proxies;
- one proxy pool per healthy exit;
- explicit, reversible 9Router pool and connection changes;
- health checks, quarantine, restart, and redacted status;
- evidence and rollback procedures.

Out of scope:

- copying DPAPI state or the Windows native library to Linux;
- changing 9Router core scheduling;
- writing the live 9Router SQLite database;
- bypassing VPNCheap account, device, or provider limits;
- per-request rotation without a separate balancer.

## Interfaces

### Broker CLI

Proposed shape:

```text
broker.ps1
  -PortBase 39001
  -MaxExits 13
  -Protocol hysteria2
  -HealthIntervalSec 30
  -FailureThreshold 3
  -StatusPath .\runtime\status.json
```

The broker should:

- read the catalog once at startup and refresh on a fixed interval;
- start one worker per selected node;
- keep node credentials inside the worker;
- expose only hashed node IDs, protocol, country, port, state, last health time,
  and exit IP hash;
- never write decrypted node JSON to disk.

### Worker State

```text
starting
  -> healthy
  -> degraded      (one or two failed health checks)
  -> quarantined   (failure threshold reached)
  -> restarting
  -> stopped
```

Rules:

- a config error does not retry until the catalog changes;
- a native crash restarts only that worker;
- a port bind error moves to the next free port;
- a quarantined node is not published to 9Router.

### 9Router Adapter

Implemented shape:

```text
9router-plan.ps1  -StatusPath .\runtime\status.json -Out .\runtime\pool-plan.json
9router-apply.ps1 -BindConnectionPool "<connection-id>=<pool-name>" -AllowRebind -Apply
```

Plan rules:

- one pool per healthy port;
- names derived from the VPNCheap node, such as `vpncheap-HK-香港2-UDP`, with
  the port as a fallback;
- reuse a pool when its normalized loopback URL matches, and reject a name that
  is already used by a different pool;
- never rebind an existing connection unless the operator named that exact
  connection and target pool;
- include a broker marker in the pool name or a local journal, not in the proxy
  URL;
- write a redacted plan before applying.

Apply rules:

- require `-Apply`;
- read pools and connections first;
- create missing pools only;
- update strict/active state on matching pools when required;
- test created, updated, or explicitly selected existing pools;
- bind only selected connections;
- re-read state and record a redacted ledger;
- record every create, update, and rebind for rollback.

## Milestones

Estimates assume one engineer familiar with Windows PowerShell and the current
probe.

| Phase | Work | Estimate |
| --- | --- | --- |
| P0 | Transport proof and evidence | done |
| P1 | Worker-per-exit broker, status, health, restart | done at two exits |
| P2 | 9Router planner, strict pools, explicit apply, bindings, rollback | done live on 2026-10-20; idempotency verified |
| P3 | Scheduled task, firewall audit, log rotation, monitoring | scheduled task done; remaining work 1-2 days |

## Validation Snapshot

Observed on 2026-10-20:

- two hysteria2 exits stayed healthy for over one hour;
- health interval 15 seconds, catalog refresh 300 seconds;
- both ports returned HTTP 204 with distinct exit IP hashes;
- killing one worker restarted only that exit, and the other stayed healthy;
- the restarted worker returned to healthy on the same port with a new PID;
- a redaction scan of runtime JSON and logs found no address, password, proxy
  URL, or token;
- two strict pools were created and tested as `active`; provider bindings were
  left unchanged, so `codex` and `claude` both remain on `vpncheap`;
- a later plan without a binding mapping reported two `exists` pools with no
  pending pool changes;
- the broker is running from the `vpncheap-multi-exit-broker` scheduled task
  with a five-minute watchdog trigger.

Open before production:

- scale to all healthy hysteria2 exits and measure provider rate limits;
- confirm 9Router spreads traffic across multiple bound connections;
- complete firewall audit, log rotation, and monitoring.

## Acceptance Matrix

| Requirement | Test | Pass condition |
| --- | --- | --- |
| Two exits concurrently | Start broker with two hysteria2 nodes | Both ports return HTTP 204 within 10 seconds |
| Distinct egress | Request a public IP through each port | IP hashes differ |
| Scale | Start all healthy hysteria2 nodes | At least 10 healthy exits |
| Isolation | Kill one worker | Other exits remain healthy |
| Recovery | Stop a worker and restart it | Port returns to healthy within the retry budget |
| 9Router pool publication | Create two pools without changing provider bindings | Both pools are active and both providers remain on `vpncheap` |
| Pool health | Call `POST /api/proxy-pools/:id/test` | Each new pool reports `active` |
| Redaction | Inspect logs and status | No node address, password, UUID, subscription URL, proxy URL, or 9Router token |
| Idempotency | Run apply twice | No duplicate pools or bindings |
| Rollback | Restore ledger bindings and remove broker-created pools | Original pool remains and both connections return to their prior pool |

One exit has shown local health latency between 3.6 and 8.1 seconds. Because the
9Router pool test uses an 8-second timeout, a slow exit should be excluded even
when its state is healthy. The ten-second local check budget above is a
transport check, not a guarantee that 9Router will mark the pool `active`.

Pool creation, strict state, tests, and idempotency have passed. Provider
bindings were intentionally left unchanged. The topology-scale checks remain
open.

## Rollback

1. Stop the broker.
2. Read the apply journal.
3. Restore strict/active values recorded in the ledger.
4. Restore each ledger binding to its recorded previous pool ID.
5. Delete only pools created by this broker.
6. Re-read 9Router state and confirm the original `vpncheap` pool remains and
   the two connections are back on their previous pool.
7. Remove local status and plan files that contain hashes or loopback URLs.

Do not use a blanket SQLite rewrite as rollback.

## Risks And Mitigations

| Risk | Mitigation |
| --- | --- |
| Node churn or expiry | Refresh catalog, health-check, quarantine, replace ports |
| Hysteria2 UDP blocked on another network | Keep the broker on a network where the probe passes; monitor failures |
| AnyTLS handshake failures | Do not include anytls until separately diagnosed |
| Provider rate or device limits | Limit concurrent exits; use separate accounts only where permitted |
| 9Router scheduling does not spread load | Verify with two bound connections; add a balancer only if required |
| Stale pool points at a reused port | Allocate fresh ports and update pools atomically |
| Worker crash orphans a listener | One worker per exit; supervisor closes and restarts |
| Secret leakage in logs | Hash by default; opt-in `-ShowNativeError` only for local debugging |
| Local admin token leakage | Derive in memory, never print or persist; loopback-only |

## Decision

Proceed with a local hysteria2 broker.

Do not proceed with an anytls-only broker or a direct Linux deployment of the
Windows DPAPI/native path. The remaining work is implementation and operational
validation, not a feasibility unknown.
