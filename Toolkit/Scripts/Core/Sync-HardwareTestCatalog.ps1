#Requires -Version 5.1
<#
.SYNOPSIS
    Sync hardwareTestCatalog from CHU Core_Hardware_Utility.json to CDE Toolkit\Config.
#>
param(
    [string]$ChuSourcePath = '',
    [string]$DestPath = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ChuSourcePath)) {
    $candidates = @(
        [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..\Core Hardware Utility\Core_Hardware_Utility.json')),
        [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\Core Hardware Utility\Core_Hardware_Utility.json'))
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) {
            $ChuSourcePath = $c
            break
        }
    }
}

if ([string]::IsNullOrWhiteSpace($DestPath)) {
    $DestPath = Join-Path $PSScriptRoot '..\..\Config\HardwareTestCatalog.json'
    $DestPath = [IO.Path]::GetFullPath($DestPath)
}

if (-not (Test-Path -LiteralPath $ChuSourcePath)) {
    throw "CHU catalog source not found: $ChuSourcePath"
}

$root = Get-Content -LiteralPath $ChuSourcePath -Raw | ConvertFrom-Json
if (-not $root.hardwareTestCatalog) {
    throw "hardwareTestCatalog section missing in $ChuSourcePath"
}

$export = @{
    version  = $root.hardwareTestCatalog.version
    profiles = $root.hardwareTestCatalog.profiles
    tests    = $root.hardwareTestCatalog.tests
    source   = $ChuSourcePath
    syncedAt = (Get-Date).ToString('o')
}

$destDir = Split-Path -Parent $DestPath
if (-not (Test-Path -LiteralPath $destDir)) {
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
}

$export | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $DestPath -Encoding UTF8
Write-Host "Hardware test catalog synced to: $DestPath"
exit 0
