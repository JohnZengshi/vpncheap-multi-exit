param([string]$RuntimeDirectory, [int]$OwnerPid)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. "$root/scripts/lib/broker-common.ps1"
. "$root/scripts/lib/vpncheap-state.ps1"
. "$root/scripts/lib/subscription-state.ps1"
$nodes = @(1..3 | ForEach-Object {
    [pscustomobject]@{ id = "fixture-$_"; name = if ($_ -lt 3) { 'TW Same' } else { 'TW Available' }
        protocol = 'anytls'; country_code = 'TW'; address = "192.0.2.$_"; port = 443; online = $true; raw_outbound = @{} }
})
Write-ProtectedSubscriptionFile (Join-Path $RuntimeDirectory 'catalog.dpapi.json') @{ nodes = $nodes }
$exits = @(0..1 | ForEach-Object {
    $node = $nodes[$_]; $hash = (Get-ExitNodeIdentity $node).SourceHash
    Save-ExitNodeSnapshot $RuntimeDirectory $hash $node
    $worker = @{ nodeHash = $hash; nodeName = $node.name; configuredNodeName = $node.name; configuredNodeHash = $hash
        port = (39101 + $_); workerPid = $OwnerPid; state = 'healthy'; healthOk = $true; protocol = 'anytls'; country = 'TW'
        activeNodeHash = $hash; activeNodeName = $node.name; fallbackActive = $false; processState = 'running'; restartCount = 0
        httpStatus = 204; latencyMs = 10; consecutiveFailures = 0; lastCheckAt = (Get-Date).ToUniversalTime().ToString('o') }
    Write-JsonFileAtomic (Join-Path $RuntimeDirectory "workers/$hash.json") $worker
    $worker
})
$status = @{ state = 'running'; brokerPid = $OwnerPid; instanceId = 'fixture'; updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    startedAt = (Get-Date).ToUniversalTime().ToString('o'); exits = $exits; selectedCount = 2; healthyCount = 2
    maxExits = 2; configuredMaxExits = 2; selectionMode = 'manual'; protocol = ''; country = ''; appliedConfigId = 'initial' }
Write-JsonFileAtomic (Join-Path $RuntimeDirectory 'status.json') $status
$status.candidates = @(Get-ExitCatalog $RuntimeDirectory $nodes | ForEach-Object {
    $_ | Add-Member NoteProperty selected ($_.NodeHash -in @($exits | ForEach-Object { $_.nodeHash })) -PassThru
})
$status.candidateCount = $status.candidates.Count
Write-JsonFileAtomic (Join-Path $RuntimeDirectory 'status.json') $status
Write-JsonFileAtomic (Join-Path $RuntimeDirectory 'exit-config.json') @{
    maxExits = 2; configId = 'initial'; nodeHashes = @($exits | ForEach-Object { $_.nodeHash }); selectionMode = 'manual'
}
Write-JsonFileAtomic (Join-Path $RuntimeDirectory '9router-applied.json') @{
    pools = @(@{ poolId = 'historical'; nodeHash = '1111111111111111'; port = 39991 }); bindings = @(); poolUpdates = @()
}
