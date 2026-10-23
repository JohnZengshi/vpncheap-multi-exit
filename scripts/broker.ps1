[CmdletBinding()]
param(
    [ValidateSet('run', 'start', 'stop', 'status')]
    [string]$Action = 'run',

    [int]$PortBase = 39001,

    [int]$MaxExits = 13,

    [string]$Protocol = 'hysteria2',

    [string]$Country = '',

    [int]$HealthIntervalSec = 30,

    [int]$ProbeTimeoutSec = 20,

    [int]$FailureThreshold = 3,

    [int]$CatalogRefreshSec = 300,

    [int]$StartupTimeoutSec = 60,

    [string]$RuntimeDirectory,

    [string]$StatePath = "$env:APPDATA\vpncheap\app_state.json",

    [string]$ManagedAssemblyPath = 'C:\Program Files\VPNCheap\VpncheapWindows.Core.dll',

    [string]$SingBoxDllPath = 'C:\Program Files\VPNCheap\sing-box.dll'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot\lib\vpncheap-state.ps1"
. "$PSScriptRoot\lib\broker-common.ps1"
. "$PSScriptRoot\lib\subscription-state.ps1"

$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($RuntimeDirectory)) {
    $RuntimeDirectory = Join-Path $projectRoot 'runtime'
}
$RuntimeDirectory = [System.IO.Path]::GetFullPath($RuntimeDirectory)

$workerScript = Join-Path $PSScriptRoot 'worker.ps1'
$workerDirectory = Join-Path $RuntimeDirectory 'workers'
$stopDirectory = Join-Path $RuntimeDirectory 'stop'
$logDirectory = Join-Path $RuntimeDirectory 'logs'
$statusPath = Join-Path $RuntimeDirectory 'status.json'
$supervisorPath = Join-Path $RuntimeDirectory 'supervisor.json'
$supervisorStopPath = Join-Path $RuntimeDirectory 'stop.supervisor'
$leasePath = Join-Path $RuntimeDirectory 'port-leases.json'
$exitConfigPath = Join-Path $RuntimeDirectory 'exit-config.json'
$brokerLogPath = Join-Path $logDirectory 'broker.log'

function Write-BrokerLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-RedactedLog -Path $brokerLogPath -Message $Message
}

function Ensure-RuntimeDirectories {
    foreach ($directory in @($RuntimeDirectory, $workerDirectory, $stopDirectory, $logDirectory)) {
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
    }
}

function Get-CandidateNodes {
    $nodes = @(Get-SubscriptionNodes -RuntimeDirectory $RuntimeDirectory -StatePath $StatePath -AssemblyPath $ManagedAssemblyPath)
    if ($nodes.Count -eq 0) { throw 'subscription-empty-catalog' }
    $result = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $claimed = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $RuntimeDirectory 'nodes') -Filter '*.dpapi.json' -ErrorAction SilentlyContinue)) {
        $slotHash = $file.Name -replace '\.dpapi\.json$', ''
        $saved = Read-ProtectedSubscriptionFile $file.FullName
        $replacement = Resolve-ExitNodeReplacement -Previous $saved.node -Nodes $nodes
        $node = if ($null -ne $replacement) { $replacement } else { $saved.node }
        $nodeProtocol = [string](Get-JsonProperty $node 'protocol')
        $nodeCountry = [string](Get-JsonProperty $node 'country_code')
        $fallbackActive = [bool](Get-OptionalProperty $saved 'fallbackActive')
        if (($Protocol -and $nodeProtocol -ne $Protocol -and -not $fallbackActive) -or
            ($Country -and $nodeCountry -ne $Country)) { continue }
        $seen.Add($slotHash) | Out-Null
        if ($null -ne $replacement) { $claimed.Add((Get-ExitNodeIdentity $replacement).SourceHash) | Out-Null }
        $result.Add([pscustomobject]@{
            NodeHash = $slotHash; NodeName = [string](Get-JsonProperty $node 'name')
            Protocol = $nodeProtocol; Country = $nodeCountry; NeedsReview = ($null -eq $replacement)
        })
    }
    foreach ($node in $nodes) {
            if (-not [bool](Get-JsonProperty -Object $node -Name 'online')) {
                continue
            }
            if ($null -eq (Get-JsonProperty -Object $node -Name 'raw_outbound')) {
                continue
            }

            $nodeProtocol = [string](Get-JsonProperty -Object $node -Name 'protocol')
            if (-not [string]::IsNullOrWhiteSpace($Protocol) -and $nodeProtocol -ne $Protocol) {
                continue
            }

            $nodeCountry = [string](Get-JsonProperty -Object $node -Name 'country_code')
            if (-not [string]::IsNullOrWhiteSpace($Country) -and $nodeCountry -ne $Country) {
                continue
            }

            $nodeId = [string](Get-JsonProperty -Object $node -Name 'id')
            if ([string]::IsNullOrWhiteSpace($nodeId)) {
                continue
            }

            $nodeHash = Get-StringSha256Short -Text $nodeId
            if ($claimed.Contains($nodeHash) -or -not $seen.Add($nodeHash)) {
                continue
            }

            $result.Add([pscustomobject]@{
                NodeHash = $nodeHash
                NodeName = [string](Get-JsonProperty -Object $node -Name 'name')
                Protocol = $nodeProtocol
                Country = $nodeCountry
                NeedsReview = $false
            })
    }

    # Retain legacy slots whose provider IDs disappeared before snapshots existed.
    # Missing metadata is not permission to guess a replacement or retire its port.
    $previousStatus = Read-JsonFile $statusPath
    foreach ($exit in @(Get-OptionalProperty $previousStatus 'exits')) {
        if ($null -eq $exit) { continue }
        $hash = [string]$exit.nodeHash
        if (($Protocol -and $exit.protocol -ne $Protocol) -or ($Country -and $exit.country -ne $Country)) { continue }
        if ($seen.Add($hash)) {
            $result.Add([pscustomobject]@{
                NodeHash = $hash; NodeName = [string]$exit.nodeName
                Protocol = [string]$exit.protocol; Country = [string]$exit.country; NeedsReview = $true
            })
        }
    }
    return @($result | Sort-Object -Property Country, NodeHash)
}

