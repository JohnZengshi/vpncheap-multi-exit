# Exit outage verification: 2026-10-23

## Scope and safety

Production dashboard: http://127.0.0.1:39080/.
Production exits: 39020 through 39028.
No production restart, stop, protocol change, subscription rewrite or pool mutation
was performed during this verification. Temporary native services were closed
after their probes. Production broker PID 15932 and all nine worker PIDs retained
their original start times.

## Observations

1. Playwright loaded the actual dashboard and probed all nine exits using curl
   against Cloudflare, gstatic and ipify. At 14:39:43 Asia/Shanghai, 0/27 requests
   succeeded. Most failed with curl code 35 after approximately five seconds.
   Some ports were temporarily closed by the worker's quarantine policy.
2. Direct HTTPS to Baidu returned HTTP 200 in 0.047 seconds during the outage.
3. At 14:43:08 the same Playwright test passed: 27/27 requests succeeded, without
   an operator restart. Recovery does not establish a permanent fix.
4. All nine applied node configuration hashes matched the current protected
   subscription catalog. A stale server address is not supported by this sample.
5. Isolated protocol comparison, final complete run, three rounds and two targets
   per node (gstatic and fixed-IP Cloudflare HTTPS):

| Region | Transport | Subscription server | Successful requests |
| --- | --- | --- | --- |
| HK | Hysteria2 | 219.78.52.166:57898 | 3/6 |
| HK | AnyTLS | 34.104.130.170:22000 | 6/6 |
| JP | Hysteria2 | 34.104.130.170:16278 | 0/6 |
| JP | AnyTLS | 34.104.130.170:33261 | 6/6 |

The HK Hysteria2 failures in this run were specifically the fixed-IP target.
The earlier five-round run also gave both AnyTLS candidates 10/10 successes.
Earlier JP Hysteria2 diagnostic jobs had invalid output transport and are excluded;
the final runner separates native stdout from PowerShell job remoting.
This is a bounded comparison, not a long-term availability guarantee.

## Confirmed local policy defects

Fault injection exercised the real Test-ProxyExitHealth function in a separate
PowerShell process, replacing only Invoke-CurlCapture:

- Successful HTTPS with all public-IP lookup sites unavailable returned
  HealthOk=true, ExitIpOk=false, Ok=false, FailureStage=exit-ip.
- A failed Cloudflare probe returned Ok=false after exactly one curl invocation;
  other reachable HTTPS targets were never attempted.

Source: scripts/lib/singbox-host.ps1:248 and :309.
After the failure threshold, scripts/worker.ps1:355 closes the native service,
then waits Max(HealthIntervalSec * 5, 60). At the current 15-second interval,
that adds a 75-second port outage before restarting the service.

These defects amplify outages and produce false negatives. They do not explain
away the real 0/27 external-request outage.

## Shipped artifact evidence

REA inspect_managed_artifact:
ev_5d14a0b30ca182336d3e14d13d15704e9a3e1d7ed055ba10f8a0b3b5489c09a7

REA inspect_managed_members, selected configuration builder/options:
ev_072a4f5bea61b69d4b42c4230e31f88a8672e169adfce1365d825d08a6053ef5

REA inspect_go_binary:
ev_cde29cbddaa5326d257d25cdc4280c851d86e62dc1f5912531894541698bdb87

Core assembly SHA-256:
225dedd1c5f0f660c79459b06792dd937260a31f11befe8a084b8ad9637c0edd

Native library SHA-256:
658189b221c65a39758e0c60e2df55e16c037d5f482469b1d41c6c435af469b3

Embedded native build metadata declares Go 1.24.13, sing-box 1.13.6 with a local
source replacement, and sing-quic 0.6.1. This is metadata, not dependency
authentication or proof that the native library is identical to upstream.

A separate local reflection probe invoked only the official builder's private
ApplyTransportTuning method on an in-memory Hysteria2 outbound using default
options. It changed no outbound fields. This does not establish full parity with
the official client's saved settings, routing, DNS, or live connection behavior.
No full official-client comparison was completed.

## Proposed solution, not applied to production

