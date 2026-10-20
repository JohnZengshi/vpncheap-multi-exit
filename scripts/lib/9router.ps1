Set-StrictMode -Version Latest

function Get-NineRouterAuthToken {
    param(
        [string]$DataDirectory = "$env:APPDATA\9router"
    )

    $machineIdPath = Join-Path $DataDirectory 'machine-id'
    $cliSecretPath = Join-Path $DataDirectory 'auth\cli-secret'
    foreach ($path in @($machineIdPath, $cliSecretPath)) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Required 9Router local auth file not found: $path"
        }
    }

    $machineId = (Get-Content -Raw -LiteralPath $machineIdPath).Trim()
    $cliSecret = (Get-Content -Raw -LiteralPath $cliSecretPath).Trim()

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($machineId + '9r-cli-auth' + $cliSecret)
        $digest = -join ($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha256.Dispose()
    }

    return $digest.Substring(0, 16)
}

function Assert-NineRouterLoopback {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl
    )

    $uri = $null
    if (-not [Uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$uri)) {
        throw ('Invalid 9Router BaseUrl: {0}' -f $BaseUrl)
    }
    if (-not $uri.IsLoopback) {
        throw 'This adapter only talks to a loopback 9Router instance.'
    }
    if ($uri.Scheme -notin @('http', 'https')) {
        throw '9Router BaseUrl must use http or https.'
    }

    return $uri
}

function New-NineRouterClient {
    param(
        [string]$BaseUrl = 'http://localhost:20128',
        [string]$DataDirectory = "$env:APPDATA\9router"
    )

    $baseUri = Assert-NineRouterLoopback -BaseUrl $BaseUrl
    $token = Get-NineRouterAuthToken -DataDirectory $DataDirectory

    return [pscustomobject]@{
        BaseUri = $baseUri
        Headers = @{ 'x-9r-cli-token' = $token }
    }
}

function Invoke-NineRouterRequest {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Client,

        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'POST', 'PUT', 'DELETE')]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [AllowNull()]
        [object]$Body,

        [int]$TimeoutSec = 20
    )

    $uri = [Uri]::new($Client.BaseUri, $Path)
    $arguments = @{
        Uri = $uri
        Method = $Method
        Headers = $Client.Headers
        UseBasicParsing = $true
        TimeoutSec = $TimeoutSec
        ErrorAction = 'Stop'
    }

    if ($null -ne $Body) {
        $arguments['ContentType'] = 'application/json'
        $arguments['Body'] = $Body | ConvertTo-Json -Depth 20 -Compress
    }

    try {
        $response = Invoke-WebRequest @arguments
    }
    catch {
        $status = $null
        if ($null -ne $_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }
        throw ('9Router {0} {1} failed with status {2}.' -f $Method, $Path, $status)
    }

    if ([string]::IsNullOrWhiteSpace([string]$response.Content)) {
        return $null
    }

    return $response.Content | ConvertFrom-Json -Depth 100
}

function Get-NineRouterPools {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Client
    )

    $response = Invoke-NineRouterRequest -Client $Client -Method GET -Path '/api/proxy-pools?includeUsage=true'
    if ($null -eq $response) {
        return @()
    }

    return @($response.proxyPools)
}

function Get-NineRouterConnections {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Client
    )

    $response = Invoke-NineRouterRequest -Client $Client -Method GET -Path '/api/providers'
    if ($null -eq $response) {
        return @()
    }

    return @($response.connections)
}

function New-NineRouterPool {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Client,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ProxyUrl
    )

    $body = [ordered]@{
        name = $Name
        proxyUrl = $ProxyUrl
        noProxy = ''
        isActive = $true
        strictProxy = $true
        type = 'http'
    }

    $response = Invoke-NineRouterRequest -Client $Client -Method POST -Path '/api/proxy-pools' -Body $body
    if ($null -eq $response -or $null -eq $response.proxyPool) {
        throw '9Router did not return the created proxy pool.'
    }

    return $response.proxyPool
}

