Set-StrictMode -Version Latest

function Get-OwnedNineRouterPlan {
    param($Status, [AllowEmptyCollection()][object[]]$Pools, $Ledger)

    foreach ($exit in @(Get-OptionalProperty $Status 'exits')) {
        if ($null -eq $exit -or -not $exit.healthOk -or $exit.state -ne 'healthy' -or [int]$exit.port -le 0) { continue }
        $entries = @(Get-OptionalProperty $Ledger 'pools' | Where-Object { $null -ne $_ } | Where-Object {
            $_.nodeHash -eq $exit.nodeHash -and $_.poolId -in @($Pools | ForEach-Object { $_.id })
        })
        $url = "http://127.0.0.1:$($exit.port)"
        $atTarget = @($entries | Where-Object port -eq $exit.port)
        if ($atTarget.Count -eq 1) { $entries = $atTarget }
        $label = [string](Get-OptionalProperty $exit 'configuredNodeName')
        if (-not $label) { $label = [string]$exit.nodeHash }
        $item = [pscustomobject]@{ nodeHash = $exit.nodeHash; port = [int]$exit.port
            name = "vpncheap-$label-$($exit.nodeHash)"; action = 'create'; existingPoolId = $null; conflictReason = $null }
        $matches = @($Pools | Where-Object { (ConvertTo-NineRouterUrlKey $_.proxyUrl) -eq $url })
        if ($entries.Count -gt 1) { $item.action = 'conflict'; $item.conflictReason = 'ambiguous-ownership' }
        elseif ($entries.Count -eq 1) {
            $entry = $entries[0]
            $pool = @($Pools | Where-Object id -eq $entry.poolId)[0]
            $item.existingPoolId = $pool.id; $item.name = $pool.name
            $actual = ConvertTo-NineRouterUrlKey $pool.proxyUrl
            if ($actual -ne "http://127.0.0.1:$($entry.port)") {
                $item.action = 'conflict'; $item.conflictReason = 'owned-address-edited'
            } elseif (@($matches | Where-Object id -ne $pool.id).Count) {
                $item.action = 'conflict'; $item.conflictReason = 'duplicate-port'
            } elseif ($actual -ne $url) { $item.action = 'repair' }
            elseif (-not $pool.strictProxy -or -not $pool.isActive) { $item.action = 'update' }
            else { $item.action = 'exists' }
        }
        elseif ($matches.Count) { $item.action = 'conflict'; $item.conflictReason = 'port-not-owned' }
        elseif (@($Pools | Where-Object name -eq $item.name).Count) { $item.action = 'conflict'; $item.conflictReason = 'name-not-owned' }
        $item
    }
}

