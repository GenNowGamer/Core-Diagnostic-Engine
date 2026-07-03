#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$coreDir = Join-Path $testsRoot '..\Core'
Import-Module (Join-Path $coreDir 'Toolkit.Core.psm1') -Force -DisableNameChecking

Write-Host 'Test-HealthCheckGroupedOutput'

$os = [PSCustomObject]@{
    Caption = 'Windows 11 Pro'
    Version = '10.0.26200'
    BuildNumber = '26200'
    OSArchitecture = '64-bit'
    InstallDate = '20240115120000.000000-300'
    RegisteredUser = 'Test User'
    SystemDirectory = 'C:\Windows\system32'
    LastBootUpTime = '6/19/2026 8:00:00 AM'
}
$osOutput = Format-HealthCheckOsVersion -Os $os
if ($osOutput -notmatch 'SUMMARY 1 :') {
    Write-Error 'OS version output missing grouped SUMMARY block.'
    exit 1
}

$drives = @(
    [PSCustomObject]@{ Name = 'C:'; Used = 120GB; Free = 80GB }
)
# Use numeric bytes-like structure - Format-HealthCheckDiskSpace expects Used/Free as numbers
$drives = @([PSCustomObject]@{ Name = 'C:'; Used = 120 * 1GB; Free = 80 * 1GB })
$diskOutput = Format-HealthCheckDiskSpace -Drives $drives -LowDriveNames @()
if ($diskOutput -notmatch 'DRIVE 1 :') {
    Write-Error 'Disk space output missing grouped DRIVE block.'
    exit 1
}

Write-Host '  PASS: grouped health-check output markers present'
Write-Host 'Test-HealthCheckGroupedOutput: PASS'
exit 0
