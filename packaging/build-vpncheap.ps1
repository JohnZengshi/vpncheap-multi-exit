[CmdletBinding()]
param(
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$packagingDirectory = $PSScriptRoot
$projectRoot = Split-Path -Parent $packagingDirectory
$sourcePath = Join-Path $packagingDirectory 'vpncheap-launcher\Program.cs'
$cscPath = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'

if (-not (Test-Path -LiteralPath $cscPath)) {
    throw 'The .NET Framework C# compiler was not found.'
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $projectRoot 'dist\vpncheap.exe'
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$bundleFiles = @()
$bundleFiles += Get-ChildItem -LiteralPath (Join-Path $projectRoot 'scripts') -Recurse -File |
    Where-Object { $_.Extension -in @('.ps1', '.cjs') }
$bundleFiles += Get-ChildItem -LiteralPath (Join-Path $projectRoot 'dashboard') -Recurse -File
$bundleFiles = @($bundleFiles | Sort-Object FullName)

$buildDirectory = Join-Path $projectRoot 'artifacts\launcher-build'
if (-not (Test-Path -LiteralPath $buildDirectory)) {
    New-Item -ItemType Directory -Path $buildDirectory -Force | Out-Null
}
$manifestPath = Join-Path $buildDirectory 'bundle.manifest'

$compilerArguments = @(
    '/nologo',
    '/target:exe',
    '/platform:anycpu',
    '/optimize+',
    '/debug-',
    '/codepage:65001',
    ('/out:{0}' -f $OutputPath)
)

$manifestLines = New-Object System.Collections.Generic.List[string]
$index = 0
foreach ($file in $bundleFiles) {
    $relativePath = [System.IO.Path]::GetRelativePath($projectRoot, $file.FullName).Replace('\', '/')
    $resourceName = 'bundle.res.{0:D4}' -f $index
    $compilerArguments += ('/resource:{0},{1}' -f $file.FullName, $resourceName)
    $manifestLines.Add(('{0}|{1}' -f $resourceName, $relativePath))
    $index++
}

[System.IO.File]::WriteAllLines(
    $manifestPath,
    $manifestLines,
    (New-Object System.Text.UTF8Encoding($false))
)
$compilerArguments += ('/resource:{0},{1}' -f $manifestPath, 'bundle.manifest')
$compilerArguments += $sourcePath

& $cscPath @compilerArguments
if ($LASTEXITCODE -ne 0) {
    throw ('Launcher compilation failed with exit code {0}.' -f $LASTEXITCODE)
}

$hash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Output ('Built: {0}' -f $OutputPath)
Write-Output ('Size:  {0} bytes' -f (Get-Item -LiteralPath $OutputPath).Length)
Write-Output ('SHA256: {0}' -f $hash)