function Get-ExitConfig {
    $document = Read-JsonFile -Path $exitConfigPath
    $maxExits = 0
    $hashes = New-Object System.Collections.Generic.List[string]
    if ($null -eq $document) {
        return [pscustomobject]@{
            MaxExits = 0
            NodeHashes = @()
        }
    }

    $rawMaxExits = Get-OptionalProperty -Object $document -Name 'maxExits'
    $parsedMaxExits = 0
    if ($null -ne $rawMaxExits -and [int]::TryParse([string]$rawMaxExits, [ref]$parsedMaxExits)) {
        if ($parsedMaxExits -ge 1 -and $parsedMaxExits -le 64) {
            $maxExits = $parsedMaxExits
        }
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($item in @(Get-OptionalProperty -Object $document -Name 'nodeHashes')) {
        $hash = ([string]$item).Trim().ToLowerInvariant()
        if ($hash -match '^[0-9a-f]{8,64}$' -and $seen.Add($hash)) {
            $hashes.Add($hash) | Out-Null
        }
    }

    return [pscustomobject]@{
        MaxExits = $maxExits
        NodeHashes = @($hashes)
    }
}

function Get-DesiredExits {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Candidates,

        [AllowNull()]
        [object]$Config
    )

    $limit = $MaxExits
    if ($null -ne $Config -and [int]$Config.MaxExits -gt 0) {
        $limit = [int]$Config.MaxExits
    }
    $limit = [Math]::Max(1, [Math]::Min(64, $limit))

    $hashes = @()
    if ($null -ne $Config) {
        $hashes = @($Config.NodeHashes)
    }
    if ($hashes.Count -eq 0) {
        return @($Candidates | Select-Object -First $limit)
    }

    $wanted = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($hash in $hashes) {
        $wanted.Add([string]$hash) | Out-Null
    }

    return @($Candidates | Where-Object { $wanted.Contains([string]$_.NodeHash) } | Select-Object -First $limit)
}

function Get-ExitConfigRevision {
    if (-not (Test-Path -LiteralPath $exitConfigPath)) {
        return 'missing'
    }

    $item = Get-Item -LiteralPath $exitConfigPath
    return ('{0}:{1}' -f $item.LastWriteTimeUtc.Ticks, $item.Length)
}

function Get-SubscriptionRevision {
    return (@($StatePath, (Join-Path $RuntimeDirectory 'catalog.dpapi.json')) | ForEach-Object {
        $item = Get-Item -LiteralPath $_ -ErrorAction SilentlyContinue
        if ($null -ne $item) { '{0}:{1}' -f $item.LastWriteTimeUtc.Ticks, $item.Length }
    }) -join '|'
}

function Get-LeaseState {
    $leases = @{}
    $retired = New-Object System.Collections.Generic.List[int]
    $document = Read-JsonFile -Path $leasePath
    if ($null -ne $document) {
        $leaseObject = Get-OptionalProperty -Object $document -Name 'leases'
        if ($null -ne $leaseObject) {
            foreach ($property in $leaseObject.PSObject.Properties) {
                $port = 0
                if ([int]::TryParse([string]$property.Value, [ref]$port)) {
                    $leases[$property.Name] = $port
                }
            }
        }

        $retiredValue = Get-OptionalProperty -Object $document -Name 'retired'
        if ($null -ne $retiredValue) {
            foreach ($item in @($retiredValue)) {
                $port = 0
                if ([int]::TryParse([string]$item, [ref]$port)) {
                    $retired.Add($port)
                }
            }
        }
    }

    return [pscustomobject]@{
        Leases = $leases
        Retired = $retired
    }
}

function Save-LeaseState {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Leases,

        [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
        [System.Collections.Generic.List[int]]$Retired
    )

    Write-JsonFileAtomic -Path $leasePath -Value ([ordered]@{
        schemaVersion = 1
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
        leases = $Leases
        retired = @($Retired | Select-Object -Unique)
    })
}

