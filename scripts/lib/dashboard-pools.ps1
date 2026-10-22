Set-StrictMode -Version Latest

function Send-DashboardJson {
    param(
        [Parameter(Mandatory = $true)] [System.Net.Sockets.NetworkStream]$Stream,
        [Parameter(Mandatory = $true)] [int]$StatusCode,
        [Parameter(Mandatory = $true)] [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 20 -Compress
    Send-DashboardResponse -Stream $Stream -StatusCode $StatusCode -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($json))
}

function Test-DashboardControlRequest {
    param(
        [Parameter(Mandatory = $true)] [System.Net.Sockets.NetworkStream]$Stream,
        [Parameter(Mandatory = $true)] [string]$Method,
        [Parameter(Mandatory = $true)] [hashtable]$Headers,
        [ValidateSet('GET', 'POST')] [string]$AllowedMethod = 'POST',
        [bool]$RequireJson = $true
    )

    if ($Method -ne $AllowedMethod) {
        Send-DashboardResponse -Stream $Stream -StatusCode 405 -ContentType 'text/plain; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes('Method not allowed'))
        return $false
    }

    $origin = ''
    if ($Headers.ContainsKey('origin')) { $origin = [string]$Headers['origin'] }
    $allowedOrigins = @(
        ('http://127.0.0.1:{0}' -f $Port),
        ('http://localhost:{0}' -f $Port),
        ('http://[::1]:{0}' -f $Port)
    )
    if (-not [string]::IsNullOrWhiteSpace($origin) -and $origin -notin $allowedOrigins) {
        Send-DashboardResponse -Stream $Stream -StatusCode 403 -ContentType 'text/plain; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes('Forbidden origin'))
        return $false
    }

    $controlHeader = ''
    if ($Headers.ContainsKey('x-exit-control')) { $controlHeader = [string]$Headers['x-exit-control'] }
    $contentType = ''
    if ($Headers.ContainsKey('content-type')) { $contentType = [string]$Headers['content-type'] }
    $validContentType = -not $RequireJson -or $contentType.StartsWith('application/json', [System.StringComparison]::OrdinalIgnoreCase)
    if ($controlHeader -ne '1' -or -not $validContentType) {
        Send-DashboardResponse -Stream $Stream -StatusCode 403 -ContentType 'text/plain; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes('Control request rejected'))
        return $false
    }

    return $true
}

function Get-PoolTestStatus {
    param([AllowNull()] [object]$Result)

    $value = Get-OptionalProperty -Object $Result -Name 'status'
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        $value = Get-OptionalProperty -Object $Result -Name 'testStatus'
    }
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        $value = Get-OptionalProperty -Object (Get-OptionalProperty -Object $Result -Name 'proxyPool') -Name 'testStatus'
    }
    return [string]$value
}

# Read-only: which healthy exits can get a new pool (create/update/exists/conflict).
function Get-DashboardPoolPlan {
    param(
        [AllowNull()] [object]$Status,
        [AllowEmptyCollection()] [object[]]$Pools,
        [AllowEmptyCollection()] [object[]]$Connections
    )

    if ($null -eq $Status) { return @() }
    try {
        $plan = New-NineRouterPlan -Status $Status -Pools @($Pools) -Connections @($Connections)
    }
    catch {
        return @()
    }
    return @($plan.Pools | ForEach-Object {
        [ordered]@{
            name = [string]$_.name
            port = [int]$_.port
            nodeHash = [string]$_.nodeHash
            action = [string]$_.action
            conflictReason = [string]$_.conflictReason
            existingPoolId = [string]$_.existingPoolId
        }
    })
}

