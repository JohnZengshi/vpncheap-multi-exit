[CmdletBinding()]
param(
    [ValidateSet('run', 'start', 'stop', 'status')]
    [string]$Action = 'start',

    [int]$Port = 39080,

    [string]$BrokerTaskName = 'vpncheap-multi-exit-broker'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDirectory = $PSScriptRoot
$projectRoot = Split-Path -Parent $scriptDirectory
$dashboardDirectory = Join-Path $projectRoot 'dashboard'
$runtimeDirectory = Join-Path $projectRoot 'runtime'
$statusPath = Join-Path $runtimeDirectory 'status.json'
$supervisorPath = Join-Path $runtimeDirectory 'supervisor.json'
$ledgerPath = Join-Path $runtimeDirectory '9router-applied.json'
$exitConfigPath = Join-Path $runtimeDirectory 'exit-config.json'
$recordPath = Join-Path $runtimeDirectory 'dashboard.json'
$logPath = Join-Path $runtimeDirectory 'logs\dashboard.log'

$nineRouterCacheSeconds = 15
$taskCacheSeconds = 10
$script:nineRouterCache = $null
$script:nineRouterCacheAt = [datetime]::MinValue
$script:taskCache = $null
$script:taskCacheAt = [datetime]::MinValue

. "$scriptDirectory\lib\broker-common.ps1"
. "$scriptDirectory\lib\9router.ps1"
. "$scriptDirectory\lib\dashboard-pools.ps1"

function Write-DashboardLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-RedactedLog -Path $logPath -Message $Message
}

