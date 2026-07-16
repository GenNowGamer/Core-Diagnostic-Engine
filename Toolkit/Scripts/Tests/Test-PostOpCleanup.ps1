#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Post-Op Cleanup shared helpers.
#>

$ErrorActionPreference = 'Stop'

$coreRoot = Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Core'
. (Join-Path $coreRoot 'PostOpCleanup.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        $script:passed++
        Write-Host "PASS: $Name"
        return
    }

    $msg = if ($Detail) { "$Name :: $Detail" } else { $Name }
    $script:failures.Add($msg) | Out-Null
    Write-Host "FAIL: $msg"
}

$content = Get-DefaultHostsFileContent
Assert-True -Name 'Default hosts includes localhost IPv4' -Condition ($content -match '127\.0\.0\.1\s+localhost')
Assert-True -Name 'Default hosts includes localhost IPv6' -Condition ($content -match '::1\s+localhost')

$unconfirmed = Invoke-PostOpHostsFileRestore
Assert-True -Name 'Hosts restore requires confirmation' -Condition ($unconfirmed.Status -eq 'Warn')

$hostsPath = Get-PostOpHostsFilePath
Assert-True -Name 'Hosts path targets system drivers etc' -Condition ($hostsPath -match 'drivers\\etc\\hosts$')

$expectedLiveHosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$previousOffline = $env:OFFLINE_WINDOWS_ROOT
$coreModule = Join-Path $coreRoot 'Toolkit.Core.psm1'
try {
    Import-Module $coreModule -Force -DisableNameChecking
    $env:OFFLINE_WINDOWS_ROOT = 'C:\'
    $livePath = Get-PostOpHostsFilePath
    Assert-True -Name 'Live Windows hosts restore ignores offline attach' -Condition ($livePath -eq $expectedLiveHosts)
} finally {
    if ($null -eq $previousOffline) {
        Remove-Item Env:OFFLINE_WINDOWS_ROOT -ErrorAction SilentlyContinue
    } else {
        $env:OFFLINE_WINDOWS_ROOT = $previousOffline
    }
}

$readOnlyDir = Join-Path ([IO.Path]::GetTempPath()) ("cde-hosts-ro-" + [Guid]::NewGuid().ToString('N'))
$readOnlyFile = Join-Path $readOnlyDir 'hosts'
try {
    New-Item -ItemType Directory -Path $readOnlyDir -Force | Out-Null
    Set-Content -LiteralPath $readOnlyFile -Value '127.0.0.1 localhost' -Encoding ASCII
    (Get-Item -LiteralPath $readOnlyFile).IsReadOnly = $true
    Clear-ToolkitFileReadOnlyAttribute -Path $readOnlyFile
    Assert-True -Name 'Read-only hosts attribute can be cleared' -Condition (-not (Get-Item -LiteralPath $readOnlyFile).IsReadOnly)
} finally {
    Remove-Item -LiteralPath $readOnlyDir -Recurse -Force -ErrorAction SilentlyContinue
}

$postOpScript = Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Workflows\PostOp.ps1'
$postOpText = Get-Content -LiteralPath $postOpScript -Raw
Assert-True -Name 'PostOp wires icon/thumb cache tool' -Condition ($postOpText -match 'IconThumbCacheClear')
Assert-True -Name 'PostOp wires DNS flush tool' -Condition ($postOpText -match 'DnsFlush')
Assert-True -Name 'PostOp wires proxy reset tool' -Condition ($postOpText -match 'ProxyReset')
Assert-True -Name 'PostOp wires hosts restore tool' -Condition ($postOpText -match 'HostsFileRestore')
Assert-True -Name 'PostOp wires restart explorer tool' -Condition ($postOpText -match 'RestartExplorer')

$fastFixes = Get-Content -LiteralPath (Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Workflows\FastFixes.ps1') -Raw
Assert-True -Name 'Fast Fixes no longer lists FlushDns' -Condition ($fastFixes -notmatch "Key='FlushDns'")
Assert-True -Name 'Fast Fixes no longer lists ClearIconCache' -Condition ($fastFixes -notmatch "Key='ClearIconCache'")
Assert-True -Name 'Fast Fixes no longer lists ClearThumbCache' -Condition ($fastFixes -notmatch "Key='ClearThumbCache'")

$osRepair = Get-Content -LiteralPath (Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Workflows\OSRepair.ps1') -Raw
Assert-True -Name 'OS Repair network reset no longer flushes DNS' -Condition ($osRepair -notmatch "FlushDNS")

Write-Host ''
Write-Host "Passed: $passed"
Write-Host "Failed: $($failures.Count)"

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) {
        Write-Host $failure
    }
    exit 1
}

exit 0