1. Correct health semantics: try an independent HTTPS target after the primary
   fails, accept success from either, keep probe time bounded, and treat public-IP
   lookup failure as missing metadata rather than tunnel failure. Never report
   actual failed requests as healthy.
2. Separate pool eligibility from native-service lifecycle. Remove a genuinely
   failing exit from new pool assignments, but do not close a functioning listener
   for a website/IP-lookup failure. Use bounded, staggered recovery and avoid nine
   simultaneous 75-second shutdowns.
3. Stage the tested HK/JP AnyTLS candidates on temporary ports first. Repeatedly
   validate real HTTPS, then explicitly migrate one stable slot at a time, retaining
   the old protected configuration for rollback. Keep public ports and pool IDs.
   Do not automatically replace all regions or protocols based on these two nodes.
   A native listener replacement can interrupt that slot's active connections;
   slot-by-slot activation must be scheduled, not described as zero downtime.
4. If exact upstream attribution is needed, repeat the same protected Hysteria2
   configuration on another access network while this one is failing. The current
   observations cannot distinguish local/ISP UDP treatment, transit loss, server
   protocol service failure, or a native implementation problem.

The tested AnyTLS endpoints are immediate backup candidates, not an implemented
failover or a guarantee that every AnyTLS node works.

## Reproduction

Read-only dashboard/real-request test:
scripts/tests/exit-health.spec.cjs

Isolated native transport comparison:

```powershell
pwsh.exe -NoProfile -File scripts/diagnose-exit-transport.ps1 -Rounds 3
```

The transport script reports missing/incomplete child results as failures and
does not persist subscription credentials or raw native logs.

Sanitized evidence:

- artifacts/verification-20261023/live/ (failed Playwright run)
- artifacts/verification-20261023/recheck/ (successful Playwright run)
- artifacts/verification-20261023/transport-final.json (complete native comparison)

At the time of the probes above, implementation and live activation were
pending. See the implementation results below for subsequent changes.

## Official-client comparison at 14:59 Asia/Shanghai

The official client was not running during this comparison. Its persisted
app_state.json selected TW Taipei 01, AnyTLS, 34.104.130.170:30106.
The persisted auto-selection value was "1", with region TW. These are saved
choices, not proof of the last active connection or of runtime failover.

Saved settings included:

- enableAutoReconnect=false;
- enablePeriodicRefresh=true, refreshInterval=1h;
- hopInterval=5s, hy2SpeedMode=off;
- windowsUseTunMode=false, windowsAutoConfigureProxy=false;
- DNS 1.1.1.1 / 223.5.5.5, domainStrategy=ipv4_only.

A separate reflection probe invoked the installed official builder's
BuildFailoverGroup with three catalog TW nodes. It produced a urltest group
with URL https://cp.cloudflare.com/generate_204, interval 3m, tolerance 30000,
and interrupt_exist_connections=true. This establishes builder capability,
not that the saved automatic mode actually used that group. Switching may
interrupt existing connections; this is not seamless connection migration.

Invoking ApplyTransportTuning with saved hopInterval=5s and speed mode off on
a catalog Hysteria2 outbound changed no fields. That sampled outbound had
neither server_ports nor hop_interval. A saved hop interval alone is therefore
not evidence that the production transport is missing an effective tuning.

Two independent read-only probes ran concurrently. The official saved AnyTLS
node ran in an owned temporary minimal-config service using the same native
DLL, not inside the official GUI. Its service was closed afterwards.
The existing production TW Hysteria2 listener on port 39026 was only queried.
Each probe made three rounds against gstatic generate_204 and fixed-IP
Cloudflare HTTPS:

| Sample | Endpoint | Result |
| --- | --- | --- |
| Official saved AnyTLS node, temporary service | 34.104.130.170:30106 | 6/6 success, 0.244-0.509 seconds |
| Existing TW Hysteria2 production exit | 1.168.164.171:57898 | 3/6 success; all three fixed-IP requests timed out at 8 seconds |

Completion times were 14:59:33 and 14:59:55 respectively. Different nodes and
servers confound protocol attribution. This short sample supports testing the
saved AnyTLS node as a backup candidate, not a long-term availability promise
or proof that UDP is blocked.

