[CmdletBinding()]
param([switch]$Json)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. "$root/scripts/lib/broker-common.ps1"
. "$root/scripts/lib/vpncheap-state.ps1"
. "$root/scripts/lib/subscription-state.ps1"
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile("$root/scripts/dashboard.ps1", [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Dashboard parse failed.' }
$function = $ast.Find({
    param($item)
    $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq 'Get-DashboardExitIpExport'
}, $true)
Invoke-Expression $function.Extent.Text
$runtimeDirectory = Join-Path ([IO.Path]::GetTempPath()) ('server-export-test-' + [guid]::NewGuid().ToString('N'))
$statusPath = Join-Path $runtimeDirectory 'status.json'
[IO.Directory]::CreateDirectory((Join-Path $runtimeDirectory 'nodes')) | Out-Null
try {
    $hash = Get-StringSha256Short 'fixture-node'
    Write-JsonFileAtomic $statusPath @{
        exits = @(@{ nodeHash = $hash; nodeName = 'Test'; country = 'HK'; protocol = 'hysteria2'; healthOk = $false })
    }
    $node = @{ id = 'fixture-node'; name = 'Original'; protocol = 'hysteria2'; country_code = 'HK'
        address = '192.0.2.1'; port = 443; password = 'never-export-this' }
    Write-ProtectedSubscriptionFile (Join-Path $runtimeDirectory 'catalog.dpapi.json') @{ nodes = @($node) }
    $result = Get-DashboardExitIpExport
    if ($result.exits.Count -ne 1 -or $result.exits[0].serverAddress -ne '192.0.2.1' -or $result.exits[0].serverPort -ne 443) {
        throw 'Unhealthy node without a snapshot did not export its catalog server.'
    }
    Write-Output 'PASS unhealthy node exports catalog server without worker health or public IP'
    $node.address = '192.0.2.2'
    $node.port = 8443
    $node.name = 'Backup'
    $node.protocol = 'anytls'
    Save-ExitNodeSnapshot $runtimeDirectory $hash $node -FallbackActive $true
    $result = Get-DashboardExitIpExport
    if ($result.exits[0].serverAddress -ne '192.0.2.2' -or $result.exits[0].serverPort -ne 8443) {
        throw 'Applied snapshot must take precedence over catalog.'
    }
    Write-Output 'PASS applied snapshot takes precedence over updated catalog'
    if ($result.exits[0].nodeName -ne 'Backup' -or $result.exits[0].protocol -ne 'anytls') {
        throw 'Fallback export still describes the original upstream.'
    }
    Write-Output 'PASS export uses actual backup name and protocol'
    $payloadJson = $result | ConvertTo-Json -Depth 10
    if ($payloadJson.Contains('never-export-this') -or $payloadJson.Contains('127.0.0.1') -or $payloadJson.Contains('exitIp')) {
        throw 'Export contains secrets, loopback or public-IP fields.'
    }
    Write-Output 'PASS export contains server fields only, without credentials'
    if ($Json) { Write-Output ('SERVER-EXPORT-RESULT:' + ($result | ConvertTo-Json -Depth 10 -Compress)) }
}
finally {
    if ([IO.Path]::GetFullPath($runtimeDirectory).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and
        (Split-Path -Leaf $runtimeDirectory) -like 'server-export-test-*') {
        Remove-Item -LiteralPath $runtimeDirectory -Recurse -Force
    }
}
