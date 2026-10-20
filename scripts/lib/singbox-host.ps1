Set-StrictMode -Version Latest

function Initialize-SingBoxNative {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DllPath
    )

    $resolvedDllPath = (Resolve-Path -LiteralPath $DllPath).Path
    $nativeTypeName = 'VpnCheapMultiExit.SingBoxNative'
    if (-not ($nativeTypeName -as [type])) {
        $escapedDllPath = $resolvedDllPath.Replace('\', '\\').Replace('"', '\"')
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
        public static extern UIntPtr singbox_new_service(
            [MarshalAs(UnmanagedType.LPUTF8Str)] string configJson);

        [DllImport("$escapedDllPath", CallingConvention = CallingConvention.Cdecl)]
        public static extern int singbox_start_service(UIntPtr id);

        [DllImport("$escapedDllPath", CallingConvention = CallingConvention.Cdecl)]
        public static extern int singbox_close_service(UIntPtr id);
    }
}
"@
        Add-Type -TypeDefinition $nativeSource -Language CSharp
    }

    return [pscustomobject]@{
        Type = $nativeTypeName -as [type]
        DllPath = $resolvedDllPath
        Directory = Split-Path -Parent $resolvedDllPath
    }
}

function Get-NativeUtf8String {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$Pointer
    )

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

function Get-SingBoxVersion {
    [CmdletBinding()]
    param()

    return Get-NativeUtf8String -Pointer ([VpnCheapMultiExit.SingBoxNative]::singbox_get_version())
}

function Get-SingBoxLastError {
    [CmdletBinding()]
    param()

    return Get-NativeUtf8String -Pointer ([VpnCheapMultiExit.SingBoxNative]::singbox_get_last_error())
}

function New-MinimalSingBoxConfig {
    [CmdletBinding()]
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

function Start-SingBoxNodeService {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Node,

        [Parameter(Mandatory = $true)]
        [int]$Port,

        [Parameter(Mandatory = $true)]
        [string]$SingBoxDirectory,

        [int]$StartupDelayMs = 1200
    )

    $config = New-MinimalSingBoxConfig -Node $Node -Port $Port
    $originalLocation = Get-Location
    $originalCurrentDirectory = [System.Environment]::CurrentDirectory
    $serviceId = [UIntPtr]::Zero
    try {
        [System.Environment]::CurrentDirectory = $SingBoxDirectory
        $serviceId = [VpnCheapMultiExit.SingBoxNative]::singbox_new_service($config)
    }
    finally {
        [System.Environment]::CurrentDirectory = $originalCurrentDirectory
        Set-Location -LiteralPath $originalLocation
    }

    if ($serviceId -eq [UIntPtr]::Zero) {
        $nativeError = Get-SingBoxLastError
        return [pscustomobject]@{
            Ok = $false
            ServiceId = [UIntPtr]::Zero
            Stage = 'native-create'
            NativeError = $nativeError
        }
    }

    $startReturnCode = [VpnCheapMultiExit.SingBoxNative]::singbox_start_service($serviceId)
    if ($startReturnCode -ne 0) {
        $nativeError = Get-SingBoxLastError
        [VpnCheapMultiExit.SingBoxNative]::singbox_close_service($serviceId) | Out-Null
        return [pscustomobject]@{
            Ok = $false
            ServiceId = [UIntPtr]::Zero
            Stage = 'native-start'
            NativeError = $nativeError
        }
    }

    if ($StartupDelayMs -gt 0) {
        Start-Sleep -Milliseconds $StartupDelayMs
    }

    return [pscustomobject]@{
        Ok = $true
        ServiceId = $serviceId
        Stage = 'started'
        NativeError = $null
    }
}

function Close-SingBoxServiceSafe {
    [CmdletBinding()]
    param(
        [UIntPtr]$ServiceId
    )

    if ($ServiceId -eq [UIntPtr]::Zero) {
        return
    }

    try {
        [VpnCheapMultiExit.SingBoxNative]::singbox_close_service($ServiceId) | Out-Null
    }
    catch {
        return
    }
}

function Invoke-CurlCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($null -eq $curl) {
        $curl = Get-Command curl -ErrorAction SilentlyContinue
    }
    if ($null -eq $curl) {
        throw 'curl or curl.exe is required for proxy health probes.'
    }

    $output = & $curl.Source @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
    }
}

function Test-ProxyExitHealth {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port,

        [int]$TimeoutSec = 20
    )

    $healthArgs = @(
        '-sS',
        '-o', 'NUL',
        '-w', '%{http_code}|%{time_total}',
        '--max-time', [string]$TimeoutSec,
        '-x', "http://127.0.0.1:$Port",
        'https://cp.cloudflare.com/generate_204'
    )
    $health = Invoke-CurlCapture -Arguments $healthArgs
    $statusCode = ''
    $elapsedSeconds = ''
    $match = [regex]::Match($health.Output, '(?m)(\d{3})\|([0-9.]+)\s*$')
    if ($match.Success) {
        $statusCode = $match.Groups[1].Value
        $elapsedSeconds = $match.Groups[2].Value
    }

    $healthOk = ($health.ExitCode -eq 0) -and ($statusCode -in @('200', '204'))
    $exitIp = $null
    $exitIpOk = $false
    if ($healthOk) {
        foreach ($endpoint in @('https://api.ipify.org', 'https://ifconfig.me/ip', 'https://icanhazip.com')) {
            $ipArgs = @(
                '-sS',
                '--max-time', [string][Math]::Min($TimeoutSec, 10),
                '-x', "http://127.0.0.1:$Port",
                $endpoint
            )
            $ipResult = Invoke-CurlCapture -Arguments $ipArgs
            if ($ipResult.ExitCode -eq 0 -and $ipResult.Output -match '^(?:(?:\d{1,3}\.){3}\d{1,3}|[0-9a-fA-F:]{3,})$') {
                $exitIp = $ipResult.Output.Trim()
                $exitIpOk = $true
                break
            }
        }
    }

    $latencyMs = $null
    $parsedElapsed = 0.0
    if ([double]::TryParse($elapsedSeconds, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsedElapsed)) {
        $latencyMs = [int][Math]::Round($parsedElapsed * 1000)
    }

    $failureStage = $null
    if (-not $healthOk) {
        $failureStage = 'health'
    }
    elseif (-not $exitIpOk) {
        $failureStage = 'exit-ip'
    }

    return [pscustomobject]@{
        Ok = ($healthOk -and $exitIpOk)
        HealthOk = $healthOk
        ExitIpOk = $exitIpOk
        StatusCode = $statusCode
        LatencyMs = $latencyMs
        ExitIp = $exitIp
        ExitIpHash = if ($exitIp) { Get-StringSha256Short -Text $exitIp -Length 20 } else { $null }
        FailureStage = $failureStage
        CurlExitCode = $health.ExitCode
        CurlOutputHash = Get-StringSha256Short -Text $health.Output
    }
}
