#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$toolkitRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $toolkitRoot 'Scripts\Core\Toolkit.Core.psm1') -Force -DisableNameChecking
. (Join-Path $toolkitRoot 'Scripts\Core\HealthChecks.ps1')
. (Join-Path $toolkitRoot 'Scripts\Core\SystemAuditChecks.ps1')
. (Join-Path $toolkitRoot 'Scripts\Core\SecurityAuditChecks.ps1')

function Test-Check {
    param([string]$Name, [scriptblock]$Script)
    $r = [PSCustomObject]@{ Steps = [System.Collections.ArrayList]@() }
    & $Script $r
    $step = $r.Steps[-1]
    if ($step.Status -match 'Skip|N/A') {
        Write-Error "$Name returned $($step.Status): $($step.Detail) $($step.Output)"
        exit 1
    }
    Write-Host "  PASS: $Name ($($step.Status))"
}

Write-Host 'Test-SkippedHealthChecks'

# Regression: 8-character driver names must not trip grouped header truncation.
$drivers = @([PSCustomObject]@{ Name = 'Acx01000'; DisplayName = 'Acx01000'; State = 'Running'; StartMode = 'Manual' })
$driverOutput = Format-DriversList -Drivers $drivers -Stopped @()
if ($driverOutput -notmatch 'DRIVER 1 : Acx01000') {
    Write-Error 'Grouped driver output failed for 8-character title.'
    exit 1
}

Test-Check 'WindowsUpdateService' { param($r) Invoke-HealthCheck_windows_update_service $r }
Test-Check 'CriticalEvents' { param($r) Invoke-HealthCheck_critical_events_7d $r $PSScriptRoot }
Test-Check 'Drivers' { param($r) Invoke-DriversAudit $r }
Test-Check 'AutorunsAudit' { param($r) Invoke-AutorunsAudit $r }
Test-Check 'HostsFile' { param($r) Invoke-HostsFileCheck $r }
Test-Check 'BrowserExtensionScan' { param($r) Invoke-BrowserExtensionScan $r }
Test-Check 'ScheduledTasksAudit' { param($r) Invoke-ScheduledTasksAudit $r }

Write-Host 'Test-SkippedHealthChecks: PASS'
exit 0
