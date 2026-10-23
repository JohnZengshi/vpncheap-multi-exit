[CmdletBinding()]
param(
    [string]$RuntimeDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime'),
    [string]$StatePath = "$env:APPDATA\vpncheap\app_state.json",
    [string]$ManagedAssemblyPath = 'C:\Program Files\VPNCheap\VpncheapWindows.Core.dll',
    [ValidateRange(60,86400)][int]$RefreshIntervalSec = 300,
    [ValidateRange(10,120)][int]$TimeoutSec = 60,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/broker-common.ps1"
. "$PSScriptRoot/lib/vpncheap-state.ps1"
. "$PSScriptRoot/lib/subscription-state.ps1"
. "$PSScriptRoot/lib/subscription-client.ps1"
$RuntimeDirectory = [IO.Path]::GetFullPath($RuntimeDirectory)
[IO.Directory]::CreateDirectory($RuntimeDirectory) | Out-Null
$lock = $null
try {
    $lock = [IO.File]::Open((Join-Path $RuntimeDirectory 'subscription.lock'),
        [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}
catch [IO.IOException] {
    if (($_.Exception.HResult -band 0xffff) -notin @(32,33)) { throw }
    return
}
$statusPath = Join-Path $RuntimeDirectory 'subscription-status.json'
$previous = $null
try { $previous = Read-JsonFile $statusPath } catch { }
if (-not $Force -and $null -ne $previous -and
    (Get-OptionalProperty $previous 'state') -in @('updated', 'error') -and
    [datetimeoffset]::UtcNow -lt (ConvertTo-SubscriptionTimestamp (Get-OptionalProperty $previous 'nextRefreshAt'))) {
    $lock.Dispose()
    return
}
$now = (Get-Date).ToUniversalTime()
$status = [ordered]@{
    state = 'refreshing'
    pid = $PID
    updatedAt = $now.ToString('o')
    lastAttemptAt = $now.ToString('o')
    lastSuccessAt = Get-OptionalProperty $previous 'lastSuccessAt'
    nodeCount = Get-OptionalProperty $previous 'nodeCount'
    errorCode = $null
    errorHash = $null
    consecutiveFailures = [int](Get-OptionalProperty $previous 'consecutiveFailures')
    nextRefreshAt = $now.AddSeconds($TimeoutSec + 15).ToString('o')
}
try {
    Write-JsonFileAtomic $statusPath $status
    $result = Invoke-VpnCheapSubscriptionFetch -StatePath $StatePath -AssemblyPath $ManagedAssemblyPath -TimeoutSec $TimeoutSec
    $path = Join-Path $RuntimeDirectory 'catalog.dpapi.json'
    $old = Read-ProtectedSubscriptionFile $path
    # Preserve the old directory when the server unexpectedly returns a partial catalog.
    if ($null -ne $old -and $old.nodes.Count -ge 10 -and $result.Nodes.Count -lt [Math]::Ceiling($old.nodes.Count / 2)) {
        throw 'subscription-suspicious-catalog-shrink'
    }
    Write-ProtectedSubscriptionFile $path @{ nodes = @($result.Nodes); fetchedAt = (Get-Date).ToUniversalTime().ToString('o') }
    $status.state = 'updated'
    $status.nodeCount = $result.Nodes.Count
    $status.lastSuccessAt = (Get-Date).ToUniversalTime().ToString('o')
    $status.consecutiveFailures = 0
    $status.nextRefreshAt = (Get-Date).ToUniversalTime().AddSeconds($RefreshIntervalSec).ToString('o')
}
catch {
    $status.state = 'error'
    $status.errorHash = Get-StringSha256Short $_.Exception.Message -Length 20
    $status.errorCode = if ($_.Exception.Message -match '^subscription-[a-z-]+$') {
        $_.Exception.Message
    } else { 'subscription-refresh-failed' }
    $status.consecutiveFailures++
    $delay = [Math]::Min(900, 60 * [Math]::Pow(2, [Math]::Min($status.consecutiveFailures - 1, 4)))
    $status.nextRefreshAt = (Get-Date).ToUniversalTime().AddSeconds($delay).ToString('o')
}
finally {
    try {
        $status.updatedAt = (Get-Date).ToUniversalTime().ToString('o')
        Write-JsonFileAtomic $statusPath $status
    }
    finally { $lock.Dispose() }
}