function Assert-NineRouterSelectionUnchanged {
    param([string]$RuntimeDirectory, $Original)
    $current = Read-JsonFile (Join-Path $RuntimeDirectory 'status.json')
    Assert-NineRouterSyncStatus $current
    $before = @($Original.exits | ForEach-Object { "$($_.nodeHash):$($_.port)" } | Sort-Object) -join '|'
    $after = @($current.exits | ForEach-Object { "$($_.nodeHash):$($_.port)" } | Sort-Object) -join '|'
    if ($current.instanceId -ne $Original.instanceId -or $before -ne $after -or
        (Get-OptionalProperty $current 'appliedConfigId') -ne (Get-OptionalProperty $Original 'appliedConfigId')) {
        throw 'sync-selection-changed'
    }
    $config = Read-JsonFile (Join-Path $RuntimeDirectory 'exit-config.json')
    $requestedId = Get-OptionalProperty $config 'configId'
    if ($requestedId -and $requestedId -ne (Get-OptionalProperty $Original 'appliedConfigId')) { throw 'sync-configuration-pending' }
}

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
    param([string]$RuntimeDirectory, [string]$MigratePool = '', [int[]]$Ports = @(), [switch]$NoCleanup)
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
    if ($null -eq $ledger.PSObject.Properties['pendingCreates']) { $ledger | Add-Member NoteProperty pendingCreates @() }
    if ($null -eq $ledger.PSObject.Properties['pendingRepairs']) { $ledger | Add-Member NoteProperty pendingRepairs @() }
    foreach ($pending in @($ledger.pendingRepairs)) {
        $found = @($pools | Where-Object id -eq $pending.poolId)
        $entries = @($ledger.pools | Where-Object { $_.poolId -eq $pending.poolId -and $_.nodeHash -eq $pending.nodeHash })
        if ($found.Count -eq 1 -and $entries.Count -eq 1 -and
            [int]$entries[0].port -eq [int]$pending.previousPort -and
            (ConvertTo-NineRouterUrlKey $found[0].proxyUrl) -eq "http://127.0.0.1:$($pending.port)") {
            $entries[0].port = $pending.port
            $ledger.pendingRepairs = @($ledger.pendingRepairs | Where-Object poolId -ne $pending.poolId)
            Write-JsonFileAtomic $ledgerPath $ledger
        }
    }
    # A persisted creation intent is the only basis for reconciling an uncertain remote response.
    foreach ($pending in @($ledger.pendingCreates)) {
        $found = @($pools | Where-Object {
            $_.name -eq $pending.name -and (ConvertTo-NineRouterUrlKey $_.proxyUrl) -eq "http://127.0.0.1:$($pending.port)"
        })
        if ($found.Count -eq 1 -and $found[0].id -notin @($ledger.pools | ForEach-Object { $_.poolId })) {
            $ledger.pools = @($ledger.pools) + @([pscustomobject]@{ name = $pending.name; poolId = $found[0].id
                port = $pending.port; nodeHash = $pending.nodeHash; createdAt = $pending.createdAt })
            $ledger.pendingCreates = @($ledger.pendingCreates | Where-Object nodeHash -ne $pending.nodeHash)
            Write-JsonFileAtomic $ledgerPath $ledger
        }
    }
    $plan = @(Get-OwnedNineRouterPlan -Status $status -Pools $pools -Ledger $ledger)
    foreach ($item in $plan) {
        if ($Ports.Count -and $item.port -notin $Ports) { continue }
        Assert-NineRouterSelectionUnchanged $RuntimeDirectory $status
        if ($item.action -eq 'conflict') {
            $actions.Add(@{ action = 'conflict'; nodeHash = $item.nodeHash; port = $item.port; reason = $item.conflictReason })
            continue
        }
        if ($item.action -eq 'create') {
            if (@($ledger.pendingCreates | Where-Object nodeHash -eq $item.nodeHash).Count) {
                $actions.Add(@{ action = 'conflict'; nodeHash = $item.nodeHash; port = $item.port; reason = 'create-outcome-unknown' })
                continue
            }
            $ledger.pendingCreates = @($ledger.pendingCreates) + @([pscustomobject]@{
                name = $item.name; port = $item.port; nodeHash = $item.nodeHash; createdAt = (Get-Date).ToUniversalTime().ToString('o')
            })
            Write-JsonFileAtomic $ledgerPath $ledger
            try { $pool = New-NineRouterPool $client $item.name ('http://127.0.0.1:{0}' -f $item.port) }
            catch {
                # Explicit client rejection cannot have created a pool; transport and server failures stay uncertain.
                if ($_.Exception.Data['statusCode'] -in @(400, 401, 403, 404, 405, 422, 429)) {
                    $ledger.pendingCreates = @($ledger.pendingCreates | Where-Object nodeHash -ne $item.nodeHash)
                    Write-JsonFileAtomic $ledgerPath $ledger
                }
                $actions.Add(@{ action = 'create-failed'; nodeHash = $item.nodeHash; port = $item.port; reason = 'create-outcome-unknown' })
                continue
            }
            $ledger.pools = @($ledger.pools) + @([pscustomobject]@{
                name = $item.name; poolId = $pool.id; port = $item.port
                nodeHash = $item.nodeHash; createdAt = (Get-Date).ToUniversalTime().ToString('o')
            })
            $ledger.pendingCreates = @($ledger.pendingCreates | Where-Object nodeHash -ne $item.nodeHash)
            # Persist ownership immediately, before tests or further remote changes.
            Write-JsonFileAtomic $ledgerPath $ledger
            $actions.Add(@{ action = 'created'; poolId = $pool.id })
        }
        elseif ($item.action -in @('update', 'repair')) {
            Set-NineRouterPool $client $item.existingPoolId $true $true | Out-Null
            if ($item.action -eq 'repair') {
                $entry = @($ledger.pools | Where-Object poolId -eq $item.existingPoolId)[0]
                $ledger.pendingRepairs = @($ledger.pendingRepairs | Where-Object poolId -ne $item.existingPoolId) + @([pscustomobject]@{
                    poolId = $item.existingPoolId; nodeHash = $item.nodeHash; previousPort = $entry.port; port = $item.port
                    createdAt = (Get-Date).ToUniversalTime().ToString('o')
                })
                Write-JsonFileAtomic $ledgerPath $ledger
                Assert-NineRouterSelectionUnchanged $RuntimeDirectory $status
                Invoke-NineRouterRequest -Client $client -Method PUT -Path "/api/proxy-pools/$($item.existingPoolId)" -Body @{ proxyUrl = "http://127.0.0.1:$($item.port)" } | Out-Null
                $entry.port = $item.port
                $ledger.pendingRepairs = @($ledger.pendingRepairs | Where-Object poolId -ne $item.existingPoolId)
                Write-JsonFileAtomic $ledgerPath $ledger
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
            if ($Ports.Count -and $selected[0].port -notin $Ports) { continue }
            try {
                Assert-NineRouterSelectionUnchanged $RuntimeDirectory $status
                Test-NineRouterPool $client $pool.id | Out-Null
                $testedPool = @(Get-NineRouterPools $client | Where-Object id -eq $pool.id)
                if ($testedPool.Count -ne 1 -or $testedPool[0].testStatus -ne 'active') { throw 'pool-test-failed' }
            }
            catch { $actions.Add(@{ action = 'test-failed'; poolId = $pool.id }) }
        }
    }
    $obsolete = @(if (-not $NoCleanup) { Get-NineRouterObsoletePools $status $pools $ledger })
    foreach ($old in $obsolete) {
        Assert-NineRouterSelectionUnchanged $RuntimeDirectory $status
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
                Assert-NineRouterSelectionUnchanged $RuntimeDirectory $status
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
        Assert-NineRouterSelectionUnchanged $RuntimeDirectory $status
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
    $failed = @($actions | Where-Object { $_.action -in @('conflict', 'create-failed', 'test-failed') -or
        ([string](Get-OptionalProperty $_ 'reason')) -in @('replacement-test-failed', 'replacement-unavailable') }).Count
    return @{ state = if ($failed) { 'error' } else { 'completed' }
        configId = Get-OptionalProperty $status 'appliedConfigId'; instanceId = $status.instanceId
        updatedAt = (Get-Date).ToUniversalTime().ToString('o'); actions = $actions.ToArray() }
}
