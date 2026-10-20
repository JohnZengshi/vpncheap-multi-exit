# Architecture

## Components

1. Read-only state reader
   - Reads `app_state.json`.
   - Uses `DpapiCipher.TryUnprotectBound` with the account-bound AAD.
   - Keeps decrypted nodes in memory and never writes them to disk.

2. Config builder
   - Takes one node's `raw_outbound` object.
   - Ensures it has a unique `tag`.
   - Wraps it in a minimal sing-box config:
     - loopback `mixed` inbound;
     - node outbound;
     - `direct` outbound;
     - `route.final` set to the node outbound tag;
     - local UDP DNS server;
     - no rule sets.
   - Does not call `SingBoxConfigBuilder.Build()`, because that path expects
     VPNCheap's installed rule-set layout.

3. sing-box host
   - Calls `singbox_new_service`, `singbox_start_service`, and
     `singbox_close_service` from `sing-box.dll`.
   - Owns the native service ID and listener lifecycle.
   - Must run with the same Windows user and architecture as VPNCheap.

4. Broker supervisor
   - Allocates ports.
   - Starts and stops workers.
   - Reads the catalog periodically.
   - Health-checks each exit.
   - Quarantines bad nodes.
   - Exposes a redacted local status view.

5. 9Router adapter
   - Reads pools and connections through the local admin API.
   - Creates or reuses one strict pool per healthy loopback port.
   - Binds only explicitly selected connections, with `-AllowRebind` required
     when an existing binding changes.
   - Uses HTTP APIs, never direct SQLite writes.
   - Writes a rollback ledger containing previous pool state and binding IDs.

## Process Model

The probe runs several native services in one PowerShell process. That proves
the API works; it is not the production model.

The implemented broker uses the process model below:

- One supervisor process.
- One child worker per exit.
- Each worker owns exactly one sing-box service and one loopback port.
- The worker receives a redacted node identifier and reads its own credentials
  from the in-memory catalog or a protected local channel.
- The supervisor restarts failed workers with backoff.
- A node is quarantined after repeated failures.

`broker.ps1` owns the supervisor loop; `worker.ps1` owns one native service and
one listener. The two-exit run confirmed that a killed worker is replaced
without affecting the other exit.

This keeps a native crash or a bad node from taking down every exit. It also
makes port ownership and cleanup unambiguous.

## Current Deployment

- The broker runs under the `vpncheap-multi-exit-broker` scheduled task.
- Triggers are user logon plus a five-minute watchdog; the task runs hidden,
  ignores new instances, has an unlimited execution limit, and restarts on
  failure.
- Ports 39001 and 39002 are published as `vpncheap-HK-香港2-UDP` and
  `vpncheap-HK-香港3-UDP`.
- Both pools use `strictProxy=true` and test as `active`.
- Provider bindings are unchanged: `codex` and `claude` both remain on the
  original `vpncheap` pool, and neither new pool is bound.

## Port Allocation

Use a deterministic local range:

```text
39001..39999 -> VPNCheap exits
```

Each node maps to a stable port only while it is healthy. If a node is replaced,
allocate a fresh port rather than immediately reusing a hot port. This prevents
9Router from sending traffic to the wrong pool during a replacement.

Before publishing a port to 9Router, check that:

- the worker is running;
- the port is listening on `127.0.0.1`;
- a request through the mixed proxy returns HTTP 204;
- a public IP request succeeds.

## Data Flow

```text
VPNCheap app_state.json
  -> DpapiCipher.TryUnprotectBound
  -> in-memory node list
  -> minimal config from node raw_outbound
  -> singbox_new_service(config)
  -> singbox_start_service(id)
  -> 127.0.0.1:<port> mixed inbound
  -> 9Router strict proxy pool http://127.0.0.1:<port>
  -> provider connection proxyPoolId
```

No node credentials need to leave the worker except inside the generated
sing-box config passed to the native library. `strictProxy=true` keeps a failed
exit from falling back to direct egress.

## 9Router Local Auth

The admin API is protected even on localhost. The packaged server accepts a
local CLI token in `x-9r-cli-token`, derived as:

```text
sha256(machine-id + "9r-cli-auth" + auth/cli-secret).substring(0, 16)
```

Rules for the broker:

- read both files at startup;
- derive the token in memory;
- never log, persist, or pass the token on a command line;
- refuse to run against a non-loopback 9Router URL;
- keep the broker under the same Windows user ACL as the 9Router data
  directory.

The token is equivalent to local admin. Possession of `auth/cli-secret` is
therefore a credential boundary, not a convenience file.

## Failure Handling

Health check through each port:

1. Request `https://cp.cloudflare.com/generate_204`.
2. Require HTTP 204.
3. Request a public IP endpoint.
4. Record the IP hash.

Failure backoff:

- first failure: retry after a short delay;
- repeated failure: quarantine the node;
- config failure: do not retry until the catalog changes;
- port bind failure: move to the next free port;
- native crash: restart only that worker.

Observed failure classes on this host:

- anytls session setup: `EOF` or closed socket;
- hysteria2 TLS handshake: one JP node failed immediately;
- healthy hysteria2 exits: 13 of 14.

## Listener Binding

Bind only to `127.0.0.1`.

Do not bind to `0.0.0.0`. A local mixed inbound has no authentication. Any
process or user that can reach the port can use the VPN account as a proxy.

For remote 9Router:

- prefer same-host deployment;
- otherwise use an SSH tunnel or WireGuard;
- if a reverse proxy is unavoidable, add authentication and restrict source
  addresses.

## Non-Goals

- Copying the DPAPI state or Windows native library to a Linux server.
- Writing the live 9Router SQLite database.
- Deleting or overwriting the retained `vpncheap` pool without explicit
  operator approval.
- Rebinding a connection without an exact connection-to-pool mapping and
  explicit rebind approval.
- Guaranteeing that a node marked online is usable.
