[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$NodeHash,

    [Parameter(Mandatory = $true)]
    [int]$Port,

    [string]$StatePath = "$env:APPDATA\vpncheap\app_state.json",

    [string]$ManagedAssemblyPath = 'C:\Program Files\VPNCheap\VpncheapWindows.Core.dll',

    [string]$SingBoxDllPath = 'C:\Program Files\VPNCheap\sing-box.dll',

    [int]$HealthIntervalSec = 30,

    [int]$ProbeTimeoutSec = 20,

    [int]$FailureThreshold = 3,

    [int]$StartupDelayMs = 1200,

    [string]$RuntimeDirectory,

    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot\lib\vpncheap-state.ps1"
. "$PSScriptRoot\lib\broker-common.ps1"
. "$PSScriptRoot\lib\singbox-host.ps1"

if ([string]::IsNullOrWhiteSpace($RuntimeDirectory)) {
    $RuntimeDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime'
}
$RuntimeDirectory = [System.IO.Path]::GetFullPath($RuntimeDirectory)

$workerDirectory = Join-Path $RuntimeDirectory 'workers'
$stopDirectory = Join-Path $RuntimeDirectory 'stop'
$logDirectory = Join-Path $RuntimeDirectory 'logs'
foreach ($directory in @($workerDirectory, $stopDirectory, $logDirectory)) {
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $logDirectory "$NodeHash.log"
}

$statusPath = Join-Path $workerDirectory "$NodeHash.json"
$stopPath = Join-Path $stopDirectory "$NodeHash.stop"

$script:status = [ordered]@{
    schemaVersion = 1
    kind = 'vpncheap-worker'
    nodeHash = $NodeHash
    port = $Port
    state = 'starting'
    stateChangedAt = (Get-Date).ToUniversalTime().ToString('o')
    updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    startedAt = (Get-Date).ToUniversalTime().ToString('o')
    protocol = $null
    country = $null
    healthOk = $false
    httpStatus = $null
    latencyMs = $null
    exitIp = $null
    exitIpHash = $null
    lastCheckAt = $null
    lastHealthyAt = $null
    consecutiveFailures = 0
    failureStage = $null
    nativeErrorHash = $null
    singBoxVersion = $null
    workerPid = $PID
}

function Write-WorkerLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-RedactedLog -Path $LogPath -Message $Message
}

function Update-WorkerStatus {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Values
    )

    foreach ($key in $Values.Keys) {
        $script:status[$key] = $Values[$key]
    }

    $script:status['updatedAt'] = (Get-Date).ToUniversalTime().ToString('o')
    $script:status['workerPid'] = $PID
    Write-JsonFileAtomic -Path $statusPath -Value $script:status
}

function Set-WorkerState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$State,

        [hashtable]$Values = @{}
    )

    if ($script:status['state'] -ne $State) {
        $script:status['state'] = $State
        $script:status['stateChangedAt'] = (Get-Date).ToUniversalTime().ToString('o')
        Write-WorkerLog -Message ("state={0} node={1} port={2}" -f $State, $NodeHash, $Port)
    }

    $Values['state'] = $State
    Update-WorkerStatus -Values $Values
}

function Get-NodeByHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Hash
    )

    $records = @(Get-VpnCheapCatalogAccountRecords -StatePath $StatePath -AssemblyPath $ManagedAssemblyPath)
    foreach ($record in $records) {
        foreach ($node in $record.Nodes) {
            $nodeId = [string](Get-JsonProperty -Object $node -Name 'id')
            if ([string]::IsNullOrWhiteSpace($nodeId)) {
                continue
            }

            if ((Get-StringSha256Short -Text $nodeId) -eq $Hash) {
                return [pscustomobject]@{
                    Node = $node
                    Protocol = [string](Get-JsonProperty -Object $node -Name 'protocol')
                    Country = [string](Get-JsonProperty -Object $node -Name 'country_code')
                }
            }
        }
    }

    return $null
}

$serviceId = [UIntPtr]::Zero
$nodeInfo = $null
$stopRequested = $false