Fault injection against the real Test-ProxyExitHealth function again returned
Ok=false, HealthOk=true, ExitIpOk=false, FailureStage=exit-ip when HTTPS
succeeded and only public-IP lookup failed. Combined with worker quarantine,
this can turn missing metadata into an avoidable listener shutdown.

Broker PID 15932 and all nine worker PIDs retained their 14:17 start times.
No production listener was stopped, restarted, or migrated by these probes.
The confirmed explanations are a different selected transport/server and an
overly destructive local health policy. Automatic client failover remains
only a capability until its actual connection configuration is observed.
Both applications already use the same installed Go-based sing-box DLL;
changing the orchestration language is not supported as a remedy by this test.

## Health and recovery implementation on October 23

Implemented in the source, without intentionally restarting production exits:

- Cloudflare HTTPS health check falls back to Google gstatic. Each target gets
  half the configured health timeout, capped at eight seconds.
- Public-IP lookup is optional metadata, with at most three seconds per service.
  A working HTTPS connection remains healthy if all IP services fail. Missing IP
  metadata is cleared rather than presented as a fresh result.
- All probes disable curlrc and override NO_PROXY so checks cannot silently
  bypass the explicitly selected local proxy. The curl wrapper explicitly allows
  empty argument strings, required for `--noproxy ''`. A real curl invocation
  regression covers parameter binding rather than mocking the wrapper.
  IP responses use IPAddress parsing.
- Transient failures remain degraded. Persistent failure remains unhealthy but
  no longer closes the listener and sleeps offline for 60-75 seconds.
- Recovery starts after a 30-46 second port-dependent delay. It stages the same
  node on a temporary port using the existing safe-update routine and shared
  update lock. Failed staging retains the old service; failed cutover attempts
  rollback. Exponential cooldown is capped at 300 seconds plus 0-16 seconds
  of port-dependent staggering. Normal health checks continue between retries.
- Recovery does not mark an unhealthy connection healthy merely because a retry
  was attempted. The ordinary next successful health check clears recovery state.
- Broker and dashboard carry optional metadata/recovery fields and tolerate old
  workers. The UI distinguishes IP lookup failure, transient failure, persistent
  outage, scheduled validation, failed staging and rebuilt-but-not-yet-rechecked.

No protocol migration or automatic cross-node failover is enabled by this change.
Retaining a listener is not proof of internet connectivity and does not disable
an existing 9Router pool. Successful fixed-port reconstruction can interrupt
existing connections; staging is not a zero-downtime handover.

Verification:

- `scripts/tests/health-regression.ps1`: starts red against the old behavior;
  covers metadata-only failure, independent target fallback, real outage, HTTP
  errors, malformed IP, explicit proxy arguments, recovery scheduling/cooldown,
  retained listener, lock contention, healthy reset and dashboard compatibility.
- `scripts/tests/health-stability.spec.cjs`: runs the actual PowerShell health
  transition under injected curl/native boundaries, then renders those results
  in the real dashboard through a routed snapshot. Five repeats passed (10 tests).
  This deterministic UI test is not evidence of live upstream availability.
- Existing subscription/safe-update, broker, pool-sync and server-export
  PowerShell regressions pass. Pool tests use isolated mock API boundaries.
- Real dashboard server-address export passed with nine nonempty server rows,
  no loopback addresses, and unchanged broker/worker identities.
- The independent live connectivity run at 15:20:08 Asia/Shanghai failed:
  zero successful requests out of 27 across nine exits and three targets.
  Most requests failed TLS setup (curl 35); two failed to connect (curl 7).
  This failure is retained, not retried into a claimed stability pass.
- A separate explicit-proxy sample at 15:24:26 had 25/27 successful requests;
  every exit reached at least one target. Port 39026 reached Cloudflare but
  timed out against gstatic and ipify. The connectivity and real export tests
  both passed their actual assertions, with unchanged process identities.
  This separate sample confirms intermittent behavior, not sustained stability.
- A subsequent call to the new production `Test-ProxyExitHealth` implementation
  against existing port 39021, using real curl rather than a stub, returned
  Ok=true, HealthOk=true, ExitIpOk=true and HTTP 204 without restarting the exit.

