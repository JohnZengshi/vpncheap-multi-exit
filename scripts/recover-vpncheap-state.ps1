param(
    [string]$StatePath = "$env:APPDATA\vpncheap\app_state.json",
    [string]$AssemblyPath = 'C:\Program Files\VPNCheap\VpncheapWindows.Core.dll',
    [switch]$ShowNodeMetadata,
    [switch]$ShowNodeIds
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. "$PSScriptRoot\lib\vpncheap-state.ps1"

$records = @(Get-VpnCheapCatalogAccountRecords -StatePath $StatePath -AssemblyPath $AssemblyPath)
if ($records.Count -eq 0) {
    throw 'No decryptable VPNCheap catalog account records were found.'
}

$summaries = foreach ($record in $records) {
    $protocols = @(
        $record.Nodes |
            Group-Object -Property protocol |
            Sort-Object Name |
            ForEach-Object { "{0}:{1}" -f $_.Name, $_.Count }
    )

    $onlineCount = @($record.Nodes | Where-Object { [bool](Get-JsonProperty -Object $_ -Name 'online') }).Count
    $idSet = @($record.Nodes | ForEach-Object { [string](Get-JsonProperty -Object $_ -Name 'id') } | Sort-Object)
    $idSetHash = Get-StringSha256Short -Text ($idSet -join "`n") -Length 24

    [pscustomobject]@{
        AccountKeyHash = $record.AccountKeyHash
        UserIdHash = $record.UserIdHash
        Generation = $record.Generation
        SchemaVersion = $record.SchemaVersion
        NodeCount = $record.NodeCount
        OnlineCount = $onlineCount
        Protocols = ($protocols -join ',')
        NodeIdSetHash = $idSetHash
        DecryptError = $record.DecryptError
    }
}

$summaries | Format-Table -AutoSize

if ($ShowNodeMetadata) {
    Write-Output ''
    Write-Output 'Node Metadata'

    foreach ($record in $records) {
        foreach ($node in $record.Nodes) {
            $nodeId = [string](Get-JsonProperty -Object $node -Name 'id')
            $nodeLabel = if ($ShowNodeIds) { $nodeId } else { Get-StringSha256Short -Text $nodeId }
            $groups = @(Get-JsonProperty -Object $node -Name 'groups')

            [pscustomobject]@{
                AccountKeyHash = $record.AccountKeyHash
                Node = $nodeLabel
                Protocol = [string](Get-JsonProperty -Object $node -Name 'protocol')
                Country = [string](Get-JsonProperty -Object $node -Name 'country_code')
                Online = [bool](Get-JsonProperty -Object $node -Name 'online')
                Groups = ($groups -join ',')
            }
        }
    }
}
