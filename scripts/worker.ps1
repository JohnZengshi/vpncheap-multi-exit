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
. "$PSScriptRoot\lib\subscription-state.ps1"
. "$PSScriptRoot\lib\exit-update.ps1"

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
    exitIpOk = $null
    healthTarget = $null
    lastCheckAt = $null
    lastHealthyAt = $null
    consecutiveFailures = 0
    failureStage = $null
    nativeErrorHash = $null
    singBoxVersion = $null
    workerPid = $PID
    updateState = $null
    updateErrorHash = $null
    recoveryAttempt = 0
    nextRecoveryAt = $null
    recoveryState = $null
    recoveryErrorHash = $null
    fallbackActive = $false
    activeNodeHash = $null
    activeNodeName = $null
    serverAddress = $null
    serverPort = $null
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

    $saved = Read-ProtectedSubscriptionFile (Get-ExitSnapshotPath $RuntimeDirectory $Hash)
    if ($null -ne $saved) {
        return [pscustomobject]@{
            Node = $saved.node; Protocol = $saved.node.protocol; Country = $saved.node.country_code
            RequiresValidation = $false
            FallbackActive = [bool](Get-OptionalProperty $saved 'fallbackActive')
        }
    }
    $nodes = @(Get-SubscriptionNodes -RuntimeDirectory $RuntimeDirectory -StatePath $StatePath -AssemblyPath $ManagedAssemblyPath)
    foreach ($node in $nodes) {
            $nodeId = [string](Get-JsonProperty -Object $node -Name 'id')
            if ([string]::IsNullOrWhiteSpace($nodeId)) {
                continue
            }

            if ((Get-StringSha256Short -Text $nodeId) -eq $Hash) {
                return [pscustomobject]@{
                    Node = $node
                    Protocol = [string](Get-JsonProperty -Object $node -Name 'protocol')
                    Country = [string](Get-JsonProperty -Object $node -Name 'country_code')
                    RequiresValidation = $false
                    FallbackActive = $false
                }
            }
    }

    $replacement = Get-ExplicitExitReplacement $RuntimeDirectory $Hash $nodes
    if ($null -ne $replacement) {
        $brokerStatus = Read-JsonFile (Join-Path $RuntimeDirectory 'status.json')
        $slot = @(Get-OptionalProperty $brokerStatus 'exits') | Where-Object nodeHash -eq $Hash | Select-Object -First 1
        if ($null -ne $slot -and $replacement.protocol -eq $slot.protocol -and $replacement.country_code -eq $slot.country) {
            return [pscustomobject]@{
                Node = $replacement; Protocol = $replacement.protocol; Country = $replacement.country_code
                RequiresValidation = $true
                FallbackActive = $false
            }
        }
    }
    return $null
}

