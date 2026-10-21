$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. "$root/scripts/lib/broker-common.ps1"
. "$root/scripts/lib/vpncheap-state.ps1"
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    "$root/scripts/broker.ps1", [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Broker parse failed.' }
foreach ($definition in $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}

$RuntimeDirectory = Join-Path ([IO.Path]::GetTempPath()) ("broker-test-" + [guid]::NewGuid())
[IO.Directory]::CreateDirectory($RuntimeDirectory) | Out-Null
$leasePath = Join-Path $RuntimeDirectory 'port-leases.json'
$brokerLogPath = Join-Path $RuntimeDirectory 'broker.log'
$PortBase = 39001
$script:failures = [System.Collections.Generic.List[string]]::new()
function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Run-Test([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        Write-Output "PASS $Name"
    }
    catch {
        $script:failures.Add("$Name : $($_.Exception.Message)")
        Write-Output "FAIL $Name : $($_.Exception.Message)"
    }
}

try {
    Run-Test 'Concurrent run must not clean up another broker workers' {
        $script:cleanupCalled = $false
        function Ensure-RuntimeDirectories {}
        function Stop-OrphanWorkers {
            $script:cleanupCalled = $true
            throw 'Another broker workers would be killed.'
        }
        $lock = [IO.File]::Open((Join-Path $RuntimeDirectory 'broker.lock'),
            [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            Invoke-BrokerRun
            Assert-Test (-not $script:cleanupCalled) 'Cleanup ran without owning the lock.'
        }
        finally { $lock.Dispose() }
    }

    Run-Test 'Occupied restart keeps its lease and waits without starting a worker' {
        $leases = @{ 'node-a' = 39001 }
        $retired = [System.Collections.Generic.List[int]]::new()
        $workers = @{}
        $pendingRestarts = @{
            'node-a' = [pscustomobject]@{ DueAt = (Get-Date).AddSeconds(-1); RestartCount = 2 }
        }
        $desired = @([pscustomobject]@{ NodeHash = 'node-a' })
        $desiredHashes = [System.Collections.Generic.HashSet[string]]::new()
        $desiredHashes.Add('node-a') | Out-Null
        $script:started = $false
        function Test-TcpPortListening { param($Port) return $Port -eq 39001 }
        function Start-WorkerEntry { $script:started = $true; return 'unexpected-worker' }
        function Save-LeaseState { throw 'Lease was rewritten on port contention.' }
        function Write-BrokerLog { param($Message) }

        $loop = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
            $node.Body.Extent.Text.Contains('$pending.DueAt')
        }, $true)
        Assert-Test ($null -ne $loop) 'Restart loop was not found.'
        . ([scriptblock]::Create($loop.Extent.Text))
        Assert-Test ($leases['node-a'] -eq 39001) 'Existing node moved to a different port.'
        Assert-Test ($retired.Count -eq 0) 'Existing port was retired.'
        Assert-Test (-not $script:started) 'Started worker on an occupied port.'
        Assert-Test ($pendingRestarts.ContainsKey('node-a')) 'Retry was lost.'
    }

    Run-Test 'Lock is released when broker startup fails' {
        function Ensure-RuntimeDirectories {}
        function Invoke-BrokerRunCore { throw 'fixture-startup-failure' }
        $failed = $false
        try { Invoke-BrokerRun } catch {
            Assert-Test ($_.Exception.Message -eq 'fixture-startup-failure') 'Unexpected failure.'
            $failed = $true
        }
        Assert-Test $failed 'Startup failure was swallowed.'
        $lock = [IO.File]::Open((Join-Path $RuntimeDirectory 'broker.lock'),
            [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $lock.Dispose()
    }

    Run-Test 'Duplicate CLI run exits before touching live state' {
        $lock = [IO.File]::Open((Join-Path $RuntimeDirectory 'broker.lock'),
            [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $output = & pwsh -NoProfile -File "$root/scripts/broker.ps1" -Action run -RuntimeDirectory $RuntimeDirectory
            Assert-Test ($LASTEXITCODE -eq 0) 'Duplicate process did not exit successfully.'
            Assert-Test (($output -join "`n") -match 'duplicate run skipped') 'Duplicate did not respect the lock.'
            Assert-Test (-not (Test-Path (Join-Path $RuntimeDirectory 'supervisor.json'))) 'Duplicate published state.'
        }
        finally { $lock.Dispose() }
    }

    Run-Test 'Initial startup waits on occupied port then reuses it after release' {
        $workers = @{}
        $pendingRestarts = @{}
        $exit = [pscustomobject]@{ NodeHash = 'node-a' }
        function Test-TcpPortListening { return $true }
        function Write-BrokerLog { param($Message) }
        function Start-WorkerEntry { throw 'Unexpected worker start.' }
        Start-LeasedWorker -Exit $exit -Port 39001 -Workers $workers -PendingRestarts $pendingRestarts
        Assert-Test ($workers.Count -eq 0) 'Worker started on occupied port.'
        Assert-Test ($pendingRestarts['node-a'].Reason -eq 'port-conflict') 'Conflict not reported.'
        Assert-Test ($pendingRestarts['node-a'].Port -eq 39001) 'Pending port changed.'
        function Test-TcpPortListening { return $false }
        function Start-WorkerEntry { param($Exit, $Port, $RestartCount) return [pscustomobject]@{ Port = $Port } }
        $pendingRestarts.Clear()
        Start-LeasedWorker -Exit $exit -Port 39001 -Workers $workers -PendingRestarts $pendingRestarts
        Assert-Test ($workers['node-a'].Port -eq 39001) 'Released lease was not reused.'
        Assert-Test ($pendingRestarts.Count -eq 0) 'Successful start left a pending retry.'
    }

    Run-Test 'Deselection and reselection preserve node leases' {
        $leases = @{ 'node-a' = 39001; 'node-b' = 39002 }
        $retired = [System.Collections.Generic.List[int]]::new()
        Update-LeasesForDesired -Desired @([pscustomobject]@{ NodeHash = 'node-b' }) -Leases $leases -Retired $retired
        Update-LeasesForDesired -Desired @([pscustomobject]@{ NodeHash = 'node-a' }) -Leases $leases -Retired $retired
        Assert-Test ($leases['node-a'] -eq 39001 -and $leases['node-b'] -eq 39002) 'Reselection changed leases.'
    }

    Run-Test 'Pending conflict cannot reuse stale healthy worker status' {
        $script:instanceId = 'test'
        $script:startedAt = '2026-10-21T00:00:00Z'
        $statusPath = Join-Path $RuntimeDirectory 'status.json'
        $MaxExits = 1
        $Protocol = 'hysteria2'
        $Country = ''
        function Get-WorkerStatus {
            return [pscustomobject]@{
                state = 'healthy'; healthOk = $true; workerPid = -1; port = 39001
                protocol = 'hysteria2'; country = 'HK'; httpStatus = '204'
                latencyMs = 100; exitIpHash = 'old'; consecutiveFailures = 0
                failureStage = $null; lastCheckAt = $null
            }
        }
        $pending = @{
            'node-a' = [pscustomobject]@{ RestartCount = 1; Reason = 'port-conflict'; Port = 39001 }
        }
        $desired = @([pscustomobject]@{ NodeHash = 'node-a'; NodeName = 'fixture'; Protocol = 'hysteria2'; Country = 'HK' })
        Write-BrokerStatus -State running -Workers @{} -PendingRestarts $pending -Desired $desired -Candidates $desired -ExitConfig $null -RefreshErrorHash $null
        $status = Read-JsonFile -Path $statusPath
        Assert-Test ($status.healthyCount -eq 0) 'Pending worker counted as healthy.'
        Assert-Test ($status.exits[0].state -eq 'port-conflict') 'Conflict hidden by stale worker state.'
        Assert-Test (-not $status.exits[0].healthOk) 'Stale health flag leaked.'
    }
}
finally {
    # This directory is created by this test and never points at the live runtime.
    $target = [IO.Path]::GetFullPath($RuntimeDirectory)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($target.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $target) -like 'broker-test-*') {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}
if ($script:failures.Count) { throw "$($script:failures.Count) regression test(s) failed." }