function Get-FreePort {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Leases,

        [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
        [System.Collections.Generic.List[int]]$Retired
    )

    $used = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($port in $Leases.Values) {
        $used.Add([int]$port) | Out-Null
    }
    foreach ($port in $Retired) {
        $used.Add([int]$port) | Out-Null
    }

    for ($offset = 0; $offset -lt 999; $offset++) {
        $candidate = $PortBase + $offset
        if ($used.Contains($candidate)) {
            continue
        }
        if (Test-TcpPortListening -Port $candidate) {
            $Retired.Add($candidate)
            $used.Add($candidate) | Out-Null
            continue
        }

        return $candidate
    }

    throw 'No free loopback port is available in the configured range.'
}

function Update-LeasesForDesired {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Desired,

        [Parameter(Mandatory = $true)]
        [hashtable]$Leases,

        [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
        [System.Collections.Generic.List[int]]$Retired
    )

    $desiredHashes = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($item in $Desired) {
        $desiredHashes.Add([string]$item.NodeHash) | Out-Null
    }

    # Keep leases for deselected nodes so reselecting them reuses the same port
    # and does not invalidate the matching 9Router proxy pool.
    $changed = $false
    foreach ($item in $Desired) {
        $hash = [string]$item.NodeHash
        if (-not $Leases.ContainsKey($hash)) {
            $Leases[$hash] = Get-FreePort -Leases $Leases -Retired $Retired
            $changed = $true
        }
    }

    if ($changed) {
        Save-LeaseState -Leases $Leases -Retired $Retired
    }
}

function Get-WorkerStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NodeHash
    )

    return Read-JsonFile -Path (Join-Path $workerDirectory "$NodeHash.json")
}

function Start-WorkerEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Exit,

        [Parameter(Mandatory = $true)]
        [int]$Port,

        [int]$RestartCount = 0
    )

    $nodeHash = [string]$Exit.NodeHash
    $workerStatusPath = Join-Path $workerDirectory "$nodeHash.json"
    $workerStopPath = Join-Path $stopDirectory "$nodeHash.stop"
    foreach ($path in @($workerStatusPath, $workerStopPath)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }

    $arguments = @(
        '-NodeHash', $nodeHash,
        '-Port', [string]$Port,
        '-StatePath', $StatePath,
        '-ManagedAssemblyPath', $ManagedAssemblyPath,
        '-SingBoxDllPath', $SingBoxDllPath,
        '-HealthIntervalSec', [string]$HealthIntervalSec,
        '-ProbeTimeoutSec', [string]$ProbeTimeoutSec,
        '-FailureThreshold', [string]$FailureThreshold,
        '-RuntimeDirectory', $RuntimeDirectory,
        '-LogPath', (Join-Path $logDirectory "$nodeHash.log")
    )

    $process = Start-DetachedPowerShell -ScriptPath $workerScript -ScriptArguments $arguments -WorkingDirectory $projectRoot
    Write-BrokerLog -Message ("worker-start node={0} port={1} pid={2} restart={3}" -f $nodeHash, $Port, $process.Id, $RestartCount)

    return [pscustomobject]@{
        NodeHash = $nodeHash
        Port = $Port
        Process = $process
        StartedAt = Get-Date
        RestartCount = $RestartCount
        StopRequested = $false
    }
}

function Stop-WorkerEntry {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Worker,

        [int]$TimeoutSec = 15
    )

    $nodeHash = [string]$Worker.NodeHash
    $stopPath = Join-Path $stopDirectory "$nodeHash.stop"
    Set-Content -LiteralPath $stopPath -Value 'stop' -Encoding ascii

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $Worker.Process.Refresh()
            if ($Worker.Process.HasExited) {
                break
            }
        }
        catch {
            break
        }
        Start-Sleep -Milliseconds 250
    }

    try {
        $Worker.Process.Refresh()
        if (-not $Worker.Process.HasExited) {
            $Worker.Process.Kill($true)
            $Worker.Process.WaitForExit(5000) | Out-Null
            Write-BrokerLog -Message ("worker-kill node={0} pid={1}" -f $nodeHash, $Worker.Process.Id)
        }
    }
    catch {
    }

    if (Test-Path -LiteralPath $stopPath) {
        Remove-Item -LiteralPath $stopPath -Force
    }

    Write-BrokerLog -Message ("worker-stop node={0} port={1}" -f $nodeHash, $Worker.Port)
}

function Start-LeasedWorker {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Exit,
        [Parameter(Mandatory = $true)]
        [int]$Port,
        [Parameter(Mandatory = $true)]
        [hashtable]$Workers,
        [Parameter(Mandatory = $true)]
        [hashtable]$PendingRestarts,
        [int]$RestartCount = 0
    )

    $hash = [string]$Exit.NodeHash
    if (Test-TcpPortListening -Port $Port) {
        $PendingRestarts[$hash] = [pscustomobject]@{
            DueAt = (Get-Date).AddSeconds(15)
            RestartCount = $RestartCount
            Port = $Port
            Reason = 'port-conflict'
        }
        Write-BrokerLog -Message ("port-conflict node={0} port={1} retryIn=15s" -f $hash, $Port)
        return
    }

    $Workers[$hash] = Start-WorkerEntry -Exit $Exit -Port $Port -RestartCount $RestartCount
}

