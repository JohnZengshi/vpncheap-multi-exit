[CmdletBinding()]
param(
    [string]$TaskName = 'vpncheap-multi-exit-broker',

    [int]$PortBase = 39001,

    [int]$MaxExits = 2,

    [string]$Protocol = 'hysteria2',

    [string]$Country = '',

    [int]$HealthIntervalSec = 15,

    [int]$ProbeTimeoutSec = 25,

    [int]$FailureThreshold = 3,

    [int]$CatalogRefreshSec = 300,

    [int]$StartupTimeoutSec = 45,

    [switch]$StartNow,

    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$brokerScript = Join-Path $PSScriptRoot 'broker.ps1'
$runtimeDirectory = Join-Path $projectRoot 'runtime'
$supervisorPath = Join-Path $runtimeDirectory 'supervisor.json'
$statePath = Join-Path $env:APPDATA 'vpncheap\app_state.json'
$managedAssemblyPath = 'C:\Program Files\VPNCheap\VpncheapWindows.Core.dll'
$singBoxDllPath = 'C:\Program Files\VPNCheap\sing-box.dll'

if ($Uninstall) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Output ('Removed scheduled task: {0}' -f $TaskName)
    }
    else {
        Write-Output ('Scheduled task not found: {0}' -f $TaskName)
    }
    return
}

function ConvertTo-TaskArgument {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    return '"' + $Value.Replace('"', '\"') + '"'
}

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$argumentValues = @(
    '-NoProfile',
    '-NonInteractive',
    '-WindowStyle',
    'Hidden',
    '-File',
    $brokerScript,
    '-Action',
    'run',
    '-PortBase',
    [string]$PortBase,
    '-MaxExits',
    [string]$MaxExits,
    '-Protocol',
    $Protocol,
    '-Country',
    $Country,
    '-HealthIntervalSec',
    [string]$HealthIntervalSec,
    '-ProbeTimeoutSec',
    [string]$ProbeTimeoutSec,
    '-FailureThreshold',
    [string]$FailureThreshold,
    '-CatalogRefreshSec',
    [string]$CatalogRefreshSec,
    '-StartupTimeoutSec',
    [string]$StartupTimeoutSec,
    '-RuntimeDirectory',
    $runtimeDirectory,
    '-StatePath',
    $statePath,
    '-ManagedAssemblyPath',
    $managedAssemblyPath,
    '-SingBoxDllPath',
    $singBoxDllPath
)
$argumentLine = ($argumentValues | ForEach-Object { ConvertTo-TaskArgument -Value ([string]$_) }) -join ' '

$action = New-ScheduledTaskAction `
    -Execute (Get-Command pwsh -ErrorAction Stop).Source `
    -Argument $argumentLine `
    -WorkingDirectory $projectRoot
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
$watchdogTrigger = New-ScheduledTaskTrigger `
    -Once `
    -At ((Get-Date).AddMinutes(1)) `
    -RepetitionInterval (New-TimeSpan -Minutes 5)
$principal = New-ScheduledTaskPrincipal `
    -UserId $identity `
    -LogonType Interactive `
    -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger @($logonTrigger, $watchdogTrigger) `
    -Principal $principal `
    -Settings $settings `
    -Description 'Runs the VPNCheap multi-exit broker for 9Router loopback proxy pools.' `
    -Force | Out-Null

Write-Output ('Registered scheduled task: {0}' -f $TaskName)
Write-Output ('Identity: {0}' -f $identity)
Write-Output ('Logon type: interactive user session')
Write-Output ('Triggers: at logon and every 5 minutes; multiple instances: ignore new')

if (-not $StartNow) {
    Write-Output 'Task was not started. Run with -StartNow to stop the current broker and launch it under Task Scheduler.'
    return
}

$supervisor = $null
if (Test-Path -LiteralPath $supervisorPath) {
    try {
        $supervisor = Get-Content -Raw -LiteralPath $supervisorPath | ConvertFrom-Json
    }
    catch {
        $supervisor = $null
    }
}

if ($null -ne $supervisor -and $null -ne (Get-Process -Id ([int]$supervisor.pid) -ErrorAction SilentlyContinue)) {
    Write-Output ('Stopping current broker pid={0} before task launch.' -f $supervisor.pid)
    & $brokerScript -Action stop
}

Start-ScheduledTask -TaskName $TaskName
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if (-not (Test-Path -LiteralPath $supervisorPath)) {
        continue
    }

    try {
        $supervisor = Get-Content -Raw -LiteralPath $supervisorPath | ConvertFrom-Json
    }
    catch {
        continue
    }

    if ($null -ne $supervisor.pid -and
        $null -ne (Get-Process -Id ([int]$supervisor.pid) -ErrorAction SilentlyContinue)) {
        Write-Output ('Task-started broker pid={0} instance={1}' -f $supervisor.pid, $supervisor.instanceId)
        return
    }
}

$task = Get-ScheduledTask -TaskName $TaskName
$taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
throw ('Broker did not start under Task Scheduler. Task state={0}, lastResult={1}. Check {2}' -f $task.State, $taskInfo.LastTaskResult, (Join-Path $runtimeDirectory 'logs\broker.log'))