$serviceId = [UIntPtr]::Zero
$nodeInfo = $null
$stopRequested = $false
$lastUpdateAttempt = [datetime]::MinValue
$lastProposalHash = ''

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
                if ($null -eq $nodeInfo) { $nodeInfo = Get-NodeByHash -Hash $NodeHash }
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

            if ($nodeInfo.RequiresValidation) {
                Update-WorkerStatus @{ updateState = 'validating' }
                $initial = Invoke-SafeExitUpdate -Previous $null -Candidate $nodeInfo.Node -ServiceId ([UIntPtr]::Zero) `
                    -NodeHash $NodeHash -Port $Port -RuntimeDirectory $RuntimeDirectory `
                    -SingBoxDirectory $native.Directory -ProbeTimeoutSec $ProbeTimeoutSec `
                    -StartupDelayMs $StartupDelayMs -StopPath $stopPath
                Update-WorkerStatus @{ updateState = $initial.State; updateErrorHash = $initial.ErrorHash }
                if ($initial.State -ne 'updated') {
                    $nodeInfo = $null
                    if (Wait-WithStopCheck -Seconds 30 -StopPath $stopPath) { $stopRequested = $true }
                    continue
                }
                $nodeInfo.RequiresValidation = $false
                $startResult = [pscustomobject]@{ Ok = $true; ServiceId = $initial.ServiceId }
            }
            else {
                $startResult = Start-SingBoxNodeService `
                    -Node $nodeInfo.Node `
                    -Port $Port `
                    -SingBoxDirectory $native.Directory `
                    -StartupDelayMs $StartupDelayMs
            }

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

        $nodes = @()
        try {
            $nodes = @(Get-SubscriptionNodes -RuntimeDirectory $RuntimeDirectory -StatePath $StatePath -AssemblyPath $ManagedAssemblyPath)
            $candidate = $null
            if (-not $nodeInfo.FallbackActive) {
                $candidate = Get-ExplicitExitReplacement $RuntimeDirectory $NodeHash $nodes
            }
            if ($null -eq $candidate) { $candidate = Resolve-ExitNodeReplacement $nodeInfo.Node $nodes }
            if ($null -eq $candidate) {
                Update-WorkerStatus @{ updateState = 'needs-review'; updateErrorHash = $null }
            }
            else {
                $oldIdentity = Get-ExitNodeIdentity $nodeInfo.Node
                $newIdentity = Get-ExitNodeIdentity $candidate
                if ($oldIdentity.ConfigHash -eq $newIdentity.ConfigHash) {
                    Save-ExitNodeSnapshot $RuntimeDirectory $NodeHash $candidate
                    $nodeInfo.Node = $candidate
                    Update-WorkerStatus @{ updateState = 'current'; updateErrorHash = $null }
                }
                elseif ($newIdentity.ConfigHash -ne $lastProposalHash -or
                    ((Get-Date) - $lastUpdateAttempt).TotalSeconds -ge 300) {
                    Update-WorkerStatus @{ updateState = 'validating'; updateErrorHash = $null }
                    $update = Invoke-SafeExitUpdate -Previous $nodeInfo.Node -Candidate $candidate -ServiceId $serviceId `
                        -NodeHash $NodeHash -Port $Port -RuntimeDirectory $RuntimeDirectory `
                        -SingBoxDirectory $native.Directory -ProbeTimeoutSec $ProbeTimeoutSec `
                        -StartupDelayMs $StartupDelayMs -StopPath $stopPath
                    $serviceId = $update.ServiceId
                    $nodeInfo.Node = $update.Node
                    if ($update.State -ne 'update-pending') {
                        $lastUpdateAttempt = Get-Date
                        $lastProposalHash = $newIdentity.ConfigHash
                    }
                    Update-WorkerStatus @{ updateState = $update.State; updateErrorHash = $update.ErrorHash }
                    Write-WorkerLog ("exit-update node={0} state={1} errorHash={2}" -f $NodeHash, $update.State, $update.ErrorHash)
                }
            }
        }
        catch {
            Update-WorkerStatus @{
                updateState = 'catalog-error'
                updateErrorHash = Get-StringSha256Short $_.Exception.Message -Length 20
            }
        }
        if ($serviceId -eq [UIntPtr]::Zero) { continue }
        Update-WorkerStatus @{
            protocol = $nodeInfo.Node.protocol
            country = $nodeInfo.Node.country_code
            fallbackActive = $nodeInfo.FallbackActive
            activeNodeHash = (Get-ExitNodeIdentity $nodeInfo.Node).SourceHash
            activeNodeName = $nodeInfo.Node.name
            serverAddress = $nodeInfo.Node.address
            serverPort = $nodeInfo.Node.port
        }
        $health = Test-ProxyExitHealth -Port $Port -TimeoutSec $ProbeTimeoutSec
        $now = (Get-Date).ToUniversalTime().ToString('o')
        if ($health.Ok) {
            try { Save-ExitNodeSnapshot $RuntimeDirectory $NodeHash $nodeInfo.Node }
            catch {
                Update-WorkerStatus @{
                    updateState = 'snapshot-error'
                    updateErrorHash = Get-StringSha256Short $_.Exception.Message -Length 20
                }
            }
            Set-WorkerState -State 'healthy' -Values @{
                healthOk = $true
                httpStatus = $health.StatusCode
                latencyMs = $health.LatencyMs
                exitIp = $health.ExitIp
                exitIpHash = $health.ExitIpHash
                exitIpOk = Get-OptionalProperty $health 'ExitIpOk'
                healthTarget = Get-OptionalProperty $health 'HealthTarget'
                lastCheckAt = $now
                lastHealthyAt = $now
                consecutiveFailures = 0
                failureStage = $null
                recoveryAttempt = 0
                nextRecoveryAt = $null
                recoveryState = $null
                recoveryErrorHash = $null
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
                exitIpOk = Get-OptionalProperty $health 'ExitIpOk'
                healthTarget = Get-OptionalProperty $health 'HealthTarget'
                lastCheckAt = $now
                consecutiveFailures = $failures
                failureStage = $health.FailureStage
            }

            if ($failures -ge $FailureThreshold) {
                # Keep the listener until a staged recovery or backup validates.
                Set-WorkerState -State 'unhealthy' -Values $values
                $nextRecovery = $script:status['nextRecoveryAt']
                if (-not $nextRecovery) {
                    $delay = Get-ExitRecoveryDelaySeconds -Attempt 0 -Port $Port
                    Update-WorkerStatus @{
                        recoveryState = 'scheduled'
                        nextRecoveryAt = ([datetime]$now).AddSeconds($delay).ToString('o')
                    }
                }
                elseif ([datetime]$now -ge [datetime]$nextRecovery) {
                    Update-WorkerStatus @{ recoveryState = 'validating' }
                    try {
                        $recovery = Invoke-ExitRecovery -Previous $nodeInfo.Node -Nodes $nodes `
                            -RecoveryAttempt ([int]$script:status['recoveryAttempt']) `
                            -ServiceId $serviceId -NodeHash $NodeHash -Port $Port `
                            -RuntimeDirectory $RuntimeDirectory -SingBoxDirectory $native.Directory `
                            -ProbeTimeoutSec $ProbeTimeoutSec -StartupDelayMs $StartupDelayMs -StopPath $stopPath
                        $serviceId = $recovery.ServiceId
                        if ($recovery.State -eq 'updated') {
                            $changed = (Get-ExitNodeIdentity $nodeInfo.Node).EndpointHash -ne
                                (Get-ExitNodeIdentity $recovery.Node).EndpointHash
                            $nodeInfo.Node = $recovery.Node
                            if ($changed) { $nodeInfo.FallbackActive = $true }
                            Update-WorkerStatus @{
                                fallbackActive = $nodeInfo.FallbackActive
                                activeNodeHash = (Get-ExitNodeIdentity $nodeInfo.Node).SourceHash
                                activeNodeName = $nodeInfo.Node.name
                                protocol = $nodeInfo.Node.protocol
                                country = $nodeInfo.Node.country_code
                                serverAddress = $nodeInfo.Node.address
                                serverPort = $nodeInfo.Node.port
                            }
                        }
                        $recoveryState = $recovery.State
                        $recoveryError = $recovery.ErrorHash
                    }
                    catch {
                        $recoveryState = 'validation-failed'
                        $recoveryError = Get-StringSha256Short $_.Exception.Message -Length 20
                    }
                    $attempt = [int]$script:status['recoveryAttempt']
                    if ($recoveryState -ne 'update-pending') { $attempt++ }
                    $delay = Get-ExitRecoveryDelaySeconds -Attempt $attempt -Port $Port
                    Update-WorkerStatus @{
                        recoveryAttempt = $attempt
                        recoveryState = $recoveryState
                        recoveryErrorHash = $recoveryError
                        nextRecoveryAt = (Get-Date).ToUniversalTime().AddSeconds($delay).ToString('o')
                    }
                    Write-WorkerLog ("exit-recovery node={0} state={1} attempt={2} errorHash={3}" -f `
                        $NodeHash, $recoveryState, $attempt, $recoveryError)
                }
            }
            else {
                Set-WorkerState -State 'degraded' -Values $values
            }
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
