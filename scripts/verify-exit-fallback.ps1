[CmdletBinding()]
param(
    [string]$OutputPath = 'artifacts/fallback-live-verification.json',
    [switch]$NativeChild
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $NativeChild) {
    # Native DLL stdout can contain sensitive configuration; expose only the framed result.
    $captured = & pwsh -NoProfile -NonInteractive -File $PSCommandPath -NativeChild 2>&1
    $framed = @($captured | ForEach-Object { [string]$_ } | Where-Object { $_.StartsWith('FALLBACK-LIVE:') })
    if ($framed.Count -ne 1) { throw 'Isolated fallback test returned no sanitized result.' }
    $report = $framed[0].Substring(14) | ConvertFrom-Json
    . "$PSScriptRoot/lib/broker-common.ps1"
    Write-JsonFileAtomic ([IO.Path]::GetFullPath($OutputPath)) $report
    $report | ConvertTo-Json -Depth 8
    if (-not $report.ok) { throw 'Live fallback verification failed; see sanitized report.' }
    return
}
. "$PSScriptRoot/lib/vpncheap-state.ps1"
. "$PSScriptRoot/lib/broker-common.ps1"
. "$PSScriptRoot/lib/subscription-state.ps1"
. "$PSScriptRoot/lib/singbox-host.ps1"
. "$PSScriptRoot/lib/exit-update.ps1"
$directory = Join-Path ([IO.Path]::GetTempPath()) ('fallback-live-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($directory) | Out-Null
$serviceId = [UIntPtr]::Zero
$report = [ordered]@{
    ok = $false; startedAt = [datetimeoffset]::UtcNow.ToString('o'); finishedAt = $null
    port = $null; state = $null; protocol = $null; server = $null; serverPort = $null
    primaryUnhealthy = $false; probes = @(); productionListenersUnchanged = $false; errorType = $null
}
function Get-ProductionListeners {
    @((Get-NetTCPConnection -State Listen -ErrorAction Stop |
        Where-Object { $_.LocalPort -in (39020..39028) } |
        Sort-Object LocalPort | Select-Object LocalPort, OwningProcess) | ConvertTo-Json -Compress)
}
try {
    $before = Get-ProductionListeners
    $catalog = Read-ProtectedSubscriptionFile "$root/runtime/catalog.dpapi.json"
    $backup = @($catalog.nodes | Where-Object {
        $_.protocol -eq 'anytls' -and $_.country_code -eq 'HK' -and $_.online
    })[0]
    $primary = ($catalog.nodes | Where-Object {
        $_.protocol -eq 'hysteria2' -and $_.country_code -eq 'HK' -and $_.online
    } | Select-Object -First 1) | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
    # Inject an unreachable server only into our isolated native instance.
    $primary.id = 'isolated-unreachable-primary'
    $primary.address = '192.0.2.1'
    $primary.raw_outbound.server = '192.0.2.1'
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try { $listener.Start(); $port = $listener.LocalEndpoint.Port }
    finally { $listener.Stop() }
    $report.port = $port
    $native = Initialize-SingBoxNative 'C:\Program Files\VPNCheap\sing-box.dll'
    $start = Start-SingBoxNodeService $primary $port $native.Directory
    if (-not $start.Ok) { throw 'isolated-primary-start-failed' }
    $serviceId = $start.ServiceId
    $report.primaryUnhealthy = -not (Test-ProxyExitHealth $port 2).Ok
    $result = Invoke-ExitRecovery -Previous $primary -Nodes @($backup) -ServiceId $serviceId `
        -NodeHash '1111111111111111' -Port $port -RuntimeDirectory $directory `
        -SingBoxDirectory $native.Directory -ProbeTimeoutSec 8
    $serviceId = $result.ServiceId
    $report.state = $result.State
    $report.protocol = $result.Node.protocol
    $report.server = $result.Node.address
    $report.serverPort = $result.Node.port
    if ($result.State -eq 'updated') {
        for ($round = 1; $round -le 6; $round++) {
            if ($round -gt 1) { Start-Sleep -Seconds 5 }
            $health = Test-ProxyExitHealth $port 8
            $report.probes += @{
                round = $round; at = [datetimeoffset]::UtcNow.ToString('o')
                ok = $health.Ok; status = $health.StatusCode; latencyMs = $health.LatencyMs
            }
        }
    }
    $report.productionListenersUnchanged = ($before -eq (Get-ProductionListeners))
    $report.ok = $report.primaryUnhealthy -and $report.state -eq 'updated' -and
        $report.protocol -eq 'anytls' -and $report.probes.Count -eq 6 -and
        @($report.probes | Where-Object { -not $_.ok }).Count -eq 0 -and $report.productionListenersUnchanged
}
catch { $report.errorType = $_.Exception.GetType().Name }
finally {
    Close-SingBoxServiceSafe $serviceId
    $target = [IO.Path]::GetFullPath($directory)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($target.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $target) -like 'fallback-live-*') {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    $report.finishedAt = [datetimeoffset]::UtcNow.ToString('o')
}
Write-Output ('FALLBACK-LIVE:' + ($report | ConvertTo-Json -Depth 8 -Compress))
