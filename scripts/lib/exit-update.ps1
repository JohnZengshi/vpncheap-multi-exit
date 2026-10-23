Set-StrictMode -Version Latest

function Get-ExitRecoveryDelaySeconds {
    param([int]$Attempt, [int]$Port)

    $backoff = [Math]::Min(300, 30 * [Math]::Pow(2, [Math]::Min(4, [Math]::Max(0, $Attempt))))
    return [int]$backoff + ($Port % 17)
}

function Test-ExitCandidateClaimed {
    param([string]$RuntimeDirectory, [string]$NodeHash, [object]$Candidate)

    $identity = Get-ExitNodeIdentity $Candidate
    $status = Read-JsonFile (Join-Path $RuntimeDirectory 'status.json')
    foreach ($slot in @(Get-OptionalProperty $status 'exits')) {
        $hash = [string](Get-OptionalProperty $slot 'nodeHash')
        if ($hash -ne $NodeHash -and $hash -eq $identity.SourceHash) { return $true }
    }
    $path = Join-Path $RuntimeDirectory 'nodes'
    if (Test-Path -LiteralPath $path) {
        foreach ($file in @(Get-ChildItem -LiteralPath $path -Filter '*.dpapi.json' -File)) {
            if ($file.Name -eq "$NodeHash.dpapi.json") { continue }
            $saved = Read-ProtectedSubscriptionFile $file.FullName
            $other = Get-ExitNodeIdentity $saved.node
            if ($other.SourceHash -eq $identity.SourceHash -or $other.EndpointHash -eq $identity.EndpointHash) {
                return $true
            }
        }
    }
    return $false
}

