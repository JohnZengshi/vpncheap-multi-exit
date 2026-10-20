param(
    [string]$AssemblyPath = 'C:\Program Files\VPNCheap\VpncheapWindows.Core.dll',
    [string]$SingBoxDllPath = 'C:\Program Files\VPNCheap\sing-box.dll'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $AssemblyPath)) {
    throw "Managed assembly not found: $AssemblyPath"
}

if (-not (Test-Path -LiteralPath $SingBoxDllPath)) {
    throw "Native library not found: $SingBoxDllPath"
}

$assemblyFile = Get-Item -LiteralPath $AssemblyPath
$singBoxFile = Get-Item -LiteralPath $SingBoxDllPath
$assemblyHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $assemblyFile.FullName).Hash.ToLowerInvariant()
$singBoxHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $singBoxFile.FullName).Hash.ToLowerInvariant()

$assembly = [System.Reflection.Assembly]::LoadFrom($assemblyFile.FullName)
$module = $assembly.ManifestModule

Write-Output 'Artifacts'
Write-Output ("  VpncheapWindows.Core.dll sha256: {0}" -f $assemblyHash)
Write-Output ("  VpncheapWindows.Core.dll mvid:   {0}" -f $assembly.ManifestModule.ModuleVersionId)
Write-Output ("  sing-box.dll sha256:             {0}" -f $singBoxHash)
Write-Output ''

$typeNames = @(
    'VpncheapWindows.Core.Services.DpapiCipher',
    'VpncheapWindows.Core.Config.IRuleSetService',
    'VpncheapWindows.Core.Config.RuleSetService',
    'VpncheapWindows.Core.Config.SingBoxConfigBuilder',
    'VpncheapWindows.Core.Config.SingBoxConfigOptions',
    'VpncheapWindows.Core.Models.Xboard.XboardNode'
)

foreach ($typeName in $typeNames) {
    $type = $assembly.GetType($typeName, $false)
    if ($null -eq $type) {
        Write-Output ("TYPE {0} NOT FOUND" -f $typeName)
        Write-Output ''
        continue
    }

    Write-Output ("TYPE {0}" -f $type.FullName)

    $constructors = $type.GetConstructors([System.Reflection.BindingFlags]'Public,NonPublic,Instance')
    if ($constructors.Count -eq 0) {
        Write-Output '  constructors: none'
    }
    else {
        foreach ($constructor in $constructors) {
            Write-Output ("  ctor {0}" -f $constructor)
        }
    }

    $properties = $type.GetProperties([System.Reflection.BindingFlags]'Public,NonPublic,Instance,Static') |
        Sort-Object Name
    foreach ($property in $properties) {
        $access = @()
        if ($null -ne $property.GetMethod) { $access += 'get' }
        if ($null -ne $property.SetMethod) { $access += 'set' }
        Write-Output ("  prop {0} {1} [{2}]" -f $property.PropertyType.FullName, $property.Name, ($access -join ','))
    }

    $methods = $type.GetMethods([System.Reflection.BindingFlags]'Public,NonPublic,Instance,Static') |
        Where-Object { -not $_.IsSpecialName } |
        Sort-Object Name
    foreach ($method in $methods) {
        $static = if ($method.IsStatic) { 'static ' } else { '' }
        Write-Output ("  method {0}{1}" -f $static, $method)
    }

    Write-Output ''
}

Write-Output 'Expected Native Exports'
Write-Output '  singbox_get_version'
Write-Output '  singbox_get_last_error'
Write-Output '  singbox_free_string'
Write-Output '  singbox_new_service'
Write-Output '  singbox_start_service'
Write-Output '  singbox_close_service'