function Stop-AllWorkerEntries {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Workers,

        [int]$TimeoutSec = 20
    )

    foreach ($hash in @($Workers.Keys)) {
        $stopPath = Join-Path $stopDirectory "$hash.stop"
        Set-Content -LiteralPath $stopPath -Value 'stop' -Encoding ascii
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $alive = $false
        foreach ($hash in @($Workers.Keys)) {
            try {
                $process = $Workers[$hash].Process
                $process.Refresh()
                if (-not $process.HasExited) {
                    $alive = $true
                    break
                }
            }
            catch {
            }
        }
        if (-not $alive) {
            break
        }
        Start-Sleep -Milliseconds 300
    }

    foreach ($hash in @($Workers.Keys)) {
        $worker = $Workers[$hash]
        try {
            $process = $worker.Process
            $process.Refresh()
            if (-not $process.HasExited) {
                $process.Kill($true)
                $process.WaitForExit(5000) | Out-Null
                Write-BrokerLog -Message ("worker-kill node={0} pid={1}" -f $hash, $process.Id)
            }
        }
        catch {
        }

        $stopPath = Join-Path $stopDirectory "$hash.stop"
        if (Test-Path -LiteralPath $stopPath) {
            Remove-Item -LiteralPath $stopPath -Force
        }
    }
}

function Stop-OrphanWorkers {
    $fileArgument = '(?:^|\s)"?-File"?\s+(?:"{0}"|{0})(?=\s|$)' -f [regex]::Escape($workerScript)
    $runtimeArgument = '(?:^|\s)"?-RuntimeDirectory"?\s+(?:"{0}"|{0})(?=\s|$)' -f [regex]::Escape($RuntimeDirectory)
    $workers = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessId -ne $PID -and
        -not [string]::IsNullOrWhiteSpace([string]$_.CommandLine) -and
        [string]$_.CommandLine -match $fileArgument -and
        [string]$_.CommandLine -match $runtimeArgument
    }

    foreach ($worker in @($workers)) {
        try {
            $process = [System.Diagnostics.Process]::GetProcessById([int]$worker.ProcessId)
            $process.Kill($true)
            $process.WaitForExit(5000) | Out-Null
            Write-BrokerLog -Message ("orphan-kill pid={0}" -f $worker.ProcessId)
        }
        catch {
        }
    }
}

function Get-SupervisorRecord {
    return Read-JsonFile -Path $supervisorPath
}

function Get-StopRequested {
    return Test-Path -LiteralPath $supervisorStopPath
}