function Get-DashboardSnapshot {
    $warnings = New-Object System.Collections.Generic.List[string]
    $status = Read-JsonFile -Path $statusPath
    $supervisor = Read-JsonFile -Path $supervisorPath
    $ledger = Read-JsonFile -Path $ledgerPath

    $brokerState = if ($null -ne $status) { [string](Get-OptionalProperty -Object $status -Name 'state') } else { 'missing' }
    if ($null -eq $status) {
        $warnings.Add('broker-status-missing')
    }
    elseif ($brokerState -ne 'running') {
        $warnings.Add('broker-not-running')
    }

    $now = Get-Date
    $task = $null
    if ($null -ne $script:taskCache -and ($now - $script:taskCacheAt).TotalSeconds -lt $taskCacheSeconds) {
        $task = $script:taskCache
    }
    else {
        try {
            $taskObject = Get-ScheduledTask -TaskName $BrokerTaskName -ErrorAction Stop
            $taskInfo = Get-ScheduledTaskInfo -TaskName $BrokerTaskName -ErrorAction Stop
            $task = [ordered]@{
                name = $BrokerTaskName
                state = [string]$taskObject.State
                lastResult = $taskInfo.LastTaskResult
                lastRunTime = if ($null -ne $taskInfo.LastRunTime) { $taskInfo.LastRunTime.ToUniversalTime().ToString('o') } else { $null }
                nextRunTime = if ($null -ne $taskInfo.NextRunTime) { $taskInfo.NextRunTime.ToUniversalTime().ToString('o') } else { $null }
            }
            $script:taskCache = $task
            $script:taskCacheAt = $now
        }
        catch {
            $warnings.Add('task-unavailable')
        }
    }
    if ($null -ne $task -and $task.state -ne 'Running') {
        $warnings.Add('task-not-running')
    }

    $pools = @()
    $connections = @()
    if ($null -ne $script:nineRouterCache -and ($now - $script:nineRouterCacheAt).TotalSeconds -lt $nineRouterCacheSeconds) {
        $pools = @($script:nineRouterCache.pools)
        $connections = @($script:nineRouterCache.connections)
    }
    else {
        try {
            $client = New-NineRouterClient
            $pools = @(Get-NineRouterPools -Client $client)
            $connections = @(Get-NineRouterConnections -Client $client)
            $script:nineRouterCache = @{
                pools = $pools
                connections = $connections
            }
            $script:nineRouterCacheAt = $now
        }
        catch {
            $warnings.Add('nine-router-unavailable')
            if ($null -ne $script:nineRouterCache) {
                $pools = @($script:nineRouterCache.pools)
                $connections = @($script:nineRouterCache.connections)
            }
        }
    }

    $managedPoolIds = New-Object 'System.Collections.Generic.HashSet[string]'
    $ledgerPools = @()
    $ledgerBindings = @()
    if ($null -ne $ledger) {
        $ledgerPools = @(Get-OptionalProperty -Object $ledger -Name 'pools' | Where-Object { $null -ne $_ })
        $ledgerBindings = @(Get-OptionalProperty -Object $ledger -Name 'bindings' | Where-Object { $null -ne $_ })
        foreach ($item in $ledgerPools) {
            $poolId = [string](Get-OptionalProperty -Object $item -Name 'poolId')
            if (-not [string]::IsNullOrWhiteSpace($poolId)) {
                $managedPoolIds.Add($poolId) | Out-Null
            }
        }
    }

    $poolRows = @($pools | ForEach-Object {
        $poolId = [string]$_.id
        $proxyPort = $null
        $proxyUrl = [string](Get-OptionalProperty -Object $_ -Name 'proxyUrl')
        try {
            $uri = [Uri]$proxyUrl
            if ($uri.IsLoopback) {
                $proxyPort = $uri.Port
            }
        }
        catch {
        }

        [ordered]@{
            id = $poolId
            name = [string]$_.name
            type = [string](Get-OptionalProperty -Object $_ -Name 'type')
            isActive = [bool](Get-OptionalProperty -Object $_ -Name 'isActive')
            strictProxy = [bool](Get-OptionalProperty -Object $_ -Name 'strictProxy')
            testStatus = [string](Get-OptionalProperty -Object $_ -Name 'testStatus')
            boundConnectionCount = [int](Get-OptionalProperty -Object $_ -Name 'boundConnectionCount')
            port = $proxyPort
            endpoint = if ($null -ne $proxyPort) { '127.0.0.1:{0}' -f $proxyPort } else { 'LAN' }
            managed = $managedPoolIds.Contains($poolId)
        }
    })

    $connectionRows = @($connections | ForEach-Object {
        $poolId = Get-NineRouterConnectionPoolId -Connection $_
        [ordered]@{
            id = [string]$_.id
            provider = [string](Get-OptionalProperty -Object $_ -Name 'provider')
            isActive = [bool](Get-OptionalProperty -Object $_ -Name 'isActive')
            priority = [int](Get-OptionalProperty -Object $_ -Name 'priority')
            poolId = $poolId
            poolName = Get-NineRouterPoolName -Pools $pools -PoolId $poolId
        }
    })

    $exitRows = @()
    $selectedCount = 0
    $healthyCount = 0
    $candidateCount = 0
    $candidateRows = @()
    $selectionMode = 'auto'
    $configuredMaxExits = $null
    if ($null -ne $status) {
        $selectedCount = [int](Get-OptionalProperty -Object $status -Name 'selectedCount')
        $healthyCount = [int](Get-OptionalProperty -Object $status -Name 'healthyCount')
        $candidateCount = [int](Get-OptionalProperty -Object $status -Name 'candidateCount')
        $selectionMode = [string](Get-OptionalProperty -Object $status -Name 'selectionMode')
        if ([string]::IsNullOrWhiteSpace($selectionMode)) {
            $selectionMode = 'auto'
        }
        $configuredMaxExits = Get-OptionalProperty -Object $status -Name 'configuredMaxExits'
        $candidateRows = @(Get-OptionalProperty -Object $status -Name 'candidates' | Where-Object { $null -ne $_ } | ForEach-Object {
            [ordered]@{
                nodeHash = [string](Get-OptionalProperty -Object $_ -Name 'nodeHash')
                nodeName = [string](Get-OptionalProperty -Object $_ -Name 'nodeName')
                protocol = [string](Get-OptionalProperty -Object $_ -Name 'protocol')
                country = [string](Get-OptionalProperty -Object $_ -Name 'country')
                selected = [bool](Get-OptionalProperty -Object $_ -Name 'selected')
            }
        })
        if ($healthyCount -lt $selectedCount) {
            $warnings.Add('exit-degraded')
        }
        if (-not [string]::IsNullOrWhiteSpace([string](Get-OptionalProperty -Object $status -Name 'refreshErrorHash'))) {
            $warnings.Add('catalog-refresh-error')
        }

        $exitRows = @($status.exits | ForEach-Object {
            $nodeHash = [string](Get-OptionalProperty -Object $_ -Name 'nodeHash')
            $workerPath = Join-Path $runtimeDirectory ('workers\{0}.json' -f $nodeHash)
            $worker = Read-JsonFile -Path $workerPath
            $workerPid = Get-OptionalProperty -Object $_ -Name 'workerPid'
            $processAlive = Test-ProcessAlive -ProcessId $workerPid

            [ordered]@{
                nodeName = [string](Get-OptionalProperty -Object $_ -Name 'nodeName')
                nodeHash = $nodeHash
                port = [int](Get-OptionalProperty -Object $_ -Name 'port')
                endpoint = '127.0.0.1:{0}' -f [int](Get-OptionalProperty -Object $_ -Name 'port')
                country = [string](Get-OptionalProperty -Object $_ -Name 'country')
                protocol = [string](Get-OptionalProperty -Object $_ -Name 'protocol')
                state = [string](Get-OptionalProperty -Object $_ -Name 'state')
                processState = [string](Get-OptionalProperty -Object $_ -Name 'processState')
                processAlive = $processAlive
                healthOk = [bool](Get-OptionalProperty -Object $_ -Name 'healthOk')
                httpStatus = [string](Get-OptionalProperty -Object $_ -Name 'httpStatus')
                latencyMs = Get-OptionalProperty -Object $_ -Name 'latencyMs'
                exitIpHash = [string](Get-OptionalProperty -Object $_ -Name 'exitIpHash')
                consecutiveFailures = [int](Get-OptionalProperty -Object $_ -Name 'consecutiveFailures')
                failureStage = Get-OptionalProperty -Object $_ -Name 'failureStage'
                lastCheckAt = Get-OptionalProperty -Object $_ -Name 'lastCheckAt'
                workerPid = $workerPid
                restartCount = [int](Get-OptionalProperty -Object $_ -Name 'restartCount')
                singBoxVersion = [string](Get-OptionalProperty -Object $worker -Name 'singBoxVersion')
                workerStartedAt = Get-OptionalProperty -Object $worker -Name 'startedAt'
            }
        })
    }

    $poolPlan = @()
    if (-not $warnings.Contains('nine-router-unavailable')) {
        $poolPlan = @(Get-DashboardPoolPlan -Status $status -Pools $pools -Connections $connections)
    }

    $boundConnections = @($connectionRows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.poolId) })
    $unboundConnections = $connectionRows.Count - $boundConnections.Count

    return [ordered]@{
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        broker = [ordered]@{
            state = $brokerState
            pid = Get-OptionalProperty -Object $status -Name 'brokerPid'
            instanceId = [string](Get-OptionalProperty -Object $status -Name 'instanceId')
            startedAt = Get-OptionalProperty -Object $status -Name 'startedAt'
            updatedAt = Get-OptionalProperty -Object $status -Name 'updatedAt'
            portBase = Get-OptionalProperty -Object $status -Name 'portBase'
            maxExits = Get-OptionalProperty -Object $status -Name 'maxExits'
            configuredMaxExits = $configuredMaxExits
            selectionMode = $selectionMode
            protocol = [string](Get-OptionalProperty -Object $status -Name 'protocol')
            country = [string](Get-OptionalProperty -Object $status -Name 'country')
            candidateCount = $candidateCount
            selectedCount = $selectedCount
            healthyCount = $healthyCount
            refreshErrorHash = [string](Get-OptionalProperty -Object $status -Name 'refreshErrorHash')
        }
        supervisor = [ordered]@{
            pid = Get-OptionalProperty -Object $supervisor -Name 'pid'
            instanceId = [string](Get-OptionalProperty -Object $supervisor -Name 'instanceId')
            startedAt = Get-OptionalProperty -Object $supervisor -Name 'startedAt'
        }
        task = $task
        exits = $exitRows
        candidates = $candidateRows
        pools = $poolRows
        connections = $connectionRows
        poolPlan = $poolPlan
        routing = [ordered]@{
            bound = $boundConnections.Count
            unbound = $unboundConnections
            total = $connectionRows.Count
        }
        ledger = [ordered]@{
            updatedAt = Get-OptionalProperty -Object $ledger -Name 'updatedAt'
            poolCount = $ledgerPools.Count
            bindingCount = $ledgerBindings.Count
        }
        warnings = $warnings.ToArray()
    }
}