Evidence: `artifacts/health-stability-20261023/` and
`artifacts/health-live-20261023/`, with explicit-proxy live results in
`artifacts/health-live-explicit-proxy-20261023/`. Final deterministic repeats
are in `artifacts/health-stability-20261023-final/`. Later rechecks are separate
point-in-time samples, not replacements for the failed run.

Activation boundary: running workers load library code at process startup.
Existing workers and the dashboard backend have not been deliberately restarted
to activate these changes. Static dashboard JavaScript is served from disk.
The broker and eight workers still retained their 14:17 start times at 15:21;
the existing supervisor had independently restarted port 39028 at 15:09:16,
before this implementation was loaded. Tests compare identities at their own
start and finish rather than claiming every worker has remained unchanged all day.

## Recurrence after activation: 16:11-16:16 Asia/Shanghai

This section supersedes the earlier activation boundary for the workers.
The 16:01 worker generation has the new recovery fields and actually executes
staged recovery. The dashboard API still omits those fields. Loading the new
worker policy therefore did not resolve the transport outage.

Read-only Playwright observation of the actual dashboard ran from 16:11:28
through 16:16:28. It sampled 15 times, queried both worker files and the API,
and made real HTTPS requests with explicit proxy selection:

| Measurement | Result |
| --- | --- |
| Requests through nine production exits | 122/270 succeeded; 148 failed |
| Direct requests to the same two targets | 29/30 succeeded |
| Samples with at least one failed proxy request | 10/15 |
| Initial seven samples | All 18 proxy requests failed in each sample |
| First sample with all proxy requests successful | 16:14:45 |
| Worker PIDs, selected node hashes and public ports | Unchanged within this run |
| Browser JavaScript errors | None |

Of the 148 proxy failures, 134 returned curl code 35 and 14 returned code 28.
Local TCP connect times for those requests were 0-17 ms, average 1.51 ms.
The local listeners were reachable; failure occurred later in connection setup
or request completion. A curl TLS error alone cannot identify whether the
remote server, access network, transit path or native implementation is at fault.

Worker recovery records included validation-failed, attempts 1-3, and
update-pending (the shared staging lock was busy). The repeated error hash
bf5b3e91233a91acb7b0 matches the literal exit-stage-health-failed:
the new temporary instance of the same selected node also failed its probe.
The safe-update implementation retains the old listener in this case.
This is a real failed recovery attempt, not proof that a backup was selected.

### Concurrent isolated comparison at 16:12

Four independent temporary services used the installed native DLL. They did not
replace the production listeners:

| Region | Transport | Subscription server | Successful requests |
| --- | --- | --- | --- |
| HK | Hysteria2 | 219.78.52.166:57898 | 0/10 |
| HK | AnyTLS | 34.104.130.170:22000 | 10/10 |
| JP | Hysteria2 | 34.104.130.170:16278 | 1/10 |
| JP | AnyTLS | 34.104.130.170:33261 | 10/10 |

Targets were gstatic and fixed-IP HTTPS to 1.1.1.1. The AnyTLS samples completed
between 16:12:49 and 16:12:56; the slower Hysteria2 samples continued until
16:13:38. These short AnyTLS samples overlap the production outage, but do not
cover its entire duration. The diagnostic script now has an optional IntervalSec
parameter to spread fast samples across time instead of immediately completing
all rounds. Its default remains zero for compatibility.

JP used the same server IP for both protocols, but different ports and services.
This strengthens the case for testing the alternative service; it still does not
prove UDP filtering or establish equal remote-server conditions.

### What the current recovery does, and does not do

scripts/worker.ps1 invokes Invoke-SafeExitUpdate with the same node as Previous
and Candidate. scripts/lib/exit-update.ps1 additionally rejects a replacement
whose protocol or country differs from the original. Automatic cross-protocol
backup selection is not implemented. Repeatedly rebuilding an unavailable
Hysteria2 endpoint cannot provide the available AnyTLS path.

