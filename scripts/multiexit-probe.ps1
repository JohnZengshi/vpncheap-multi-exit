param(
    [string]$StatePath = "$env:APPDATA\vpncheap\app_state.json",
    [string]$ManagedAssemblyPath = 'C:\Program Files\VPNCheap\VpncheapWindows.Core.dll',
    [string]$SingBoxDllPath = 'C:\Program Files\VPNCheap\sing-box.dll',
    [int]$PortBase = 39001,
    [int]$MaxNodes = 2,
    [int]$MaxAttempts = 8,
    [int]$StartupDelayMs = 1500,
    [int]$ProbeTimeoutSec = 25,

    [string]$Protocol = 'hysteria2',

    [string]$Country,
    [switch]$RequireDistinctExitIps,
    [switch]$ShowExitIp,
    [switch]$ShowNodeId,
    [switch]$ShowNativeError
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot\lib\vpncheap-state.ps1"

if (-not (Test-Path -LiteralPath $StatePath)) {
    throw "State file not found: $StatePath"
}

if (-not (Test-Path -LiteralPath $ManagedAssemblyPath)) {
    throw "Managed assembly not found: $ManagedAssemblyPath"
}

if (-not (Test-Path -LiteralPath $SingBoxDllPath)) {
    throw "sing-box.dll not found: $SingBoxDllPath"
}

$curl = Get-Command curl.exe -ErrorAction SilentlyContinue
if ($null -eq $curl) {
    $curl = Get-Command curl -ErrorAction SilentlyContinue
}
if ($null -eq $curl) {
    throw 'curl or curl.exe is required for proxy probes.'
}
$curlPath = $curl.Source
$singBoxDirectory = Split-Path -Parent (Resolve-Path -LiteralPath $SingBoxDllPath).Path

$escapedDllPath = $SingBoxDllPath.Replace('\', '\\').Replace('"', '\"')
$nativeTypeName = 'VpnCheapMultiExit.SingBoxNative'
if (-not ($nativeTypeName -as [type])) {
    $nativeSource = @"
using System;
using System.Runtime.InteropServices;

namespace VpnCheapMultiExit
{
    public static class SingBoxNative
    {
        [DllImport("$escapedDllPath", CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr singbox_get_version();

        [DllImport("$escapedDllPath", CallingConvention = CallingConvention.Cdecl)]
        public static extern IntPtr singbox_get_last_error();

        [DllImport("$escapedDllPath", CallingConvention = CallingConvention.Cdecl)]
        public static extern void singbox_free_string(IntPtr value);

        [DllImport("$escapedDllPath", CallingConvention = CallingConvention.Cdecl)]
        public static extern UIntPtr singbox_new_service([MarshalAs(UnmanagedType.LPUTF8Str)] string configJson);

        [DllImport("$escapedDllPath", CallingConvention = CallingConvention.Cdecl)]
        public static extern int singbox_start_service(UIntPtr id);

        [DllImport("$escapedDllPath", CallingConvention = CallingConvention.Cdecl)]
        public static extern int singbox_close_service(UIntPtr id);
    }
}
"@
    Add-Type -TypeDefinition $nativeSource -Language CSharp
}

$nativeType = $nativeTypeName -as [type]

function Get-NativeUtf8String {
    param([IntPtr]$Pointer)

    if ($Pointer -eq [IntPtr]::Zero) {
        return ''
    }

    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringUTF8($Pointer)
    }
    finally {
        [VpnCheapMultiExit.SingBoxNative]::singbox_free_string($Pointer) | Out-Null
    }
}

function Get-SingBoxLastError {
    return Get-NativeUtf8String -Pointer ([VpnCheapMultiExit.SingBoxNative]::singbox_get_last_error())
}

function Get-ExceptionMessageChain {
    param(
        [Parameter(Mandatory = $true)]
        [System.Exception]$Exception
    )

    $messages = New-Object System.Collections.Generic.List[string]
    $current = $Exception
    while ($null -ne $current) {
        $message = [string]$current.Message
        if (-not [string]::IsNullOrWhiteSpace($message)) {
            $messages.Add($message.Trim())
        }

        $current = $current.InnerException
    }

    return ($messages -join ' -> ')
}

function New-SingBoxConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Node,

        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    $rawOutbound = Get-JsonProperty -Object $Node -Name 'raw_outbound'
    if ($null -eq $rawOutbound) {
        throw 'Node has no raw_outbound object.'
    }

    $outbound = $rawOutbound | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json -Depth 100
    $tag = [string](Get-JsonProperty -Object $outbound -Name 'tag')
    if ([string]::IsNullOrWhiteSpace($tag)) {
        $tag = 'proxy'
        $outbound | Add-Member -NotePropertyName tag -NotePropertyValue $tag -Force
    }

    # Avoid VPNCheap rule-set paths and remote rule sets entirely: route
    # everything through the single node outbound.
    $config = [ordered]@{
        log = [ordered]@{
            level = 'warn'
        }
        dns = [ordered]@{
            servers = @(
                [ordered]@{
                    tag = 'local'
                    type = 'udp'
                    server = '223.5.5.5'
                }
            )
            final = 'local'
        }
        inbounds = @(
            [ordered]@{
                type = 'mixed'
                tag = 'mixed-in'
                listen = '127.0.0.1'
                listen_port = $Port
            }
        )
        outbounds = @(
            $outbound,
            [ordered]@{
                type = 'direct'
                tag = 'direct'
            }
        )
        route = [ordered]@{
            final = $tag
        }
    }

    return ($config | ConvertTo-Json -Depth 100 -Compress)
}

function Invoke-CurlCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & $curlPath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
    }
}