try {
    $native = Initialize-SingBoxNative -DllPath $SingBoxDllPath
    $version = Get-SingBoxVersion
    Update-WorkerStatus -Values @{ singBoxVersion = $version }
    Write-WorkerLog -Message ("worker-start node={0} port={1} singbox={2}" -f $NodeHash, $Port, $version)

    while (-not $stopRequested) {
        if (Test-Path -LiteralPath $stopPath) {
            $stopRequested = $true
            break
        }

        if ($serviceId -eq [UIntPtr]::Zero) {
            Set-WorkerState -State 'starting' -Values @{
                failureStage = $null
                nativeErrorHash = $null
            }

            try {
                $nodeInfo = Get-NodeByHash -Hash $NodeHash
            }
            catch {
                $errorHash = Get-StringSha256Short -Text $_.Exception.Message -Length 20
                Set-WorkerState -State 'catalog-error' -Values @{
                    failureStage = 'catalog'
                    nativeErrorHash = $errorHash
                }
                Write-WorkerLog -Message ("catalog-error node={0} errorHash={1}" -f $NodeHash, $errorHash)
                if (Wait-WithStopCheck -Seconds 15 -StopPath $stopPath) {
                    $stopRequested = $true
                    break
                }
                continue
            }

            if ($null -eq $nodeInfo) {
                Set-WorkerState -State 'node-missing' -Values @{
                    failureStage = 'catalog'
                }
                Write-WorkerLog -Message ("node-missing node={0}" -f $NodeHash)
                if (Wait-WithStopCheck -Seconds 15 -StopPath $stopPath) {
                    $stopRequested = $true
                    break
                }
                continue
            }

            Update-WorkerStatus -Values @{
                protocol = $nodeInfo.Protocol
                country = $nodeInfo.Country
            }

            $startResult = Start-SingBoxNodeService `
                -Node $nodeInfo.Node `
                -Port $Port `
                -SingBoxDirectory $native.Directory `
                -StartupDelayMs $StartupDelayMs

            if (-not $startResult.Ok) {
                $errorHash = if ($startResult.NativeError) {
                    Get-StringSha256Short -Text ([string]$startResult.NativeError) -Length 20
                }
                else {
                    $null
                }
                Set-WorkerState -State 'config-error' -Values @{
                    failureStage = $startResult.Stage
                    nativeErrorHash = $errorHash
                }
                Write-WorkerLog -Message ("config-error node={0} stage={1} errorHash={2}" -f $NodeHash, $startResult.Stage, $errorHash)
                if (Wait-WithStopCheck -Seconds 60 -StopPath $stopPath) {
                    $stopRequested = $true
                    break
                }
                continue
            }

            $serviceId = $startResult.ServiceId
            Set-WorkerState -State 'starting' -Values @{
                consecutiveFailures = 0
                failureStage = $null
                nativeErrorHash = $null
            }
        }

        $health = Test-ProxyExitHealth -Port $Port -TimeoutSec $ProbeTimeoutSec
        $now = (Get-Date).ToUniversalTime().ToString('o')
        if ($health.Ok) {
            Set-WorkerState -State 'healthy' -Values @{
                healthOk = $true
                httpStatus = $health.StatusCode
                latencyMs = $health.LatencyMs
                exitIp = $health.ExitIp
                exitIpHash = $health.ExitIpHash
                lastCheckAt = $now
                lastHealthyAt = $now
                consecutiveFailures = 0
                failureStage = $null
            }
        }
        else {
            $failures = [int]$script:status['consecutiveFailures'] + 1
            $values = @{
                healthOk = $false
                httpStatus = $health.StatusCode
                latencyMs = $health.LatencyMs
                exitIp = $health.ExitIp
                exitIpHash = $health.ExitIpHash
                lastCheckAt = $now
                consecutiveFailures = $failures
                failureStage = $health.FailureStage
            }

            if ($failures -ge $FailureThreshold) {
                Set-WorkerState -State 'quarantined' -Values $values
                Write-WorkerLog -Message ("quarantine node={0} port={1} failures={2} stage={3}" -f $NodeHash, $Port, $failures, $health.FailureStage)
                Close-SingBoxServiceSafe -ServiceId $serviceId
                $serviceId = [UIntPtr]::Zero
                $nodeInfo = $null
                $waitSeconds = [Math]::Max($HealthIntervalSec * 5, 60)
                if (Wait-WithStopCheck -Seconds $waitSeconds -StopPath $stopPath) {
                    $stopRequested = $true
                    break
                }
                continue
            }

            Set-WorkerState -State 'degraded' -Values $values
        }

        if (Wait-WithStopCheck -Seconds $HealthIntervalSec -StopPath $stopPath) {
            $stopRequested = $true
            break
        }
    }
}
catch {
    $errorHash = Get-StringSha256Short -Text $_.Exception.Message -Length 20
    try {
        Set-WorkerState -State 'fatal' -Values @{
            failureStage = 'worker'
            nativeErrorHash = $errorHash
        }
        Write-WorkerLog -Message ("worker-fatal node={0} errorHash={1}" -f $NodeHash, $errorHash)
    }
    catch {
    }
    exit 1
}
finally {
    Close-SingBoxServiceSafe -ServiceId $serviceId
    try {
        Set-WorkerState -State 'stopped' -Values @{
            healthOk = $false
        }
        Write-WorkerLog -Message ("worker-stop node={0} port={1}" -f $NodeHash, $Port)
    }
    catch {
    }
}
