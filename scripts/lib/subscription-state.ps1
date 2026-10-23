Set-StrictMode -Version Latest

function ConvertTo-SubscriptionTimestamp {
    param([AllowNull()][object]$Value)
    if ($Value -is [datetimeoffset]) { return $Value }
    if ($Value -is [datetime]) { return [datetimeoffset]$Value }
    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return $parsed }
    return [datetimeoffset]::MinValue
}

function Write-ProtectedSubscriptionFile {
    param([string]$Path, [object]$Value)

    $plain = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 100 -Compress))
    $entropy = [Text.Encoding]::UTF8.GetBytes('vpncheap-multi-exit|' + [IO.Path]::GetFullPath($Path).ToLowerInvariant())
    $encrypted = [Security.Cryptography.ProtectedData]::Protect($plain, $entropy,
        [Security.Cryptography.DataProtectionScope]::CurrentUser)
    Write-JsonFileAtomic -Path $Path -Value @{ schemaVersion = 1; payload = [Convert]::ToBase64String($encrypted) }
}

function Read-ProtectedSubscriptionFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $document = Read-JsonFile -Path $Path
    if ($null -eq $document) { throw 'subscription-snapshot-unreadable' }
    $entropy = [Text.Encoding]::UTF8.GetBytes('vpncheap-multi-exit|' + [IO.Path]::GetFullPath($Path).ToLowerInvariant())
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($document.payload),
        $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -Depth 100)
}

function Get-SubscriptionNodes {
    param([string]$RuntimeDirectory, [string]$StatePath, [string]$AssemblyPath)

    $snapshot = Read-ProtectedSubscriptionFile -Path (Join-Path $RuntimeDirectory 'catalog.dpapi.json')
    if ($null -ne $snapshot) { return @($snapshot.nodes) }
    $records = @(Get-VpnCheapCatalogAccountRecords -StatePath $StatePath -AssemblyPath $AssemblyPath)
    return @($records | ForEach-Object { $_.Nodes })
}

function Get-ExitNodeIdentity {
    param([object]$Node)

    $protocol = [string](Get-JsonProperty $Node 'protocol')
    $country = [string](Get-JsonProperty $Node 'country_code')
    $address = [string](Get-JsonProperty $Node 'address')
    $port = [int](Get-JsonProperty $Node 'port')
    $name = ([string](Get-JsonProperty $Node 'name')).ToLowerInvariant() -replace '\s+', ''
    $name = [regex]::Replace($name, '\d+', {
        param($m)
        $digits = $m.Value.TrimStart('0')
        if ($digits.Length) { $digits } else { '0' }
    })
    return [pscustomobject]@{
        SourceHash = Get-StringSha256Short ([string](Get-JsonProperty $Node 'id'))
        EndpointHash = Get-StringSha256 "$protocol|$($address.ToLowerInvariant())|$port"
        NameKey = "$protocol|$country|$name"
        ConfigHash = Get-StringSha256 ((Get-JsonProperty $Node 'raw_outbound') | ConvertTo-Json -Depth 100 -Compress)
    }
}

function Resolve-ExitNodeReplacement {
    param([object]$Previous, [AllowEmptyCollection()][object[]]$Nodes)

    $identity = Get-ExitNodeIdentity $Previous
    $eligible = @($Nodes | Where-Object {
        [bool](Get-JsonProperty $_ 'online') -and
        (Get-JsonProperty $_ 'protocol') -eq (Get-JsonProperty $Previous 'protocol') -and
        (Get-JsonProperty $_ 'country_code') -eq (Get-JsonProperty $Previous 'country_code')
    })
    foreach ($key in @('SourceHash', 'EndpointHash', 'NameKey')) {
        $matches = @($eligible | Where-Object { (Get-ExitNodeIdentity $_).$key -eq $identity.$key })
        if ($matches.Count -eq 1) { return $matches[0] }
        if ($matches.Count -gt 1) { return $null }
    }
    return $null
}

function Get-ExitSnapshotPath {
    param([string]$RuntimeDirectory, [string]$NodeHash)
    if ($NodeHash -notmatch '^[0-9a-f]{8,64}$') { throw 'invalid-slot-hash' }
    return Join-Path $RuntimeDirectory "nodes/$NodeHash.dpapi.json"
}

function Save-ExitNodeSnapshot {
    param([string]$RuntimeDirectory, [string]$NodeHash, [object]$Node,
        [Nullable[bool]]$FallbackActive = $null)
    $path = Get-ExitSnapshotPath $RuntimeDirectory $NodeHash
    [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
    if ($null -eq $FallbackActive) {
        $saved = Read-ProtectedSubscriptionFile $path
        $FallbackActive = [bool](Get-OptionalProperty $saved 'fallbackActive')
    }
    Write-ProtectedSubscriptionFile -Path $path -Value @{ node = $Node; fallbackActive = [bool]$FallbackActive }
}

function Get-ExplicitExitReplacement {
    param([string]$RuntimeDirectory, [string]$NodeHash, [AllowEmptyCollection()][object[]]$Nodes)
    $config = Read-JsonFile (Join-Path $RuntimeDirectory 'exit-config.json')
    $mappings = Get-OptionalProperty $config 'replacements'
    $sourceHash = [string](Get-OptionalProperty $mappings $NodeHash)
    if ($sourceHash -notmatch '^[0-9a-f]{16}$') { return $null }
    $matches = @($Nodes | Where-Object { (Get-ExitNodeIdentity $_).SourceHash -eq $sourceHash })
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Start-SubscriptionRefreshIfDue {
    param([string]$RuntimeDirectory, [string]$StatePath, [string]$AssemblyPath,
        [string]$ScriptPath, [int]$IntervalSec = 300)

    $status = $null
    try { $status = Read-JsonFile (Join-Path $RuntimeDirectory 'subscription-status.json') } catch { }
    if ($null -ne $status) {
        if ((Get-OptionalProperty $status 'state') -eq 'refreshing' -and
            (Test-ProcessAlive (Get-OptionalProperty $status 'pid'))) { return }
        $next = ConvertTo-SubscriptionTimestamp (Get-OptionalProperty $status 'nextRefreshAt')
        if ([datetimeoffset]::UtcNow -lt $next) { return }
    }
    Start-DetachedPowerShell -ScriptPath $ScriptPath -ScriptArguments @(
        '-RuntimeDirectory', $RuntimeDirectory, '-StatePath', $StatePath,
        '-ManagedAssemblyPath', $AssemblyPath, '-RefreshIntervalSec', [string]$IntervalSec
    ) -WorkingDirectory (Split-Path -Parent (Split-Path -Parent $ScriptPath)) | Out-Null
}
