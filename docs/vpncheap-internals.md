# VPNCheap Internals

## Scope

This note explains the parts of VPNCheap that the multi-exit design depends on.
It is based on the installed Windows artifacts, managed metadata, and local
runtime behavior. It does not claim knowledge of VPNCheap's server-side account
system, subscription protocol, or update service.

Artifacts:

- `C:\Program Files\VPNCheap\VpncheapWindows.Core.dll`
  - SHA-256:
    `225dedd1c5f0f660c79459b06792dd937260a31f11befe8a084b8ad9637c0edd`
  - MVID: `c5f081ea-8786-4024-a528-9b8393716c34`
- `C:\Program Files\VPNCheap\sing-box.dll`
  - SHA-256:
    `658189b221c65a39758e0c60e2df55e16c037d5f482469b1d41c6c435af469b3`
  - reported sing-box version: `1.13.6`

## Components

### Managed core

`VpncheapWindows.Core.dll` contains the pieces the client uses to turn an
account-bound node catalog into a running tunnel:

- `VpncheapWindows.Core.Services.DpapiCipher`
  - unprotects catalog payloads bound to the current Windows user;
  - exposes `TryUnprotectBound(token, associatedData)`.
- `VpncheapWindows.Core.Models.Xboard.XboardNode`
  - node model: `id`, `name`, `protocol`, `address`, `port`,
    `country_code`, `groups`, `online`, `raw_outbound`.
- `VpncheapWindows.Core.Config.RuleSetService`
  - resolves rule-set files under the application directory.
- `VpncheapWindows.Core.Config.SingBoxConfigBuilder`
  - `Build(XboardNode, SingBoxConfigOptions) -> string`;
  - options include `MixedListenPort`, `EnableClashApi`, and
    `UseRemoteRuleSets`.
- `VpncheapWindows.Core.Config.SingBoxConfigOptions`
  - controls the generated config.

### Native sing-box library

`sing-box.dll` exports a small service API:

- `singbox_get_version()`
- `singbox_get_last_error()`
- `singbox_free_string(ptr)`
- `singbox_new_service(configJson) -> serviceId`
- `singbox_start_service(serviceId) -> int`
- `singbox_close_service(serviceId) -> int`

The library runs an in-process sing-box instance. Multiple services can coexist
in one host process; the probe started thirteen concurrently on distinct
loopback ports.

## Node Catalog

The client stores account-bound catalogs in:

```text
C:\Users\<user>\AppData\Roaming\vpncheap\app_state.json
```

Observed structure:

```text
xboard_node_catalogs_bound_v3
  SchemaVersion
  Accounts
    <accountKey>
      UserId
      AccountGeneration
      PayloadToken
```

`PayloadToken` is a DPAPI-protected JSON array. The associated data is:

```text
vpncheap-node-cache|schema=<SchemaVersion>|type=catalog|account=<UserId>|generation=<AccountGeneration>
```

This means the payload is bound to both the Windows user and the account
generation. Changing the generation invalidates the old ciphertext.

Each node's `raw_outbound` is already a complete sing-box outbound object. For
the observed hysteria2 nodes it contained:

```text
type, tag, server, server_port, password, up_mbps, down_mbps, tls, obfs
```

The TLS object contained `enabled`, `insecure`, and `server_name`; the obfs
object contained `type` and `password`. These values are credentials and are
never logged by the scripts.

## Node To Tunnel

The client's normal path is:

```text
XboardNode + SingBoxConfigOptions
  -> RuleSetService
  -> SingBoxConfigBuilder.Build()
  -> singbox_new_service(config)
  -> singbox_start_service(serviceId)
  -> local mixed / tun listener
```

The builder adds routing policy, rule sets, and client-specific options. Those
extras are not required to prove transport. They are also the reason the builder
is fragile outside the installed application layout:

- `RuleSetService.GetRuleSetPath()` resolves paths relative to
  `AppContext.BaseDirectory`;
- `UseRemoteRuleSets` can fetch remote rule-set assets;
- a host process outside `C:\Program Files\VPNCheap` does not have the same
  working-directory assumptions.

The multi-exit probe therefore builds a minimal config directly:

```json
{
  "log": { "level": "warn" },
  "dns": {
    "servers": [{ "tag": "local", "type": "udp", "server": "223.5.5.5" }],
    "final": "local"
  },
  "inbounds": [{
    "type": "mixed",
    "tag": "mixed-in",
    "listen": "127.0.0.1",
    "listen_port": 39001
  }],
  "outbounds": [
    "<node raw_outbound with a tag>",
    { "type": "direct", "tag": "direct" }
  ],
  "route": { "final": "<node tag>" }
}
```

No rule sets, no Clash API, no TUN device. This isolates the transport path and
keeps the listener loopback-only.

## Protocol Behavior

Observed on 2026-10-20 from this host:

- catalog: 59 online nodes;
- 45 anytls, 14 hysteria2;
- hysteria2: 13 healthy, 13 distinct exit IP hashes, one JP TLS handshake
  failure;
- anytls: 0 of 5 sampled nodes connected, all failed with `EOF` or a closed
  socket during session setup.

The anytls result is a local/network observation, not proof that the protocol is
globally unusable. Possible causes include server-side blocking, a changed
protocol expectation, MTU or TCP issues, or node-specific failure. Hysteria2
works on this network, including its UDP/QUIC path.

## Security Boundary

- The DPAPI payload is tied to the current Windows user. Copying
  `app_state.json` to another user or machine is not equivalent to copying a
  portable credential.
- `sing-box.dll` is a Windows native library. The broker must match the
  installed architecture and load path.
- The broker process can read decrypted node credentials in memory. Keep it
  under the same user ACL as VPNCheap and 9Router.
- The generated config contains node secrets. Do not log it, write it to a
  shared temp directory, or include it in crash reports.
- The loopback mixed listener has no authentication. Bind only to `127.0.0.1`.

## Unknowns

- VPNCheap server API and subscription refresh behavior.
- Exact device-limit and concurrent-session enforcement.
- Whether the client uses additional TLS fingerprints or transport tweaks for
  anytls outside the observed `raw_outbound`.
- How often the catalog generation changes and how the client reacts to
  invalidation.
- Whether the desktop UI or updater observes the broker's native services.