At 16:11, worker port 39020 reported recoveryAttempt=3 and
recoveryState=validation-failed. The matching API row returned neither field.
This is an independent observability/activation problem: the source dashboard
already forwards them, but the running API does not. A browser refresh cannot
reload server-side PowerShell definitions. Updating only the dashboard process
can expose recovery information without restarting the nine worker processes;
it does not fix upstream connectivity.

A later process check found another broker/worker generation starting at
16:22:37-16:22:41. This investigation did not initiate that restart. Do not mix
its PIDs with the unchanged-identity claim for the 16:11-16:16 run.

### Recommended remediation and remaining limits

1. Add explicit, per-slot backup policy rather than reusing subscription-address
   refresh or same-node reconstruction as failover. Retain the public local port
   and pool identity; keep original and currently active upstream identities
   separately so exports and pool metadata reflect the real selected server.
2. Validate same-region candidates on independent ports over multiple spaced
   samples. Include a different transport such as the tested AnyTLS services,
   not just a different Hysteria2 address. Validate SG/TW/US independently before
   extrapolating from HK/JP. Preserve distinct exits; do not silently fill nine
   slots with one shared backup.
3. On persistent failure, select only a recently validated candidate. Serialize
   slot activation, retain the protected old configuration for rollback, use
   cooldown and sustained recovery before switching back. Make protocol changes
   an explicit policy. A fixed-port native-service replacement can interrupt that
   slot's existing connections; it is not zero-downtime migration.
4. Publish recovery state, candidate validation, active endpoint and last switch
   reason in the API/UI. Treat failed validation as failure, not a healthy status.
5. To identify the exact upstream cause, repeat the same protected Hysteria2
   configuration on a second access network during an outage and compare bounded
   native transport diagnostics. This run does not justify blaming an ISP or
   claiming that all VPNCheap server addresses have changed.

REA retained-member view
ev_70147ea889b0d4314a7e3c97fc366ed5106d1c7051f415ca800fe436e5f60fd1
confirms the shipped BuildFailoverGroup method (build-local token 0x0600097f)
under the assembly identity recorded above. This remains static capability,
not evidence that the official GUI was running or switched during this outage.

Reproduction:

```powershell
$env:MONITOR_SECONDS = '300'
npx playwright test scripts/tests/exit-monitor.spec.cjs --workers=1 --reporter=list
pwsh -NoProfile -File scripts/diagnose-exit-transport.ps1 -Rounds 8 -IntervalSec 15 -OutputPath artifacts/transport-spaced.json
```

The monitor intentionally fails its availability assertion if any real proxy
request fails. That red result is retained even if later samples recover.
Artifacts contain sanitized timings, statuses and endpoint addresses, not
subscription credentials or raw native output:

- artifacts/monitor-20261023-1610/
- artifacts/monitor-transport-20261023-1612.json

The 15 health-policy regression cases still pass. They validate policy behavior,
not live availability. No production protocol migration or fallback activation
was performed in this investigation.

### Spaced follow-up: 16:25-16:28 Asia/Shanghai

Eight diagnostic rounds, spaced at 15 seconds where probe duration permitted,
covered 16:25:25 through approximately 16:27:20:

| Region | Transport | Subscription server | Successful requests |
| --- | --- | --- | --- |
| HK | Hysteria2 | 219.78.52.166:57898 | 5/16 |
| HK | AnyTLS | 34.104.130.170:22000 | 16/16 |
| JP | Hysteria2 | 34.104.130.170:16278 | 0/16 |
| JP | AnyTLS | 34.104.130.170:33261 | 16/16 |

Unlike the earlier burst, both AnyTLS services remained under observation across
the entire spaced sampling window. This supports prioritizing those candidates
for an explicit backup policy; it is still only a roughly two-minute comparison.

Concurrent read-only Playwright monitoring ran from 16:25:28 to 16:28:30:
9 samples, 137/162 successful production-proxy requests, 15/18 successful direct
requests, 5 samples with at least one proxy failure, no page errors, and unchanged
worker PIDs/node hashes/ports within this follow-up. The first sample had 0/18
proxy successes; the last had 18/18. The availability assertion correctly failed
because of the 25 actual proxy failures, rather than treating final recovery as
a clean run. Direct failures also occurred, so not every individual failure can
be attributed solely to the proxy transport.