function Send-DashboardResponse {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.Sockets.NetworkStream]$Stream,

        [Parameter(Mandatory = $true)]
        [int]$StatusCode,

        [Parameter(Mandatory = $true)]
        [string]$ContentType,

        [AllowEmptyCollection()]
        [byte[]]$Body = @(),

        [bool]$IncludeBody = $true
    )

    $reasons = @{
        200 = 'OK'
        202 = 'Accepted'
        204 = 'No Content'
        400 = 'Bad Request'
        403 = 'Forbidden'
        404 = 'Not Found'
        405 = 'Method Not Allowed'
        409 = 'Conflict'
        413 = 'Payload Too Large'
        500 = 'Internal Server Error'
        502 = 'Bad Gateway'
    }
    $reason = if ($reasons.ContainsKey($StatusCode)) { $reasons[$StatusCode] } else { 'Unknown' }
    $header = "HTTP/1.1 $StatusCode $reason`r`n" +
        "Content-Type: $ContentType`r`n" +
        "Content-Length: $($Body.Length)`r`n" +
        "Connection: close`r`n" +
        "Cache-Control: no-store`r`n" +
        "X-Content-Type-Options: nosniff`r`n" +
        "X-Frame-Options: DENY`r`n" +
        "Referrer-Policy: no-referrer`r`n" +
        "Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'`r`n`r`n"
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($IncludeBody -and $Body.Length -gt 0) {
        $Stream.Write($Body, 0, $Body.Length)
    }
}

