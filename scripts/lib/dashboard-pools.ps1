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
        [AllowEmptyCollection()] [object[]]$Connections,
        [AllowNull()] [object]$Ledger = $null
    )

    if ($null -eq $Status) { return @() }
    try {
        $plan = @(Get-OwnedNineRouterPlan -Status $Status -Pools @($Pools) -Ledger $Ledger)
    }
    catch {
        return @()
    }
    return @($plan | ForEach-Object {
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

    $ledger = Read-JsonFile $ledgerPath
    $plan = @(Get-OwnedNineRouterPlan -Status $status -Pools $pools -Ledger $ledger)
    foreach ($port in $requestedPorts) {
        $item = @($plan | Where-Object port -eq $port)
        if ($item.Count -ne 1) { return @{ code = 409; body = @{ error = 'exit-not-healthy'; port = $port } } }
        if ($item[0].action -eq 'conflict') { return @{ code = 409; body = @{ error = 'pool-conflict'; port = $port; reason = $item[0].conflictReason } } }
    }
    $result = Invoke-NineRouterSync -RuntimeDirectory $runtimeDirectory -Ports @($requestedPorts) -NoCleanup
    $script:nineRouterCache = $null
    $script:nineRouterCacheAt = [datetime]::MinValue
    return @{ code = 200; body = @{ ok = $result.state -eq 'completed'; results = $result.actions; state = $result.state } }
}
