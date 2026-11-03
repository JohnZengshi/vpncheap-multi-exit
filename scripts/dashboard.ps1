[CmdletBinding()]
param(
    [ValidateSet('run', 'start', 'stop', 'status')]
    [string]$Action = 'start',

    [int]$Port = 39080,

    [string]$BrokerTaskName = 'vpncheap-multi-exit-broker',

    [string]$RuntimeDirectory = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptDirectory = $PSScriptRoot
$projectRoot = Split-Path -Parent $scriptDirectory
$dashboardDirectory = Join-Path $projectRoot 'dashboard'
if (-not $RuntimeDirectory) { $RuntimeDirectory = Join-Path $projectRoot 'runtime' }
$runtimeDirectory = [IO.Path]::GetFullPath($RuntimeDirectory)
$statusPath = Join-Path $runtimeDirectory 'status.json'
$supervisorPath = Join-Path $runtimeDirectory 'supervisor.json'
$ledgerPath = Join-Path $runtimeDirectory '9router-applied.json'
$exitConfigPath = Join-Path $runtimeDirectory 'exit-config.json'
$recordPath = Join-Path $runtimeDirectory 'dashboard.json'
$logPath = Join-Path $runtimeDirectory 'logs\dashboard.log'
$subscriptionStatusPath = Join-Path $runtimeDirectory 'subscription-status.json'
$script:subscriptionRefreshProcess = $null
$script:subscriptionRefreshLaunchAt = [datetime]::MinValue
$subscriptionRefreshCooldownSeconds = 10

$nineRouterCacheSeconds = 15
$taskCacheSeconds = 10
$script:nineRouterCache = $null
$script:nineRouterCacheAt = [datetime]::MinValue
$script:taskCache = $null
$script:taskCacheAt = [datetime]::MinValue
$script:poolSyncProcess = $null
$script:poolSyncLaunchAt = [datetime]::MinValue
$script:poolSyncFingerprint = ''

. "$scriptDirectory\lib\broker-common.ps1"
. "$scriptDirectory\lib\9router.ps1"
. "$scriptDirectory\lib\9router-sync.ps1"
. "$scriptDirectory\lib\dashboard-pools.ps1"
. "$scriptDirectory\lib\vpncheap-state.ps1"
. "$scriptDirectory\lib\subscription-state.ps1"
. "$scriptDirectory\lib\exit-control.ps1"

function Write-DashboardLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-RedactedLog -Path $logPath -Message $Message
}

function Start-DashboardPoolSync {
    if ($null -ne $script:poolSyncProcess -and -not $script:poolSyncProcess.HasExited) { return }
    $script:poolSyncProcess = Start-DetachedPowerShell -ScriptPath "$scriptDirectory\9router-sync.ps1" -ScriptArguments @('-RuntimeDirectory', $runtimeDirectory) -WorkingDirectory $projectRoot
    $script:poolSyncLaunchAt = Get-Date
}

function Get-DashboardSubscriptionStatus {
    $record = Read-JsonFile -Path $subscriptionStatusPath
    $result = [ordered]@{
        state = if ($null -ne $record) { [string](Get-OptionalProperty -Object $record -Name 'state') } else { 'missing' }
        updatedAt = Get-OptionalProperty -Object $record -Name 'updatedAt'
        lastSuccessAt = Get-OptionalProperty -Object $record -Name 'lastSuccessAt'
        nodeCount = Get-OptionalProperty -Object $record -Name 'nodeCount'
        errorCode = Get-OptionalProperty -Object $record -Name 'errorCode'
        errorHash = Get-OptionalProperty -Object $record -Name 'errorHash'
        nextRefreshAt = Get-OptionalProperty -Object $record -Name 'nextRefreshAt'
        cooldownUntil = if ($script:subscriptionRefreshLaunchAt -ne [datetime]::MinValue) {
            $script:subscriptionRefreshLaunchAt.AddSeconds($subscriptionRefreshCooldownSeconds).ToUniversalTime().ToString('o')
        } else { $null }
    }
    $refreshOwnerAlive = Test-ProcessAlive -ProcessId (Get-OptionalProperty -Object $record -Name 'pid')
    if ($result.state -eq 'refreshing' -and -not $refreshOwnerAlive) {
        $result.state = 'error'
        $result.errorCode = 'subscription-refresh-incomplete'
    }
    if ($null -ne $script:subscriptionRefreshProcess) {
        if (-not $script:subscriptionRefreshProcess.HasExited) {
            $result.state = 'refreshing'
            $result.errorCode = $null
            $result.errorHash = $null
        }
        else {
            # A failed child can exit before publishing its terminal status.
            $publishedAt = ConvertTo-SubscriptionTimestamp $result.updatedAt
            $hasNewStatus = $publishedAt -ne [datetimeoffset]::MinValue -and
                $publishedAt.UtcDateTime -ge $script:subscriptionRefreshLaunchAt.ToUniversalTime() -and
                $result.state -in @('updated', 'error')
            if (-not $hasNewStatus -and -not ($result.state -eq 'refreshing' -and $refreshOwnerAlive)) {
                $result.state = 'error'
                $result.errorCode = 'subscription-refresh-incomplete'
            }
        }
    }
    return $result
}