function Get-ContentType {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.html' { return 'text/html; charset=utf-8' }
        '.css' { return 'text/css; charset=utf-8' }
        '.js' { return 'text/javascript; charset=utf-8' }
        '.json' { return 'application/json; charset=utf-8' }
        '.svg' { return 'image/svg+xml' }
        '.png' { return 'image/png' }
        '.ico' { return 'image/x-icon' }
        default { return 'application/octet-stream' }
    }
}

function Invoke-DashboardRequest {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.Sockets.TcpClient]$Client
    )

    $stream = $Client.GetStream()
    $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::ASCII, $false, 1024, $true)
    try {
        $requestLine = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($requestLine)) {
            return
        }

        $headers = @{}
        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line -or $line.Length -eq 0) {
                break
            }
            $separator = $line.IndexOf(':')
            if ($separator -gt 0) {
                $name = $line.Substring(0, $separator).Trim().ToLowerInvariant()
                $headers[$name] = $line.Substring($separator + 1).Trim()
            }
        }

        $parts = $requestLine.Split(' ')
        if ($parts.Length -lt 2) {
            Send-DashboardResponse -Stream $stream -StatusCode 400 -ContentType 'text/plain; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes('Bad request'))
            return
        }

        $method = $parts[0].ToUpperInvariant()
        if ($method -notin @('GET', 'HEAD', 'POST')) {
            Send-DashboardResponse -Stream $stream -StatusCode 405 -ContentType 'text/plain; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes('Method not allowed'))
            return
        }

        $contentLength = 0
        if ($headers.ContainsKey('content-length')) {
            if (-not [int]::TryParse([string]$headers['content-length'], [ref]$contentLength) -or $contentLength -lt 0) {
                Send-DashboardResponse -Stream $stream -StatusCode 400 -ContentType 'text/plain; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes('Invalid content length'))
                return
            }
        }
        if ($contentLength -gt 16384) {
            Send-DashboardResponse -Stream $stream -StatusCode 413 -ContentType 'text/plain; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes('Payload too large'))
            return
        }

        $requestBody = ''
        if ($contentLength -gt 0) {
            $buffer = New-Object char[] $contentLength
            $read = 0
            while ($read -lt $contentLength) {
                $count = $reader.Read($buffer, $read, $contentLength - $read)
                if ($count -le 0) {
                    break
                }
                $read += $count
            }
            $requestBody = [string]::new($buffer, 0, $read)
        }

        $requestTarget = $parts[1]
        $path = $requestTarget.Split('?')[0]
        try {
            $path = [Uri]::UnescapeDataString($path)
        }
        catch {
        }

        if ($path -eq '/api/health') {
            $payload = [ordered]@{
                ok = $true
                pid = $PID
                port = $Port
                startedAt = $script:serverStartedAt.ToUniversalTime().ToString('o')
                uptimeSeconds = [int]((Get-Date) - $script:serverStartedAt).TotalSeconds
            } | ConvertTo-Json -Depth 10 -Compress
            Send-DashboardResponse -Stream $stream -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) -IncludeBody ($method -eq 'GET')
            return
        }

        if ($path -eq '/api/snapshot') {
            if ($method -eq 'POST') {
                Send-DashboardResponse -Stream $stream -StatusCode 405 -ContentType 'text/plain; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes('Method not allowed'))
                return
            }
            $snapshot = Get-DashboardSnapshot
            $payload = $snapshot | ConvertTo-Json -Depth 20 -Compress
            Send-DashboardResponse -Stream $stream -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) -IncludeBody ($method -eq 'GET')
            return
        }

        if ($path -eq '/api/exit-config') {
            if ($method -ne 'POST') {
                Send-DashboardResponse -Stream $stream -StatusCode 405 -ContentType 'text/plain; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes('Method not allowed'))
                return
            }

            $origin = ''
            if ($headers.ContainsKey('origin')) {
                $origin = [string]$headers['origin']
            }
            $allowedOrigins = @(
                'http://127.0.0.1:{0}' -f $Port,
                'http://localhost:{0}' -f $Port,
                'http://[::1]:{0}' -f $Port
            )
            if (-not [string]::IsNullOrWhiteSpace($origin) -and $origin -notin $allowedOrigins) {
                Send-DashboardResponse -Stream $stream -StatusCode 403 -ContentType 'text/plain; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes('Forbidden origin'))
                return
            }

            $controlHeader = ''
            if ($headers.ContainsKey('x-exit-control')) {
                $controlHeader = [string]$headers['x-exit-control']
            }
            $contentType = ''
            if ($headers.ContainsKey('content-type')) {
                $contentType = [string]$headers['content-type']
            }
            if ($controlHeader -ne '1' -or -not $contentType.StartsWith('application/json', [System.StringComparison]::OrdinalIgnoreCase)) {
                Send-DashboardResponse -Stream $stream -StatusCode 403 -ContentType 'text/plain; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes('Write request rejected'))
                return
            }

            try {
                $request = $requestBody | ConvertFrom-Json -Depth 10 -ErrorAction Stop
            }
            catch {
                Send-DashboardResponse -Stream $stream -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes('{"error":"invalid-json"}'))
                return
            }

            $status = Read-JsonFile -Path $statusPath
            if ($null -eq $status) {
                Send-DashboardResponse -Stream $stream -StatusCode 409 -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes('{"error":"broker-status-missing"}'))
                return
            }

            $knownHashes = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($candidate in @(Get-OptionalProperty -Object $status -Name 'candidates')) {
                $knownHashes.Add([string](Get-OptionalProperty -Object $candidate -Name 'nodeHash')) | Out-Null
            }
            if ($knownHashes.Count -eq 0) {
                Send-DashboardResponse -Stream $stream -StatusCode 409 -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes('{"error":"candidate-list-unavailable"}'))
                return
            }

            $maxExitsValue = Get-OptionalProperty -Object $request -Name 'maxExits'
            if ($null -eq $maxExitsValue) {
                $maxExitsValue = Get-OptionalProperty -Object $status -Name 'maxExits'
            }
            $maxExits = 0
            if ($null -eq $maxExitsValue -or -not [int]::TryParse([string]$maxExitsValue, [ref]$maxExits) -or $maxExits -lt 1 -or $maxExits -gt 64) {
                Send-DashboardResponse -Stream $stream -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes('{"error":"invalid-max-exits"}'))
                return
            }

            $nodeHashes = New-Object System.Collections.Generic.List[string]
            $seenHashes = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($item in @(Get-OptionalProperty -Object $request -Name 'nodeHashes')) {
                $hash = ([string]$item).Trim().ToLowerInvariant()
                if ([string]::IsNullOrWhiteSpace($hash)) {
                    continue
                }
                if ($hash -notmatch '^[0-9a-f]{8,64}$' -or -not $knownHashes.Contains($hash)) {
                    Send-DashboardResponse -Stream $stream -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes('{"error":"unknown-node"}'))
                    return
                }
                if ($seenHashes.Add($hash)) {
                    $nodeHashes.Add($hash) | Out-Null
                }
            }
            if ($nodeHashes.Count -gt $maxExits) {
                Send-DashboardResponse -Stream $stream -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes('{"error":"selection-exceeds-max"}'))
                return
            }

            $selectionMode = if ($nodeHashes.Count -gt 0) { 'manual' } else { 'auto' }
            Write-JsonFileAtomic -Path $exitConfigPath -Value ([ordered]@{
                schemaVersion = 1
                maxExits = $maxExits
                selectionMode = $selectionMode
                nodeHashes = @($nodeHashes)
                updatedAt = (Get-Date).ToUniversalTime().ToString('o')
            })
            Write-DashboardLog -Message ('exit-config mode={0} max={1} selected={2}' -f $selectionMode, $maxExits, $nodeHashes.Count)

            $payload = [ordered]@{
                ok = $true
                maxExits = $maxExits
                selectionMode = $selectionMode
                nodeHashes = @($nodeHashes)
            } | ConvertTo-Json -Depth 10 -Compress
            Send-DashboardResponse -Stream $stream -StatusCode 202 -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($payload))
            return
        }

        if ($path -eq '/api/nine-router/pools') {
            if (-not (Test-DashboardWriteRequest -Stream $stream -Method $method -Headers $headers)) {
                return
            }
            try {
                $request = $requestBody | ConvertFrom-Json -Depth 10 -ErrorAction Stop
            }
            catch {
                Send-DashboardJson -Stream $stream -StatusCode 400 -Value @{ error = 'invalid-json' }
                return
            }
            if ($null -eq $request) {
                Send-DashboardJson -Stream $stream -StatusCode 400 -Value @{ error = 'invalid-json' }
                return
            }
            $outcome = Invoke-CreateNineRouterPools -Request $request
            Send-DashboardJson -Stream $stream -StatusCode $outcome.code -Value $outcome.body
            return
        }
        if ($method -eq 'POST') {
            Send-DashboardResponse -Stream $stream -StatusCode 405 -ContentType 'text/plain; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes('Method not allowed'))
            return
        }

        if ($path -eq '/') {
            $path = '/index.html'
        }

        $relativePath = $path.TrimStart('/').Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $dashboardDirectory $relativePath))
        $expectedPrefix = $dashboardDirectory.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        if (-not $fullPath.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            Send-DashboardResponse -Stream $stream -StatusCode 403 -ContentType 'text/plain; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes('Forbidden'))
            return
        }

        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            Send-DashboardResponse -Stream $stream -StatusCode 404 -ContentType 'text/plain; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes('Not found'))
            return
        }

        $body = [System.IO.File]::ReadAllBytes($fullPath)
        Send-DashboardResponse -Stream $stream -StatusCode 200 -ContentType (Get-ContentType -Path $fullPath) -Body $body -IncludeBody ($method -eq 'GET')
    }
    finally {
        $reader.Dispose()
    }
}

