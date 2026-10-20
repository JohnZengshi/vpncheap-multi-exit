# VPNCheap Multi Exit

Independent proof-of-concept workspace for turning the locally installed
VPNCheap node cache into multiple loopback proxy exits for 9Router proxy pools.

This repository is intentionally separate from `C:\Work\vpncheap-console`.
It does not modify the VPNCheap installation, VPNCheap application state, or the
9Router database.

## Status

Feasibility is proven on this Windows host:

- 59 online nodes were readable from the DPAPI-bound catalog.
- 13 of 14 hysteria2 nodes produced healthy loopback exits.
- All 13 healthy exits returned distinct public exit IP hashes.
- 5 of 5 sampled anytls nodes failed the handshake on this network.
- 9Router admin API authentication was verified read-only.
- A supervisor/worker broker ran two exits continuously for over an hour with
  health checks every 15 seconds and catalog refresh every 5 minutes.
- Killing one worker only restarted that exit; the other exit stayed healthy,
  and the replacement worker returned to healthy with a new PID.
- The 9Router adapter created and tested two strict, active proxy pools.
- Provider bindings were left untouched at the operator's request: both `codex`
  and `claude` remain on the original `vpncheap` pool, and neither new pool has
  a bound connection.
- Re-running the planner without a binding mapping reports both pools as
  `exists`, with no pending pool changes or conflicts.
- The broker is installed as a logon-triggered scheduled task with
  single-instance, restart, and five-minute watchdog settings.
- The original `vpncheap` pool is intact and continues to serve both provider
  connections.

The 13-exit figure comes from the temporary probe. The long-running broker has
been validated at two exits so far; scale testing beyond that is still open.

## Architecture

```text
VPNCheap app_state.json
  -> DpapiCipher.TryUnprotectBound
  -> in-memory node catalog
  -> minimal sing-box config from node raw_outbound
  -> singbox_new_service / singbox_start_service
  -> 127.0.0.1:<port> mixed inbound per node
  -> one 9Router proxy pool per port
  -> provider connection bound to one pool
```

9Router has one `proxyUrl` per proxy pool. Multiple exits therefore require
multiple pools, not one pool containing several URLs.

## Layout

- `FEASIBILITY.md`: verdict, measured capacity, deployment limits, phased plan.
- `FEASIBILITY.zh-CN.md`: Chinese feasibility and delivery proposal.
- `EVIDENCE.md`: evidence ledger, runtime observations, unknowns.
- `docs/vpncheap-internals.md`: reverse-engineered state, config, and native API.
- `docs/architecture.md`: broker and worker design.
- `docs/9router-integration.md`: local auth, pool creation, binding plan.
- `docs/delivery-plan.md`: interfaces, milestones, acceptance, rollback.
- `docs/security-risks.md`: credential, exposure, account, and operational risk.
- `scripts/lib/vpncheap-state.ps1`: read-only DPAPI catalog reader.
- `scripts/inspect-managed-surface.ps1`: managed API inspection.
- `scripts/recover-vpncheap-state.ps1`: redacted catalog summary.
- `scripts/multiexit-probe.ps1`: temporary multi-exit proof.
- `scripts/broker.ps1`: supervisor with start/stop/status and worker restart.
- `scripts/worker.ps1`: one native sing-box service and loopback port per exit.
- `scripts/dashboard.ps1`: local status page plus the guarded exit-selection endpoint.
- `dashboard/`: browser UI for exits, proxy pools, provider routing, and exit configuration.
- `scripts/9router-plan.ps1`: read-only pool and binding plan.
- `scripts/9router-apply.ps1`: explicit, journaled 9Router apply path.
- `scripts/9router-rollback.ps1`: rollback for objects created by this broker.
- `scripts/9router-inventory.ps1`: read-only 9Router pool/connection inventory.
- `scripts/install-broker-task.ps1`: install, start, or remove the scheduled
  task that runs the broker at logon.
- `scripts/read-9router-db.cjs`: read-only SQLite inspection.

## Quick Start

```powershell
pwsh -NoProfile -File .\scripts\inspect-managed-surface.ps1
pwsh -NoProfile -File .\scripts\recover-vpncheap-state.ps1
pwsh -NoProfile -File .\scripts\multiexit-probe.ps1 -MaxNodes 2 -MaxAttempts 14 -Protocol hysteria2 -RequireDistinctExitIps
pwsh -NoProfile -File .\scripts\broker.ps1 -Action start -MaxExits 2
pwsh -NoProfile -File .\scripts\broker.ps1 -Action status
pwsh -NoProfile -File .\scripts\dashboard.ps1 -Action start
pwsh -NoProfile -File .\scripts\install-broker-task.ps1 -StartNow
pwsh -NoProfile -File .\scripts\9router-inventory.ps1 -ShowNames
```

The dashboard listens on `http://127.0.0.1:39080/`. Open "配置出口" to change the
number of parallel exits or select exact nodes. The page writes only
`runtime/exit-config.json`; the running broker hot-loads it within a few seconds.
Port leases stay attached to node hashes, so a node that is unchecked and checked
again returns to the same loopback port and keeps its existing 9Router pool binding.

In the "9Router 代理池" panel, exits without a pool show a "创建代理池" button,
and the panel header offers "为 N 个出口创建" for all of them. This calls the
guarded `POST /api/nine-router/pools` endpoint (body `{"ports":[39004]}`,
same-origin plus `X-Exit-Control: 1`). It only creates/re-enables healthy-exit
pools named `vpncheap-<node>` with `strictProxy=true`, runs the 9Router pool test,
and records them in `runtime/9router-applied.json`. It never changes provider
bindings and refuses name/port conflicts (409).

Use `-BindConnectionPool "<connection-id>=<pool-name>"` to select the exact
connection for each exit. `9router-plan.ps1` is read-only; `9router-apply.ps1`
is a dry run unless `-Apply` is passed. Apply creates only missing pools,
updates strict/active state, tests selected pools, writes a local journal, and
binds only explicitly named connections. Add `-AllowRebind` only after
reviewing the current binding shown by the plan.

The current deployment leaves provider bindings unchanged. If you deliberately
choose to bind connections, plan an explicit mapping first:

```powershell
pwsh -NoProfile -Command "& .\scripts\9router-plan.ps1 -BindConnectionPool @('<codex-connection-id>=vpncheap-HK-香港2-UDP','<claude-connection-id>=vpncheap-HK-香港3-UDP') -AllowRebind"
```

Add `-ShowExitIp` only when the real exit IPs are needed locally. Node
addresses, ports, passwords, UUIDs, subscription URLs, proxy URLs, and 9Router
tokens are never printed by default.

The probe defaults to `hysteria2`, the protocol that passed on this host. Pass
`-Protocol ''` to scan every protocol, or `-Protocol anytls` for diagnosis.

## Safety Defaults

- `9router-plan.ps1` is read-only; `9router-apply.ps1` is a dry run unless
  `-Apply` is passed.
- Never rebind an existing connection unless its exact ID and target pool are
  named and `-AllowRebind` is supplied.
- Preserve the original `vpncheap` pool and leave it unbound unless a new
  explicit migration is approved.
- Bind listeners to `127.0.0.1` only.
- Do not copy `app_state.json`, DPAPI tokens, or decrypted node JSON to another
  machine or issue tracker.
- Do not write the live 9Router SQLite database while 9Router is running.
- Do not run the probe or broker against nodes that are offline or lack
  `raw_outbound`.
