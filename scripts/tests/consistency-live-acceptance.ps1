[CmdletBinding()]
param([int]$ExitPort = 39201, [int]$DashboardPort = 39280)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. "$root/scripts/lib/broker-common.ps1"
. "$root/scripts/lib/vpncheap-state.ps1"
. "$root/scripts/lib/subscription-state.ps1"
. "$root/scripts/lib/9router.ps1"
$runId = [guid]::NewGuid().ToString('N')
$runtime = Join-Path $root "runtime/acceptance/live-$runId"
[IO.Directory]::CreateDirectory($runtime) | Out-Null
$client = New-NineRouterClient
$evidence = [ordered]@{ runId = $runId; startedAt = (Get-Date).ToUniversalTime().ToString('o'); results = @() }
$providerId = $null; $historyId = $null; $currentId = $null
$dashboard = "http://127.0.0.1:$DashboardPort"
function Read-Snapshot { Invoke-RestMethod "$dashboard/api/snapshot" -TimeoutSec 20 }
function Post-Control($Path, $Body) {
    Invoke-WebRequest "$dashboard$Path" -Method POST -ContentType 'application/json' -Headers @{ 'x-exit-control' = '1' } `
        -Body ($Body | ConvertTo-Json -Depth 10 -Compress) -SkipHttpErrorCheck -TimeoutSec 30
}
function Wait-For($Read, $Accept, [int]$Seconds = 90) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $value = & $Read
        if (& $Accept $value) { return $value }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    throw 'live-acceptance-timeout'
}
function Check($Value, $Name) {
    if (-not $Value) { throw "Acceptance failed: $Name" }
    $evidence.results += @{ name = $Name; passed = $true; at = (Get-Date).ToUniversalTime().ToString('o') }
    Write-Output "PASS $Name"
}
function Provider-State($Connections) {
    @($Connections | ForEach-Object { @{ id = $_.id; isActive = $_.isActive; poolId = Get-NineRouterConnectionPoolId $_ } } | Sort-Object { $_.id }) | ConvertTo-Json -Compress
}
$beforeProviders = Provider-State @(Get-NineRouterConnections $client)
try {
    if ((Test-TcpPortListening $ExitPort) -or (Test-TcpPortListening $DashboardPort)) { throw 'acceptance-port-in-use' }
    $production = Read-JsonFile "$root/runtime/status.json"
    $healthy = @($production.exits | Where-Object { $_.healthOk -and $_.state -eq 'healthy' })
    if (-not $healthy.Count) { throw 'no-healthy-production-node-for-dedicated-test' }
    $saved = Read-ProtectedSubscriptionFile (Get-ExitSnapshotPath "$root/runtime" $healthy[0].nodeHash)
    $node = $saved.node | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
    $node.id = "acceptance-$runId"; $node.name = "Acceptance $runId"
    $other = $node | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
    $other.id = "acceptance-alternative-$runId"
    $hash = (Get-ExitNodeIdentity $node).SourceHash
    $otherHash = (Get-ExitNodeIdentity $other).SourceHash
    Write-ProtectedSubscriptionFile "$runtime/catalog.dpapi.json" @{ nodes = @($node, $other) }
    Write-JsonFileAtomic "$runtime/subscription-status.json" @{ state = 'updated'; nextRefreshAt = (Get-Date).ToUniversalTime().AddHours(1).ToString('o') }
    Save-ExitNodeSnapshot $runtime $hash $node
    Write-JsonFileAtomic "$runtime/exit-config.json" @{ maxExits = 1; nodeHashes = @($hash); configId = $runId; autoFallback = $false }
    $history = New-NineRouterPool $client "vpncheap-$($node.name)" "http://127.0.0.1:$($ExitPort - 1)"
    $historyId = $history.id
    Write-JsonFileAtomic "$runtime/9router-applied.json" @{ pools = @(@{ poolId = $historyId; nodeHash = 'historical'; port = $ExitPort - 1 }); bindings = @(); poolUpdates = @() }
    # 9Router's create endpoint always starts active. Use an invalid, unique test key and disable immediately.
    $created = Invoke-NineRouterRequest $client POST '/api/providers' @{ provider = 'openrouter'; name = "Acceptance $runId";
        apiKey = "invalid-acceptance-$runId"; priority = 100000; testStatus = 'error'; proxyPoolId = $historyId }
    $providerId = $created.connection.id
    Invoke-NineRouterRequest $client PUT "/api/providers/$providerId" @{ isActive = $false } | Out-Null
    & "$root/scripts/broker.ps1" -Action start -RuntimeDirectory $runtime -PortBase $ExitPort -MaxExits 1 -HealthIntervalSec 10 -ProbeTimeoutSec 15 | Out-Null
    & "$root/scripts/dashboard.ps1" -Action start -RuntimeDirectory $runtime -Port $DashboardPort | Out-Null
    $null = Wait-For { Read-Snapshot } { param($s) $s.exits.Count -eq 1 -and $s.exits[0].healthOk } 120
    $null = Post-Control '/api/nine-router/sync' @{}
    $snapshot = Wait-For { Read-Snapshot } { param($s) $s.exits[0].poolId } 90
    $currentId = $snapshot.exits[0].poolId
    $evidence.initial = @{ broker = $snapshot.broker; exits = $snapshot.exits; pools = $snapshot.pools; configuration = $snapshot.configuration }
    Check ($currentId -ne $historyId -and @($snapshot.pools | Where-Object { $_.id -eq $historyId -and $_.relationState -eq 'historical' }).Count -eq 1) 'Same-name historical pool retained; dedicated current exit gets independent pool'
    $pidBefore = $snapshot.exits[0].workerPid
    Set-NineRouterConnectionPool $client $providerId $currentId | Out-Null
    $response = Post-Control '/api/exit-config' @{ maxExits = 1; nodeHashes = @($otherHash) }
    $rejected = $response.Content | ConvertFrom-Json
    Check ($response.StatusCode -eq 409 -and $rejected.error -eq 'exit-has-bindings') 'Actual configuration request rejects inactive Provider cancellation'
    $afterReject = Read-Snapshot
    $connection = @(Get-NineRouterConnections $client | Where-Object id -eq $providerId)[0]
    Check ($afterReject.exits[0].workerPid -eq $pidBefore -and -not $connection.isActive -and (Get-NineRouterConnectionPoolId $connection) -eq $currentId) 'Rejected cancellation preserves live worker and binding'
    Invoke-NineRouterRequest $client PUT "/api/proxy-pools/$currentId" @{ proxyUrl = 'http://127.0.0.1:1' } | Out-Null
    $response = Post-Control '/api/nine-router/sync' @{}
    Check ($response.StatusCode -eq 202) 'Actual synchronization request accepted'
    $failed = Wait-For { Read-Snapshot } { param($s) $s.configuration.state -eq 'sync-error' }
    Check ($failed.exits[0].workerPid -eq $pidBefore -and $failed.exits[0].healthOk) 'Real pool conflict shows partial success and preserves healthy exit'
    $evidence.failure = @{ configuration = $failed.configuration; exits = $failed.exits }
    Invoke-NineRouterRequest $client PUT "/api/proxy-pools/$currentId" @{ proxyUrl = "http://127.0.0.1:$ExitPort" } | Out-Null
    $null = Post-Control '/api/nine-router/sync' @{}
    $restored = Wait-For { Read-Snapshot } { param($s) $s.configuration.state -eq 'completed' }
    $poolCount = @(Get-NineRouterPools $client).Count
    $repeat = (Post-Control '/api/nine-router/sync' @{}).Content | ConvertFrom-Json
    $null = Wait-For { Invoke-RestMethod "$dashboard/api/nine-router/sync" } {
        param($s) $s.state -eq 'completed' -and [datetime]$s.updatedAt -ge [datetime]$repeat.startedAt
    }
    Check (@(Get-NineRouterPools $client).Count -eq $poolCount -and $restored.exits[0].workerPid -eq $pidBefore) 'Real retry completes without duplicate pools or worker restart'
    $evidence.restored = @{ configuration = $restored.configuration; exits = $restored.exits; pools = $restored.pools }
    $evidence.state = 'passed'
}
catch { $evidence.state = 'failed'; $evidence.error = $_.Exception.Message; throw }
finally {
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    function Cleanup-Step($Name, [scriptblock]$Action) {
        try { & $Action }
        catch { $cleanupErrors.Add($Name) }
    }
    Cleanup-Step 'stop-dashboard' { & "$root/scripts/dashboard.ps1" -Action stop -RuntimeDirectory $runtime -Port $DashboardPort | Out-Null }
    $script:cleanupLock = $null
    Cleanup-Step 'wait-for-sync-before-cleanup' {
        $deadline = (Get-Date).AddSeconds(30)
        do {
            try { $script:cleanupLock = [IO.File]::Open((Join-Path $runtime '9router-sync.lock'), 'OpenOrCreate', 'ReadWrite', 'None'); break }
            catch [IO.IOException] { Start-Sleep -Milliseconds 200 }
        } while ((Get-Date) -lt $deadline)
        if ($null -eq $script:cleanupLock) { throw 'sync-still-running' }
    }
    if ($providerId) {
        Cleanup-Step 'unbind-test-provider' { Set-NineRouterConnectionPool $client $providerId $null | Out-Null }
        Cleanup-Step 'delete-test-provider' { Invoke-NineRouterRequest $client DELETE "/api/providers/$providerId" | Out-Null }
    }
    Cleanup-Step 'stop-test-broker' { & "$root/scripts/broker.ps1" -Action stop -RuntimeDirectory $runtime | Out-Null }
    $testIds = @($historyId, $currentId)
    Cleanup-Step 'read-test-ownership' {
        $owned = Read-JsonFile "$runtime/9router-applied.json"
        $script:cleanupPoolIds = @($testIds) + @(Get-OptionalProperty $owned 'pools' | Where-Object { $null -ne $_ } | ForEach-Object { $_.poolId })
    }
    if (Get-Variable cleanupPoolIds -Scope Script -ErrorAction SilentlyContinue) { $testIds = $script:cleanupPoolIds }
    Cleanup-Step 'delete-test-pools' {
        if ($null -eq $script:cleanupLock) { throw 'sync-still-running' }
        foreach ($pool in @(Get-NineRouterPools $client)) {
            if ($pool.id -in $testIds) {
                try { Remove-NineRouterPool $client $pool.id | Out-Null }
                catch { if ($_.Exception.Data['statusCode'] -ne 404) { $cleanupErrors.Add("delete-test-pool:$($pool.id)") } }
            }
        }
    }
    if ($null -ne $script:cleanupLock) { $script:cleanupLock.Dispose() }
    $evidence.providersUnchanged = $false
    $evidence.cleanup = @{ providerAbsent = $false; poolsAbsent = $false }
    Cleanup-Step 'verify-cleanup-and-business-baseline' {
        $evidence.providersUnchanged = $beforeProviders -eq (Provider-State @(Get-NineRouterConnections $client))
        $evidence.cleanup.providerAbsent = $providerId -notin @(Get-NineRouterConnections $client | ForEach-Object { $_.id })
        $evidence.cleanup.poolsAbsent = @((Get-NineRouterPools $client) | Where-Object id -in $testIds).Count -eq 0
    }
    $evidence.cleanupErrors = $cleanupErrors.ToArray()
    $evidence.finishedAt = (Get-Date).ToUniversalTime().ToString('o')
    if ($cleanupErrors.Count -or -not $evidence.providersUnchanged -or -not $evidence.cleanup.providerAbsent -or -not $evidence.cleanup.poolsAbsent) {
        $evidence.state = 'failed'; $evidence.error = 'provider-baseline-or-cleanup-verification-failed'
    }
    Write-JsonFileAtomic "$runtime/evidence.json" $evidence
    Write-Output "Evidence: $runtime/evidence.json"
    if ($evidence.state -eq 'failed') { throw $evidence.error }
}
