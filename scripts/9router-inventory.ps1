param(
    [string]$BaseUrl = 'http://localhost:20128',

    [string]$DataDirectory = "$env:APPDATA\9router",

    [switch]$ShowNames
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$baseUri = [Uri]$BaseUrl
if (-not $baseUri.IsLoopback) {
    throw 'This inventory script only talks to a loopback 9Router instance.'
}

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
    $digest = ($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
}
finally {
    $sha256.Dispose()
}

# 9Router derives its local CLI token the same way. Never print or persist it.
$cliToken = $digest.Substring(0, 16)
$headers = @{ 'x-9r-cli-token' = $cliToken }

function Invoke-NineRouterGet {
    param([Parameter(Mandatory = $true)][string]$Path)

    $uri = [Uri]::new($baseUri, $Path)
    $response = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing -TimeoutSec 10
    return $response.Content | ConvertFrom-Json
}

function Get-OptionalProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

$poolResponse = Invoke-NineRouterGet -Path '/api/proxy-pools?isActive=true&includeUsage=true'
$providerResponse = Invoke-NineRouterGet -Path '/api/providers'

$pools = @($poolResponse.proxyPools)
$connections = @($providerResponse.connections)
$poolNameById = @{}
foreach ($pool in $pools) {
    $poolNameById[[string]$pool.id] = [string]$pool.name
}
$boundConnections = @($connections | Where-Object {
    -not [string]::IsNullOrWhiteSpace([string](Get-OptionalProperty -Object (Get-OptionalProperty -Object $_ -Name 'providerSpecificData') -Name 'proxyPoolId'))
})

Write-Output ("9router pools: {0}" -f $pools.Count)
Write-Output ("9router provider connections: {0}" -f $connections.Count)
Write-Output ("connections bound to a pool: {0}" -f $boundConnections.Count)
Write-Output ''

foreach ($pool in $pools) {
    $name = if ($ShowNames) { [string]$pool.name } else { '***' }
    Write-Output ("pool id={0} name={1} type={2} active={3} test={4} strict={5} bound={6} hasProxyUrl={7}" -f `
        $pool.id, $name, $pool.type, $pool.isActive, $pool.testStatus, $pool.strictProxy, `
        $pool.boundConnectionCount, (-not [string]::IsNullOrWhiteSpace([string]$pool.proxyUrl)))
}

Write-Output ''
foreach ($connection in $connections) {
    $poolId = [string](Get-OptionalProperty -Object (Get-OptionalProperty -Object $connection -Name 'providerSpecificData') -Name 'proxyPoolId')
    $poolName = if ([string]::IsNullOrWhiteSpace($poolId)) { '' } else { [string]$poolNameById[$poolId] }
    Write-Output ("connection id={0} provider={1} active={2} priority={3} poolBound={4} pool={5}" -f `
        $connection.id, $connection.provider, $connection.isActive, $connection.priority, `
        (-not [string]::IsNullOrWhiteSpace($poolId)), $poolName)
}