function Invoke-ExitRecovery {
    param(
        [object]$Previous, [AllowEmptyCollection()][object[]]$Nodes,
        [UIntPtr]$ServiceId, [string]$NodeHash, [int]$Port,
        [string]$RuntimeDirectory, [string]$SingBoxDirectory,
        [int]$ProbeTimeoutSec = 20, [int]$StartupDelayMs = 1200, [string]$StopPath,
        [int]$StageProbeIntervalMs = 2000,
        [int]$RecoveryAttempt = 0
    )

    $arguments = @{
        Previous = $Previous; ServiceId = $ServiceId; NodeHash = $NodeHash; Port = $Port
        RuntimeDirectory = $RuntimeDirectory; SingBoxDirectory = $SingBoxDirectory
        ProbeTimeoutSec = $ProbeTimeoutSec; StartupDelayMs = $StartupDelayMs; StopPath = $StopPath
    }
    $config = Read-JsonFile (Join-Path $RuntimeDirectory 'exit-config.json')
    if ((Get-OptionalProperty $config 'autoFallback') -ne $false) {
        $current = Get-ExitNodeIdentity $Previous
        $seen = @{}
        $candidates = @($Nodes | Where-Object {
            [bool](Get-JsonProperty $_ 'online') -and
            $null -ne (Get-JsonProperty $_ 'raw_outbound') -and
            (Get-JsonProperty $_ 'country_code') -eq (Get-JsonProperty $Previous 'country_code') -and
            (Get-JsonProperty $_ 'protocol') -in @('anytls', 'hysteria2') -and
            (Get-ExitNodeIdentity $_).EndpointHash -ne $current.EndpointHash
        } | Sort-Object @{ Expression = {
            if ($_.protocol -ne $Previous.protocol -and $_.protocol -eq 'anytls') { 0 }
            elseif ($_.protocol -ne $Previous.protocol) { 1 } else { 2 }
        } }, @{ Expression = { (Get-ExitNodeIdentity $_).SourceHash } })
        $attempted = 0
        for ($index = 0; $index -lt $candidates.Count; $index++) {
            $candidate = $candidates[($index + [Math]::Max(0, $RecoveryAttempt) * 3) % $candidates.Count]
            $endpoint = (Get-ExitNodeIdentity $candidate).EndpointHash
            if ($seen.ContainsKey($endpoint)) { continue }
            $seen[$endpoint] = $true
            if (Test-ExitCandidateClaimed $RuntimeDirectory $NodeHash $candidate) { continue }
            $result = Invoke-SafeExitUpdate @arguments -Candidate $candidate -AllowProtocolFallback `
                -StageProbeCount 3 -StageProbeIntervalMs $StageProbeIntervalMs
            if ($result.State -ne 'validation-failed') { return $result }
            $attempted++
            if ($attempted -ge 3) { break }
        }
    }
    # If no backup validates, a staged reconstruction may still repair the current node.
    return Invoke-SafeExitUpdate @arguments -Candidate $Previous
}

function Invoke-SafeExitUpdate {
    param(
        [AllowNull()][object]$Previous,
        [object]$Candidate,
        [UIntPtr]$ServiceId,
        [string]$NodeHash,
        [int]$Port,
        [string]$RuntimeDirectory,
        [string]$SingBoxDirectory,
        [int]$ProbeTimeoutSec = 20,
        [int]$StartupDelayMs = 1200,
        [string]$StopPath,
        [switch]$AllowProtocolFallback,
        [ValidateRange(1, 5)][int]$StageProbeCount = 1,
        [ValidateRange(0, 10000)][int]$StageProbeIntervalMs = 2000
    )

    $result = [pscustomobject]@{
        Node = $Previous; ServiceId = $ServiceId; State = 'update-pending'; ErrorHash = $null
    }
    try {
        $lock = [IO.File]::Open((Join-Path $RuntimeDirectory 'exit-update.lock'),
            [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    catch [IO.IOException] {
        if (($_.Exception.HResult -band 0xffff) -notin @(32,33)) { throw }
        return $result
    }
    $staged = [UIntPtr]::Zero
    $cutover = $false
    try {
        if ($StopPath -and (Test-Path -LiteralPath $StopPath)) { return $result }
        if ($null -ne $Previous) {
            if (((Get-JsonProperty $Previous 'protocol') -ne (Get-JsonProperty $Candidate 'protocol') -and
                    -not $AllowProtocolFallback) -or
                (Get-JsonProperty $Previous 'country_code') -ne (Get-JsonProperty $Candidate 'country_code')) {
                throw 'exit-replacement-incompatible'
            }
            Save-ExitNodeSnapshot $RuntimeDirectory $NodeHash $Previous
        }
        # Recheck inside the global lock: another exit may have just claimed this backup.
        if ($AllowProtocolFallback -and (Test-ExitCandidateClaimed $RuntimeDirectory $NodeHash $Candidate)) {
            throw 'exit-backup-already-claimed'
        }
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        try {
            $listener.Start()
            $temporaryPort = $listener.LocalEndpoint.Port
        }
        finally { $listener.Stop() }
        $stage = Start-SingBoxNodeService -Node $Candidate -Port $temporaryPort `
            -SingBoxDirectory $SingBoxDirectory -StartupDelayMs $StartupDelayMs
        if (-not $stage.Ok) { throw 'exit-stage-start-failed' }
        $staged = $stage.ServiceId
        for ($probe = 0; $probe -lt $StageProbeCount; $probe++) {
            if ($StopPath -and (Test-Path -LiteralPath $StopPath)) { return $result }
            if ($probe -gt 0 -and $StageProbeIntervalMs -gt 0) {
                Start-Sleep -Milliseconds $StageProbeIntervalMs
            }
            $health = Test-ProxyExitHealth -Port $temporaryPort -TimeoutSec $ProbeTimeoutSec
            if (-not $health.Ok) { throw 'exit-stage-health-failed' }
        }
        Close-SingBoxServiceSafe $staged
        $staged = [UIntPtr]::Zero
        if ($StopPath -and (Test-Path -LiteralPath $StopPath)) { return $result }

        $cutover = $true
        Close-SingBoxServiceSafe $ServiceId
        $result.ServiceId = [UIntPtr]::Zero
        $start = Start-SingBoxNodeService -Node $Candidate -Port $Port `
            -SingBoxDirectory $SingBoxDirectory -StartupDelayMs $StartupDelayMs
        if (-not $start.Ok) { throw 'exit-cutover-start-failed' }
        $result.ServiceId = $start.ServiceId
        $health = Test-ProxyExitHealth -Port $Port -TimeoutSec $ProbeTimeoutSec
        if (-not $health.Ok) { throw 'exit-cutover-health-failed' }
        if ($AllowProtocolFallback) {
            Save-ExitNodeSnapshot $RuntimeDirectory $NodeHash $Candidate -FallbackActive $true
        }
        else { Save-ExitNodeSnapshot $RuntimeDirectory $NodeHash $Candidate }
        $result.Node = $Candidate
        $result.State = 'updated'
    }
    catch {
        $result.ErrorHash = Get-StringSha256Short $_.Exception.Message -Length 20
        $result.State = 'validation-failed'
        if ($cutover) {
            Close-SingBoxServiceSafe $result.ServiceId
            $result.ServiceId = [UIntPtr]::Zero
            $result.State = 'rollback-failed'
            if ($null -ne $Previous) {
                try {
                    $rollback = Start-SingBoxNodeService -Node $Previous -Port $Port `
                        -SingBoxDirectory $SingBoxDirectory -StartupDelayMs $StartupDelayMs
                    if ($rollback.Ok) {
                        $result.ServiceId = $rollback.ServiceId
                        $result.State = 'rolled-back'
                    }
                }
                catch { $result.State = 'rollback-failed' }
            }
        }
    }
    finally {
        Close-SingBoxServiceSafe $staged
        $lock.Dispose()
    }
    return $result
}
