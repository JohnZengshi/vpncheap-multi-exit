# 9Router Integration

## Constraint

One 9Router proxy pool has one `proxyUrl`. Multiple exits therefore require
multiple pools:

```text
pool-vpn-01 -> http://127.0.0.1:39001
pool-vpn-02 -> http://127.0.0.1:39002
pool-vpn-03 -> http://127.0.0.1:39003
```

A provider connection is bound to one pool through
`providerSpecificData.proxyPoolId`. To use several exits concurrently, 9Router
needs several connections, each bound to a different pool. Adding the same
upstream account repeatedly is an operator decision with account and policy
consequences.

## Local Authentication

The admin API is not open on localhost. An unauthenticated
`GET /api/proxy-pools` returns HTTP 401.

The packaged server accepts a local CLI token in the `x-9r-cli-token` header.
The value is derived from the 9Router data directory:

```text
sha256(machine-id + "9r-cli-auth" + auth/cli-secret).substring(0, 16)
```

With that header, `GET /api/proxy-pools` and `GET /api/providers` return HTTP
200. The inventory script derives the token in memory and never prints it:

```powershell
pwsh -NoProfile -File .\scripts\9router-inventory.ps1 -ShowNames
```

Do not put the token in a command line, a log line, or a config file. The token
is equivalent to local admin. Restrict the broker and the 9Router data directory
to the same Windows user.

## Observed API Shape

From the packaged 9Router server:

- `GET /api/proxy-pools?isActive=true&includeUsage=true`
- `POST /api/proxy-pools`
- `GET /api/proxy-pools/:id`
- `PUT /api/proxy-pools/:id`
- `DELETE /api/proxy-pools/:id`
- `POST /api/proxy-pools/:id/test`
- `GET /api/providers`
- `POST /api/providers`
- `PUT /api/providers/:id`
- `DELETE /api/providers/:id`

Observed response wrappers:

- proxy pools: `{ "proxyPools": [...] }`
- providers: `{ "connections": [...] }`

Create pool request body:

```json
{
  "name": "vpncheap-01",
  "proxyUrl": "http://127.0.0.1:39001",
  "noProxy": "",
  "isActive": true,
  "strictProxy": true,
  "type": "http"
}
```

Provider connection binding:

```json
{
  "provider": "provider-id",
  "apiKey": "provider-key",
  "name": "provider-account-01",
  "priority": 1,
  "proxyPoolId": "<pool-id>",
  "testStatus": "unknown"
}
```

The server serializes `proxyPoolId` into
`providerSpecificData.proxyPoolId`.

## Current Live State

Inventory and apply ledger on 2026-10-20:

| Pool | Pool ID | Strict | Test | Bound |
| --- | --- | --- | --- | --- |
| `vpncheap-HK-香港2-UDP` | `153bcddc-d985-4c09-8499-162b1a911622` | true | active | none |
| `vpncheap-HK-香港3-UDP` | `734bcd1f-aa73-4504-af79-b6af456f4927` | true | active | none |
| `vpncheap` | `3728b7ab-0674-4c8d-8dca-163eb019742e` | true | active | `codex`, `claude` |

There are 8 provider connections. Provider bindings were left unchanged at the
operator's request:

| Connection | Provider | Pool |
| --- | --- | --- |
| `fd0ba669-98e8-490d-a67a-d388403eb2d3` | `codex` | `vpncheap` |
| `86e2d8e5-aa7b-422d-9e9e-39552d9f0a90` | `claude` | `vpncheap` |

The original `vpncheap` pool remains the active provider route. The two new
pools are available in the dashboard but are unbound. Preserve all three pool
objects and their history.

`strictProxy=true` is deliberate for the new pools. If a loopback exit is
unavailable after an operator binds it, 9Router should fail the request instead
of falling back to direct network egress.

The dashboard view is at
`http://localhost:20128/dashboard/proxy-pools`.

## Applied CLI

These commands are available for an explicit future binding decision. They are
not part of the current deployment, which leaves both providers on `vpncheap`.

Use exact IDs for existing bindings. The mapping form is:

```text
-BindConnectionPool "<connection-id>=<pool-name>"
```

Plan without changing live state:

```powershell
pwsh -NoProfile -Command "& .\scripts\9router-plan.ps1 -BindConnectionPool @('<codex-connection-id>=vpncheap-HK-香港2-UDP','<claude-connection-id>=vpncheap-HK-香港3-UDP') -AllowRebind"
```

Apply the same mapping:

