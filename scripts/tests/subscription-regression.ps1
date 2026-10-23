$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. "$root/scripts/lib/broker-common.ps1"
. "$root/scripts/lib/vpncheap-state.ps1"
. "$root/scripts/lib/subscription-state.ps1"
. "$root/scripts/lib/subscription-client.ps1"
. "$root/scripts/lib/exit-update.ps1"
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('subscription-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testDirectory) | Out-Null
$script:failures = [Collections.Generic.List[string]]::new()
function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Run-Test([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Output "PASS $Name" }
    catch {
        $script:failures.Add("$Name : $($_.Exception.Message)")
        Write-Output "FAIL $Name : $($_.Exception.Message)"
    }
}
function New-TestNode([string]$Id, [string]$Name = 'HK-01-UDP', [string]$Address = '192.0.2.1',
    [string]$Protocol = 'hysteria2') {
    return [pscustomobject]@{
        id = $Id; name = $Name; address = $Address; port = 443; protocol = $Protocol
        country_code = 'HK'; online = $true
        raw_outbound = [pscustomobject]@{ type = $Protocol; server = $Address; server_port = 443; password = 'fixture-secret' }
    }
}
try {
    Run-Test 'Valid catalog accepted; empty, duplicate and sentinel catalogs rejected' {
        $node = New-TestNode a
        Assert-VpnCheapSubscriptionCatalog @($node)
        foreach ($bad in @(
            [pscustomobject]@{ Nodes = @() },
            [pscustomobject]@{ Nodes = @($node, $node) },
            [pscustomobject]@{ Nodes = @((New-TestNode b warning localhost)) }
        )) {
            $rejected = $false
            try { Assert-VpnCheapSubscriptionCatalog $bad.Nodes } catch { $rejected = $true }
            Assert-Test $rejected 'Unsafe catalog accepted.'
        }
    }
    Run-Test 'Snapshot encrypted, round-trips and cannot be moved to another slot' {
        $path = Join-Path $testDirectory 'catalog.dpapi.json'
        Write-ProtectedSubscriptionFile $path @{ nodes = @((New-TestNode a)) }
        Assert-Test ((Get-Content $path -Raw) -notmatch 'fixture-secret|192\.0\.2') 'Plaintext leaked.'
        $saved = Read-ProtectedSubscriptionFile $path
        Assert-Test ($saved.nodes[0].id -eq 'a') 'Snapshot round-trip failed.'
        $other = Join-Path $testDirectory 'other.dpapi.json'
        Copy-Item -LiteralPath $path -Destination $other
        $rejected = $false
        try { $null = Read-ProtectedSubscriptionFile $other } catch { $rejected = $true }
        Assert-Test $rejected 'Snapshot was not bound to its destination.'
    }
    Run-Test 'ID rotation and renamed node resolved by unique endpoint' {
        $old = New-TestNode a old-name
        $new = New-TestNode b new-name
        Assert-Test ((Resolve-ExitNodeReplacement $old @($new)).id -eq 'b') 'Endpoint migration lost.'
    }
    Run-Test 'Address change resolved by normalized exact name' {
        $old = New-TestNode a 'HK-01-UDP'
        $new = New-TestNode b 'HK-1-UDP' '192.0.2.2'
        Assert-Test ((Resolve-ExitNodeReplacement $old @($new)).id -eq 'b') 'Normalized name was not used.'
    }
    Run-Test 'No region-only guessing, protocol switching or ambiguous matching' {
        $old = New-TestNode a 'HK-01-UDP'
        Assert-Test ($null -eq (Resolve-ExitNodeReplacement $old @())) 'Empty catalog gave a replacement.'
        Assert-Test ($null -eq (Resolve-ExitNodeReplacement $old @((New-TestNode b 'HK-02-UDP' '192.0.2.2')))) 'Region-only match.'
        Assert-Test ($null -eq (Resolve-ExitNodeReplacement $old @((New-TestNode b 'HK-01-UDP' '192.0.2.1' anytls)))) 'Protocol switched.'
        Assert-Test ($null -eq (Resolve-ExitNodeReplacement $old @((New-TestNode b), (New-TestNode c)))) 'Ambiguous endpoint guessed.'
    }
    Run-Test 'Explicit replacement is scoped to a stable slot' {
        $path = Join-Path $testDirectory 'exit-config.json'
        $source = New-TestNode replacement
        $sourceHash = (Get-ExitNodeIdentity $source).SourceHash
        Write-JsonFileAtomic $path @{ replacements = @{ '1234567890123456' = $sourceHash } }
        $node = Get-ExplicitExitReplacement $testDirectory '1234567890123456' @($source)
        Assert-Test ($node.id -eq 'replacement') 'Explicit mapping ignored.'
        Assert-Test ($null -eq (Get-ExplicitExitReplacement $testDirectory '0000000000000000' @($source))) 'Mapping crossed slots.'
    }
    Run-Test 'Refresh scheduler respects single-flight and next refresh time' {
        $script:spawned = 0
        function Start-DetachedPowerShell { $script:spawned++ }
        $path = Join-Path $testDirectory 'subscription-status.json'
        Write-JsonFileAtomic $path @{ state = 'refreshing'; pid = $PID; nextRefreshAt = '2000-01-01T00:00:00Z' }
        Start-SubscriptionRefreshIfDue $testDirectory unused unused unused
        Assert-Test ($script:spawned -eq 0) 'Live refresh duplicated.'
        Write-JsonFileAtomic $path @{ state = 'updated'; nextRefreshAt = (Get-Date).AddHours(1).ToString('o') }
        Start-SubscriptionRefreshIfDue $testDirectory unused unused unused
        Assert-Test ($script:spawned -eq 0) 'Refresh ignored schedule.'
        Write-JsonFileAtomic $path @{ state = 'updated'; nextRefreshAt = (Get-Date).ToUniversalTime().AddMinutes(5).ToString('o') }
        Start-SubscriptionRefreshIfDue $testDirectory unused unused unused
        Assert-Test ($script:spawned -eq 0) 'UTC JSON timestamp lost its timezone.'
        Write-JsonFileAtomic $path @{ state = 'updated'; nextRefreshAt = '2000-01-01T00:00:00Z' }
        Start-SubscriptionRefreshIfDue $testDirectory unused unused "$root/scripts/subscription-refresh.ps1"
        Assert-Test ($script:spawned -eq 1) 'Due refresh not launched.'
    }
    Run-Test 'Refresh child enforces schedule even with an older supervisor' {
        $path = Join-Path $testDirectory 'subscription-status.json'
        Write-JsonFileAtomic $path @{ state = 'updated'; nextRefreshAt = (Get-Date).ToUniversalTime().AddMinutes(5).ToString('o') }
        $before = (Get-FileHash $path).Hash
        & pwsh -NoProfile -File "$root/scripts/subscription-refresh.ps1" -RuntimeDirectory $testDirectory -StatePath "$testDirectory/missing.json"
        Assert-Test ($LASTEXITCODE -eq 0 -and (Get-FileHash $path).Hash -eq $before) 'Scheduled refresh ran before its deadline.'
    }
    Run-Test 'Broker retains stable aliases after ID changes and missing legacy slots' {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile("$root/scripts/broker.ps1", [ref]$tokens, [ref]$errors)
        $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-CandidateNodes'
        }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        $RuntimeDirectory = Join-Path $testDirectory 'broker'
        [IO.Directory]::CreateDirectory($RuntimeDirectory) | Out-Null
        $StatePath = 'unused'; $ManagedAssemblyPath = 'unused'
        $statusPath = Join-Path $RuntimeDirectory 'status.json'
        $Protocol = 'hysteria2'; $Country = ''
        $old = New-TestNode old
        $new = New-TestNode new
        $stable = (Get-ExitNodeIdentity $old).SourceHash
        Save-ExitNodeSnapshot $RuntimeDirectory $stable $old
        Write-ProtectedSubscriptionFile (Join-Path $RuntimeDirectory 'catalog.dpapi.json') @{ nodes = @($new) }
        Write-JsonFileAtomic $statusPath @{ exits = @(
            @{ nodeHash = '0000000000000000'; nodeName = 'legacy'; protocol = 'hysteria2'; country = 'HK' }
        ) }
        $candidates = @(Get-CandidateNodes)
        Assert-Test ($candidates.Count -eq 2) 'Candidate aliases duplicated or legacy slot lost.'
        Assert-Test (@($candidates | Where-Object { $_.NodeHash -eq $stable -and -not $_.NeedsReview }).Count -eq 1) 'Stable slot changed.'
        Assert-Test (@($candidates | Where-Object { $_.NodeHash -eq '0000000000000000' -and $_.NeedsReview }).Count -eq 1) 'Legacy slot not retained for review.'
    }
    foreach ($scenario in @('stage-fails', 'cutover-fails', 'success', 'rollback-throws', 'snapshot-fails', 'stop-before-cutover')) {
        Run-Test "Safe update: $scenario" {
            $script:starts = [Collections.Generic.List[object]]::new()
            $script:closed = [Collections.Generic.List[UIntPtr]]::new()
            $script:saved = [Collections.Generic.List[string]]::new()
            $script:healthCalls = 0
            $script:scenario = $scenario
            function Start-SingBoxNodeService {
                param($Node, $Port, $SingBoxDirectory, $StartupDelayMs)
                $script:starts.Add([pscustomobject]@{ Id = $Node.id; Port = $Port })
                if ($script:scenario -eq 'rollback-throws' -and $script:starts.Count -eq 3) { throw 'fixture-rollback-failure' }
                return [pscustomobject]@{ Ok = $true; ServiceId = [UIntPtr](100 + $script:starts.Count) }
            }
            function Close-SingBoxServiceSafe {
                param([UIntPtr]$ServiceId)
                if ($ServiceId -ne [UIntPtr]::Zero) { $script:closed.Add($ServiceId) }
            }
            function Test-ProxyExitHealth {
                param($Port, $TimeoutSec)
                $script:healthCalls++
                return [pscustomobject]@{
                    Ok = -not (($script:scenario -eq 'stage-fails' -and $script:healthCalls -eq 1) -or
                        ($script:scenario -in @('cutover-fails', 'rollback-throws') -and $script:healthCalls -eq 2))
                }
            }
            function Save-ExitNodeSnapshot {
                param($RuntimeDirectory, $NodeHash, $Node)
                if ($script:scenario -eq 'snapshot-fails' -and $Node.id -eq 'new') { throw 'fixture-write-failure' }
                $script:saved.Add($Node.id)
            }
            $stop = Join-Path $testDirectory "$scenario.stop"
            if ($scenario -eq 'stop-before-cutover') { [IO.File]::WriteAllText($stop, 'stop') }
            $result = Invoke-SafeExitUpdate -Previous (New-TestNode old) -Candidate (New-TestNode new) `
                -ServiceId ([UIntPtr]99) -NodeHash '1234567890123456' -Port 39001 `
                -RuntimeDirectory $testDirectory -SingBoxDirectory unused -StartupDelayMs 0 -StopPath $stop
            if ($scenario -ne 'stop-before-cutover') {
                Assert-Test ($script:starts[0].Port -ne 39001) 'Validation used production port.'
            }
            switch ($scenario) {
                'stage-fails' {
                    Assert-Test ($result.State -eq 'validation-failed') 'Failure state wrong.'
                    Assert-Test (-not $script:closed.Contains([UIntPtr]99)) 'Old service closed on staging failure.'
                    Assert-Test ($result.ServiceId -eq [UIntPtr]99 -and $result.Node.id -eq 'old') 'Old service lost.'
                }
                { $_ -in @('cutover-fails', 'snapshot-fails') } {
                    Assert-Test ($result.State -eq 'rolled-back') 'Rollback did not run.'
                    Assert-Test ($script:starts[2].Id -eq 'old' -and $script:starts[2].Port -eq 39001) 'Rollback changed node or port.'
                    Assert-Test ($result.Node.id -eq 'old' -and $result.ServiceId -eq [UIntPtr]103) 'Rollback state lost.'
                    Assert-Test (-not $script:saved.Contains('new')) 'Failed candidate persisted.'
                }
                'rollback-throws' {
                    Assert-Test ($result.State -eq 'rollback-failed' -and $result.ServiceId -eq [UIntPtr]::Zero) 'Closed service handle retained.'
                }
                'success' {
                    Assert-Test ($result.State -eq 'updated' -and $result.Node.id -eq 'new') 'Successful update lost.'
                    Assert-Test ($script:starts[1].Port -eq 39001) 'Fixed port changed.'
                    Assert-Test ($script:saved[-1] -eq 'new') 'New config not persisted after health check.'
                }
                'stop-before-cutover' {
                    Assert-Test ($script:starts.Count -eq 0) 'Stop request started an unnecessary instance.'
                    Assert-Test (-not $script:closed.Contains([UIntPtr]99)) 'Stop caused an unnecessary cutover.'
                }
            }
        }
    }
    Run-Test 'Update lock prevents concurrent exit changes' {
        $lock = [IO.File]::Open((Join-Path $testDirectory 'exit-update.lock'),
            [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            function Start-SingBoxNodeService { throw 'Must not start while another slot is updating.' }
            $result = Invoke-SafeExitUpdate -Previous (New-TestNode old) -Candidate (New-TestNode new) `
                -ServiceId ([UIntPtr]99) -NodeHash '1234567890123456' -Port 39001 `
                -RuntimeDirectory $testDirectory -SingBoxDirectory unused
            Assert-Test ($result.State -eq 'update-pending' -and $result.ServiceId -eq [UIntPtr]99) 'Lock failed.'
        }
        finally { $lock.Dispose() }
    }
    Run-Test 'Failed refresh preserves last directory and records retry backoff' {
        $catalogPath = Join-Path $testDirectory 'catalog.dpapi.json'
        $before = (Get-FileHash $catalogPath).Hash
        & pwsh -NoProfile -File "$root/scripts/subscription-refresh.ps1" -RuntimeDirectory $testDirectory -StatePath "$testDirectory/missing.json" -Force
        Assert-Test ($LASTEXITCODE -eq 0) 'Refresh failure escaped sanitized boundary.'
        Assert-Test ((Get-FileHash $catalogPath).Hash -eq $before) 'Refresh destroyed previous catalog.'
        $status = Read-JsonFile (Join-Path $testDirectory 'subscription-status.json')
        Assert-Test ($status.state -eq 'error' -and $null -ne $status.errorHash) 'Failure not reported.'
        Assert-Test ([datetime]$status.nextRefreshAt -gt (Get-Date).ToUniversalTime()) 'No retry backoff.'
    }
    Run-Test 'Corrupt refresh status is recovered without losing the catalog' {
        $path = Join-Path $testDirectory 'subscription-status.json'
        [IO.File]::WriteAllText($path, '{broken')
        & pwsh -NoProfile -File "$root/scripts/subscription-refresh.ps1" -RuntimeDirectory $testDirectory -StatePath "$testDirectory/missing.json"
        Assert-Test ($LASTEXITCODE -eq 0) 'Corrupt status escaped sanitized boundary.'
        Assert-Test ((Read-JsonFile $path).state -eq 'error') 'Corrupt status not replaced.'
    }
    Run-Test 'Passive catalog reconciliation cannot stop workers' {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile("$root/scripts/broker.ps1", [ref]$tokens, [ref]$errors)
        $refreshBlock = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Extent.Text.Contains('$lastSubscriptionRevision') -and
            $node.Extent.Text.Contains('$newCandidates = @(Get-CandidateNodes)')
        }, $true)
        Assert-Test ($null -ne $refreshBlock) 'Reconciliation block missing.'
        Assert-Test ($refreshBlock.Extent.Text -notmatch 'Stop-WorkerEntry|pendingRestarts.Remove|workers.Remove') 'Passive update can retire a live exit.'
    }
    Run-Test 'Healthy worker survives a snapshot write failure' {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile("$root/scripts/worker.ps1", [ref]$tokens, [ref]$errors)
        $healthBlock = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Extent.Text.StartsWith('if ($health.Ok)')
        }, $true)
        Assert-Test ($null -ne $healthBlock) 'Health transition missing.'
        $health = [pscustomobject]@{ Ok = $true; StatusCode = '204'; LatencyMs = 1; ExitIp = '192.0.2.1'; ExitIpHash = 'fixture' }
        $RuntimeDirectory = $testDirectory; $NodeHash = '1111111111111111'
        $nodeInfo = [pscustomobject]@{ Node = New-TestNode old }
        $now = (Get-Date).ToUniversalTime().ToString('o')
        $script:reportedUpdateState = $null; $script:reportedHealth = $null
        function Save-ExitNodeSnapshot { throw 'fixture-disk-full' }
        function Update-WorkerStatus { param($Values) $script:reportedUpdateState = $Values.updateState }
        function Set-WorkerState { param($State, $Values) $script:reportedHealth = $State }
        . ([scriptblock]::Create($healthBlock.Extent.Text))
        Assert-Test ($script:reportedHealth -eq 'healthy') 'Healthy exit was not retained.'
        Assert-Test ($script:reportedUpdateState -eq 'snapshot-error') 'Snapshot failure not visible.'
    }
}
finally {
    $target = [IO.Path]::GetFullPath($testDirectory)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($target.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $target) -like 'subscription-test-*') {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}
if ($script:failures.Count) { throw "$($script:failures.Count) subscription regression test(s) failed." }
