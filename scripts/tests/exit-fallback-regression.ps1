[CmdletBinding()]
param([switch]$Json)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. "$root/scripts/lib/broker-common.ps1"
. "$root/scripts/lib/vpncheap-state.ps1"
. "$root/scripts/lib/subscription-state.ps1"
. "$root/scripts/lib/exit-update.ps1"
$directory = Join-Path ([IO.Path]::GetTempPath()) ('exit-fallback-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($directory) | Out-Null
$failures = [Collections.Generic.List[string]]::new()
$results = @{}
function Assert-Test($Condition, $Message) { if (-not $Condition) { throw $Message } }
function New-Node($Id, $Protocol = 'hysteria2', $Country = 'HK') {
    [pscustomobject]@{
        id = $Id; name = $Id; protocol = $Protocol; country_code = $Country
        online = $true; address = "192.0.2.$Id"; port = 443
        raw_outbound = @{ type = $Protocol; server = "192.0.2.$Id"; server_port = 443 }
    }
}
try {
    foreach ($scenario in @('fallback', 'stage-fails', 'flapping', 'cutover-fails', 'claimed',
        'reserved', 'wrong-country', 'disabled', 'strict-update', 'stop', 'lock-busy')) {
        try {
            $runtime = Join-Path $directory $scenario
            [IO.Directory]::CreateDirectory($runtime) | Out-Null
            $old = New-Node 1
            $backup = New-Node 2 anytls
            $slot = '1111111111111111'
            $script:starts = [Collections.Generic.List[object]]::new()
            $script:closed = [Collections.Generic.List[UIntPtr]]::new()
            $script:probes = 0
            function Start-SingBoxNodeService {
                param($Node, $Port, $SingBoxDirectory, $StartupDelayMs)
                $script:starts.Add(@{ id = $Node.id; port = $Port })
                @{ Ok = $true; ServiceId = [UIntPtr](100 + $script:starts.Count) }
            }
            function Close-SingBoxServiceSafe {
                param($ServiceId)
                if ($ServiceId -ne [UIntPtr]::Zero) { $script:closed.Add($ServiceId) }
            }
            function Test-ProxyExitHealth {
                param($Port, $TimeoutSec)
                $script:probes++
                @{ Ok = -not ($scenario -eq 'stage-fails' -or
                    ($scenario -eq 'flapping' -and $script:starts[-1].id -eq '1') -or
                    ($scenario -eq 'flapping' -and $script:probes -eq 2) -or
                    ($scenario -eq 'cutover-fails' -and $Port -eq 39991)) }
            }
            Save-ExitNodeSnapshot $runtime $slot $old
            if ($scenario -eq 'claimed') { Save-ExitNodeSnapshot $runtime '2222222222222222' $backup }
            if ($scenario -eq 'reserved') {
                Write-JsonFileAtomic (Join-Path $runtime 'status.json') @{
                    exits = @(@{ nodeHash = (Get-ExitNodeIdentity $backup).SourceHash })
                }
            }
            if ($scenario -eq 'wrong-country') { $backup.country_code = 'JP' }
            if ($scenario -eq 'disabled') {
                Write-JsonFileAtomic (Join-Path $runtime 'exit-config.json') @{ autoFallback = $false }
            }
            $stop = Join-Path $runtime 'stop'
            if ($scenario -eq 'stop') { [IO.File]::WriteAllText($stop, '') }
            $arguments = @{
                Previous = $old; ServiceId = [UIntPtr]99; NodeHash = $slot; Port = 39991
                RuntimeDirectory = $runtime; SingBoxDirectory = 'unused'; ProbeTimeoutSec = 1
                StartupDelayMs = 0; StopPath = $stop
            }
            $lock = $null
            try {
                if ($scenario -eq 'lock-busy') {
                    $lock = [IO.File]::Open((Join-Path $runtime 'exit-update.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
                }
                if ($scenario -eq 'strict-update') {
                    $result = Invoke-SafeExitUpdate @arguments -Candidate $backup
                }
                else {
                    $result = Invoke-ExitRecovery @arguments -Nodes @($old, $backup) -StageProbeIntervalMs 0
                }
            }
            finally { if ($null -ne $lock) { $lock.Dispose() } }
            switch ($scenario) {
                fallback {
                    Assert-Test ($result.State -eq 'updated' -and $result.Node.id -eq '2') 'Failed primary never switched to the working backup.'
                    Assert-Test ($script:probes -eq 4) 'Backup was not checked three times before cutover.'
                    Assert-Test ($script:starts[0].port -ne 39991 -and $script:starts[1].port -eq 39991) 'Fixed port changed or staging touched it.'
                    Assert-Test ((Read-ProtectedSubscriptionFile (Get-ExitSnapshotPath $runtime $slot)).node.id -eq '2') 'Actual upstream was not saved.'
                }
                { $_ -in @('stage-fails', 'flapping') } {
                    Assert-Test ($result.State -eq 'validation-failed' -and $result.Node.id -eq '1') 'Unstable backup accepted.'
                    Assert-Test (-not $script:closed.Contains([UIntPtr]99)) 'Failed staging closed the live exit.'
                }
                cutover-fails {
                    Assert-Test ($result.State -eq 'rolled-back' -and $result.Node.id -eq '1') 'Cutover failure did not roll back.'
                    Assert-Test ($script:starts[-1].id -eq '1' -and $result.ServiceId -ne [UIntPtr]::Zero) 'Old listener lost.'
                }
                { $_ -in @('claimed', 'reserved', 'wrong-country', 'disabled') } {
                    Assert-Test (@($script:starts | Where-Object id -eq '2').Count -eq 0) 'Unsafe backup was selected.'
                }
                strict-update {
                    Assert-Test ($result.State -eq 'validation-failed' -and $script:starts.Count -eq 0) 'Ordinary subscription updates now allow protocol changes.'
                }
                { $_ -in @('stop', 'lock-busy') } {
                    Assert-Test ($result.State -eq 'update-pending' -and -not $script:closed.Contains([UIntPtr]99)) 'Stop/lock changed live exit.'
                }
            }
            $results[$scenario] = @{ state = $result.State; protocol = $result.Node.protocol; nodeName = $result.Node.name }
            Write-Host "PASS $scenario"
        }
        catch { $failures.Add($scenario); Write-Host "FAIL ${scenario}: $($_.Exception.Message)" }
    }
    try {
        $runtime = Join-Path $directory 'sticky'
        [IO.Directory]::CreateDirectory($runtime) | Out-Null
        $slot = (Get-ExitNodeIdentity (New-Node 1)).SourceHash
        $backup = New-Node 2 anytls
        Save-ExitNodeSnapshot $runtime $slot $backup -FallbackActive $true
        Save-ExitNodeSnapshot $runtime $slot $backup
        Assert-Test ((Read-ProtectedSubscriptionFile (Get-ExitSnapshotPath $runtime $slot)).fallbackActive) 'Health snapshots cleared fallback state.'
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile("$root/scripts/broker.ps1", [ref]$tokens, [ref]$errors)
        $definition = $ast.Find({
            param($n)
            $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-CandidateNodes'
        }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        $RuntimeDirectory = $runtime; $StatePath = 'unused'; $ManagedAssemblyPath = 'unused'
        $statusPath = Join-Path $runtime 'status.json'; $Protocol = 'hysteria2'; $Country = ''
        Write-ProtectedSubscriptionFile (Join-Path $runtime 'catalog.dpapi.json') @{ nodes = @((New-Node 1), $backup) }
        $candidates = @(Get-CandidateNodes)
        Assert-Test (@($candidates | Where-Object NodeHash -eq $slot).Count -eq 1) 'Protocol filter retired a working fallback slot.'
        Assert-Test ($candidates[0].Protocol -eq 'anytls') 'Broker hid the actual backup protocol.'
        Write-Host 'PASS sticky fallback survives snapshots and broker protocol filters'

        $ast = [Management.Automation.Language.Parser]::ParseFile("$root/scripts/worker.ps1", [ref]$tokens, [ref]$errors)
        $definition = $ast.Find({
            param($n)
            $n -is [Management.Automation.Language.TryStatementAst] -and
            $n.Body.Extent.Text -match '^\{\s*\$nodes = @\(Get-SubscriptionNodes'
        }, $true)
        $nodeInfo = [pscustomobject]@{ Node = $backup; FallbackActive = $true }
        $NodeHash = $slot
        Write-JsonFileAtomic (Join-Path $runtime 'exit-config.json') @{
            replacements = @{ $slot = (Get-ExitNodeIdentity (New-Node 1)).SourceHash }
        }
        $script:updateState = ''
        function Update-WorkerStatus { param($Values) $script:updateState = $Values.updateState }
        . ([scriptblock]::Create($definition.Extent.Text))
        Assert-Test ($script:updateState -eq 'current' -and $nodeInfo.Node.id -eq '2') 'Subscription refresh forced fallback back to the broken primary.'
        Write-Host 'PASS active fallback is not flipped back by subscription reconciliation'
    }
    catch { $failures.Add('sticky'); Write-Host "FAIL sticky: $($_.Exception.Message)" }
}
finally {
    $target = [IO.Path]::GetFullPath($directory)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($target.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $target) -like 'exit-fallback-*') {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}
if ($failures.Count) { throw "$($failures.Count) fallback regression test(s) failed." }
if ($Json) { Write-Output ('FALLBACK-RESULT:' + ($results | ConvertTo-Json -Depth 8 -Compress)) }
