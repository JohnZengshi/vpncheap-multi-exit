Set-StrictMode -Version Latest

function Read-JsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -Depth 100
}

function Write-JsonFileAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Value,

        [int]$Depth = 100
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $json = $Value | ConvertTo-Json -Depth $Depth
    $tempPath = "{0}.tmp.{1}" -f $Path, $PID
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($tempPath, $json, $utf8)

    try {
        if (Test-Path -LiteralPath $Path) {
            [System.IO.File]::Replace($tempPath, $Path, $null)
        }
        else {
            [System.IO.File]::Move($tempPath, $Path)
        }
    }
    catch {
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }
}

function Write-RedactedLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [long]$MaxBytes = 5MB
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    if (Test-Path -LiteralPath $Path) {
        $length = (Get-Item -LiteralPath $Path).Length
        if ($length -ge $MaxBytes) {
            Move-Item -LiteralPath $Path -Destination "$Path.1" -Force
        }
    }

    $line = "{0} {1}" -f (Get-Date).ToUniversalTime().ToString('o'), $Message
    Add-Content -LiteralPath $Path -Value $line -Encoding utf8
}

function Test-ProcessAlive {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$ProcessId
    )

    if ($null -eq $ProcessId) {
        return $false
    }

    $numericId = 0
    if (-not [int]::TryParse([string]$ProcessId, [ref]$numericId)) {
        return $false
    }

    return $null -ne (Get-Process -Id $numericId -ErrorAction SilentlyContinue)
}

function Test-TcpPortListening {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port,

        [int]$TimeoutMs = 250
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync('127.0.0.1', $Port)
        if (-not $task.Wait($TimeoutMs)) {
            return $false
        }

        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Start-DetachedPowerShell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [string[]]$ScriptArguments = @(),

        [string]$WorkingDirectory = (Get-Location).Path
    )

    $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwsh
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.ArgumentList.Add('-NoProfile')
    $startInfo.ArgumentList.Add('-NonInteractive')
    $startInfo.ArgumentList.Add('-File')
    $startInfo.ArgumentList.Add($ScriptPath)

    foreach ($argument in $ScriptArguments) {
        $startInfo.ArgumentList.Add([string]$argument)
    }

    return [System.Diagnostics.Process]::Start($startInfo)
}

function Wait-WithStopCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$Seconds,

        [Parameter(Mandatory = $true)]
        [string]$StopPath
    )

    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $StopPath) {
            return $true
        }

        Start-Sleep -Milliseconds 500
    }

    return (Test-Path -LiteralPath $StopPath)
}

function Get-OptionalProperty {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Resolve-ProjectPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $Path))
}
