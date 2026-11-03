Set-StrictMode -Version Latest

function Get-ExitCatalog {
    param([string]$RuntimeDirectory, [object[]]$Nodes, [string]$Protocol = '', [string]$Country = '')

    $status = Read-JsonFile (Join-Path $RuntimeDirectory 'status.json')
    $config = Read-JsonFile (Join-Path $RuntimeDirectory 'exit-config.json')
    $selected = @{}
    foreach ($slot in @(Get-OptionalProperty $status 'exits')) {
        if ($null -ne $slot) { $selected[[string]$slot.nodeHash] = $slot }
    }
    $wanted = @(Get-OptionalProperty $config 'nodeHashes')
    $records = [Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $RuntimeDirectory 'nodes') -Filter '*.dpapi.json' -ErrorAction SilentlyContinue)) {
        $hash = $file.BaseName -replace '\.dpapi$', ''
        $saved = Read-ProtectedSubscriptionFile $file.FullName
        if ($null -eq $saved) { continue }
        $configured = Get-OptionalProperty $saved 'configuredNode'
        if ($null -eq $configured -and -not [bool](Get-OptionalProperty $saved 'fallbackActive')) { $configured = $saved.node }
        if ($null -eq $configured) {
            $exact = @($Nodes | Where-Object { (Get-ExitNodeIdentity $_).SourceHash -eq $hash })
            if ($exact.Count -eq 1) { $configured = $exact[0] }
        }
        $resolved = if ($null -ne $configured) { Resolve-ExitNodeReplacement $configured $Nodes } else { $null }
        $display = if ($null -ne $resolved) { $resolved } elseif ($null -ne $configured) { $configured } else { $saved.node }
        $records.Add([pscustomobject]@{
            Hash = $hash; Configured = $configured; Resolved = $resolved; Display = $display
            SourceHash = if ($null -ne $resolved) { (Get-ExitNodeIdentity $resolved).SourceHash } else { '' }
        })
    }

    $result = [Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($node in $Nodes) {
        if (-not [bool](Get-JsonProperty $node 'online') -or $null -eq (Get-JsonProperty $node 'raw_outbound')) { continue }
        if (($Protocol -and $node.protocol -ne $Protocol) -or ($Country -and $node.country_code -ne $Country)) { continue }
        $source = (Get-ExitNodeIdentity $node).SourceHash
        $aliases = @($records | Where-Object SourceHash -eq $source)
        $active = @($aliases | Where-Object { $selected.ContainsKey($_.Hash) -or $_.Hash -in $wanted })
        $chosen = @(if ($active.Count) { $active } elseif ($aliases.Count -eq 1) { $aliases })
        # Multiple historical aliases cannot silently transfer a port or binding.
        if ($chosen.Count -eq 0) {
            $chosen = @([pscustomobject]@{ Hash = $source; Configured = $node; Resolved = $node; Display = $node; SourceHash = $source })
        }
        foreach ($alias in $chosen) {
            if ($seen.ContainsKey($alias.Hash)) { continue }
            $seen[$alias.Hash] = $true
            $review = $aliases.Count -gt 1 -and $active.Count -eq 0
            # A selected exact source identity resolves otherwise duplicate historical snapshots.
            if ($alias.Hash -eq $source -and $selected.ContainsKey($source)) { $review = $false }
            $result.Add([pscustomobject]@{
                NodeHash = $alias.Hash; NodeName = [string]$node.name; Protocol = [string]$node.protocol
                Country = [string]$node.country_code; SourceNodeHash = $source
                ConfiguredNodeHash = $source; ConfiguredNodeName = [string]$node.name
                NeedsReview = $review; Category = if ($selected.ContainsKey($alias.Hash)) { 'existing' } else { 'available' }
            })
        }
    }
    foreach ($hash in @($selected.Keys) + $wanted) {
        if (-not $hash -or $seen.ContainsKey([string]$hash)) { continue }
        $record = @($records | Where-Object Hash -eq $hash | Select-Object -First 1)
        $old = if ($selected.ContainsKey([string]$hash)) { $selected[[string]$hash] } else { $null }
        $display = if ($record.Count) { $record[0].Display } else { $null }
        $configured = if ($record.Count) { $record[0].Configured } else { $null }
        $result.Add([pscustomobject]@{
            NodeHash = [string]$hash
            NodeName = if ($null -ne $configured) { [string]$configured.name } elseif ($null -ne $old) { [string]$old.nodeName } else { [string]$hash }
            Protocol = if ($null -ne $display) { [string]$display.protocol } else { [string](Get-OptionalProperty $old 'protocol') }
            Country = if ($null -ne $display) { [string]$display.country_code } else { [string](Get-OptionalProperty $old 'country') }
            SourceNodeHash = ''; ConfiguredNodeHash = $null
            ConfiguredNodeName = if ($null -ne $configured) { [string]$configured.name } else { $null }
            NeedsReview = $true; Category = 'existing'
        })
        $seen[[string]$hash] = $true
    }
    return @($result | Sort-Object Country, NodeHash)
}

function Get-ExitSelection {
    param([object[]]$Candidates, [string[]]$NodeHashes = @(), [int]$MaxExits = 1, [object[]]$Exits = @())

    $chosen = [Collections.Generic.List[object]]::new()
    foreach ($candidate in $Candidates) {
        if ($NodeHashes.Count -and $candidate.NodeHash -notin $NodeHashes) { continue }
        $occupied = @($Exits | Where-Object { $null -ne $_ } | Where-Object {
            $_.nodeHash -ne $candidate.NodeHash -and
            (Get-OptionalProperty $_ 'activeNodeHash') -eq (Get-OptionalProperty $candidate 'sourceNodeHash') -and
            -not [string]::IsNullOrWhiteSpace([string](Get-OptionalProperty $candidate 'sourceNodeHash'))
        })
        $existing = @($Exits | Where-Object { $null -ne $_ } | Where-Object nodeHash -eq $candidate.NodeHash).Count -gt 0
        if ($occupied.Count -or ([bool](Get-OptionalProperty $candidate 'needsReview') -and -not $existing)) {
            if ($NodeHashes.Count) { throw 'node-unavailable' }
            continue
        }
        $chosen.Add($candidate)
        if ($chosen.Count -ge $MaxExits) { break }
    }
    if ($NodeHashes.Count -and $chosen.Count -ne $NodeHashes.Count) { throw 'unknown-node' }
    return $chosen.ToArray()
}