function Write-BrokerStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$State,

        [Parameter(Mandatory = $true)]
        [hashtable]$Workers,

        [Parameter(Mandatory = $true)]
        [hashtable]$PendingRestarts,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Desired,

        [AllowNull()]
        [object[]]$Candidates,

        [AllowNull()]
        [object]$ExitConfig,

        [AllowNull()]
        [string]$RefreshErrorHash
    )

    $exitRows = New-Object System.Collections.Generic.List[object]
    $healthyCount = 0
    foreach ($exit in $Desired) {
        $hash = [string]$exit.NodeHash
        $workerStatus = Get-WorkerStatus -NodeHash $hash
        $workerEntry = if ($Workers.ContainsKey($hash)) { $Workers[$hash] } else { $null }
        $processState = 'missing'
        $workerPid = $null
        $restartCount = 0

        if ($null -ne $workerEntry) {
            $workerPid = $workerEntry.Process.Id
            $restartCount = $workerEntry.RestartCount
            try {
                $processState = if ($workerEntry.Process.HasExited) { 'exited' } else { 'running' }
            }
            catch {
                $processState = 'unknown'
            }
        }
        elseif ($PendingRestarts.ContainsKey($hash)) {
            $processState = 'restart-pending'
            $restartCount = $PendingRestarts[$hash].RestartCount
        }

        $rowState = if ($null -ne $workerStatus) { [string]$workerStatus.state } else { 'starting' }
        $healthOk = $null -ne $workerEntry -and $processState -eq 'running' -and
            $null -ne $workerStatus -and $workerStatus.workerPid -eq $workerPid -and
            [bool]$workerStatus.healthOk
        if ($PendingRestarts.ContainsKey($hash)) {
            $reason = [string](Get-OptionalProperty -Object $PendingRestarts[$hash] -Name 'Reason')
            $rowState = if ($reason -eq 'port-conflict') { 'port-conflict' } else { 'restarting' }
        }
        if ($healthOk -and $rowState -eq 'healthy') {
            $healthyCount++
        }

        $exitRows.Add([ordered]@{
            nodeHash = $hash
            nodeName = [string](Get-OptionalProperty -Object $exit -Name 'NodeName')
            protocol = if ($null -ne $workerStatus) { $workerStatus.protocol } else { $exit.Protocol }
            country = if ($null -ne $workerStatus) { $workerStatus.country } else { $exit.Country }
            port = if ($null -ne $workerStatus) {
                $workerStatus.port
            }
            elseif ($null -ne $workerEntry) {
                $workerEntry.Port
            }
            elseif ($PendingRestarts.ContainsKey($hash)) {
                Get-OptionalProperty -Object $PendingRestarts[$hash] -Name 'Port'
            }
            else {
                $null
            }
            state = $rowState
            processState = $processState
            healthOk = $healthOk
            httpStatus = if ($null -ne $workerStatus) { $workerStatus.httpStatus } else { $null }
            latencyMs = if ($null -ne $workerStatus) { $workerStatus.latencyMs } else { $null }
            exitIpHash = if ($null -ne $workerStatus) { $workerStatus.exitIpHash } else { $null }
            exitIpOk = Get-OptionalProperty $workerStatus 'exitIpOk'
            healthTarget = Get-OptionalProperty $workerStatus 'healthTarget'
            recoveryState = Get-OptionalProperty $workerStatus 'recoveryState'
            recoveryAttempt = Get-OptionalProperty $workerStatus 'recoveryAttempt'
            nextRecoveryAt = Get-OptionalProperty $workerStatus 'nextRecoveryAt'
            recoveryErrorHash = Get-OptionalProperty $workerStatus 'recoveryErrorHash'
            fallbackActive = [bool](Get-OptionalProperty $workerStatus 'fallbackActive')
            activeNodeHash = Get-OptionalProperty $workerStatus 'activeNodeHash'
            activeNodeName = Get-OptionalProperty $workerStatus 'activeNodeName'
            serverAddress = Get-OptionalProperty $workerStatus 'serverAddress'
            serverPort = Get-OptionalProperty $workerStatus 'serverPort'
            consecutiveFailures = if ($null -ne $workerStatus) { $workerStatus.consecutiveFailures } else { 0 }
            failureStage = if ($null -ne $workerStatus) { $workerStatus.failureStage } else { $null }
            lastCheckAt = if ($null -ne $workerStatus) { $workerStatus.lastCheckAt } else { $null }
            workerPid = $workerPid
            restartCount = $restartCount
            needsReview = [bool](Get-OptionalProperty $exit 'NeedsReview')
            updateState = Get-OptionalProperty $workerStatus 'updateState'
            updateErrorHash = Get-OptionalProperty $workerStatus 'updateErrorHash'
        })
    }

    $catalogHash = $null
    if ($null -ne $Candidates) {
        $catalogHash = Get-StringSha256Short -Text (($Candidates | ForEach-Object { $_.NodeHash }) -join "`n") -Length 24
    }

    $candidateCount = 0
    if ($null -ne $Candidates) {
        $candidateCount = $Candidates.Count
    }

    $selectedCount = $Desired.Count
    $desiredHashes = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($item in $Desired) {
        $desiredHashes.Add([string]$item.NodeHash) | Out-Null
    }

    $candidateRows = @()
    if ($null -ne $Candidates) {
        $candidateRows = @($Candidates | ForEach-Object {
            [ordered]@{
                nodeHash = [string]$_.NodeHash
                nodeName = [string]$_.NodeName
                protocol = [string]$_.Protocol
                country = [string]$_.Country
                selected = $desiredHashes.Contains([string]$_.NodeHash)
                needsReview = [bool](Get-OptionalProperty $_ 'NeedsReview')
            }
        })
    }

    $effectiveMaxExits = $MaxExits
    $selectionMode = 'auto'
    if ($null -ne $ExitConfig -and [int]$ExitConfig.MaxExits -gt 0) {
        $effectiveMaxExits = [int]$ExitConfig.MaxExits
    }
    if ($null -ne $ExitConfig -and @($ExitConfig.NodeHashes).Count -gt 0) {
        $selectionMode = 'manual'
    }

    $document = [ordered]@{
        schemaVersion = 1
        kind = 'vpncheap-broker'
        state = $State
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
        brokerPid = $PID
        instanceId = $script:instanceId
        startedAt = $script:startedAt
        portBase = $PortBase
        maxExits = $effectiveMaxExits
        configuredMaxExits = if ($null -ne $ExitConfig -and [int]$ExitConfig.MaxExits -gt 0) { [int]$ExitConfig.MaxExits } else { $null }
        selectionMode = $selectionMode
        protocol = $Protocol
        country = $Country
        catalogHash = $catalogHash
        candidateCount = $candidateCount
        selectedCount = $selectedCount
        healthyCount = $healthyCount
        refreshErrorHash = $RefreshErrorHash
        exits = $exitRows.ToArray()
        candidates = $candidateRows
    }

    Write-JsonFileAtomic -Path $statusPath -Value $document
}

function Invoke-BrokerRun {
    Ensure-RuntimeDirectories
    $lockPath = Join-Path $RuntimeDirectory 'broker.lock'
    try {
        $runLock = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    }
    catch [System.IO.IOException] {
        if (($_.Exception.HResult -band 0xffff) -notin @(32, 33)) { throw }
        Write-Output 'Broker already running for this runtime; duplicate run skipped.'
        return
    }

    try {
        Invoke-BrokerRunCore
    }
    finally {
        # Keep the lock file: deleting it after release races the next owner.
        $runLock.Dispose()
    }
}