Additional evidence:

- artifacts/monitor-transport-spaced-20261023.json
- artifacts/monitor-20261023-followup/

These are two completed bounded monitoring sessions (about eight minutes total),
not a claim that an unattended monitor remains running after this investigation.
Diagnostic child processes and temporary native services completed and were
cleaned up. Production exits were not stopped, restarted or migrated by this
investigation.

## Implemented fallback and isolated verification

The recovery call now uses a bounded same-country backup policy instead of
only reconstructing the identical failed server. An AnyTLS alternative is
preferred when the active transport is Hysteria2. Each backup must pass three
staged checks, spaced by two seconds, before the original listener is closed.
A fixed-port check follows cutover; failure attempts rollback. Up to three
unclaimed backup endpoints are tried per recovery round, rotating on retries.
Ordinary subscription replacement retains its strict protocol/country checks.

Candidate selection excludes reserved slot IDs and other encrypted snapshots.
The exclusive update lock protects a second claim check and the applied snapshot
commit. Successfully applied backups retain their stable slot/port but persist
their actual configuration and a fallback flag. Subscription reconciliation
updates the active backup rather than automatically returning to the failed
primary. Broker protocol filtering must not retire these fallback aliases.
Dashboard status and CSV metadata now describe the applied upstream.

`exit-config.json` supports `autoFallback: false` to disable future backup
selection; missing means enabled. This does not undo an already applied backup.
The dashboard configuration writer preserves this setting. Recovery retains
the existing failure threshold, staggered scheduling and bounded backoff.
There is a brief listener replacement window and established connections may
break. No end-to-end guarantee of uninterrupted connectivity is implied.

The real native isolated test ran on October 23, 2026, 16:41:28-16:42:16
Asia/Shanghai. It started its own intentionally unreachable Hysteria2 instance
using documentation-only address 192.0.2.1 on temporary local port 54480.
The actual recovery implementation switched that same local port to the HK
AnyTLS server 34.104.130.170:22000. Following the staged checks and cutover check,
all six spaced follow-up checks returned HTTP 204 (249-271 ms reported latency).
The original nine production listener ports and owning PIDs were unchanged
through this isolated run. Only the isolated services were closed on completion.

Sanitized evidence: `artifacts/fallback-live-verification.json`.
This is a short isolated failover test, not a long-duration production
availability result. The earlier red production monitoring results remain valid.
Existing PowerShell processes need an authorized reload/restart to pick up all
new function definitions. No production restart was performed by this fix.

Regression commands:

```powershell
pwsh -NoProfile -File scripts/tests/exit-fallback-regression.ps1
pwsh -NoProfile -File scripts/tests/health-regression.ps1
pwsh -NoProfile -File scripts/tests/subscription-regression.ps1
pwsh -NoProfile -File scripts/tests/server-export-regression.ps1
pwsh -NoProfile -File scripts/tests/9router-sync-regression.ps1
npx playwright test scripts/tests/health-stability.spec.cjs --workers=1 --repeat-each=5
pwsh -NoProfile -File scripts/verify-exit-fallback.ps1
```

The browser regression uses the edited app.js and actual PowerShell fault
transition/export results with intercepted read-only API responses. It checks
backup protocol, server address, truthful unhealthy-until-rechecked state and
downloaded CSV fields; it does not simulate successful production migration.

Final verification passed all fallback, health, subscription, server-export,
9Router-sync and broker PowerShell regression scripts. The three Playwright
scenarios each passed five repetitions: 15/15, 35.9 seconds. Artifacts are in
`artifacts/fallback-playwright-verified/`. An earlier added CSV harness failed
because its switch parameter and local JSON variable differed only in case;
that test-only collision was fixed before this final repeat run.

PowerShell AST syntax, JavaScript syntax and whitespace checks also passed.
The rebuilt `dist/vpncheap.exe` is 451584 bytes, SHA256
`1b880ff44a47f2771e5f19b7275aa6eb7b702544334d9729a62c1ebb3792a06c`.
Its embedded exit-update resource hash matches the current source file.
Building this executable does not reload currently running PowerShell processes.
