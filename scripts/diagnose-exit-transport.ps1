param(
    [ValidateRange(1, 10)][int]$Rounds = 3,
    [ValidateRange(0, 60)][int]$IntervalSec = 0,
    [string]$OutputPath = 'artifacts/verification-20261023/transport.json'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. "$root/scripts/lib/broker-common.ps1"
$jobs = @()
try {
    foreach ($country in @('HK', 'JP')) {
        foreach ($protocol in @('hysteria2', 'anytls')) {
            $jobs += Start-Job -Name "$country-$protocol" -ArgumentList $root, $country, $protocol, $Rounds, $IntervalSec -ScriptBlock {
                param($root, $country, $protocol, $rounds, $intervalSec)
                $run = {
                param($root, $country, $protocol, $rounds, $intervalSec)
                $ErrorActionPreference = 'Stop'
                . "$root/scripts/lib/vpncheap-state.ps1"
                . "$root/scripts/lib/broker-common.ps1"
                . "$root/scripts/lib/subscription-state.ps1"
                . "$root/scripts/lib/singbox-host.ps1"
                $serviceId = [UIntPtr]::Zero
                $rows = @()
                $failure = $null
                $server = $null
                $serverPort = $null
                try {
                    $catalog = Read-ProtectedSubscriptionFile "$root/runtime/catalog.dpapi.json"
                    $node = $catalog.nodes | Where-Object {
                        $_.raw_outbound.type -eq $protocol -and $_.country_code -eq $country -and $_.online
                    } | Select-Object -First 1
                    if ($null -eq $node) { throw 'No candidate' }
                    $server = $node.raw_outbound.server
                    $serverPort = $node.raw_outbound.server_port
                    $native = Initialize-SingBoxNative 'C:\Program Files\VPNCheap\sing-box.dll'
                    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
                    try {
                        $listener.Start()
                        $port = $listener.LocalEndpoint.Port
                    }
                    finally { $listener.Stop() }
                    $start = Start-SingBoxNodeService $node $port $native.Directory
                    if (-not $start.Ok) { throw 'Native startup failed' }
                    $serviceId = $start.ServiceId
                    $clock = [Diagnostics.Stopwatch]::StartNew()
                    for ($round = 1; $round -le $rounds; $round++) {
                        # Space fast candidates too, so their coverage overlaps slow failures.
                        $remainingMs = ($round - 1) * $intervalSec * 1000 - $clock.ElapsedMilliseconds
                        if ($remainingMs -gt 0) { Start-Sleep -Milliseconds ([int]$remainingMs) }
                        foreach ($target in @('https://www.gstatic.com/generate_204',
                            'https://1.1.1.1/cdn-cgi/trace')) {
                            $checkAt = [DateTimeOffset]::UtcNow.ToString('o')
                            $probe = Invoke-CurlCapture @('-q', '-sS', '-o', 'NUL',
                                '-w', '%{http_code}|%{time_total}', '--max-time', '8',
                                '--noproxy', 'diagnostic.invalid', '-x', "http://127.0.0.1:$port", $target)
                            $match = [regex]::Match($probe.Output, '(\d{3})\|([0-9.]+)\s*$')
                            $status = if ($match.Success) { $match.Groups[1].Value } else { '' }
                            $rows += [pscustomobject]@{
                                round = $round; checkedAt = $checkAt; target = $target
                                status = $status; exitCode = $probe.ExitCode
                                seconds = if ($match.Success) { $match.Groups[2].Value } else { $null }
                                ok = $probe.ExitCode -eq 0 -and $status -in @('200', '204')
                            }
                        }
                    }
                }
                catch {
                    # Do not persist native messages or decrypted subscription content.
                    $failure = $_.Exception.GetType().Name
                }
                finally { Close-SingBoxServiceSafe $serviceId }
                $result = [pscustomobject]@{
                    diagnosticResult = $true; country = $country; protocol = $protocol
                    server = $server; serverPort = $serverPort; failure = $failure; probes = $rows
                }
                Write-Output ('DIAG-RESULT:' + ($result | ConvertTo-Json -Depth 10 -Compress))
                }
                # Native stdout is not PowerShell remoting data. Capture it in a nested
                # process and forward only the explicitly framed, sanitized JSON result.
                $escapedRoot = $root.Replace("'", "''")
                $command = "& { $($run.ToString()) } '$escapedRoot' '$country' '$protocol' $rounds $intervalSec"
                $captured = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive `
                    -OutputFormat Text -Command $command 2>&1
                $nativeExitCode = $LASTEXITCODE
                $returned = $false
                foreach ($line in $captured) {
                    $text = [string]$line
                    if ($text.StartsWith('DIAG-RESULT:')) {
                        $text.Substring(12) | ConvertFrom-Json
                        $returned = $true
                    }
                }
                if (-not $returned) {
                    [pscustomobject]@{
                        diagnosticResult = $true; country = $country; protocol = $protocol
                        server = $null; serverPort = $null; probes = @()
                        failure = "NativeChildExit:$nativeExitCode"
                    }
                }
            }
        }
    }
    $null = $jobs | Wait-Job -Timeout (40 + $Rounds * 20 + ($Rounds - 1) * $IntervalSec)
    if (@($jobs | Where-Object State -eq 'Running').Count) { throw 'Diagnostic timeout' }
    # Native libraries may emit console lines; retain only our explicit result objects.
    $results = @(foreach ($job in $jobs) {
        $output = @($job | Receive-Job -ErrorAction SilentlyContinue)
        $result = @($output | Where-Object {
            $_ -isnot [string] -and $_.PSObject.Properties['diagnosticResult'] -and $_.diagnosticResult
        })
        if ($result.Count -eq 1) { $result[0] }
        else {
            $parts = $job.Name.Split('-', 2)
            [pscustomobject]@{
                diagnosticResult = $true; country = $parts[0]; protocol = $parts[1]
                server = $null; serverPort = $null; probes = @()
                failure = "ChildProcessDidNotReturn:$($job.State)"
            }
        }
    })
    Write-JsonFileAtomic -Path ([IO.Path]::GetFullPath($OutputPath)) -Value @{
        checkedAt = [DateTimeOffset]::UtcNow.ToString('o')
        rounds = $Rounds
        intervalSec = $IntervalSec
        note = 'Different servers: protocol comparison is not proof of UDP filtering.'
        results = $results
    }
    $results | ForEach-Object {
        [pscustomobject]@{
            country = $_.country; protocol = $_.protocol
            endpoint = "$($_.server):$($_.serverPort)"
            passed = @($_.probes | Where-Object ok).Count
            total = @($_.probes).Count; failure = $_.failure
        }
    } | Format-Table -AutoSize
    if ($results.Count -ne 4 -or @($results | Where-Object failure).Count) {
        throw 'Incomplete diagnostic results; inspect the sanitized report.'
    }
}
finally {
    $jobs | Where-Object State -eq 'Running' | Stop-Job
    $jobs | Remove-Job -Force
}