```powershell
pwsh -NoProfile -Command "& .\scripts\9router-apply.ps1 -BindConnectionPool @('<codex-connection-id>=vpncheap-HK-香港2-UDP','<claude-connection-id>=vpncheap-HK-香港3-UDP') -AllowRebind -Apply -TestExisting"
```

`-AllowRebind` is required only when a connection is already bound elsewhere.
It does not permit a blanket rebind: each change must still match an explicit
connection-to-pool pair.

## Applied Result

The live apply created and tested both pools. A later operator instruction
prohibited changing provider proxies, so both provider connections were restored
to their original `vpncheap` binding. A plan without a binding mapping reports:

- `vpncheap-HK-香港2-UDP`: `exists`, strict, active;
- `vpncheap-HK-香港3-UDP`: `exists`, strict, active;
- no conflicts and no pending pool updates.

The local ledger at `runtime/9router-applied.json` records the created pool IDs
and their previous `strictProxy` values. Its binding list is empty because no
managed provider binding remains.

Before applying, require each exit to have a comfortable margin under the
8-second pool-test timeout. One observed exit fluctuated between 3.6 and 8.1
seconds on the broker's own health check; that exit is a poor candidate even
though its state is `healthy`.

## Apply Behavior

Default to a dry run. Require an explicit apply switch.

1. Read pools with
   `GET /api/proxy-pools?isActive=true&includeUsage=true`.
2. Read connections with `GET /api/providers`.
3. Refuse to change an existing binding unless the exact connection and target
   pool are named with `-BindConnectionPool` and `-AllowRebind` is supplied.
4. Create one new pool per healthy exit. Name it from the VPNCheap node name,
   such as `vpncheap-HK-香港2-UDP`, and fall back to the port when no node name
   is available.
5. Reuse a pool when its normalized proxy URL matches. Refuse the plan if the
   target name is already used by a different pool. Update strict/active state
   when an existing pool does not match the plan.
6. Test each created, updated, or selected existing pool with
   `POST /api/proxy-pools/:id/test`.
7. Bind only explicitly selected connections to the new pools.
8. Re-read state and write the redacted result to the local ledger.

Apply is idempotent:

- match by pool name and normalized loopback URL before creating;
- never create a second pool for the same port;
- never rebind a connection whose current pool differs from the plan unless
  the operator supplied that exact mapping and `-AllowRebind`.

## Pool Test Behavior

Packaged 9Router HTTP proxy testing uses:

- method: `HEAD`;
- URL: `https://google.com/`;
- default timeout: 8 seconds;
- success: `testStatus=active`;
- failure: `testStatus=error` plus `lastError`.

Because the timeout is short, publish only ports that already pass a local
health check. A port that takes 6 to 7 seconds locally is a poor candidate even
if it eventually succeeds.

## Scheduling Caveat

Creating several pools does not automatically make every request rotate across
them. 9Router chooses a provider connection according to its own priority and
scheduling rules, and each connection is pinned to one pool.

The current setup leaves both `codex` and `claude` on the original `vpncheap`
pool. The new 39001 and 39002 pools are published but unbound, so they do not
change provider routing.

There are two practical modes:

- per-connection exits: bind different connections to different pools;
- per-request balancing: requires a separate local balancer or a change in
  9Router behavior, and is not part of this proof.

## Failure Modes

- pool points to a dead local port;
- node is healthy but too slow for the 8 second pool test;
- the same upstream account is duplicated across too many pools and gets
  rate-limited;
- a pool test marks a transient network failure as `error`;
- a user manually rebinds a pool while the broker is rotating ports;
- a node is replaced but the old pool still points at the reused port.

## Creating pools from the dashboard

`http://127.0.0.1:39080/` shows a "创建代理池" button next to every healthy exit
whose port has no 9Router pool, plus a batch button in the pool panel header.
The snapshot field `poolPlan` (from `New-NineRouterPlan`) decides which exits
are `create`, `exists`, `update` or `conflict`.

`POST /api/nine-router/pools` with `{"ports":[...]}`:

- requires `X-Exit-Control: 1`, `Content-Type: application/json` and a
  loopback origin; the broker must be `running` and each port a healthy exit;
- creates `http://127.0.0.1:<port>` http pools with `strictProxy=true`, or
  re-enables strict/active on an existing matching pool;
- tests each pool once and returns `{name, port, action, poolId, testStatus, error}`;
- appends to `runtime/9router-applied.json` so `9router-rollback.ps1` can remove them;
- never changes provider connection bindings.