function Test-Health {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    $healthArgs = @(
        '-sS',
        '-o', 'NUL',
        '-w', '%{http_code}|%{time_total}',
        '--max-time', [string]$ProbeTimeoutSec,
        '-x', "http://127.0.0.1:$Port",
        'https://cp.cloudflare.com/generate_204'
    )
    $health = Invoke-CurlCapture -Arguments $healthArgs
    $parts = $health.Output -split '\|'
    $statusCode = if ($parts.Count -ge 1) { $parts[0] } else { '' }
    $elapsed = if ($parts.Count -ge 2) { $parts[1] } else { '' }
    $healthOk = ($health.ExitCode -eq 0) -and ($statusCode -in @('200', '204'))

    $exitIp = $null
    if ($healthOk) {
        $ipArgs = @(
            '-sS',
            '--max-time', [string]$ProbeTimeoutSec,
            '-x', "http://127.0.0.1:$Port",
            'https://api.ipify.org'
        )
        $ipResult = Invoke-CurlCapture -Arguments $ipArgs
        if ($ipResult.ExitCode -eq 0 -and $ipResult.Output -match '^(?:(?:\d{1,3}\.){3}\d{1,3}|[0-9a-fA-F:]{3,})$') {
            $exitIp = $ipResult.Output
        }
    }

    return [pscustomobject]@{
        Ok = ($healthOk -and -not [string]::IsNullOrWhiteSpace($exitIp))
        HealthOk = $healthOk
        ExitIpOk = -not [string]::IsNullOrWhiteSpace($exitIp)
        StatusCode = $statusCode
        Elapsed = $elapsed
        ExitIp = $exitIp
        ExitIpHash = if ($exitIp) { Get-StringSha256Short -Text $exitIp -Length 20 } else { $null }
        CurlExitCode = $health.ExitCode
        CurlOutputHash = Get-StringSha256Short -Text $health.Output
    }
}

$accounts = @(Get-VpnCheapCatalogAccountRecords -StatePath $StatePath -AssemblyPath $ManagedAssemblyPath)
if ($accounts.Count -eq 0) {
    throw 'No VPNCheap catalog account records found.'
}

$candidates = @(
    $accounts |
        ForEach-Object { $_.Nodes } |
        Where-Object {
            [bool](Get-JsonProperty -Object $_ -Name 'online') -and
            $null -ne (Get-JsonProperty -Object $_ -Name 'raw_outbound') -and
            ([string]::IsNullOrWhiteSpace($Protocol) -or [string](Get-JsonProperty -Object $_ -Name 'protocol') -eq $Protocol) -and
            ([string]::IsNullOrWhiteSpace($Country) -or [string](Get-JsonProperty -Object $_ -Name 'country_code') -eq $Country)
        } |
        Sort-Object -Property @{ Expression = {
            [string](Get-JsonProperty -Object $_ -Name 'country_code')
        } }, @{ Expression = {
            [string](Get-JsonProperty -Object $_ -Name 'name')
        } }
)

$uniqueCandidates = @()
$seenNodeIds = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($candidate in $candidates) {
    $nodeId = [string](Get-JsonProperty -Object $candidate -Name 'id')
    if ($seenNodeIds.Add($nodeId)) {
        $uniqueCandidates += $candidate
    }
}

if ($uniqueCandidates.Count -lt $MaxNodes) {
    throw "Only $($uniqueCandidates.Count) online unique candidate nodes are available; $MaxNodes requested."
}

$services = New-Object System.Collections.Generic.List[object]
$results = New-Object System.Collections.Generic.List[object]

