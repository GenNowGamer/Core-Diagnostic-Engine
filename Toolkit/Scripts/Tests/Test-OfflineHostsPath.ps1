#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$coreModule = Join-Path $PSScriptRoot '..\Core\Toolkit.Core.psm1'
Import-Module $coreModule -Force -DisableNameChecking

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cde_offline_hosts_{0}" -f [guid]::NewGuid().ToString('N'))
$offlineWindows = Join-Path $tempRoot 'Windows'
$etcDir = Join-Path $offlineWindows 'System32\drivers\etc'
New-Item -ItemType Directory -Path $etcDir -Force | Out-Null
Set-Content -LiteralPath (Join-Path $etcDir 'hosts') -Value '# test hosts' -Encoding ASCII

$previousOffline = $env:OFFLINE_WINDOWS_ROOT
try {
    $env:OFFLINE_WINDOWS_ROOT = "$tempRoot\"
    $path = Get-ToolkitHostsFilePath
    $expected = Join-Path $tempRoot 'Windows\System32\drivers\etc\hosts'
    Assert-True ($path -eq $expected) "Expected offline hosts path '$expected', got: '$path'"
} finally {
    if ($null -eq $previousOffline) {
        Remove-Item Env:OFFLINE_WINDOWS_ROOT -ErrorAction SilentlyContinue
    } else {
        $env:OFFLINE_WINDOWS_ROOT = $previousOffline
    }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$livePath = Get-ToolkitHostsFilePath
Assert-True ($livePath -eq (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts')) "Expected live SystemRoot hosts path, got: $livePath"

Write-Output 'Test-OfflineHostsPath: PASS'
