[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://localhost:20128',

    [string]$DataDirectory = "$env:APPDATA\9router",

    [string]$RuntimeDirectory,

    [string]$StatusPath,

    [string]$LedgerPath,

    [string]$NamePrefix = 'vpncheap',

    [string[]]$BindConnectionId = @(),

    [string]$BindPoolName,

    [string[]]$BindConnectionPool = @(),

    [switch]$AllowRebind,

    [switch]$Apply,

    [switch]$SkipTest,

    [switch]$TestExisting,

    [ValidateRange(1, 5)]
    [int]$TestAttempts = 2
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot\lib\broker-common.ps1"
. "$PSScriptRoot\lib\9router.ps1"

if ([string]::IsNullOrWhiteSpace($RuntimeDirectory)) {
    $RuntimeDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime'
}
$RuntimeDirectory = [System.IO.Path]::GetFullPath($RuntimeDirectory)

if ([string]::IsNullOrWhiteSpace($StatusPath)) {
    $StatusPath = Join-Path $RuntimeDirectory 'status.json'
}
if ([string]::IsNullOrWhiteSpace($LedgerPath)) {
    $LedgerPath = Join-Path $RuntimeDirectory '9router-applied.json'
}

$status = Read-JsonFile -Path $StatusPath
if ($null -eq $status) {
    throw ('Broker status not found: {0}. Start the broker first.' -f $StatusPath)
}

$client = New-NineRouterClient -BaseUrl $BaseUrl -DataDirectory $DataDirectory
$pools = Get-NineRouterPools -Client $client
$connections = Get-NineRouterConnections -Client $client
$bindingMap = New-NineRouterBindingMap `
    -BindConnectionId $BindConnectionId `
    -BindPoolName $BindPoolName `
    -BindConnectionPool $BindConnectionPool

$plan = New-NineRouterPlan `
    -Status $status `
    -Pools $pools `
    -Connections $connections `
    -NamePrefix $NamePrefix `
    -BindConnectionId $BindConnectionId `
    -BindPoolName $BindPoolName `
    -BindConnectionPoolMap $bindingMap `
    -AllowRebind:$AllowRebind

$planPath = Join-Path $RuntimeDirectory 'pool-plan.json'
Write-JsonFileAtomic -Path $planPath -Value ([ordered]@{
    schemaVersion = $plan.SchemaVersion
    kind = $plan.Kind
    generatedAt = $plan.GeneratedAt
    baseUrl = $BaseUrl
    brokerState = $plan.BrokerState
    brokerInstanceId = $plan.BrokerInstanceId
    pools = $plan.Pools
    bindings = $plan.Bindings
    warnings = $plan.Warnings
})

Write-Output ('Broker state: {0} instance={1}' -f $plan.BrokerState, $plan.BrokerInstanceId)
$plan.Pools | Format-Table @{ Label = 'Pool'; Expression = { $_.name } },
    @{ Label = 'Port'; Expression = { $_.port } },
    @{ Label = 'Action'; Expression = { $_.action } },
    @{ Label = 'Strict'; Expression = { $_.currentStrictProxy } },
    @{ Label = 'Reason'; Expression = { $_.conflictReason } } -AutoSize | Out-String -Width 200 | Write-Output

if ($plan.Bindings.Count -gt 0) {
    $plan.Bindings | Format-Table @{ Label = 'Connection'; Expression = { $_.connectionId } },
        @{ Label = 'TargetPool'; Expression = { $_.targetPoolName } },
        @{ Label = 'CurrentPool'; Expression = { $_.currentPoolName } },
        @{ Label = 'Action'; Expression = { $_.action } },
        @{ Label = 'Reason'; Expression = { $_.conflictReason } } -AutoSize | Out-String -Width 240 | Write-Output
}

foreach ($item in $plan.Warnings) {
    Write-Output ('WARN: {0}' -f $item)
}

$conflicts = New-Object System.Collections.Generic.List[string]
foreach ($item in $plan.Pools) {
    if ($item.action -eq 'conflict') {
        $conflicts.Add(('pool {0}: {1}' -f $item.name, $item.conflictReason))
    }
}
foreach ($item in $plan.Bindings) {
    if ($item.action -eq 'conflict') {
        $conflicts.Add(('connection {0}: {1}' -f $item.connectionId, $item.conflictReason))
    }
}

if ($conflicts.Count -gt 0) {
    Write-Output ''
    Write-Output 'Refusing to apply because the plan contains conflicts.'
    foreach ($item in $conflicts) {
        Write-Output ('  {0}' -f $item)
    }
    exit 2
}

if ($plan.BrokerState -ne 'running') {
    Write-Output ''
    Write-Output ('Refusing to apply because broker state is {0}.' -f $plan.BrokerState)
    exit 2
}

$pendingCreates = 0
$pendingUpdates = 0
foreach ($item in $plan.Pools) {
    if ($item.action -eq 'create') {
        $pendingCreates++
    }
    elseif ($item.action -eq 'update') {
        $pendingUpdates++
    }
}

if (-not $Apply) {
    Write-Output ''
    Write-Output ('Dry run only. Pools to create: {0}; pools to update: {1}. Re-run with -Apply to change 9Router.' -f $pendingCreates, $pendingUpdates)
    exit 0
}

$ledger = Read-JsonFile -Path $LedgerPath
if ($null -eq $ledger) {
    $ledger = [pscustomobject]@{
        schemaVersion = 1
        kind = 'vpncheap-9router-ledger'
        updatedAt = $null
        pools = @()
        poolUpdates = @()
        bindings = @()
    }
}

$ledgerPools = New-Object System.Collections.Generic.List[object]
foreach ($item in @($ledger.pools)) {
    if ($null -ne $item) {
        $ledgerPools.Add($item)
    }
}
$ledgerBindings = New-Object System.Collections.Generic.List[object]
foreach ($item in @($ledger.bindings)) {
    if ($null -ne $item) {
        $ledgerBindings.Add($item)
    }
}
$ledgerPoolUpdates = New-Object System.Collections.Generic.List[object]
foreach ($item in @(Get-OptionalProperty -Object $ledger -Name 'poolUpdates')) {
    if ($null -ne $item) {
        $ledgerPoolUpdates.Add($item)
    }
}

foreach ($item in $plan.Pools) {
    if ($item.action -notin @('create', 'update')) {
        continue
    }

    try {
        if ($item.action -eq 'create') {
            $pool = New-NineRouterPool -Client $client -Name $item.name -ProxyUrl ('http://127.0.0.1:{0}' -f $item.port)
            Write-Output ('created pool={0} port={1} id={2}' -f $item.name, $item.port, $pool.id)

            $ledgerPools.Add([ordered]@{
                name = $item.name
                poolId = [string]$pool.id
                port = $item.port
                nodeHash = $item.nodeHash
                createdAt = (Get-Date).ToUniversalTime().ToString('o')
            })
        }
        else {
            Set-NineRouterPool `
                -Client $client `
                -PoolId ([string]$item.existingPoolId) `
                -StrictProxy $true `
                -IsActive $true | Out-Null
            Write-Output ('updated pool={0} port={1} strictProxy=true isActive=true' -f $item.name, $item.port)

            $ledgerPoolUpdates.Add([ordered]@{
                name = $item.name
                poolId = [string]$item.existingPoolId
                port = $item.port
                nodeHash = $item.nodeHash
                previousStrictProxy = [bool]$item.currentStrictProxy
                previousIsActive = [bool]$item.currentIsActive
                updatedAt = (Get-Date).ToUniversalTime().ToString('o')
            })
        }
    }
    catch {
        Write-Output ('failed pool={0} port={1}: {2}' -f $item.name, $item.port, $_.Exception.Message)
        throw
    }
}

$livePools = Get-NineRouterPools -Client $client
$poolIdByName = @{}
foreach ($pool in $livePools) {
    $poolIdByName[[string]$pool.name] = [string]$pool.id
}
foreach ($item in $ledgerPools) {
    if (-not $poolIdByName.ContainsKey([string]$item.name)) {
        $poolIdByName[[string]$item.name] = [string]$item.poolId
    }
}

$testFailures = New-Object System.Collections.Generic.List[string]
if (-not $SkipTest) {
    foreach ($item in $plan.Pools) {
        if ($item.action -in @('create', 'update') -or ($TestExisting -and $item.action -eq 'exists')) {
            $poolId = $poolIdByName[$item.name]
            $testStatus = $null
            for ($attempt = 1; $attempt -le $TestAttempts; $attempt++) {
                try {
                    $result = Test-NineRouterPool -Client $client -PoolId $poolId
                    $testStatus = Get-OptionalProperty -Object $result -Name 'status'
                    if ([string]::IsNullOrWhiteSpace([string]$testStatus)) {
                        $testStatus = Get-OptionalProperty -Object $result -Name 'testStatus'
                    }
                    if ([string]::IsNullOrWhiteSpace([string]$testStatus)) {
                        $testStatus = Get-OptionalProperty -Object (Get-OptionalProperty -Object $result -Name 'proxyPool') -Name 'testStatus'
                    }
                    if ([string]$testStatus -eq 'active') {
                        break
                    }
                }
                catch {
                    $testStatus = 'request-error'
                }

                if ($attempt -lt $TestAttempts) {
                    Start-Sleep -Seconds 2
                }
            }

            $livePool = $null
            foreach ($candidate in @(Get-NineRouterPools -Client $client)) {
                if ([string]$candidate.id -eq [string]$poolId) {
                    $livePool = $candidate
                    break
                }
            }

            $persistedStatus = [string](Get-OptionalProperty -Object $livePool -Name 'testStatus')
            $persistedActive = [bool](Get-OptionalProperty -Object $livePool -Name 'isActive')
            Write-Output ('tested pool={0} status={1} active={2}' -f $item.name, $persistedStatus, $persistedActive)
            if ($persistedStatus -ne 'active' -or -not $persistedActive) {
                $testFailures.Add([string]$item.name)
            }
        }
    }
}

foreach ($item in $plan.Bindings) {
    if ($item.action -notin @('bind', 'rebind')) {
        continue
    }

    if ($testFailures -contains [string]$item.targetPoolName) {
        Write-Output ('skip binding connection={0}: target pool failed its test' -f $item.connectionId)
        continue
    }

    if (-not $poolIdByName.ContainsKey([string]$item.targetPoolName)) {
        Write-Output ('skip binding connection={0}: target pool id unknown' -f $item.connectionId)
        continue
    }

    $targetPoolId = [string]$poolIdByName[[string]$item.targetPoolName]
    $liveConnections = Get-NineRouterConnections -Client $client
    $liveConnection = $null
    foreach ($connection in $liveConnections) {
        if ([string]$connection.id -eq [string]$item.connectionId) {
            $liveConnection = $connection
            break
        }
    }

    $previousPoolId = Get-NineRouterConnectionPoolId -Connection $liveConnection
    Set-NineRouterConnectionPool -Client $client -ConnectionId $item.connectionId -PoolId $targetPoolId | Out-Null

    $ledgerBindings.Add([ordered]@{
        connectionId = [string]$item.connectionId
        poolId = $targetPoolId
        poolName = [string]$item.targetPoolName
        previousPoolId = $previousPoolId
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    })

    Write-Output ('bound connection={0} pool={1}' -f $item.connectionId, $item.targetPoolName)
}

Write-JsonFileAtomic -Path $LedgerPath -Value ([ordered]@{
    schemaVersion = 1
    kind = 'vpncheap-9router-ledger'
    updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    pools = $ledgerPools.ToArray()
    poolUpdates = $ledgerPoolUpdates.ToArray()
    bindings = $ledgerBindings.ToArray()
})

$finalPools = Get-NineRouterPools -Client $client
$managedNames = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($item in $ledgerPools) {
    $managedNames.Add([string]$item.name) | Out-Null
}

Write-Output ''
Write-Output ('Managed pools in 9Router: {0}' -f $managedNames.Count)
foreach ($pool in $finalPools) {
    if ($managedNames.Contains([string]$pool.name)) {
        Write-Output ('pool={0} active={1} strict={2} test={3}' -f $pool.name, $pool.isActive, $pool.strictProxy, $pool.testStatus)
    }
}

Write-Output ('Ledger: {0}' -f $LedgerPath)

if ($testFailures.Count -gt 0) {
    Write-Output ''
    Write-Output ('Pool tests failed after {0} attempt(s): {1}' -f $TestAttempts, ($testFailures -join ', '))
    exit 3
}