try {
    $version = Get-NativeUtf8String -Pointer ([VpnCheapMultiExit.SingBoxNative]::singbox_get_version())
    Write-Output ("sing-box version: {0}" -f $version)
    Write-Output ("candidate online nodes: {0}" -f $uniqueCandidates.Count)
    Write-Output ''

    $successfulExits = 0
    $attemptLimit = [Math]::Min($MaxAttempts, $uniqueCandidates.Count)

    for ($attempt = 0; $attempt -lt $attemptLimit -and $successfulExits -lt $MaxNodes; $attempt++) {
        $node = $uniqueCandidates[$attempt]
        $port = $PortBase + $attempt
        $nodeId = [string](Get-JsonProperty -Object $node -Name 'id')
        $nodeLabel = if ($ShowNodeId) { $nodeId } else { Get-StringSha256Short -Text $nodeId }
        $protocol = [string](Get-JsonProperty -Object $node -Name 'protocol')
        $country = [string](Get-JsonProperty -Object $node -Name 'country_code')

        $serviceId = [UIntPtr]::Zero
        $nativeError = $null
        $startResult = $null
        $stage = 'config'
        try {
            $config = New-SingBoxConfig -Node $node -Port $port
            $originalLocation = Get-Location
            $originalCurrentDirectory = [System.Environment]::CurrentDirectory
            try {
                [System.Environment]::CurrentDirectory = $singBoxDirectory
                $stage = 'native-create'
                $serviceId = [VpnCheapMultiExit.SingBoxNative]::singbox_new_service($config)
            }
            finally {
                [System.Environment]::CurrentDirectory = $originalCurrentDirectory
                Set-Location -LiteralPath $originalLocation
            }
            if ($serviceId -eq [UIntPtr]::Zero) {
                $nativeError = Get-SingBoxLastError
                throw 'singbox_new_service returned zero.'
            }

            $services.Add([pscustomobject]@{ Id = $serviceId; Port = $port; Node = $nodeLabel })
            $stage = 'native-start'
            $startReturnCode = [VpnCheapMultiExit.SingBoxNative]::singbox_start_service($serviceId)
            if ($startReturnCode -ne 0) {
                $nativeError = Get-SingBoxLastError
                throw "singbox_start_service returned $startReturnCode."
            }

            Start-Sleep -Milliseconds $StartupDelayMs
            $stage = 'health'
            $startResult = Test-Health -Port $port
            if ($startResult.Ok) {
                $successfulExits++
            }
        }
        catch {
            if ([string]::IsNullOrWhiteSpace($nativeError)) {
                $nativeError = Get-ExceptionMessageChain -Exception $_.Exception
            }

            $startResult = [pscustomobject]@{
                Ok = $false
                HealthOk = $false
                ExitIpOk = $false
                StatusCode = ''
                Elapsed = ''
                ExitIp = $null
                ExitIpHash = $null
                CurlExitCode = $null
                CurlOutputHash = $null
            }
        }

        $result = [pscustomobject]@{
            Node = $nodeLabel
            Protocol = $protocol
            Country = $country
            Port = $port
            Ok = [bool]$startResult.Ok
            HealthOk = [bool]$startResult.HealthOk
            ExitIpOk = [bool]$startResult.ExitIpOk
            HttpStatus = $startResult.StatusCode
            Seconds = $startResult.Elapsed
            ExitIpHash = $startResult.ExitIpHash
            Failure = if ($startResult.Ok) {
                $null
            }
            elseif ($stage -eq 'health' -and $startResult.HealthOk) {
                'exit-ip'
            }
            else {
                $stage
            }
            NativeErrorHash = if ($nativeError) { Get-StringSha256Short -Text $nativeError -Length 20 } else { $null }
            NativeError = if ($ShowNativeError) { $nativeError } else { $null }
        }

        if ($ShowExitIp) {
            $result | Add-Member -NotePropertyName ExitIp -NotePropertyValue $startResult.ExitIp
        }

        $results.Add($result)
    }
}
finally {
    foreach ($service in $services) {
        try {
            [VpnCheapMultiExit.SingBoxNative]::singbox_close_service($service.Id) | Out-Null
        }
        catch {
            Write-Warning ("Failed to close sing-box service on port {0}: {1}" -f $service.Port, $_.Exception.Message)
        }
    }
}

    if ($ShowNativeError) {
        $results | Format-List
    }
    else {
        $results | Format-Table -AutoSize
    }

$okResults = @($results | Where-Object { $_.Ok -and $_.ExitIpHash })
$distinctExitIpCount = @($okResults | Select-Object -ExpandProperty ExitIpHash -Unique).Count

Write-Output ''
Write-Output ("healthy exits: {0}" -f $okResults.Count)
Write-Output ("distinct exit IPs: {0}" -f $distinctExitIpCount)

if ($okResults.Count -lt $MaxNodes) {
    throw "Only $($okResults.Count) healthy exits were obtained; $MaxNodes requested."
}

if ($RequireDistinctExitIps -and $distinctExitIpCount -lt $MaxNodes) {
    throw "Only $distinctExitIpCount distinct exit IPs were obtained; $MaxNodes required."
}