function Test-NineRouterPool {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Client,

        [Parameter(Mandatory = $true)]
        [string]$PoolId
    )

    return Invoke-NineRouterRequest -Client $Client -Method POST -Path ("/api/proxy-pools/{0}/test" -f $PoolId)
}

function Set-NineRouterPool {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Client,

        [Parameter(Mandatory = $true)]
        [string]$PoolId,

        [Parameter(Mandatory = $true)]
        [bool]$StrictProxy,

        [Parameter(Mandatory = $true)]
        [bool]$IsActive
    )

    $body = [ordered]@{
        strictProxy = $StrictProxy
        isActive = $IsActive
    }

    return Invoke-NineRouterRequest -Client $Client -Method PUT -Path ("/api/proxy-pools/{0}" -f $PoolId) -Body $body
}

function Rename-NineRouterPool {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Client,

        [Parameter(Mandatory = $true)]
        [string]$PoolId,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $body = [ordered]@{
        name = $Name
    }

    return Invoke-NineRouterRequest -Client $Client -Method PUT -Path ("/api/proxy-pools/{0}" -f $PoolId) -Body $body
}

function Set-NineRouterConnectionPool {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Client,

        [Parameter(Mandatory = $true)]
        [string]$ConnectionId,

        [AllowNull()]
        [string]$PoolId
    )

    $body = [ordered]@{
        proxyPoolId = $PoolId
    }

    return Invoke-NineRouterRequest -Client $Client -Method PUT -Path ("/api/providers/{0}" -f $ConnectionId) -Body $body
}

function Remove-NineRouterPool {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Client,

        [Parameter(Mandatory = $true)]
        [string]$PoolId
    )

    return Invoke-NineRouterRequest -Client $Client -Method DELETE -Path ("/api/proxy-pools/{0}" -f $PoolId)
}

function Get-NineRouterConnectionPoolId {
    param(
        [AllowNull()]
        [object]$Connection
    )

    if ($null -eq $Connection) {
        return $null
    }

    $specific = Get-OptionalProperty -Object $Connection -Name 'providerSpecificData'
    $poolId = Get-OptionalProperty -Object $specific -Name 'proxyPoolId'
    if ([string]::IsNullOrWhiteSpace([string]$poolId)) {
        return $null
    }

    return [string]$poolId
}

function Get-NineRouterPoolName {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Pools,

        [AllowNull()]
        [string]$PoolId
    )

    if ([string]::IsNullOrWhiteSpace($PoolId)) {
        return $null
    }

    foreach ($pool in $Pools) {
        if ([string]$pool.id -eq $PoolId) {
            return [string]$pool.name
        }
    }

    return $null
}

function ConvertTo-NineRouterUrlKey {
    param(
        [AllowNull()]
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ''
    }

    return $Url.Trim().TrimEnd('/').ToLowerInvariant()
}

function New-NineRouterBindingMap {
    param(
        [string[]]$BindConnectionId = @(),

        [AllowNull()]
        [string]$BindPoolName,

        [string[]]$BindConnectionPool = @()
    )

    $map = [ordered]@{}
    foreach ($pair in @($BindConnectionPool)) {
        if ([string]::IsNullOrWhiteSpace([string]$pair)) {
            continue
        }

        $separator = ([string]$pair).IndexOf('=')
        if ($separator -le 0 -or $separator -ge ([string]$pair).Length - 1) {
            throw ('Invalid -BindConnectionPool value. Expected <connection-id>=<pool-name>: {0}' -f $pair)
        }

        $connectionId = ([string]$pair).Substring(0, $separator).Trim()
        $poolName = ([string]$pair).Substring($separator + 1).Trim()
        if ([string]::IsNullOrWhiteSpace($connectionId) -or [string]::IsNullOrWhiteSpace($poolName)) {
            throw ('Invalid -BindConnectionPool value. Expected <connection-id>=<pool-name>: {0}' -f $pair)
        }
        if ($map.Contains($connectionId) -and [string]$map[$connectionId] -ne $poolName) {
            throw ('Connection {0} was mapped to more than one pool.' -f $connectionId)
        }
        $map[$connectionId] = $poolName
    }

    foreach ($connectionId in @($BindConnectionId)) {
        if ([string]::IsNullOrWhiteSpace([string]$connectionId)) {
            continue
        }
        if ($map.Contains([string]$connectionId) -and
            -not [string]::IsNullOrWhiteSpace($BindPoolName) -and
            [string]$map[[string]$connectionId] -ne $BindPoolName) {
            throw ('Connection {0} was mapped to more than one pool.' -f $connectionId)
        }
        if (-not $map.Contains([string]$connectionId)) {
            $map[[string]$connectionId] = $BindPoolName
        }
    }

    return $map
}

