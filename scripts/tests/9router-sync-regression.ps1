$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. "$root/scripts/lib/broker-common.ps1"
. "$root/scripts/lib/9router.ps1"
. "$root/scripts/lib/9router-sync.ps1"
$runtime = Join-Path ([IO.Path]::GetTempPath()) ('pool-sync-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($runtime) | Out-Null

function New-NineRouterClient { return @{} }
function Get-NineRouterPools { param($Client) return $script:pools }
function Get-NineRouterConnections { param($Client) return $script:connections }
function Test-TcpPortListening { param($Port) return $Port -in $script:listening }
function Test-NineRouterPool {
    param($Client, $PoolId)
    foreach ($pool in $script:pools) {
        if ($pool.id -eq $PoolId) { $pool.testStatus = $script:testStatus }
    }
}
function Remove-NineRouterPool {
    param($Client, $PoolId)
    $script:deleted += $PoolId
    $script:pools = @($script:pools | Where-Object id -NE $PoolId)
}
function Set-NineRouterConnectionPool {
    param($Client, $ConnectionId, $PoolId)
    if ($script:bindFailure) { throw 'fixture-bind-failure' }
    foreach ($connection in $script:connections) {
        if ($connection.id -eq $ConnectionId) { $connection.providerSpecificData.proxyPoolId = $PoolId }
    }
}
function Reset-Fixture {
    $script:deleted = @()
    $script:listening = @(39026)
    $script:testStatus = 'active'
    $script:bindFailure = $false
    $script:status = [pscustomobject]@{
        state = 'running'; brokerPid = $PID; instanceId = 'fixture'
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
        exits = @([pscustomobject]@{
            nodeHash = 'new'; nodeName = 'TW-Test'; port = 39026; state = 'healthy'; healthOk = $true
        })
    }
    $script:pools = @(
        [pscustomobject]@{ id = 'new'; name = 'vpncheap-TW-Test'; proxyUrl = 'http://127.0.0.1:39026'; strictProxy = $true; isActive = $true; testStatus = 'active' },
        [pscustomobject]@{ id = 'old'; name = 'vpncheap-old'; proxyUrl = 'http://127.0.0.1:39009'; strictProxy = $true; isActive = $true; testStatus = 'error' },
        [pscustomobject]@{ id = 'foreign'; name = 'vpncheap-foreign'; proxyUrl = 'http://127.0.0.1:39008'; strictProxy = $true; isActive = $true; testStatus = 'error' }
    )
    $script:connections = @([pscustomobject]@{ id = 'claude'; providerSpecificData = [pscustomobject]@{ proxyPoolId = 'old' } })
    Write-JsonFileAtomic "$runtime/status.json" $script:status
    Write-JsonFileAtomic "$runtime/9router-applied.json" @{
        pools = @(@{ poolId = 'new'; port = 39026; nodeHash = 'new' }, @{ poolId = 'old'; port = 39009; nodeHash = 'old' })
        bindings = @(); poolUpdates = @()
    }
    Write-JsonFileAtomic "$runtime/9router-sync-config.json" @{ migrations = @{} }
}
function Assert-True($Value, $Message) {
    if (-not $Value) { throw $Message }
    Write-Output "PASS $Message"
}
try {
    Reset-Fixture
    Write-JsonFileAtomic "$runtime/9router-sync-config.json" $null
    $result = Invoke-NineRouterSync $runtime
    Assert-True ($script:deleted.Count -eq 0) 'bound old pool without explicit replacement is retained'

    Reset-Fixture
    $result = Invoke-NineRouterSync $runtime -MigratePool 'old=39026'
    Assert-True ((Get-NineRouterConnectionPoolId $script:connections[0]) -eq 'new' -and 'old' -in $script:deleted) 'verified migration occurs before old pool deletion'
    Assert-True ('foreign' -notin $script:deleted) 'unowned pool with matching prefix is untouched'
    $applied = Read-JsonFile "$runtime/9router-applied.json"
    Assert-True (@($applied.bindings).Count -eq 0) 'cleanup migrations do not create invalid legacy rollback targets'
    $result = Invoke-NineRouterSync $runtime
    Assert-True ($script:deleted.Count -eq 1 -and $result.actions.Count -eq 0) 'repeat sync is idempotent'

    Reset-Fixture
    $script:testStatus = 'error'
    $result = Invoke-NineRouterSync $runtime -MigratePool 'old=39026'
    Assert-True ($script:deleted.Count -eq 0 -and (Get-NineRouterConnectionPoolId $script:connections[0]) -eq 'old') 'failed target test preserves old binding and pool'
    $script:testStatus = 'active'
    $result = Invoke-NineRouterSync $runtime
    Assert-True ('old' -in $script:deleted) 'persisted replacement retries automatically after recovery'

    Reset-Fixture
    $script:connections = @()
    $script:status.exits += [pscustomobject]@{ nodeHash = 'old'; nodeName = 'old'; port = 39009; state = 'degraded'; healthOk = $false }
    Write-JsonFileAtomic "$runtime/status.json" $script:status
    $result = Invoke-NineRouterSync $runtime
    Assert-True ($script:deleted.Count -eq 0) 'selected unhealthy pool is never deleted'

    Reset-Fixture
    $script:connections = @()
    $script:listening += 39009
    $result = Invoke-NineRouterSync $runtime
    Assert-True ($script:deleted.Count -eq 0) 'listening obsolete endpoint is retained'

    Reset-Fixture
    $script:pools[1].proxyUrl = 'http://127.0.0.1:39999'
    $script:connections = @()
    $result = Invoke-NineRouterSync $runtime
    Assert-True ($script:deleted.Count -eq 0) 'externally edited endpoint is not treated as owned'

    Reset-Fixture
    $script:status.updatedAt = (Get-Date).AddMinutes(-10).ToUniversalTime().ToString('o')
    Write-JsonFileAtomic "$runtime/status.json" $script:status
    $blocked = $false
    try { Invoke-NineRouterSync $runtime | Out-Null } catch { $blocked = $_.Exception.Message -eq 'broker-status-not-safe' }
    Assert-True ($blocked -and $script:deleted.Count -eq 0) 'stale broker status prevents all mutations'

    Reset-Fixture
    $script:bindFailure = $true
    $blocked = $false
    try { Invoke-NineRouterSync $runtime -MigratePool 'old=39026' | Out-Null } catch { $blocked = $true }
    Assert-True ($blocked -and $script:deleted.Count -eq 0) 'binding request failure cannot delete old pool'

    Reset-Fixture
    $script:connections = @()
    $result = Invoke-NineRouterSync $runtime
    Assert-True ('old' -in $script:deleted) 'unbound obsolete owned pool is removed'

    Reset-Fixture
    $script:pools[1].name = 'vpncheap'
    $script:connections = @()
    $result = Invoke-NineRouterSync $runtime
    Assert-True ($script:deleted.Count -eq 0) 'protected base pool is never deleted'
}
finally {
    $fullPath = [IO.Path]::GetFullPath($runtime)
    if ($fullPath.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and
        (Split-Path -Leaf $fullPath) -like 'pool-sync-test-*') {
        Remove-Item -LiteralPath $fullPath -Recurse -Force
    }
}
