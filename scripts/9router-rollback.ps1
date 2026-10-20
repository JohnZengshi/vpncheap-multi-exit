[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://localhost:20128',

    [string]$DataDirectory = "$env:APPDATA\9router",

    [string]$RuntimeDirectory,

    [string]$LedgerPath,

    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot\lib\broker-common.ps1"
. "$PSScriptRoot\lib\9router.ps1"

if ([string]::IsNullOrWhiteSpace($RuntimeDirectory)) {
    $RuntimeDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime'
}
$RuntimeDirectory = [System.IO.Path]::GetFullPath($RuntimeDirectory)
if ([string]::IsNullOrWhiteSpace($LedgerPath)) {
    $LedgerPath = Join-Path $RuntimeDirectory '9router-applied.json'
}

$ledger = Read-JsonFile -Path $LedgerPath
if ($null -eq $ledger) {
    Write-Output ('No ledger found: {0}' -f $LedgerPath)
    exit 0
}

$client = New-NineRouterClient -BaseUrl $BaseUrl -DataDirectory $DataDirectory
$livePools = Get-NineRouterPools -Client $client
$liveConnections = Get-NineRouterConnections -Client $client

$livePoolById = @{}
foreach ($pool in $livePools) {
    $livePoolById[[string]$pool.id] = $pool
}

$remainingBindings = New-Object System.Collections.Generic.List[object]
foreach ($item in @($ledger.bindings)) {
    if ($null -eq $item) {
        continue
    }

    $connection = $null
    foreach ($candidate in $liveConnections) {
        if ([string]$candidate.id -eq [string]$item.connectionId) {
            $connection = $candidate
            break
        }
    }

    if ($null -eq $connection) {
        Write-Output ('skip connection={0}: not found' -f $item.connectionId)
        continue
    }

    $currentPoolId = Get-NineRouterConnectionPoolId -Connection $connection
    if ([string]$currentPoolId -ne [string]$item.poolId) {
        Write-Output ('skip connection={0}: current pool changed' -f $item.connectionId)
        continue
    }

    if (-not $Apply) {
        Write-Output ('would unbind connection={0} pool={1}' -f $item.connectionId, $item.poolName)
        $remainingBindings.Add($item)
        continue
    }

    try {
        Set-NineRouterConnectionPool -Client $client -ConnectionId $item.connectionId -PoolId $item.previousPoolId | Out-Null
        Write-Output ('unbound connection={0} pool={1}' -f $item.connectionId, $item.poolName)
    }
    catch {
        Write-Output ('failed unbind connection={0}: {1}' -f $item.connectionId, $_.Exception.Message)
        $remainingBindings.Add($item)
    }
}

$remainingPoolUpdates = New-Object System.Collections.Generic.List[object]
foreach ($item in @(Get-OptionalProperty -Object $ledger -Name 'poolUpdates')) {
    if ($null -eq $item) {
        continue
    }

    $livePool = $livePoolById[[string]$item.poolId]
    if ($null -eq $livePool) {
        Write-Output ('skip pool update name={0}: pool not found' -f $item.name)
        continue
    }

    if (-not $Apply) {
        Write-Output ('would restore pool={0} strictProxy={1} isActive={2}' -f $item.name, $item.previousStrictProxy, $item.previousIsActive)
        $remainingPoolUpdates.Add($item)
        continue
    }

    try {
        Set-NineRouterPool `
            -Client $client `
            -PoolId ([string]$item.poolId) `
            -StrictProxy ([bool]$item.previousStrictProxy) `
            -IsActive ([bool]$item.previousIsActive) | Out-Null
        Write-Output ('restored pool={0} strictProxy={1} isActive={2}' -f $item.name, $item.previousStrictProxy, $item.previousIsActive)
    }
    catch {
        Write-Output ('failed restore pool={0}: {1}' -f $item.name, $_.Exception.Message)
        $remainingPoolUpdates.Add($item)
    }
}

$remainingPools = New-Object System.Collections.Generic.List[object]
foreach ($item in @($ledger.pools)) {
    if ($null -eq $item) {
        continue
    }

    if ([string]$item.name -eq 'vpncheap') {
        Write-Output 'skip pool: protected base pool name'
        $remainingPools.Add($item)
        continue
    }

    $livePool = $livePoolById[[string]$item.poolId]
    if ($null -eq $livePool) {
        Write-Output ('pool already gone name={0}' -f $item.name)
        continue
    }

    $expectedUrl = 'http://127.0.0.1:{0}' -f $item.port
    if ((ConvertTo-NineRouterUrlKey -Url ([string]$livePool.proxyUrl)) -ne (ConvertTo-NineRouterUrlKey -Url $expectedUrl)) {
        Write-Output ('skip pool={0}: proxy url changed' -f $item.name)
        $remainingPools.Add($item)
        continue
    }

    if (-not $Apply) {
        Write-Output ('would delete pool={0} port={1}' -f $item.name, $item.port)
        $remainingPools.Add($item)
        continue
    }

    try {
        Remove-NineRouterPool -Client $client -PoolId $item.poolId | Out-Null
        Write-Output ('deleted pool={0} port={1}' -f $item.name, $item.port)
    }
    catch {
        Write-Output ('failed delete pool={0}: {1}' -f $item.name, $_.Exception.Message)
        $remainingPools.Add($item)
    }
}

if ($Apply) {
    Write-JsonFileAtomic -Path $LedgerPath -Value ([ordered]@{
        schemaVersion = 1
        kind = 'vpncheap-9router-ledger'
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
        pools = $remainingPools.ToArray()
        poolUpdates = $remainingPoolUpdates.ToArray()
        bindings = $remainingBindings.ToArray()
    })
    Write-Output ('Ledger updated: {0}' -f $LedgerPath)
}
else {
    Write-Output ''
    Write-Output 'Dry run only. Re-run with -Apply to unbind connections and delete managed pools.'
}
