Set-StrictMode -Version Latest

function Assert-NineRouterSyncStatus {
    param($Status)
    if ($null -eq $Status -or $Status.state -ne 'running' -or
        -not (Test-ProcessAlive -ProcessId $Status.brokerPid) -or
        [math]::Abs(((Get-Date).ToUniversalTime() - [datetime]$Status.updatedAt).TotalSeconds) -gt 120 -or
        @($Status.exits).Count -eq 0) {
        throw 'broker-status-not-safe'
    }
}

function Get-NineRouterObsoletePools {
    param($Status, [object[]]$Pools, $Ledger)
    # A selected but temporarily unhealthy exit is still in use.
    $ports = @($Status.exits | ForEach-Object { [int]$_.port })
    foreach ($entry in @(Get-OptionalProperty $Ledger 'pools')) {
        if ($null -eq $entry -or [int]$entry.port -in $ports) { continue }
        foreach ($pool in $Pools) {
            if ([string]$pool.id -ne [string]$entry.poolId) { continue }
            if ([string]$pool.name -eq 'vpncheap') { continue }
            $expected = ConvertTo-NineRouterUrlKey ('http://127.0.0.1:{0}' -f $entry.port)
            if ((ConvertTo-NineRouterUrlKey $pool.proxyUrl) -ne $expected) { continue }
            if (Test-TcpPortListening -Port ([int]$entry.port)) { continue }
            [pscustomobject]@{ pool = $pool; entry = $entry }
        }
    }
}

