$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. "$root/scripts/lib/broker-common.ps1"
. "$root/scripts/lib/vpncheap-state.ps1"
. "$root/scripts/lib/subscription-state.ps1"
. "$root/scripts/lib/9router.ps1"
if (Test-Path "$root/scripts/lib/exit-control.ps1") { . "$root/scripts/lib/exit-control.ps1" }
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile("$root/scripts/broker.ps1", [ref]$tokens, [ref]$errors)
foreach ($definition in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$RuntimeDirectory = Join-Path ([IO.Path]::GetTempPath()) ('consistency-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($RuntimeDirectory) | Out-Null
$statusPath = Join-Path $RuntimeDirectory 'status.json'
$StatePath = 'unused'; $ManagedAssemblyPath = 'unused'; $Protocol = ''; $Country = ''
function Assert-True($Value, $Message) { if (-not $Value) { throw $Message }; Write-Output "PASS $Message" }
try {
    Add-Type -TypeDefinition @'
using System.IO;
using System.Threading;
using System.Threading.Tasks;
public static class TemporaryJsonReplacement {
    public static Task Replace(string path) {
        File.Move(path, path + ".replacing");
        return Task.Run(() => { Thread.Sleep(30); File.Move(path + ".replacing", path); });
    }
}
'@
    $transient = Join-Path $RuntimeDirectory 'transient.json'
    Write-JsonFileAtomic $transient @{ identity = 'preserved' }
    $replacement = [TemporaryJsonReplacement]::Replace($transient)
    $recovered = Read-JsonFile $transient
    $replacement.GetAwaiter().GetResult()
    Assert-True ($null -ne $recovered -and $recovered.identity -eq 'preserved') 'State reads survive a transient atomic replacement gap'
    $node = [pscustomobject]@{ id = 'primary'; name = 'TW Same'; protocol = 'anytls'; country_code = 'TW';
        address = '192.0.2.1'; port = 443; online = $true; raw_outbound = @{} }
    $other = [pscustomobject]@{ id = 'other'; name = 'TW Same'; protocol = 'anytls'; country_code = 'TW';
        address = '192.0.2.2'; port = 443; online = $true; raw_outbound = @{} }
    $hash = (Get-ExitNodeIdentity $node).SourceHash
    Save-ExitNodeSnapshot $RuntimeDirectory $hash $node
    Save-ExitNodeSnapshot $RuntimeDirectory '1111111111111111' $node
    Write-ProtectedSubscriptionFile (Join-Path $RuntimeDirectory 'catalog.dpapi.json') @{ nodes = @($node, $other) }
    Write-JsonFileAtomic $statusPath @{ exits = @(@{ nodeHash = $hash; activeNodeHash = $hash }) }
    $candidates = @(Get-CandidateNodes)
    Assert-True ($candidates.Count -eq 2) 'Repeated snapshots merge without hiding distinct same-name nodes'
    Assert-True (@($candidates | Where-Object NodeHash -eq $hash).Count -eq 1) 'Selected logical exit identity survives catalog merge'
    $primary = @($candidates | Where-Object NodeHash -eq $hash)[0]
    Assert-True ($primary.ConfiguredNodeName -eq 'TW Same') 'Catalog publishes configured node independently'
    $selectionRejected = $false
    try {
        Get-ExitSelection -Candidates @($primary) -NodeHashes @($hash) -MaxExits 1 -Exits @(
            [pscustomobject]@{ nodeHash = '2222222222222222'; activeNodeHash = $hash }
        ) | Out-Null
    } catch { $selectionRejected = $_.Exception.Message -eq 'node-unavailable' }
    Assert-True $selectionRejected 'Selection rejects a node occupied as another exit backup'
    function New-NineRouterClient { return @{} }
    function Get-NineRouterPools { param($Client) return @([pscustomobject]@{ id = 'bound'; proxyUrl = 'http://127.0.0.1:39001' }) }
    function Get-NineRouterConnections { param($Client) return @([pscustomobject]@{
        id = 'inactive'; provider = 'fixture'; isActive = $false; providerSpecificData = @{ proxyPoolId = 'bound' }
    }) }
    $status = [pscustomobject]@{ state = 'running'; brokerPid = $PID; updatedAt = (Get-Date).ToUniversalTime().ToString('o')
        exits = @([pscustomobject]@{ nodeHash = $hash; port = 39001 }); candidates = $candidates; maxExits = 2 }
    Write-JsonFileAtomic $statusPath $status
    $outcome = Invoke-ExitConfigChange -RuntimeDirectory $RuntimeDirectory -Request ([pscustomobject]@{
        maxExits = 1; nodeHashes = @((Get-ExitNodeIdentity $other).SourceHash)
    })
    Assert-True ($outcome.code -eq 409 -and $outcome.body.error -eq 'exit-has-bindings') "Disabled provider binding prevents deselection ($($outcome | ConvertTo-Json -Depth 5 -Compress))"
    Assert-True (-not (Test-Path (Join-Path $RuntimeDirectory 'exit-config.json'))) 'Rejected selection does not write configuration'
    $held = [IO.File]::Open((Join-Path $RuntimeDirectory 'exit-config.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        $busy = Invoke-ExitConfigChange $RuntimeDirectory ([pscustomobject]@{ maxExits = 2; nodeHashes = @($hash) })
        Assert-True ($busy.body.error -eq 'config-change-running') 'Configuration save cannot race Broker execution lock'
    } finally { $held.Dispose() }
    function Get-NineRouterConnections { param($Client) throw 'fixture-unavailable' }
    $outcome = Invoke-ExitConfigChange -RuntimeDirectory $RuntimeDirectory -Request ([pscustomobject]@{
        maxExits = 1; nodeHashes = @((Get-ExitNodeIdentity $other).SourceHash)
    })
    Assert-True ($outcome.body.error -eq 'binding-check-unavailable') 'Unavailable binding lookup fails closed'
    $status.exits += [pscustomobject]@{ nodeHash = (Get-ExitNodeIdentity $other).SourceHash; port = 39002 }
    Write-JsonFileAtomic $statusPath $status
    $outcome = Invoke-ExitConfigChange -RuntimeDirectory $RuntimeDirectory -Request ([pscustomobject]@{ maxExits = 1; nodeHashes = @() })
    Assert-True ($outcome.code -eq 409) 'Automatic selection cannot bypass removal checks'
    $blocked = $false
    try { Assert-ExitRemovalAllowed $RuntimeDirectory @($status.exits) @($primary) }
    catch { $blocked = $_.Exception.Message -eq 'binding-check-unavailable' }
    Assert-True $blocked 'Execution rechecks bindings independently of configuration save'
}
finally {
    Remove-Item -LiteralPath $RuntimeDirectory -Recurse -Force
}