function Invoke-BrokerRunCore {
    Ensure-RuntimeDirectories
    Stop-OrphanWorkers

    if (Test-Path -LiteralPath $supervisorStopPath) {
        Remove-Item -LiteralPath $supervisorStopPath -Force
    }
    foreach ($stopFile in @(Get-ChildItem -LiteralPath $stopDirectory -Filter '*.stop' -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $stopFile.FullName -Force
    }

    $script:instanceId = [guid]::NewGuid().ToString()
    $script:startedAt = (Get-Date).ToUniversalTime().ToString('o')
    $candidates = @(Get-CandidateNodes)
    if ($candidates.Count -eq 0) {
        throw 'No online nodes matched the requested protocol and country filters.'
    }

    $exitConfig = Get-ExitConfig
    $lastExitConfigRevision = Get-ExitConfigRevision
    $desired = @(Get-DesiredExits -Candidates $candidates -Config $exitConfig)
    $leaseState = Get-LeaseState
    $leases = $leaseState.Leases
    $retired = $leaseState.Retired
    Update-LeasesForDesired -Desired $desired -Leases $leases -Retired $retired

    Write-JsonFileAtomic -Path $supervisorPath -Value ([ordered]@{
        schemaVersion = 1
        pid = $PID
        instanceId = $script:instanceId
        startedAt = $script:startedAt
        runtimeDirectory = $RuntimeDirectory
        portBase = $PortBase
        maxExits = if ($exitConfig.MaxExits -gt 0) { $exitConfig.MaxExits } else { $MaxExits }
        configuredMaxExits = if ($exitConfig.MaxExits -gt 0) { $exitConfig.MaxExits } else { $null }
        selectionMode = if (@($exitConfig.NodeHashes).Count -gt 0) { 'manual' } else { 'auto' }
        protocol = $Protocol
        country = $Country
        workerScript = $workerScript
    })

    Write-BrokerLog -Message ("broker-start pid={0} candidates={1} selected={2} protocol={3}" -f $PID, $candidates.Count, $desired.Count, $Protocol)

    $workers = @{}
    $pendingRestarts = @{}
    $lastCatalogRefresh = Get-Date
    $lastSubscriptionRevision = Get-SubscriptionRevision
    $refreshErrorHash = $null
    $state = 'running'

    try {
        foreach ($exit in $desired) {
            $hash = [string]$exit.NodeHash
            Start-LeasedWorker -Exit $exit -Port $leases[$hash] -Workers $workers -PendingRestarts $pendingRestarts
        }

        while ($true) {
            if (Get-StopRequested) {
                $state = 'stopping'
                break
            }

            try {
                Start-SubscriptionRefreshIfDue -RuntimeDirectory $RuntimeDirectory -StatePath $StatePath `
                    -AssemblyPath $ManagedAssemblyPath -ScriptPath (Join-Path $PSScriptRoot 'subscription-refresh.ps1') `
                    -IntervalSec ([Math]::Min(86400, [Math]::Max(60, $CatalogRefreshSec)))
            }
            catch {
                Write-BrokerLog ("subscription-schedule-error errorHash={0}" -f (Get-StringSha256Short $_.Exception.Message -Length 20))
            }

            $configRevision = Get-ExitConfigRevision
            if ($configRevision -ne $lastExitConfigRevision) {
                try {
                    $newExitConfig = Get-ExitConfig
                    $newDesired = @(Get-DesiredExits -Candidates $candidates -Config $newExitConfig)
                    $newDesiredHashes = New-Object 'System.Collections.Generic.HashSet[string]'
                    foreach ($item in $newDesired) {
                        $newDesiredHashes.Add([string]$item.NodeHash) | Out-Null
                    }

                    foreach ($hash in @($workers.Keys)) {
                        if (-not $newDesiredHashes.Contains([string]$hash)) {
                            Stop-WorkerEntry -Worker $workers[$hash]
                            $workers.Remove($hash)
                        }
                    }
                    foreach ($hash in @($pendingRestarts.Keys)) {
                        if (-not $newDesiredHashes.Contains([string]$hash)) {
                            $pendingRestarts.Remove($hash)
                        }
                    }

                    $exitConfig = $newExitConfig
                    $desired = $newDesired
                    Update-LeasesForDesired -Desired $desired -Leases $leases -Retired $retired
                    $lastExitConfigRevision = $configRevision
                    Write-BrokerLog -Message ("exit-config changed mode={0} max={1} selected={2}" -f $(if (@($exitConfig.NodeHashes).Count -gt 0) { 'manual' } else { 'auto' }), $exitConfig.MaxExits, $desired.Count)
                }
                catch {
                    $lastExitConfigRevision = $configRevision
                    Write-BrokerLog -Message ("exit-config-error errorHash={0}" -f (Get-StringSha256Short -Text $_.Exception.Message -Length 20))
                }
            }

            $subscriptionRevision = Get-SubscriptionRevision
            if ($subscriptionRevision -ne $lastSubscriptionRevision -or
                ((Get-Date) - $lastCatalogRefresh).TotalSeconds -ge $CatalogRefreshSec) {
                $lastCatalogRefresh = Get-Date
                $lastSubscriptionRevision = $subscriptionRevision
                try {
                    $newCandidates = @(Get-CandidateNodes)
                    $newDesired = @(Get-DesiredExits -Candidates $newCandidates -Config $exitConfig)
                    # Passive subscription updates never deselect running slots.
                    # Only an explicit exit-config change may stop a worker.
                    if ($desired.Count -gt 0) {
                        $newDesired = @($desired | ForEach-Object {
                            $old = $_
                            $updated = $newCandidates | Where-Object NodeHash -eq $old.NodeHash | Select-Object -First 1
                            if ($null -ne $updated) { $updated } else { $old }
                        })
                    }
                    $candidates = $newCandidates
                    $desired = $newDesired
                    Update-LeasesForDesired -Desired $desired -Leases $leases -Retired $retired
                    $lastCatalogRefresh = Get-Date
                    $refreshErrorHash = $null
                    Write-BrokerLog -Message ("catalog-refresh candidates={0} selected={1}" -f $candidates.Count, $desired.Count)
                }
                catch {
                    $refreshErrorHash = Get-StringSha256Short -Text $_.Exception.Message -Length 20
                    Write-BrokerLog -Message ("catalog-refresh-error errorHash={0}" -f $refreshErrorHash)
                }
            }

            $desiredHashes = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($item in $desired) {
                $desiredHashes.Add([string]$item.NodeHash) | Out-Null
            }

            foreach ($hash in @($workers.Keys)) {
                $worker = $workers[$hash]
                $exited = $false
                try {
                    $worker.Process.Refresh()
                    $exited = $worker.Process.HasExited
                }
                catch {
                    $exited = $true
                }

                if (-not $exited) {
                    $workerStatus = Get-WorkerStatus -NodeHash $hash
                    if ($null -eq $workerStatus -and ((Get-Date) - $worker.StartedAt).TotalSeconds -ge $StartupTimeoutSec) {
                        Write-BrokerLog -Message ("worker-start-timeout node={0} pid={1}" -f $hash, $worker.Process.Id)
                        Stop-WorkerEntry -Worker $worker -TimeoutSec 5
                        $exited = $true
                    }
                }

                if ($exited) {
                    $restartCount = $worker.RestartCount + 1
                    if (((Get-Date) - $worker.StartedAt).TotalSeconds -ge 300) {
                        $restartCount = 1
                    }
                    $workers.Remove($hash)
                    if ($desiredHashes.Contains([string]$hash)) {
                        $delay = [Math]::Min(60, 5 * [Math]::Pow(2, [Math]::Min($restartCount - 1, 4)))
                        $pendingRestarts[$hash] = [pscustomobject]@{
                            DueAt = (Get-Date).AddSeconds($delay)
                            RestartCount = $restartCount
                            Port = $worker.Port
                        }
                        Write-BrokerLog -Message ("worker-exit node={0} restartIn={1}s count={2}" -f $hash, $delay, $restartCount)
                    }
                }
            }

            foreach ($hash in @($pendingRestarts.Keys)) {
                $pending = $pendingRestarts[$hash]
                if ((Get-Date) -lt $pending.DueAt) {
                    continue
                }
                $pendingRestarts.Remove($hash)
                if (-not $desiredHashes.Contains([string]$hash)) {
                    continue
                }

                $exit = $desired | Where-Object { $_.NodeHash -eq $hash } | Select-Object -First 1
                if ($null -eq $exit) {
                    continue
                }

                $port = [int]$leases[$hash]
                Start-LeasedWorker -Exit $exit -Port $port -Workers $workers -PendingRestarts $pendingRestarts -RestartCount $pending.RestartCount
            }

            foreach ($exit in $desired) {
                $hash = [string]$exit.NodeHash
                if (-not $workers.ContainsKey($hash) -and -not $pendingRestarts.ContainsKey($hash)) {
                    $port = [int]$leases[$hash]
                    Start-LeasedWorker -Exit $exit -Port $port -Workers $workers -PendingRestarts $pendingRestarts
                }
            }

            Write-BrokerStatus -State $state -Workers $workers -PendingRestarts $pendingRestarts -Desired $desired -Candidates $candidates -ExitConfig $exitConfig -RefreshErrorHash $refreshErrorHash
            Start-Sleep -Seconds 2
        }
    }
    finally {
        Write-BrokerStatus -State 'stopping' -Workers $workers -PendingRestarts $pendingRestarts -Desired $desired -Candidates $candidates -ExitConfig $exitConfig -RefreshErrorHash $refreshErrorHash
        Stop-AllWorkerEntries -Workers $workers
        $workers.Clear()
        $pendingRestarts.Clear()
        Write-BrokerStatus -State 'stopped' -Workers $workers -PendingRestarts $pendingRestarts -Desired $desired -Candidates $candidates -ExitConfig $exitConfig -RefreshErrorHash $refreshErrorHash
        Write-BrokerLog -Message ("broker-stop pid={0}" -f $PID)

        foreach ($path in @($supervisorPath, $supervisorStopPath)) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force
            }
        }
    }
}

