Set-StrictMode -Version Latest

function Invoke-VpnCheapSubscriptionFetch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][string]$AssemblyPath,
        [int]$TimeoutSec = 60
    )

    $assembly = [Reflection.Assembly]::LoadFrom((Resolve-Path -LiteralPath $AssemblyPath).Path)
    $clientPath = Join-Path (Split-Path -Parent $assembly.Location) 'vpncheap.exe'
    $clientVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($clientPath).FileVersion
    if ([string]::IsNullOrWhiteSpace($clientVersion)) { throw 'subscription-client-version-unavailable' }
    [VpncheapWindows.Core.Net.AppNetworkIdentity]::Initialize($clientVersion)
    if (-not ('VpnCheapMultiExit.ReadOnlyCredentialStore' -as [type])) {
        Add-Type -ReferencedAssemblies @($assembly.Location, (Join-Path $PSHOME 'ref/mscorlib.dll')) -TypeDefinition @'
using VpncheapWindows.Core.Services;
namespace VpnCheapMultiExit {
    public sealed class ReadOnlyCredentialStore : ICredentialStore {
        private readonly WindowsCredentialStore inner = new WindowsCredentialStore();
        public string Read(string key) { return inner.Read(key); }
        public void Write(string key, string value) { }
        public void Delete(string key) { }
    }
}
'@
    }

    $shadowDirectory = Join-Path ([IO.Path]::GetTempPath()) ('vpncheap-subscription-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($shadowDirectory) | Out-Null
    $shadowPath = Join-Path $shadowDirectory 'app_state.json'
    $store = $null
    $http = $null
    $mutation = $null
    $subscribe = $null
    $cts = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSec))
    try {
        Copy-Item -LiteralPath $StatePath -Destination $shadowPath
        $store = [VpncheapWindows.Core.Services.AppStateStore]::new($shadowPath)
        $credentials = [VpnCheapMultiExit.ReadOnlyCredentialStore]::new()
        $secure = [VpncheapWindows.Core.Services.SecureStorageService]::new($credentials)
        $session = [VpncheapWindows.Core.Services.SessionStore]::new($secure, $store)
        if (-not $session.HasSession) { throw 'subscription-login-required' }
        $registry = [VpncheapWindows.Core.Net.MirrorHostRegistry]::new()
        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.UseProxy = $false
        $http = [Net.Http.HttpClient]::new($handler)
        $http.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
        $paths = [VpncheapWindows.Core.Net.ApiPathService]::new($http, $store, $registry)
        $mutation = [VpncheapWindows.Core.Net.XboardMutationHttpClient]::new($registry)
        $api = [VpncheapWindows.Core.Net.XboardApiClient]::new($http, $paths, $secure, $mutation, $null)
        $subscription = [VpncheapWindows.Core.Services.SubscriptionService]::new($api, $store, $session)
        $subscribe = [VpncheapWindows.Core.Net.NodeSubscribeHttpClient]::new($registry)
        $service = [VpncheapWindows.Core.Services.XboardNodeService]::new($subscription, $subscribe, $store, $paths, $registry, $session)
        $task = $service.FetchNodesAsync($true, $cts.Token)
        $result = $task.GetAwaiter().GetResult()
        if ($result.RequiresLogin) { throw 'subscription-login-required' }
        if ([string]$result.Source -ne 'Network') { throw 'subscription-network-refresh-failed' }
        if ($result.Nodes.Count -eq 0) { throw 'subscription-empty-catalog' }
        $nodes = @($result.Nodes | ForEach-Object {
            [pscustomobject]@{
                id = $_.Id
                name = $_.Name
                protocol = $_.Protocol
                address = $_.Address
                port = $_.Port
                country_code = $_.CountryCode
                groups = @($_.Groups)
                online = $_.Online
                raw_outbound = ($_.RawOutbound.GetRawText() | ConvertFrom-Json -Depth 100)
            }
        })
        Assert-VpnCheapSubscriptionCatalog -Nodes $nodes
        return [pscustomobject]@{
            Nodes = $nodes
            Changed = $result.CatalogChanged
            Source = [string]$result.Source
        }
    }
    finally {
        foreach ($resource in @($store, $http, $mutation, $subscribe, $cts)) {
            if ($null -ne $resource) {
                try { $resource.Dispose() } catch { }
            }
        }
        $resolved = [IO.Path]::GetFullPath($shadowDirectory)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolved) -like 'vpncheap-subscription-*') {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}

function Assert-VpnCheapSubscriptionCatalog {
    param([AllowEmptyCollection()][object[]]$Nodes)

    if ($Nodes.Count -eq 0) { throw 'subscription-empty-catalog' }
    $ids = [Collections.Generic.HashSet[string]]::new()
    foreach ($node in $Nodes) {
        $address = [string]$node.address
        $ip = $null
        if ([string]::IsNullOrWhiteSpace([string]$node.id) -or
            -not $ids.Add([string]$node.id) -or
            [string]::IsNullOrWhiteSpace($address) -or
            $address -match '^(localhost|0\.0\.0\.0|::)$' -or
            ([Net.IPAddress]::TryParse($address, [ref]$ip) -and [Net.IPAddress]::IsLoopback($ip)) -or
            [int]$node.port -lt 1 -or [int]$node.port -gt 65535 -or
            $null -eq $node.raw_outbound -or
            [string]$node.name -match '\u7248\u672c\u8fc7\u4f4e|\u8bf7\u5347\u7ea7|\u5e94\u7528\u5185\u68c0\u67e5\u66f4\u65b0|upgrade.required') {
            throw 'subscription-invalid-catalog'
        }
    }
}
