[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{16}$')][string]$SlotHash,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{16}$')][string]$SourceHash,
    [string]$RuntimeDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime'),
    [string]$StatePath = "$env:APPDATA\vpncheap\app_state.json",
    [string]$ManagedAssemblyPath = 'C:\Program Files\VPNCheap\VpncheapWindows.Core.dll'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib/broker-common.ps1"
. "$PSScriptRoot/lib/vpncheap-state.ps1"
. "$PSScriptRoot/lib/subscription-state.ps1"
$RuntimeDirectory = [IO.Path]::GetFullPath($RuntimeDirectory)
$status = Read-JsonFile (Join-Path $RuntimeDirectory 'status.json')
$slot = @(Get-OptionalProperty $status 'exits') | Where-Object nodeHash -eq $SlotHash | Select-Object -First 1
$nodes = @(Get-SubscriptionNodes $RuntimeDirectory $StatePath $ManagedAssemblyPath)
$node = $nodes | Where-Object { (Get-ExitNodeIdentity $_).SourceHash -eq $SourceHash } | Select-Object -First 1
if ($null -eq $slot -or $null -eq $node) { throw 'exit-map-unknown-slot-or-source' }
if ($slot.protocol -ne $node.protocol -or $slot.country -ne $node.country_code) {
    throw 'exit-map-protocol-or-country-mismatch'
}
$configPath = Join-Path $RuntimeDirectory 'exit-config.json'
$config = Read-JsonFile $configPath
if ($null -eq $config) { throw 'exit-map-config-missing' }
$mappings = Get-OptionalProperty $config 'replacements'
if ($null -eq $mappings) { $mappings = [pscustomobject]@{} }
$mappings | Add-Member -NotePropertyName $SlotHash -NotePropertyValue $SourceHash -Force
$config | Add-Member -NotePropertyName replacements -NotePropertyValue $mappings -Force
Write-JsonFileAtomic $configPath $config
Write-Output "Replacement queued for slot=$SlotHash port=$($slot.port); validation is required before activation."