function Show-BrokerStatus {
    $document = Read-JsonFile -Path $statusPath
    if ($null -eq $document) {
        Write-Output 'No broker status file found.'
        return
    }

    Write-Output ("broker state={0} pid={1} updated={2}" -f $document.state, $document.brokerPid, $document.updatedAt)
    Write-Output ("catalog candidates={0} selected={1} healthy={2}" -f $document.candidateCount, $document.selectedCount, $document.healthyCount)
    if ($document.refreshErrorHash) {
        Write-Output ("last refresh error hash={0}" -f $document.refreshErrorHash)
    }

    $rows = @($document.exits | ForEach-Object {
        [pscustomobject]@{
            Node = $_.nodeName
            Port = $_.port
            Country = $_.country
            Protocol = $_.protocol
            State = $_.state
            Health = $_.healthOk
            HTTP = $_.httpStatus
            LatencyMs = $_.latencyMs
            ExitIpHash = $_.exitIpHash
            PID = $_.workerPid
            Restarts = $_.restartCount
        }
    })
    if ($rows.Count -gt 0) {
        $rows | Format-Table -AutoSize
    }
}

function Start-BrokerBackground {
    Ensure-RuntimeDirectories
    $record = Get-SupervisorRecord
    if ($null -ne $record -and (Test-ProcessAlive -ProcessId $record.pid)) {
        Write-Output ("Broker already running. pid={0}" -f $record.pid)
        Show-BrokerStatus
        return
    }

    if ($null -ne $record -and (Test-Path -LiteralPath $supervisorPath)) {
        Remove-Item -LiteralPath $supervisorPath -Force
    }

    $arguments = @(
        '-Action', 'run',
        '-PortBase', [string]$PortBase,
        '-MaxExits', [string]$MaxExits,
        '-Protocol', $Protocol,
        '-Country', $Country,
        '-HealthIntervalSec', [string]$HealthIntervalSec,
        '-ProbeTimeoutSec', [string]$ProbeTimeoutSec,
        '-FailureThreshold', [string]$FailureThreshold,
        '-CatalogRefreshSec', [string]$CatalogRefreshSec,
        '-StartupTimeoutSec', [string]$StartupTimeoutSec,
        '-RuntimeDirectory', $RuntimeDirectory,
        '-StatePath', $StatePath,
        '-ManagedAssemblyPath', $ManagedAssemblyPath,
        '-SingBoxDllPath', $SingBoxDllPath
    )

    $process = Start-DetachedPowerShell -ScriptPath $PSCommandPath -ScriptArguments $arguments -WorkingDirectory $projectRoot
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        $record = Get-SupervisorRecord
        if ($null -ne $record -and [int]$record.pid -eq $process.Id) {
            Write-Output ("Broker started. pid={0} runtime={1}" -f $process.Id, $RuntimeDirectory)
            Start-Sleep -Seconds 1
            Show-BrokerStatus
            return
        }
        if ($process.HasExited) {
            if ($process.ExitCode -eq 0 -and $null -ne $record -and
                (Test-ProcessAlive -ProcessId $record.pid)) {
                Write-Output ("Broker already running. pid={0}" -f $record.pid)
                return
            }
            throw "Broker process exited during startup with code $($process.ExitCode). Check $brokerLogPath"
        }
        Start-Sleep -Milliseconds 300
    }

    throw "Broker did not publish supervisor state within 15 seconds. Check $brokerLogPath"
}

