[CmdletBinding()]
param([string]$MigratePool = '', [string]$RuntimeDirectory = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot\lib\broker-common.ps1"
. "$PSScriptRoot\lib\9router.ps1"
. "$PSScriptRoot\lib\9router-sync.ps1"
$runtime = if ($RuntimeDirectory) { [IO.Path]::GetFullPath($RuntimeDirectory) } else { Join-Path (Split-Path $PSScriptRoot -Parent) 'runtime' }
$lock = $null
$initialStatus = Read-JsonFile (Join-Path $runtime 'status.json')
$configId = Get-OptionalProperty $initialStatus 'appliedConfigId'
$instanceId = Get-OptionalProperty $initialStatus 'instanceId'
try {
    try {
        $lock = [IO.File]::Open((Join-Path $runtime '9router-sync.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    } catch { return }
    Write-JsonFileAtomic (Join-Path $runtime '9router-sync-status.json') @{
        state = 'running'; pid = $PID; configId = $configId; instanceId = $instanceId; updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    $result = Invoke-NineRouterSync -RuntimeDirectory $runtime -MigratePool $MigratePool
    Write-JsonFileAtomic (Join-Path $runtime '9router-sync-status.json') $result
    $result | ConvertTo-Json -Depth 10
}
catch {
    Write-JsonFileAtomic (Join-Path $runtime '9router-sync-status.json') @{
        state = 'error'; error = 'sync-failed'; configId = $configId; instanceId = $instanceId; updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-RedactedLog (Join-Path $runtime 'logs\9router-sync.log') ('sync-error type={0}' -f $_.Exception.GetType().Name)
    throw
}
finally {
    if ($null -ne $lock) { $lock.Dispose() }
}