# Creates (or re-enables strict mode on) 9Router pools for the requested loopback ports.
# Never touches provider connection bindings.
function Invoke-CreateNineRouterPools {
    param([Parameter(Mandatory = $true)] [object]$Request)

    $requestedPorts = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($item in @(Get-OptionalProperty -Object $Request -Name 'ports')) {
        if ($null -eq $item) { continue }
        $value = 0
        if (-not [int]::TryParse([string]$item, [ref]$value) -or $value -lt 1 -or $value -gt 65535) {
            return @{ code = 400; body = [ordered]@{ error = 'invalid-port' } }
        }
        $requestedPorts.Add($value) | Out-Null
    }
    if ($requestedPorts.Count -eq 0 -or $requestedPorts.Count -gt 64) {
        return @{ code = 400; body = [ordered]@{ error = 'no-ports' } }
    }

    $status = Read-JsonFile -Path $statusPath
    if ($null -eq $status) {
        return @{ code = 409; body = [ordered]@{ error = 'broker-status-missing' } }
    }
    if ([string](Get-OptionalProperty -Object $status -Name 'state') -ne 'running') {
        return @{ code = 409; body = [ordered]@{ error = 'broker-not-running' } }
    }

    try {
        $client = New-NineRouterClient
        $pools = @(Get-NineRouterPools -Client $client)
        $connections = @(Get-NineRouterConnections -Client $client)
    }
    catch {
        return @{ code = 502; body = [ordered]@{ error = 'nine-router-unavailable' } }
    }

    $plan = New-NineRouterPlan -Status $status -Pools $pools -Connections $connections
    $planByPort = @{}
    foreach ($item in @($plan.Pools)) { $planByPort[[int]$item.port] = $item }

    foreach ($port in $requestedPorts) {
        if (-not $planByPort.ContainsKey($port)) {
            return @{ code = 409; body = [ordered]@{ error = 'exit-not-healthy'; port = $port } }
        }
        if ($planByPort[$port].action -eq 'conflict') {
            return @{ code = 409; body = [ordered]@{ error = 'pool-conflict'; port = $port; reason = [string]$planByPort[$port].conflictReason } }
        }
    }

    $ledger = Read-JsonFile -Path $ledgerPath
    $ledgerPools = New-Object System.Collections.Generic.List[object]
    $ledgerPoolUpdates = New-Object System.Collections.Generic.List[object]
    $ledgerBindings = New-Object System.Collections.Generic.List[object]
    if ($null -ne $ledger) {
        foreach ($item in @(Get-OptionalProperty -Object $ledger -Name 'pools')) { if ($null -ne $item) { $ledgerPools.Add($item) } }
        foreach ($item in @(Get-OptionalProperty -Object $ledger -Name 'poolUpdates')) { if ($null -ne $item) { $ledgerPoolUpdates.Add($item) } }
        foreach ($item in @(Get-OptionalProperty -Object $ledger -Name 'bindings')) { if ($null -ne $item) { $ledgerBindings.Add($item) } }
    }

    $results = New-Object System.Collections.Generic.List[object]
    $ledgerChanged = $false
    foreach ($port in @($requestedPorts | Sort-Object)) {
        $item = $planByPort[$port]
        $result = [ordered]@{
            name = [string]$item.name
            port = $port
            action = [string]$item.action
            poolId = [string]$item.existingPoolId
            testStatus = $null
            error = $null
        }
        try {
            if ($item.action -eq 'create') {
                $pool = New-NineRouterPool -Client $client -Name ([string]$item.name) -ProxyUrl ('http://127.0.0.1:{0}' -f $port)
                $result.poolId = [string]$pool.id
                $ledgerPools.Add([ordered]@{
                    name = [string]$item.name
                    poolId = [string]$pool.id
                    port = $port
                    nodeHash = [string]$item.nodeHash
                    createdAt = (Get-Date).ToUniversalTime().ToString('o')
                })
                $ledgerChanged = $true
                Write-DashboardLog ('pool-create port={0} id={1}' -f $port, $pool.id)
            }
            elseif ($item.action -eq 'update') {
                Set-NineRouterPool -Client $client -PoolId ([string]$item.existingPoolId) -StrictProxy $true -IsActive $true | Out-Null
                $ledgerPoolUpdates.Add([ordered]@{
                    name = [string]$item.name
                    poolId = [string]$item.existingPoolId
                    port = $port
                    nodeHash = [string]$item.nodeHash
                    previousStrictProxy = [bool]$item.currentStrictProxy
                    previousIsActive = [bool]$item.currentIsActive
                    updatedAt = (Get-Date).ToUniversalTime().ToString('o')
                })
                $ledgerChanged = $true
                Write-DashboardLog ('pool-update port={0} id={1}' -f $port, $item.existingPoolId)
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$result.poolId)) {
                try {
                    $result.testStatus = Get-PoolTestStatus -Result (Test-NineRouterPool -Client $client -PoolId ([string]$result.poolId))
                }
                catch {
                    $result.testStatus = 'request-error'
                }
            }
        }
        catch {
            $result.error = 'request-failed'
            Write-DashboardLog ('pool-create-failed port={0}' -f $port)
        }
        $results.Add($result)
    }

    if ($ledgerChanged) {
        Write-JsonFileAtomic -Path $ledgerPath -Value ([ordered]@{
            schemaVersion = 1
            kind = 'vpncheap-9router-ledger'
            updatedAt = (Get-Date).ToUniversalTime().ToString('o')
            pools = $ledgerPools.ToArray()
            poolUpdates = $ledgerPoolUpdates.ToArray()
            bindings = $ledgerBindings.ToArray()
        })
    }

    $script:nineRouterCache = $null
    $script:nineRouterCacheAt = [datetime]::MinValue

    $failed = @($results | Where-Object { $null -ne $_.error }).Count
    return @{
        code = 200
        body = [ordered]@{
            ok = ($failed -eq 0)
            results = $results.ToArray()
        }
    }
}