function New-NineRouterPlan {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Status,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Pools,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Connections,

        [string]$NamePrefix = 'vpncheap',

        [string[]]$BindConnectionId = @(),

        [string]$BindPoolName,

        [System.Collections.IDictionary]$BindConnectionPoolMap = @{},

        [switch]$AllowRebind
    )

    $planPools = New-Object System.Collections.Generic.List[object]
    $planBindings = New-Object System.Collections.Generic.List[object]

    $exits = Get-OptionalProperty -Object $Status -Name 'exits'
    foreach ($exit in @($exits)) {
        $state = [string](Get-OptionalProperty -Object $exit -Name 'state')
        $healthOk = [bool](Get-OptionalProperty -Object $exit -Name 'healthOk')
        if ($state -ne 'healthy' -or -not $healthOk) {
            continue
        }

        $port = [int](Get-OptionalProperty -Object $exit -Name 'port')
        if ($port -le 0) {
            continue
        }

        $nodeName = [string](Get-OptionalProperty -Object $exit -Name 'nodeName')
        if (-not [string]::IsNullOrWhiteSpace($nodeName)) {
            $name = '{0}-{1}' -f $NamePrefix, $nodeName.Trim()
        }
        else {
            $name = '{0}-{1}' -f $NamePrefix, $port
        }
        $proxyUrl = 'http://127.0.0.1:{0}' -f $port
        $urlKey = ConvertTo-NineRouterUrlKey -Url $proxyUrl

        $nameMatch = $null
        $urlMatch = $null
        $urlMatchCount = 0
        foreach ($pool in $Pools) {
            if ([string]$pool.name -eq $name) {
                $nameMatch = $pool
            }
            if ((ConvertTo-NineRouterUrlKey -Url ([string]$pool.proxyUrl)) -eq $urlKey) {
                $urlMatch = $pool
                $urlMatchCount++
            }
        }

        $action = 'create'
        $reason = $null
        $existingPoolId = $null
        $currentStrictProxy = $null
        $currentIsActive = $null
        if ($urlMatchCount -gt 1) {
            $action = 'conflict'
            $reason = 'duplicate-port'
        }
        elseif ($null -ne $urlMatch) {
            $existingPoolId = [string]$urlMatch.id
            $name = [string]$urlMatch.name
            $currentStrictProxy = [bool](Get-OptionalProperty -Object $urlMatch -Name 'strictProxy')
            $currentIsActive = [bool](Get-OptionalProperty -Object $urlMatch -Name 'isActive')
            if ($null -ne $nameMatch -and [string]$nameMatch.id -ne [string]$urlMatch.id) {
                $action = 'conflict'
                $reason = 'name-in-use'
            }
            elseif (-not $currentStrictProxy -or -not $currentIsActive) {
                $action = 'update'
            }
            else {
                $action = 'exists'
            }
        }
        elseif ($null -ne $nameMatch) {
            $action = 'conflict'
            $reason = 'name-url-mismatch'
            $existingPoolId = [string]$nameMatch.id
        }

        $planPools.Add([pscustomobject]@{
            name = $name
            port = $port
            nodeHash = [string](Get-OptionalProperty -Object $exit -Name 'nodeHash')
            action = $action
            existingPoolId = $existingPoolId
            conflictReason = $reason
            strictProxy = $true
            isActive = $true
            currentStrictProxy = $currentStrictProxy
            currentIsActive = $currentIsActive
        })
    }

    $defaultTargetPool = $null
    foreach ($item in $planPools) {
        if ($item.action -ne 'conflict') {
            $defaultTargetPool = $item
            break
        }
    }

    if ($BindConnectionPoolMap.Count -eq 0) {
        $BindConnectionPoolMap = New-NineRouterBindingMap `
            -BindConnectionId $BindConnectionId `
            -BindPoolName $BindPoolName
    }

    foreach ($bindingEntry in $BindConnectionPoolMap.GetEnumerator()) {
        $connectionId = [string]$bindingEntry.Key
        $requestedPoolName = [string]$bindingEntry.Value
        $targetPool = $defaultTargetPool
        if (-not [string]::IsNullOrWhiteSpace($requestedPoolName)) {
            $targetPool = $null
            foreach ($item in $planPools) {
                if ([string]$item.name -eq $requestedPoolName) {
                    $targetPool = $item
                    break
                }
            }
        }

        $connection = $null
        foreach ($item in $Connections) {
            if ([string]$item.id -eq [string]$connectionId) {
                $connection = $item
                break
            }
        }

        $currentPoolId = Get-NineRouterConnectionPoolId -Connection $connection
        $currentPoolName = Get-NineRouterPoolName -Pools $Pools -PoolId $currentPoolId
        $action = 'bind'
        $reason = $null

        if ($null -eq $connection) {
            $action = 'conflict'
            $reason = 'connection-missing'
        }
        elseif ($null -eq $targetPool -or $targetPool.action -eq 'conflict') {
            $action = 'conflict'
            $reason = 'target-pool-unavailable'
        }
        elseif ($null -ne $currentPoolId) {
            if ($null -ne $targetPool.existingPoolId -and $currentPoolId -eq $targetPool.existingPoolId) {
                $action = 'exists'
            }
            elseif ($AllowRebind) {
                $action = 'rebind'
            }
            else {
                $action = 'conflict'
                $reason = 'already-bound'
            }
        }

        $planBindings.Add([pscustomobject]@{
            connectionId = [string]$connectionId
            targetPoolName = if ($null -ne $targetPool) { [string]$targetPool.name } else { $null }
            currentPoolId = $currentPoolId
            currentPoolName = $currentPoolName
            action = $action
            conflictReason = $reason
        })
    }

    $brokerState = [string](Get-OptionalProperty -Object $Status -Name 'state')
    $warnings = New-Object System.Collections.Generic.List[string]
    if ($brokerState -ne 'running') {
        $warnings.Add(('Broker state is {0}, not running.' -f $brokerState))
    }
    foreach ($item in $planPools) {
        if ($item.action -eq 'conflict') {
            $warnings.Add(('Pool {0} conflicts: {1}' -f $item.name, $item.conflictReason))
        }
    }
    foreach ($item in $planBindings) {
        if ($item.action -eq 'conflict') {
            $warnings.Add(('Connection {0} conflicts: {1}' -f $item.connectionId, $item.conflictReason))
        }
    }

    return [pscustomobject]@{
        SchemaVersion = 1
        Kind = 'vpncheap-9router-plan'
        GeneratedAt = (Get-Date).ToUniversalTime().ToString('o')
        BrokerState = $brokerState
        BrokerInstanceId = [string](Get-OptionalProperty -Object $Status -Name 'instanceId')
        Pools = $planPools.ToArray()
        Bindings = $planBindings.ToArray()
        Warnings = $warnings.ToArray()
    }
}
