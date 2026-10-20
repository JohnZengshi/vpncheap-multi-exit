[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://localhost:20128',

    [string]$DataDirectory = "$env:APPDATA\9router",

    [string]$RuntimeDirectory,

    [string]$StatusPath,

    [string]$PlanPath,

    [string]$NamePrefix = 'vpncheap',

    [string[]]$BindConnectionId = @(),

    [string]$BindPoolName,

    [string[]]$BindConnectionPool = @(),

    [switch]$AllowRebind
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
if ([string]::IsNullOrWhiteSpace($PlanPath)) {
    $PlanPath = Join-Path $RuntimeDirectory 'pool-plan.json'
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

Write-JsonFileAtomic -Path $PlanPath -Value ([ordered]@{
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

Write-Output ('Plan: {0}' -f $PlanPath)
Write-Output ('Broker state: {0} instance={1}' -f $plan.BrokerState, $plan.BrokerInstanceId)
Write-Output ('Live pools: {0} connections: {1}' -f $pools.Count, $connections.Count)
Write-Output ''

if ($plan.Pools.Count -eq 0) {
    Write-Output 'No healthy exits were found in the broker status.'
}
else {
    $plan.Pools | Format-Table @{ Label = 'Pool'; Expression = { $_.name } },
        @{ Label = 'Port'; Expression = { $_.port } },
        @{ Label = 'Action'; Expression = { $_.action } },
        @{ Label = 'Strict'; Expression = { $_.currentStrictProxy } },
        @{ Label = 'Reason'; Expression = { $_.conflictReason } } -AutoSize | Out-String -Width 200 | Write-Output
}

if ($plan.Bindings.Count -gt 0) {
    $plan.Bindings | Format-Table @{ Label = 'Connection'; Expression = { $_.connectionId } },
        @{ Label = 'TargetPool'; Expression = { $_.targetPoolName } },
        @{ Label = 'CurrentPool'; Expression = { $_.currentPoolName } },
        @{ Label = 'Action'; Expression = { $_.action } },
        @{ Label = 'Reason'; Expression = { $_.conflictReason } } -AutoSize | Out-String -Width 240 | Write-Output
}

if ($plan.Warnings.Count -gt 0) {
    Write-Output ''
    foreach ($warning in $plan.Warnings) {
        Write-Output ('WARN: {0}' -f $warning)
    }
}

$hasConflict = $false
foreach ($item in $plan.Pools) {
    if ($item.action -eq 'conflict') {
        $hasConflict = $true
    }
}
foreach ($item in $plan.Bindings) {
    if ($item.action -eq 'conflict') {
        $hasConflict = $true
    }
}

if ($hasConflict) {
    exit 2
}