function Invoke-DashboardSubscriptionRefresh {
    $subscription = Get-DashboardSubscriptionStatus
    if ($subscription.state -eq 'refreshing') {
        return @{ code = 202; body = @{ ok = $true; launched = $false; subscription = $subscription } }
    }
    if (((Get-Date) - $script:subscriptionRefreshLaunchAt).TotalSeconds -lt $subscriptionRefreshCooldownSeconds) {
        return @{ code = 202; body = @{ ok = $true; launched = $false; subscription = $subscription } }
    }

    try {
        if ($null -ne $script:subscriptionRefreshProcess) {
            $script:subscriptionRefreshProcess.Dispose()
            $script:subscriptionRefreshProcess = $null
        }
        $script:subscriptionRefreshLaunchAt = Get-Date
        $script:subscriptionRefreshProcess = Start-DetachedPowerShell `
            -ScriptPath (Join-Path $scriptDirectory 'subscription-refresh.ps1') `
            -ScriptArguments @('-RuntimeDirectory', $runtimeDirectory, '-Force') `
            -WorkingDirectory $projectRoot
    }
    catch {
        Write-DashboardLog -Message ('subscription-refresh-launch-error type={0}' -f $_.Exception.GetType().Name)
        return @{ code = 500; body = @{ error = 'subscription-refresh-launch-failed' } }
    }
    return @{ code = 202; body = @{ ok = $true; launched = $true; subscription = (Get-DashboardSubscriptionStatus) } }
}

function Get-DashboardSnapshot {
    $warnings = New-Object System.Collections.Generic.List[string]
    $status = Read-JsonFile -Path $statusPath
    $supervisor = Read-JsonFile -Path $supervisorPath
    $ledger = Read-JsonFile -Path $ledgerPath

    $brokerState = if ($null -ne $status) { [string](Get-OptionalProperty -Object $status -Name 'state') } else { 'missing' }
    $brokerAlive = Test-ProcessAlive -ProcessId (Get-OptionalProperty -Object $status -Name 'brokerPid')
    if ($null -ne $status -and -not $brokerAlive) {
        $brokerState = 'stopped'
    }
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
                needsReview = [bool](Get-OptionalProperty -Object $_ -Name 'needsReview')
                configuredNodeName = Get-OptionalProperty $_ 'configuredNodeName'
                configuredNodeHash = Get-OptionalProperty $_ 'configuredNodeHash'
                sourceNodeHash = Get-OptionalProperty $_ 'sourceNodeHash'
                category = Get-OptionalProperty $_ 'category'
            }
        })
        if (-not [string]::IsNullOrWhiteSpace([string](Get-OptionalProperty -Object $status -Name 'refreshErrorHash'))) {
            $warnings.Add('catalog-refresh-error')
        }

        $exitRows = @($status.exits | ForEach-Object {
            $nodeHash = [string](Get-OptionalProperty -Object $_ -Name 'nodeHash')
            $workerPath = Join-Path $runtimeDirectory ('workers\{0}.json' -f $nodeHash)
            $worker = Read-JsonFile -Path $workerPath
            $workerPid = Get-OptionalProperty -Object $_ -Name 'workerPid'
            $processAlive = Test-ProcessAlive -ProcessId $workerPid
            $workerIsCurrent = $processAlive -and $null -ne $worker -and
                [string](Get-OptionalProperty -Object $worker -Name 'workerPid') -eq [string]$workerPid
            $workerHealthy = $brokerAlive -and $brokerState -eq 'running' -and $workerIsCurrent -and
                [bool](Get-OptionalProperty -Object $worker -Name 'healthOk')
            $updateState = Get-OptionalProperty -Object $_ -Name 'updateState'
            $updateErrorHash = Get-OptionalProperty -Object $_ -Name 'updateErrorHash'
            if ($workerIsCurrent) {
                $workerUpdateState = Get-OptionalProperty -Object $worker -Name 'updateState'
                if (-not [string]::IsNullOrWhiteSpace([string]$workerUpdateState)) {
                    $updateState = $workerUpdateState
                    $updateErrorHash = Get-OptionalProperty -Object $worker -Name 'updateErrorHash'
                }
            }

            [ordered]@{
                nodeName = [string](Get-OptionalProperty -Object $_ -Name 'nodeName')
                nodeHash = $nodeHash
                configuredNodeName = Get-OptionalProperty $_ 'configuredNodeName'
                configuredNodeHash = Get-OptionalProperty $_ 'configuredNodeHash'
                port = [int](Get-OptionalProperty -Object $_ -Name 'port')
                endpoint = '127.0.0.1:{0}' -f [int](Get-OptionalProperty -Object $_ -Name 'port')
                country = [string](Get-OptionalProperty -Object $_ -Name 'country')
                protocol = if ($workerIsCurrent -and (Get-OptionalProperty $worker 'protocol')) {
                    [string](Get-OptionalProperty $worker 'protocol')
                } else { [string](Get-OptionalProperty $_ 'protocol') }
                state = if (-not $brokerAlive) { 'stopped' } elseif ($workerIsCurrent) { [string](Get-OptionalProperty -Object $worker -Name 'state') } else { [string](Get-OptionalProperty -Object $_ -Name 'state') }
                processState = [string](Get-OptionalProperty -Object $_ -Name 'processState')
                processAlive = $processAlive
                needsReview = [bool](Get-OptionalProperty -Object $_ -Name 'needsReview')
                healthOk = $workerHealthy
                httpStatus = if ($workerIsCurrent) { [string](Get-OptionalProperty -Object $worker -Name 'httpStatus') } else { '' }
                latencyMs = if ($workerIsCurrent) { Get-OptionalProperty -Object $worker -Name 'latencyMs' } else { $null }
                exitIpHash = if ($workerIsCurrent) { [string](Get-OptionalProperty -Object $worker -Name 'exitIpHash') } else { '' }
                exitIpOk = if ($workerIsCurrent) { Get-OptionalProperty $worker 'exitIpOk' } else { $null }
                healthTarget = if ($workerIsCurrent) { Get-OptionalProperty $worker 'healthTarget' } else { $null }
                recoveryState = if ($workerIsCurrent) { Get-OptionalProperty $worker 'recoveryState' } else { $null }
                recoveryAttempt = if ($workerIsCurrent) { Get-OptionalProperty $worker 'recoveryAttempt' } else { $null }
                nextRecoveryAt = if ($workerIsCurrent) { Get-OptionalProperty $worker 'nextRecoveryAt' } else { $null }
                recoveryErrorHash = if ($workerIsCurrent) { Get-OptionalProperty $worker 'recoveryErrorHash' } else { $null }
                fallbackActive = $workerIsCurrent -and [bool](Get-OptionalProperty $worker 'fallbackActive')
                activeNodeHash = if ($workerIsCurrent) { Get-OptionalProperty $worker 'activeNodeHash' } else { $null }
                activeNodeName = if ($workerIsCurrent) { Get-OptionalProperty $worker 'activeNodeName' } else { $null }
                serverAddress = if ($workerIsCurrent) { Get-OptionalProperty $worker 'serverAddress' } else { $null }
                serverPort = if ($workerIsCurrent) { Get-OptionalProperty $worker 'serverPort' } else { $null }
                consecutiveFailures = if ($workerIsCurrent) { [int](Get-OptionalProperty -Object $worker -Name 'consecutiveFailures') } else { 0 }
                failureStage = if ($workerIsCurrent) { Get-OptionalProperty -Object $worker -Name 'failureStage' } else { $null }
                lastCheckAt = if ($workerIsCurrent) { Get-OptionalProperty -Object $worker -Name 'lastCheckAt' } else { $null }
                workerPid = $workerPid
                restartCount = [int](Get-OptionalProperty -Object $_ -Name 'restartCount')
                singBoxVersion = if ($workerIsCurrent) { [string](Get-OptionalProperty -Object $worker -Name 'singBoxVersion') } else { '' }
                workerStartedAt = if ($workerIsCurrent) { Get-OptionalProperty -Object $worker -Name 'startedAt' } else { $null }
                updateState = $updateState
                updateErrorHash = $updateErrorHash
            }
        })
        $healthyCount = @($exitRows | Where-Object { $_.healthOk }).Count
        if ($healthyCount -lt $selectedCount) {
            $warnings.Add('exit-degraded')
        }
    }

    foreach ($candidate in $candidateRows) {
        $owners = @($exitRows | Where-Object {
            $_.nodeHash -ne $candidate.nodeHash -and $candidate.sourceNodeHash -and
            $_.activeNodeHash -eq $candidate.sourceNodeHash
        })
        $candidate['occupiedBy'] = @($owners | ForEach-Object { $_.nodeHash })
        $candidate['disabledReason'] = if ($owners.Count) { 'node-occupied' } elseif ($candidate.needsReview -and -not $candidate.selected) { 'mapping-review' } else { $null }
    }

    foreach ($pool in $poolRows) {
        $raw = @($pools | Where-Object id -eq $pool.id)[0]
        $entries = @($ledgerPools | Where-Object poolId -eq $pool.id)
        $pool['nodeHash'] = if ($entries.Count -eq 1) { $entries[0].nodeHash } else { $null }
        $matching = @($exitRows | Where-Object { $_.nodeHash -eq $pool.nodeHash -and $_.port -eq $pool.port })
        $pool['relationState'] = if (-not $pool.managed) { 'external' } elseif ($entries.Count -ne 1) { 'conflict' }
            elseif ((ConvertTo-NineRouterUrlKey $raw.proxyUrl) -ne "http://127.0.0.1:$($entries[0].port)") { 'conflict' }
            elseif ($matching.Count -eq 1) { 'matched' } else { 'historical' }
        $pool['boundConnectionCount'] = @($connectionRows | Where-Object poolId -eq $pool.id).Count
        $pool['reason'] = if ($pool.relationState -eq 'historical' -and $pool.boundConnectionCount) { '仍有绑定，保留历史池' }
            elseif ($pool.relationState -eq 'historical') { '历史池，等待核验清理条件' }
            elseif ($pool.relationState -eq 'conflict') { '归属或地址冲突，待核对' } else { $null }
        $pool['lastTestedAt'] = Get-OptionalProperty $raw 'lastTestedAt'
    }
    foreach ($exit in $exitRows) {
        $matches = @($poolRows | Where-Object { $_.nodeHash -eq $exit.nodeHash -and $_.port -eq $exit.port -and $_.relationState -eq 'matched' })
        $exit['poolId'] = if ($matches.Count -eq 1) { $matches[0].id } else { $null }
        $exit['poolName'] = if ($matches.Count -eq 1) { $matches[0].name } else { $null }
        $exit['poolState'] = if ($matches.Count -eq 1) { 'matched' } elseif ($matches.Count -gt 1) { 'conflict' } else { 'missing' }
    }
    foreach ($connection in $connectionRows) {
        $pool = @($poolRows | Where-Object id -eq $connection.poolId)
        $exit = @($exitRows | Where-Object { $_.poolId -and $_.poolId -eq $connection.poolId })
        $connection['endpoint'] = if ($pool.Count -eq 1) { $pool[0].endpoint } else { $null }
        $connection['activeNodeName'] = if ($exit.Count -eq 1) { $exit[0].activeNodeName } else { $null }
        $connection['routeState'] = if (-not $connection.poolId) { '未绑定' } elseif ($pool.Count -ne 1) { '代理池缺失' }
            elseif ($pool[0].relationState -eq 'external') { '外部代理池' } elseif ($exit.Count -ne 1) { '未对应当前出口' } else { '关系完整' }
    }

    $poolPlan = @()
    if ($brokerAlive -and $brokerState -eq 'running' -and -not $warnings.Contains('nine-router-unavailable')) {
        $poolPlan = @(Get-DashboardPoolPlan -Status $status -Pools $pools -Connections $connections -Ledger $ledger)
    }

    $boundConnections = @($connectionRows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.poolId) })
    $unboundConnections = $connectionRows.Count - $boundConnections.Count

    return [ordered]@{
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        configuration = Get-DashboardConfigurationState -Status $status -Exits $exitRows
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
        subscription = Get-DashboardSubscriptionStatus
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

function Get-DashboardConfigurationState {
    param($Status, [object[]]$Exits)
    $config = Read-JsonFile $exitConfigPath
    $requested = [string](Get-OptionalProperty $config 'configId')
    $applied = [string](Get-OptionalProperty $Status 'appliedConfigId')
    $failure = Get-OptionalProperty $Status 'configError'
    $sync = Read-JsonFile (Join-Path $runtimeDirectory '9router-sync-status.json')
    $state = 'untracked'
    $reason = $null
    if ($requested) {
        if (-not (Test-ProcessAlive (Get-OptionalProperty $Status 'brokerPid'))) { $state = 'exit-error'; $reason = 'Broker 未运行' }
        elseif ((Get-OptionalProperty $failure 'configId') -eq $requested) { $state = 'exit-error'; $reason = Get-OptionalProperty $failure 'error' }
        elseif ($requested -ne $applied) { $state = 'adjusting' }
        elseif (@($Exits | Where-Object { $_.state -in @('failed', 'degraded', 'port-conflict', 'stopped', 'unhealthy') }).Count) { $state = 'exit-error'; $reason = '部分出口未就绪' }
        elseif (-not $Exits.Count -or @($Exits | Where-Object { -not $_.healthOk }).Count) { $state = 'adjusting' }
        elseif ((Get-OptionalProperty $sync 'configId') -ne $requested -or
            (Get-OptionalProperty $sync 'instanceId') -ne (Get-OptionalProperty $Status 'instanceId')) { $state = 'syncing' }
        elseif ($sync.state -eq 'error' -or ($sync.state -eq 'running' -and -not (Test-ProcessAlive (Get-OptionalProperty $sync 'pid')))) {
            $state = 'sync-error'; $reason = '出口已生效，代理池同步失败'
        }
        elseif (@($Exits | Where-Object { $_.poolState -ne 'matched' }).Count) { $state = 'syncing' }
        elseif ($sync.state -eq 'completed') { $state = 'completed' }
        else { $state = 'syncing' }
    }
    return @{ configId = $requested; appliedConfigId = $applied; state = $state; reason = $reason
        affected = @(Get-OptionalProperty $failure 'affected' | Where-Object { $null -ne $_ })
        sync = $sync }
}

function Get-DashboardExitIpExport {
    $status = Read-JsonFile -Path $statusPath
    if ($null -eq $status) {
        throw 'broker-status-missing'
    }

    $catalog = Read-ProtectedSubscriptionFile -Path (Join-Path $runtimeDirectory 'catalog.dpapi.json')
    $nodesByHash = @{}
    foreach ($node in @(Get-OptionalProperty -Object $catalog -Name 'nodes')) {
        if ($null -ne $node) {
            $nodesByHash[(Get-StringSha256Short -Text ([string]$node.id))] = $node
        }
    }
    $rows = @(Get-OptionalProperty -Object $status -Name 'exits' | Where-Object { $null -ne $_ } | ForEach-Object {
        $nodeHash = [string](Get-OptionalProperty -Object $_ -Name 'nodeHash')
        $snapshot = Read-ProtectedSubscriptionFile -Path (Get-ExitSnapshotPath -RuntimeDirectory $runtimeDirectory -NodeHash $nodeHash)
        # The slot snapshot records the applied server, even when a subscription changes.
        $node = Get-OptionalProperty -Object $snapshot -Name 'node'
        if ($null -eq $node -and $nodesByHash.ContainsKey($nodeHash)) {
            $node = $nodesByHash[$nodeHash]
        }

        [ordered]@{
            nodeName = if ($null -ne $node) { [string](Get-OptionalProperty $node 'name') } else { [string](Get-OptionalProperty $_ 'nodeName') }
            country = if ($null -ne $node) { [string](Get-OptionalProperty $node 'country_code') } else { [string](Get-OptionalProperty $_ 'country') }
            protocol = if ($null -ne $node) { [string](Get-OptionalProperty $node 'protocol') } else { [string](Get-OptionalProperty $_ 'protocol') }
            serverAddress = [string](Get-OptionalProperty -Object $node -Name 'address')
            serverPort = Get-OptionalProperty -Object $node -Name 'port'
        }
    })

    return [ordered]@{
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        exits = $rows
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

        if ($path -eq '/api/exit-ip-export') {
            if (-not (Test-DashboardControlRequest -Stream $stream -Method $method -Headers $headers -AllowedMethod 'GET' -RequireJson $false)) {
                return
            }
            try {
                $payload = Get-DashboardExitIpExport
            }
            catch {
                Send-DashboardJson -Stream $stream -StatusCode 409 -Value @{ error = 'broker-status-missing' }
                return
            }
            Send-DashboardJson -Stream $stream -StatusCode 200 -Value $payload
            return
        }

        if ($path -eq '/api/subscription/refresh') {
            if (-not (Test-DashboardControlRequest -Stream $stream -Method $method -Headers $headers -AllowedMethod 'POST')) {
                return
            }
            $outcome = Invoke-DashboardSubscriptionRefresh
            Send-DashboardJson -Stream $stream -StatusCode $outcome.code -Value $outcome.body
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

            $outcome = Invoke-ExitConfigChange -RuntimeDirectory $runtimeDirectory -Request $request
            Send-DashboardJson -Stream $stream -StatusCode $outcome.code -Value $outcome.body
            return
        }

        if ($path -eq '/api/nine-router/sync') {
            if ($method -eq 'GET') {
                $syncStatus = Read-JsonFile (Join-Path $runtimeDirectory '9router-sync-status.json')
                if ($null -eq $syncStatus) { $syncStatus = @{ state = 'pending' } }
                if ($syncStatus.state -ne 'running') { $script:nineRouterCache = $null }
                Send-DashboardJson -Stream $stream -StatusCode 200 -Value $syncStatus
                return
            }
            if (-not (Test-DashboardControlRequest -Stream $stream -Method $method -Headers $headers)) { return }
            Start-DashboardPoolSync
            Send-DashboardJson -Stream $stream -StatusCode 202 -Value @{
                ok = $true; state = 'running'; startedAt = $script:poolSyncLaunchAt.ToUniversalTime().ToString('o')
            }
            return
        }
        if ($path -eq '/api/nine-router/pools') {
            if (-not (Test-DashboardControlRequest -Stream $stream -Method $method -Headers $headers -AllowedMethod 'POST')) {
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
            $poolLock = $null
            try {
                try {
                    $poolLock = [IO.File]::Open((Join-Path $runtimeDirectory '9router-sync.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
                } catch {
                    Send-DashboardJson -Stream $stream -StatusCode 409 -Value @{ error = 'pool-sync-running' }
                    return
                }
                $outcome = Invoke-CreateNineRouterPools -Request $request
            }
            finally { if ($null -ne $poolLock) { $poolLock.Dispose() } }
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
            try {
                $latest = Read-JsonFile $statusPath
                $config = Read-JsonFile $exitConfigPath
                $sync = Read-JsonFile (Join-Path $runtimeDirectory '9router-sync-status.json')
                $appliedId = [string](Get-OptionalProperty $latest 'appliedConfigId')
                $needsSync = $appliedId -and $appliedId -eq (Get-OptionalProperty $config 'configId') -and
                    $appliedId -ne (Get-OptionalProperty $sync 'configId')
                $readyExits = @(Get-OptionalProperty $latest 'exits' | Where-Object { $null -ne $_ -and $_.healthOk -and $_.state -eq 'healthy' } |
                    ForEach-Object { "$($_.nodeHash):$($_.port)" } | Sort-Object) -join '|'
                $fingerprint = "$appliedId|$(Get-OptionalProperty $latest 'instanceId')|$readyExits"
                $elapsed = ((Get-Date) - $script:poolSyncLaunchAt).TotalSeconds
                $syncIdle = $null -eq $script:poolSyncProcess -or $script:poolSyncProcess.HasExited
                if ($syncIdle -and ($elapsed -ge 300 -or (($needsSync -or $fingerprint -ne $script:poolSyncFingerprint) -and $elapsed -ge 5))) {
                    try { Start-DashboardPoolSync; $script:poolSyncFingerprint = $fingerprint }
                    catch { Write-DashboardLog 'pool-sync-launch-failed' }
                }
            }
            catch { Write-DashboardLog ('pool-sync-schedule-error type={0} id={1} line={2}' -f $_.Exception.GetType().Name, $_.FullyQualifiedErrorId, $_.InvocationInfo.ScriptLineNumber) }
            if (-not $listener.Pending()) {
                Start-Sleep -Milliseconds 100
                continue
            }
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
        -ScriptArguments @('-Action', 'run', '-Port', [string]$Port, '-BrokerTaskName', $BrokerTaskName, '-RuntimeDirectory', $runtimeDirectory) `
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