function Invoke-DashboardServer {
    if (-not (Test-Path -LiteralPath $dashboardDirectory)) {
        throw "Dashboard asset directory not found: $dashboardDirectory"
    }

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    $script:serverStartedAt = Get-Date
    $record = [ordered]@{
        schemaVersion = 1
        pid = $PID
        port = $Port
        url = 'http://127.0.0.1:{0}/' -f $Port
        startedAt = $script:serverStartedAt.ToUniversalTime().ToString('o')
    }
    Write-JsonFileAtomic -Path $recordPath -Value $record
    Write-DashboardLog -Message ('dashboard-start pid={0} port={1}' -f $PID, $Port)

    try {
        while ($true) {
            $client = $listener.AcceptTcpClient()
            try {
                $client.ReceiveTimeout = 5000
                $client.SendTimeout = 5000
                Invoke-DashboardRequest -Client $client
            }
            catch {
                Write-DashboardLog -Message ('request-error type={0}' -f $_.Exception.GetType().Name)
            }
            finally {
                $client.Dispose()
            }
        }
    }
    finally {
        $listener.Stop()
        $current = Read-JsonFile -Path $recordPath
        if ($null -ne $current -and [int](Get-OptionalProperty -Object $current -Name 'pid') -eq $PID) {
            Remove-Item -LiteralPath $recordPath -Force -ErrorAction SilentlyContinue
        }
        Write-DashboardLog -Message ('dashboard-stop pid={0}' -f $PID)
    }
}