function Invoke-NineRouterSync {
    param([string]$RuntimeDirectory, [string]$MigratePool = '')
    $statusPath = Join-Path $RuntimeDirectory 'status.json'
    $ledgerPath = Join-Path $RuntimeDirectory '9router-applied.json'
    $status = Read-JsonFile $statusPath
    Assert-NineRouterSyncStatus $status
    $configPath = Join-Path $RuntimeDirectory '9router-sync-config.json'
    $config = Read-JsonFile $configPath
    $mapping = @{}
    $migrations = Get-OptionalProperty $config 'migrations'
    if ($null -ne $migrations) {
        foreach ($property in $migrations.PSObject.Properties) {
            $mapping[$property.Name] = [string]$property.Value
        }
    }
    if ($MigratePool) {
        $parts = $MigratePool.Split('=')
        if ($parts.Count -ne 2) { throw 'invalid-migration-map' }
        $replacement = @($status.exits | Where-Object port -EQ ([int]$parts[1]))
        if ($replacement.Count -ne 1) { throw 'migration-target-not-selected' }
        $mapping[$parts[0]] = [string]$replacement[0].nodeHash
        Write-JsonFileAtomic $configPath @{ migrations = $mapping }
    }
    $client = New-NineRouterClient
    $pools = @(Get-NineRouterPools $client)
    $ledger = Read-JsonFile $ledgerPath
    if ($null -eq $ledger) {
        $ledger = [pscustomobject]@{ schemaVersion = 1; kind = 'vpncheap-9router-ledger'; pools = @(); poolUpdates = @(); bindings = @() }
    }
    $actions = [System.Collections.Generic.List[object]]::new()
    $owned = @($ledger.pools | ForEach-Object { [string]$_.poolId })
    $plan = New-NineRouterPlan -Status $status -Pools $pools -Connections @()
    foreach ($item in $plan.Pools) {
        if ($item.action -eq 'create') {
            $pool = New-NineRouterPool $client $item.name ('http://127.0.0.1:{0}' -f $item.port)
            $ledger.pools = @($ledger.pools) + @([pscustomobject]@{
                name = $item.name; poolId = $pool.id; port = $item.port
                nodeHash = $item.nodeHash; createdAt = (Get-Date).ToUniversalTime().ToString('o')
            })
            # Persist ownership immediately, before tests or further remote changes.
            Write-JsonFileAtomic $ledgerPath $ledger
            $actions.Add(@{ action = 'created'; poolId = $pool.id })
        }
        elseif ($item.existingPoolId -in $owned) {
            if ($item.action -eq 'update') {
                Set-NineRouterPool $client $item.existingPoolId $true $true | Out-Null
            }
            if ($item.action -in @('update', 'exists')) {
                $pool = @($pools | Where-Object id -EQ $item.existingPoolId)[0]
                $exit = @($status.exits | Where-Object port -EQ $item.port)[0]
                if ([string]$pool.name -ne "vpncheap-$($exit.nodeName)") {
                    Rename-NineRouterPool $client $pool.id "vpncheap-$($exit.nodeName)" | Out-Null
                }
            }
        }
    }
    $pools = @(Get-NineRouterPools $client)
    foreach ($pool in $pools) {
        if ($pool.id -notin @($ledger.pools | ForEach-Object { $_.poolId })) { continue }
        $url = ConvertTo-NineRouterUrlKey $pool.proxyUrl
        $selected = @($status.exits | Where-Object {
            (ConvertTo-NineRouterUrlKey ('http://127.0.0.1:{0}' -f $_.port)) -eq $url
        })
        if ($selected.Count -eq 1) {
            try { Test-NineRouterPool $client $pool.id | Out-Null }
            catch { $actions.Add(@{ action = 'test-failed'; poolId = $pool.id }) }
        }
    }
    $obsolete = @(Get-NineRouterObsoletePools $status $pools $ledger)
    foreach ($old in $obsolete) {
        $oldId = [string]$old.pool.id
        $connections = @(Get-NineRouterConnections $client)
        $bound = @($connections | Where-Object { (Get-NineRouterConnectionPoolId $_) -eq $oldId })
        if ($bound.Count -gt 0) {
            $targetExits = @($status.exits | Where-Object {
                ($mapping.ContainsKey($oldId) -and [string]$_.nodeHash -eq $mapping[$oldId]) -or
                (-not $mapping.ContainsKey($oldId) -and $_.nodeHash -eq $old.entry.nodeHash)
            })
            if ($targetExits.Count -ne 1) {
                $actions.Add(@{ action = 'retained'; poolId = $oldId; reason = 'bound-no-explicit-replacement' })
                continue
            }
            $targetExit = $targetExits[0]
            $targetUrl = ConvertTo-NineRouterUrlKey ('http://127.0.0.1:{0}' -f $targetExit.port)
            $targets = @($pools | Where-Object {
                (ConvertTo-NineRouterUrlKey $_.proxyUrl) -eq $targetUrl -and
                $_.id -in @($ledger.pools | ForEach-Object { $_.poolId })
            })
            if ($targets.Count -ne 1 -or -not $targets[0].strictProxy -or -not $targets[0].isActive) {
                $actions.Add(@{ action = 'retained'; poolId = $oldId; reason = 'replacement-unavailable' })
                continue
            }
            $target = $targets[0]
            try { Test-NineRouterPool $client $target.id | Out-Null }
            catch {
                $actions.Add(@{ action = 'retained'; poolId = $oldId; reason = 'replacement-test-failed' })
                continue
            }
            $tested = @(Get-NineRouterPools $client | Where-Object id -EQ $target.id)
            if ($tested.Count -ne 1 -or $tested[0].testStatus -ne 'active') {
                $actions.Add(@{ action = 'retained'; poolId = $oldId; reason = 'replacement-test-failed' })
                continue
            }
            foreach ($connection in $bound) {
                $bindingStatus = Read-JsonFile $statusPath
                Assert-NineRouterSyncStatus $bindingStatus
                $currentTarget = @($bindingStatus.exits | Where-Object {
                    $_.nodeHash -eq $targetExit.nodeHash -and [int]$_.port -eq [int]$targetExit.port
                })
                if ($bindingStatus.instanceId -ne $status.instanceId -or $currentTarget.Count -ne 1) {
                    throw 'migration-selection-changed'
                }
                $fresh = @(Get-NineRouterConnections $client | Where-Object id -EQ $connection.id)
                if ($fresh.Count -ne 1 -or (Get-NineRouterConnectionPoolId $fresh[0]) -ne $oldId) { continue }
                $audit = @{ connectionId = $connection.id; previousPoolId = $oldId; poolId = $target.id; updatedAt = (Get-Date).ToUniversalTime().ToString('o') }
                # The apply ledger's rollback cannot restore a pool that sync deletes.
                Write-RedactedLog (Join-Path $RuntimeDirectory 'logs\9router-sync.log') ('migration-intent ' + ($audit | ConvertTo-Json -Compress))
                Set-NineRouterConnectionPool $client $connection.id $target.id | Out-Null
                $confirmed = @(Get-NineRouterConnections $client | Where-Object id -EQ $connection.id)
                if ($confirmed.Count -ne 1 -or (Get-NineRouterConnectionPoolId $confirmed[0]) -ne $target.id) {
                    throw 'binding-verification-failed'
                }
                $actions.Add(@{ action = 'migrated'; connectionId = $connection.id; poolId = $target.id })
            }
        }
        # Recheck selection, endpoint ownership and bindings immediately before deletion.
        $freshStatus = Read-JsonFile $statusPath
        Assert-NineRouterSyncStatus $freshStatus
        if ($freshStatus.instanceId -ne $status.instanceId) { throw 'broker-instance-changed' }
        $stillObsolete = @(Get-NineRouterObsoletePools $freshStatus @(Get-NineRouterPools $client) $ledger |
            Where-Object { $_.pool.id -eq $oldId })
        $remaining = @(Get-NineRouterConnections $client | Where-Object { (Get-NineRouterConnectionPoolId $_) -eq $oldId })
        if ($stillObsolete.Count -ne 1 -or $remaining.Count -gt 0) { continue }
        Write-RedactedLog (Join-Path $RuntimeDirectory 'logs\9router-sync.log') "delete-intent poolId=$oldId"
        Remove-NineRouterPool $client $oldId | Out-Null
        $actions.Add(@{ action = 'deleted'; poolId = $oldId })
    }
    # Keep the ownership ledger as a durable audit trail, including deleted pools.
    return @{ state = 'completed'; updatedAt = (Get-Date).ToUniversalTime().ToString('o'); actions = $actions.ToArray() }
}
