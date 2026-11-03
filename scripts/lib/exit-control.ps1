Set-StrictMode -Version Latest

function Assert-ExitRemovalAllowed {
    param([string]$RuntimeDirectory, [object[]]$Current, [AllowEmptyCollection()][object[]]$Desired)

    $desiredHashes = @($Desired | ForEach-Object { [string]$_.NodeHash })
    $removed = @($Current | Where-Object { [string]$_.nodeHash -notin $desiredHashes })
    if (-not $removed.Count) { return }
    try {
        $client = New-NineRouterClient
        $pools = @(Get-NineRouterPools $client)
        $connections = @(Get-NineRouterConnections $client)
    } catch { throw 'binding-check-unavailable' }
    $ledger = Read-JsonFile (Join-Path $RuntimeDirectory '9router-applied.json')
    $affected = [Collections.Generic.List[object]]::new()
    foreach ($exit in $removed) {
        $ownedIds = @(Get-OptionalProperty $ledger 'pools' | Where-Object { $null -ne $_ } | Where-Object {
            [string]$_.nodeHash -eq [string]$exit.nodeHash
        } | ForEach-Object { [string]$_.poolId })
        $poolIds = @($pools | Where-Object {
            [string]$_.id -in $ownedIds -or
            (ConvertTo-NineRouterUrlKey $_.proxyUrl) -eq "http://127.0.0.1:$($exit.port)"
        } | ForEach-Object { [string]$_.id })
        foreach ($connection in $connections) {
            if ((Get-NineRouterConnectionPoolId $connection) -in $poolIds) {
                $affected.Add(@{ nodeHash = $exit.nodeHash; port = $exit.port
                    connectionId = $connection.id; provider = Get-OptionalProperty $connection 'provider' })
            }
        }
    }
    if ($affected.Count) {
        $errorRecord = [InvalidOperationException]::new('exit-has-bindings')
        $errorRecord.Data['affected'] = $affected.ToArray()
        throw $errorRecord
    }
}

function Invoke-ExitConfigChange {
    param([string]$RuntimeDirectory, [object]$Request)

    $lock = $null
    try {
        try { $lock = [IO.File]::Open((Join-Path $RuntimeDirectory 'exit-config.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
        catch { return @{ code = 409; body = @{ error = 'config-change-running' } } }
        $status = Read-JsonFile (Join-Path $RuntimeDirectory 'status.json')
        if ($null -eq $status -or $status.state -ne 'running' -or
            -not (Test-ProcessAlive (Get-OptionalProperty $status 'brokerPid')) -or
            [math]::Abs(((Get-Date).ToUniversalTime() - [datetime]$status.updatedAt).TotalSeconds) -gt 120) {
            return @{ code = 409; body = @{ error = 'broker-status-not-safe' } }
        }
        $max = 0
        if (-not [int]::TryParse([string](Get-OptionalProperty $Request 'maxExits'), [ref]$max) -or $max -lt 1 -or $max -gt 64) {
            return @{ code = 400; body = @{ error = 'invalid-max-exits' } }
        }
        $hashes = @(@(Get-OptionalProperty $Request 'nodeHashes') | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)
        if ($hashes.Count -gt $max) { return @{ code = 400; body = @{ error = 'selection-exceeds-max' } } }
        if (@($hashes | Where-Object { $_ -notmatch '^[0-9a-f]{8,64}$' }).Count) {
            return @{ code = 400; body = @{ error = 'unknown-node' } }
        }
        $candidates = @(Get-OptionalProperty $status 'candidates')
        $catalogPath = Join-Path $RuntimeDirectory 'catalog.dpapi.json'
        if (Test-Path -LiteralPath $catalogPath) {
            $catalog = Read-ProtectedSubscriptionFile $catalogPath
            $candidates = @(Get-ExitCatalog $RuntimeDirectory $catalog.nodes ([string](Get-OptionalProperty $status 'protocol')) ([string](Get-OptionalProperty $status 'country')))
        }
        if (-not $candidates.Count) { return @{ code = 409; body = @{ error = 'candidate-list-unavailable' } } }
        $desired = @(Get-ExitSelection -Candidates $candidates -NodeHashes $hashes -MaxExits $max -Exits @($status.exits))
        if (-not $desired.Count) { return @{ code = 409; body = @{ error = 'no-selectable-nodes' } } }
        Assert-ExitRemovalAllowed $RuntimeDirectory @($status.exits) $desired
        $path = Join-Path $RuntimeDirectory 'exit-config.json'
        $existing = Read-JsonFile $path
        $config = [ordered]@{
            schemaVersion = 1; configId = [guid]::NewGuid().ToString('N'); maxExits = $max
            selectionMode = if ($hashes.Count) { 'manual' } else { 'auto' }; nodeHashes = $hashes
            updatedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        foreach ($name in @('replacements', 'autoFallback')) {
            $value = Get-OptionalProperty $existing $name
            if ($null -ne $value) { $config[$name] = $value }
        }
        Write-JsonFileAtomic $path $config
        return @{ code = 202; body = @{ ok = $true; state = 'saved'; configId = $config.configId
            maxExits = $max; selectionMode = $config.selectionMode; nodeHashes = $hashes } }
    }
    catch {
        $reason = $_.Exception.Message
        $code = if ($reason -in @('unknown-node', 'node-unavailable')) { 400 } else { 409 }
        if ($reason -notin @('unknown-node', 'node-unavailable', 'exit-has-bindings', 'binding-check-unavailable')) { $reason = 'config-check-failed' }
        return @{ code = $code; body = @{ error = $reason; affected = @($_.Exception.Data['affected'] | Where-Object { $null -ne $_ }) } }
    }
    finally { if ($null -ne $lock) { $lock.Dispose() } }
}
