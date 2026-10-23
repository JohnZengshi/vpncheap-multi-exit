[CmdletBinding()]
param([switch]$Json)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. "$root/scripts/lib/vpncheap-state.ps1"
. "$root/scripts/lib/broker-common.ps1"
. "$root/scripts/lib/singbox-host.ps1"
. "$root/scripts/lib/subscription-state.ps1"
. "$root/scripts/lib/exit-update.ps1"
$script:failures = [Collections.Generic.List[string]]::new()
$script:transitions = @{}
function Assert-Test($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Run-Test($Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "PASS $Name" }
    catch { $script:failures.Add($Name); Write-Host "FAIL ${Name}: $($_.Exception.Message)" }
}

Run-Test 'IP lookup failure does not make a working proxy unhealthy' {
    function Invoke-CurlCapture {
        param($Arguments)
        if ($Arguments -contains '-w') { return @{ ExitCode = 0; Output = '204|0.1' } }
        return @{ ExitCode = 28; Output = 'simulated metadata timeout' }
    }
    $result = Test-ProxyExitHealth -Port 39999 -TimeoutSec 2
    Assert-Test ($result.Ok -and $result.HealthOk) 'Working proxy marked unhealthy.'
    Assert-Test (-not $result.ExitIpOk -and $null -eq $result.ExitIp) 'Failed metadata reported as current.'
    Assert-Test ($null -eq $result.FailureStage) 'Metadata failure counted as network outage.'
}
Run-Test 'Independent health target rescues a failed primary target' {
    $script:targets = [Collections.Generic.List[string]]::new()
    function Invoke-CurlCapture {
        param($Arguments)
        $script:targets.Add($Arguments[-1])
        if ($Arguments[-1] -eq 'https://www.gstatic.com/generate_204') {
            return @{ ExitCode = 0; Output = '204|0.2' }
        }
        return @{ ExitCode = 28; Output = 'simulated timeout' }
    }
    $result = Test-ProxyExitHealth -Port 39999 -TimeoutSec 2
    Assert-Test $result.Ok 'Independent target not used.'
    Assert-Test ($script:targets.Contains('https://www.gstatic.com/generate_204')) 'Fallback missing.'
    Assert-Test ($result.HealthTarget -eq 'www.gstatic.com') 'Successful target not recorded.'
}
Run-Test 'Real outage stays unhealthy and skips metadata requests' {
    $script:requests = 0
    function Invoke-CurlCapture {
        param($Arguments)
        $script:requests++
        return @{ ExitCode = 28; Output = '000|0.1' }
    }
    $result = Test-ProxyExitHealth -Port 39999 -TimeoutSec 2
    Assert-Test (-not $result.Ok -and $result.FailureStage -eq 'health') 'Outage hidden.'
    Assert-Test ($script:requests -eq 2) 'Expected exactly two independent health probes.'
}
Run-Test 'HTTP errors and malformed IP metadata cannot produce a false success' {
    function Invoke-CurlCapture {
        param($Arguments)
        if ($Arguments -contains '-w') { return @{ ExitCode = 0; Output = '503|0.1' } }
        return @{ ExitCode = 0; Output = '999.999.999.999' }
    }
    Assert-Test (-not (Test-ProxyExitHealth -Port 39999 -TimeoutSec 2).Ok) 'HTTP 503 accepted.'
    function Invoke-CurlCapture {
        param($Arguments)
        if ($Arguments -contains '-w') { return @{ ExitCode = 0; Output = '204|0.1' } }
        return @{ ExitCode = 0; Output = '999.999.999.999' }
    }
    $result = Test-ProxyExitHealth -Port 39999 -TimeoutSec 2
    Assert-Test ($result.Ok -and -not $result.ExitIpOk) 'Malformed metadata accepted.'
}
Run-Test 'Curl probes cannot bypass the explicit proxy or inherit curlrc' {
    function Invoke-CurlCapture {
        param($Arguments)
        Assert-Test ($Arguments[0] -eq '-q') 'curlrc was not disabled.'
        $index = [array]::IndexOf($Arguments, '--noproxy')
        Assert-Test ($index -ge 0 -and $Arguments[$index + 1] -eq '') 'NO_PROXY can bypass the exit.'
        return @{ ExitCode = 0; Output = '204|0.1' }
    }
    $null = Test-ProxyExitHealth -Port 39999 -TimeoutSec 2
}
Run-Test 'Actual curl wrapper accepts an empty NO_PROXY override' {
    $result = Invoke-CurlCapture -Arguments @('-q', '--noproxy', '', '--version')
    Assert-Test ($result.ExitCode -eq 0 -and $result.Output -match '^curl ') 'Native curl arguments were rejected.'
}

