Set-StrictMode -Version Latest

function Resolve-VpnCheapType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Reflection.Assembly]$Assembly,

        [Parameter(Mandatory = $true)]
        [string]$TypeName
    )

    $type = $Assembly.GetType($TypeName, $false)
    if ($null -eq $type) {
        throw "Type not found: $TypeName"
    }

    return $type
}

function Get-JsonProperty {
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

function Get-StringSha256 {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Text
    )

    if ($null -eq $Text) {
        $Text = ''
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $sha.Dispose()
    }
}

function Get-StringSha256Short {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Text,

        [int]$Length = 16
    )

    $hash = Get-StringSha256 -Text $Text
    if ($Length -gt $hash.Length) {
        return $hash
    }

    return $hash.Substring(0, $Length)
}

function Get-VpnCheapCatalogAccountRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatePath,

        [Parameter(Mandatory = $true)]
        [string]$AssemblyPath
    )

    $resolvedStatePath = (Resolve-Path -LiteralPath $StatePath).Path
    $resolvedAssemblyPath = (Resolve-Path -LiteralPath $AssemblyPath).Path
    $state = Get-Content -Raw -LiteralPath $resolvedStatePath | ConvertFrom-Json -Depth 100

    $catalog = Get-JsonProperty -Object $state -Name 'xboard_node_catalogs_bound_v3'
    if ($null -eq $catalog) {
        throw "State does not contain xboard_node_catalogs_bound_v3."
    }

    $schemaVersion = [int](Get-JsonProperty -Object $catalog -Name 'SchemaVersion')
    $accounts = Get-JsonProperty -Object $catalog -Name 'Accounts'
    if ($null -eq $accounts) {
        return @()
    }

    $assembly = [System.Reflection.Assembly]::LoadFrom($resolvedAssemblyPath)
    $cipherType = Resolve-VpnCheapType -Assembly $assembly -TypeName 'VpncheapWindows.Core.Services.DpapiCipher'
    $unprotectMethod = $cipherType.GetMethod(
        'TryUnprotectBound',
        [System.Reflection.BindingFlags]'Public,Static'
    )
    if ($null -eq $unprotectMethod) {
        throw 'DpapiCipher.TryUnprotectBound was not found.'
    }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($accountProperty in $accounts.PSObject.Properties) {
        $account = $accountProperty.Value
        $payloadToken = [string](Get-JsonProperty -Object $account -Name 'PayloadToken')
        if ([string]::IsNullOrWhiteSpace($payloadToken)) {
            continue
        }

        $userId = [string](Get-JsonProperty -Object $account -Name 'UserId')
        $generation = [string](Get-JsonProperty -Object $account -Name 'AccountGeneration')
        $associatedData = "vpncheap-node-cache|schema=$schemaVersion|type=catalog|account=$userId|generation=$generation"

        $decryptError = $null
        $payload = $null
        try {
            $payload = [string]$unprotectMethod.Invoke($null, [object[]]@($payloadToken, $associatedData))
        }
        catch {
            $decryptError = $_.Exception.Message
        }

        if ([string]::IsNullOrWhiteSpace($payload)) {
            $records.Add([pscustomobject]@{
                AccountKey = $accountProperty.Name
                AccountKeyHash = Get-StringSha256Short -Text $accountProperty.Name
                UserId = $userId
                UserIdHash = Get-StringSha256Short -Text $userId
                Generation = $generation
                SchemaVersion = $schemaVersion
                NodeCount = 0
                Nodes = @()
                DecryptError = if ($decryptError) { $decryptError } else { 'TryUnprotectBound returned null or empty.' }
            })
            continue
        }

        $nodes = @($payload | ConvertFrom-Json -Depth 100)
        $records.Add([pscustomobject]@{
            AccountKey = $accountProperty.Name
            AccountKeyHash = Get-StringSha256Short -Text $accountProperty.Name
            UserId = $userId
            UserIdHash = Get-StringSha256Short -Text $userId
            Generation = $generation
            SchemaVersion = $schemaVersion
            NodeCount = $nodes.Count
            Nodes = $nodes
            DecryptError = $null
        })
    }

    return $records.ToArray()
}