function Stop-Broker {
    Ensure-RuntimeDirectories
    $record = Get-SupervisorRecord
    if ($null -eq $record -or -not (Test-ProcessAlive -ProcessId $record.pid)) {
        if (Test-Path -LiteralPath $supervisorPath) {
            Remove-Item -LiteralPath $supervisorPath -Force
        }
        Stop-OrphanWorkers
        Write-Output 'Broker is not running.'
        return
    }

    Set-Content -LiteralPath $supervisorStopPath -Value 'stop' -Encoding ascii
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-ProcessAlive -ProcessId $record.pid)) {
            break
        }
        Start-Sleep -Milliseconds 300
    }

    if (Test-ProcessAlive -ProcessId $record.pid) {
        $status = Read-JsonFile -Path $statusPath
        if ($null -ne $status) {
            foreach ($exit in @($status.exits)) {
                if ($exit.workerPid -and (Test-ProcessAlive -ProcessId $exit.workerPid)) {
                    try {
                        $process = [System.Diagnostics.Process]::GetProcessById([int]$exit.workerPid)
                        $process.Kill($true)
                        Write-BrokerLog -Message ("forced-stop-worker pid={0}" -f $exit.workerPid)
                    }
                    catch {
                    }
                }
            }
        }

        try {
            $process = [System.Diagnostics.Process]::GetProcessById([int]$record.pid)
            $process.Kill($true)
            Write-BrokerLog -Message ("forced-stop-broker pid={0}" -f $record.pid)
        }
        catch {
        }
    }

    foreach ($path in @($supervisorPath, $supervisorStopPath)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    Write-Output 'Broker stopped.'
}

Ensure-RuntimeDirectories

switch ($Action) {
    'run' {
        Invoke-BrokerRun
    }
    'start' {
        Start-BrokerBackground
    }
    'stop' {
        Stop-Broker
    }
    'status' {
        Show-BrokerStatus
    }
}