$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile("$root/scripts/worker.ps1", [ref]$tokens, [ref]$errors)
$block = $ast.Find({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
    $node.Extent.Text.StartsWith('if ($health.Ok)')
}, $true)
if ($null -eq $block) { throw 'Worker health transition missing.' }
$transition = [scriptblock]::Create("for (`$step = 0; `$step -lt 1; `$step++) { $($block.Extent.Text) }")

foreach ($scenario in @('transient', 'schedule', 'waiting', 'stage-fails', 'lock-busy', 'recovered', 'fallback', 'healthy')) {
    Run-Test "Worker recovery: $scenario" {
        $script:closed = 0; $script:recoveries = 0
        $script:status = @{
            state = 'unhealthy'
            consecutiveFailures = if ($scenario -eq 'transient') { 0 } else { 3 }
            recoveryAttempt = 0
            nextRecoveryAt = switch ($scenario) {
                schedule { $null }
                transient { $null }
                waiting { (Get-Date).ToUniversalTime().AddMinutes(1).ToString('o') }
                default { (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o') }
            }
        }
        $health = [pscustomobject]@{
            Ok = ($scenario -eq 'healthy'); StatusCode = '000'; LatencyMs = 100
            ExitIp = $null; ExitIpHash = $null; ExitIpOk = $false
            FailureStage = 'health'; HealthTarget = $null
        }
        $now = (Get-Date).ToUniversalTime().ToString('o')
        $Port = 39999; $NodeHash = 'fixture'; $FailureThreshold = 3
        $HealthIntervalSec = 15; $ProbeTimeoutSec = 2; $StartupDelayMs = 0
        $serviceId = [UIntPtr]99; $RuntimeDirectory = 'unused'; $stopPath = ''
        $nodes = @()
        $nodeInfo = [pscustomobject]@{
            FallbackActive = $false
            Node = [pscustomobject]@{ id = 'fixture'; name = 'fixture'; protocol = 'hysteria2'
                country_code = 'HK'; address = '192.0.2.1'; port = 443; raw_outbound = @{} }
        }
        if ($scenario -eq 'fallback') {
            $nodes = @([pscustomobject]@{
                id = 'backup'; name = 'HK-backup'; protocol = 'anytls'; online = $true
                country_code = 'HK'; address = '192.0.2.2'; port = 8443
                raw_outbound = @{ type = 'anytls'; server = '192.0.2.2' }
            })
        }
        $native = [pscustomobject]@{ Directory = 'unused' }
        function Close-SingBoxServiceSafe { param($ServiceId) $script:closed++ }
        function Wait-WithStopCheck { param($Seconds, $StopPath) return $false }
        function Write-WorkerLog { param($Message) }
        function Save-ExitNodeSnapshot { param($Directory, $Hash, $Node) }
        function Update-WorkerStatus {
            param($Values)
            foreach ($key in $Values.Keys) { $script:status[$key] = $Values[$key] }
        }
        function Set-WorkerState {
            param($State, $Values)
            $script:status.state = $State
            Update-WorkerStatus $Values
        }
        function Invoke-SafeExitUpdate {
            param($Previous, $Candidate, $ServiceId, $NodeHash, $Port,
                $RuntimeDirectory, $SingBoxDirectory, $ProbeTimeoutSec, $StartupDelayMs, $StopPath,
                [switch]$AllowProtocolFallback, $StageProbeCount, $StageProbeIntervalMs)
            $script:recoveries++
            if ($scenario -eq 'fallback') {
                Assert-Test ($Candidate.protocol -eq 'anytls' -and $AllowProtocolFallback -and $StageProbeCount -eq 3) 'Worker did not validate a protocol backup.'
            } else { Assert-Test ($Previous -eq $Candidate) 'Unexpected candidate change.' }
            return [pscustomobject]@{
                ServiceId = if ($scenario -in @('recovered', 'fallback')) { [UIntPtr]100 } else { [UIntPtr]99 }
                Node = if ($scenario -eq 'fallback') { $Candidate } else { $Previous }
                State = switch ($scenario) {
                    recovered { 'updated' }
                    fallback { 'updated' }
                    lock-busy { 'update-pending' }
                    default { 'validation-failed' }
                }
                ErrorHash = $null
            }
        }
        . $transition
        Assert-Test ($script:closed -eq 0) 'Health threshold closed the live listener.'
        if ($scenario -eq 'healthy') {
            Assert-Test ($script:status.healthOk -and $script:status.state -eq 'healthy') 'Healthy transition failed.'
            Assert-Test ($null -eq $script:status.nextRecoveryAt -and $script:status.recoveryAttempt -eq 0) 'Recovery not reset.'
        }
        elseif ($scenario -eq 'transient') {
            Assert-Test (-not $script:status.healthOk -and $script:status.state -eq 'degraded') 'Transient failure hidden.'
            Assert-Test ($script:recoveries -eq 0 -and $null -eq $script:status.nextRecoveryAt) 'Transient failure triggered recovery.'
        }
        else {
            Assert-Test (-not $script:status.healthOk -and $script:status.state -eq 'unhealthy') 'Real outage hidden.'
            Assert-Test ([datetime]$script:status.nextRecoveryAt -gt [datetime]$now) 'No recovery cooldown.'
            $expectedCalls = if ($scenario -in @('schedule', 'waiting')) { 0 } else { 1 }
            Assert-Test ($script:recoveries -eq $expectedCalls) 'Recovery ignored its schedule.'
            Assert-Test ($serviceId -ne [UIntPtr]::Zero) 'Failed recovery lost the listener.'
            if ($scenario -eq 'fallback') {
                Assert-Test ($nodeInfo.Node.id -eq 'backup' -and $nodeInfo.FallbackActive -and
                    $script:status.protocol -eq 'anytls' -and $script:status.serverAddress -eq '192.0.2.2') 'Actual fallback metadata lost.'
            }
        }
        $script:transitions[$scenario] = $script:status.Clone()
    }
}
Run-Test 'Recovery backoff is bounded and staggered by port' {
    $first = Get-ExitRecoveryDelaySeconds -Attempt 0 -Port 39020
    $other = Get-ExitRecoveryDelaySeconds -Attempt 0 -Port 39021
    $last = Get-ExitRecoveryDelaySeconds -Attempt 20 -Port 39020
    Assert-Test ($first -ge 30 -and $first -ne $other) 'Exits retry together.'
    Assert-Test ($last -gt $first -and $last -le 330) 'Retry delay not bounded.'
}
Run-Test 'Dashboard forwards current recovery status and tolerates old workers' {
    $dashboardAst = [Management.Automation.Language.Parser]::ParseFile(
        "$root/scripts/dashboard.ps1", [ref]$tokens, [ref]$errors)
    $definition = $dashboardAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-DashboardSnapshot'
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
    $statusPath = 'fixture-status'; $supervisorPath = 'fixture-supervisor'; $ledgerPath = 'fixture-ledger'
    $runtimeDirectory = Join-Path ([IO.Path]::GetTempPath()) 'health-fixture-unwritten'
    $script:taskCache = @{ state = 'Running' }; $script:taskCacheAt = Get-Date
    $taskCacheSeconds = 60
    $script:nineRouterCache = @{ pools = @(); connections = @() }
    $script:nineRouterCacheAt = Get-Date; $nineRouterCacheSeconds = 60
    $script:fixtureWorker = [pscustomobject]@{
        workerPid = 123; healthOk = $true; state = 'healthy'; exitIpOk = $false
        healthTarget = 'www.gstatic.com'; recoveryState = 'scheduled'
        recoveryAttempt = 2; nextRecoveryAt = (Get-Date).ToUniversalTime().AddMinutes(1).ToString('o')
    }
    function Test-ProcessAlive { param($ProcessId) return $true }
    function Get-DashboardPoolPlan { param($Status, $Pools, $Connections) return @() }
    function Get-DashboardSubscriptionStatus { return @{ state = 'missing' } }
    function Read-JsonFile {
        param($Path)
        if ($Path -eq 'fixture-status') {
            return [pscustomobject]@{
                state = 'running'; brokerPid = 456; selectedCount = 1
                exits = @([pscustomobject]@{ nodeHash = 'fixture'; port = 39999; workerPid = 123; state = 'running' })
            }
        }
        if ($Path -like '*workers*') { return $script:fixtureWorker }
        return $null
    }
    $snapshot = Get-DashboardSnapshot
    Assert-Test ($snapshot.exits[0].exitIpOk -eq $false -and
        $snapshot.exits[0].healthTarget -eq 'www.gstatic.com' -and
        $snapshot.exits[0].recoveryAttempt -eq 2) 'New worker metadata lost.'
    foreach ($key in @('exitIpOk', 'healthTarget', 'recoveryState', 'recoveryAttempt', 'nextRecoveryAt')) {
        $script:fixtureWorker.PSObject.Properties.Remove($key)
    }
    $snapshot = Get-DashboardSnapshot
    Assert-Test ($snapshot.exits[0].healthOk -and $null -eq $snapshot.exits[0].exitIpOk) 'Old worker status broke.'
    $script:fixtureWorker.workerPid = 999
    $snapshot = Get-DashboardSnapshot
    Assert-Test (-not $snapshot.exits[0].healthOk -and $null -eq $snapshot.exits[0].nextRecoveryAt) 'Stale worker accepted.'
}
if ($script:failures.Count) { throw "$($script:failures.Count) health regression test(s) failed." }
if ($Json) { Write-Output ('HEALTH-RESULT:' + ($script:transitions | ConvertTo-Json -Depth 8 -Compress)) }