function Start-Dashboard {
    $record = Read-JsonFile -Path $recordPath
    if ($null -ne $record -and (Test-ProcessAlive -ProcessId (Get-OptionalProperty -Object $record -Name 'pid'))) {
        Write-Output ('Dashboard already running at {0}' -f (Get-OptionalProperty -Object $record -Name 'url'))
        return
    }

    $process = Start-DetachedPowerShell `
        -ScriptPath $PSCommandPath `
        -ScriptArguments @('-Action', 'run', '-Port', [string]$Port, '-BrokerTaskName', $BrokerTaskName) `
        -WorkingDirectory $projectRoot
    $healthUrl = 'http://127.0.0.1:{0}/api/health' -f $Port
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) {
            throw ('Dashboard process exited during startup with code {0}. Check {1}' -f $process.ExitCode, $logPath)
        }
        try {
            $response = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                Write-Output ('Dashboard started: http://127.0.0.1:{0}/' -f $Port)
                return
            }
        }
        catch {
        }
        Start-Sleep -Milliseconds 300
    }

    throw ('Dashboard did not become healthy within 15 seconds. Check {0}' -f $logPath)
}

function Stop-Dashboard {
    $record = Read-JsonFile -Path $recordPath
    if ($null -eq $record) {
        Write-Output 'Dashboard is not running.'
        return
    }

    $dashboardPid = [int](Get-OptionalProperty -Object $record -Name 'pid')
    if (Test-ProcessAlive -ProcessId $dashboardPid) {
        Stop-Process -Id $dashboardPid -Force
        $deadline = (Get-Date).AddSeconds(5)
        while ((Get-Date) -lt $deadline -and (Test-ProcessAlive -ProcessId $dashboardPid)) {
            Start-Sleep -Milliseconds 200
        }
        Write-Output ('Dashboard stopped. pid={0}' -f $dashboardPid)
    }
    else {
        Write-Output 'Dashboard process was not running.'
    }

    if (Test-Path -LiteralPath $recordPath) {
        Remove-Item -LiteralPath $recordPath -Force
    }
}

function Show-DashboardStatus {
    $record = Read-JsonFile -Path $recordPath
    if ($null -eq $record) {
        Write-Output 'Dashboard is not running.'
        return
    }

    $dashboardPid = [int](Get-OptionalProperty -Object $record -Name 'pid')
    $alive = Test-ProcessAlive -ProcessId $dashboardPid
    $url = [string](Get-OptionalProperty -Object $record -Name 'url')
    Write-Output ('dashboard alive={0} pid={1} url={2}' -f $alive, $dashboardPid, $url)
    if ($alive) {
        try {
            $health = Invoke-WebRequest -Uri ('{0}api/health' -f $url) -UseBasicParsing -TimeoutSec 20
            Write-Output ('health={0}' -f $health.StatusCode)
        }
        catch {
            Write-Output 'health=unavailable'
        }
    }
}

switch ($Action) {
    'run' { Invoke-DashboardServer }
    'start' { Start-Dashboard }
    'stop' { Stop-Dashboard }
    'status' { Show-DashboardStatus }
}
