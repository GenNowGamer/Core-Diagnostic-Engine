#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$coreDir = Join-Path $testsRoot '..\Core'
Import-Module (Join-Path $coreDir 'Toolkit.Core.psm1') -Force -DisableNameChecking
. (Join-Path $coreDir 'HealthFindings.ps1')
. (Join-Path $coreDir 'DriverFilterAllowlist.ps1')
. (Join-Path $coreDir 'HealthChecks.ps1')
. (Join-Path $coreDir 'SystemAuditChecks.ps1')

Write-Host 'Test-AuditCheckRobustness'

$singleEvent = [PSCustomObject]@{
    EntryType     = 'Error'
    TimeGenerated = Get-Date
    Source        = 'TestSource'
    Message       = 'Single event regression'
}
$eventOutput = Format-EventLogDetail -SystemEvents $singleEvent -AppEvents @()
if ($eventOutput -notmatch 'System Events \(Errors/Warnings\): 1') {
    Write-Error 'Format-EventLogDetail failed for a single system event under strict mode.'
    exit 1
}

$drivers = @(
    [PSCustomObject]@{ Name = 'disk'; DisplayName = 'Disk Driver'; State = 'Running'; StartMode = 'Manual' }
)
$driverOutput = Format-DriversList -Drivers $drivers -Stopped @()
if ($driverOutput -notmatch 'Auto-Start Stopped\s+: 0') {
    Write-Error 'Format-DriversList failed when no auto-start stopped drivers were present.'
    exit 1
}

$r = [PSCustomObject]@{ Steps = [System.Collections.ArrayList]@() }
Invoke-DriversAudit $r
$driverStep = $r.Steps[-1]
if ($driverStep.Status -eq 'Skip') {
    Write-Error "Invoke-DriversAudit skipped unexpectedly: $($driverStep.Output)"
    exit 1
}

$unsignedFilterInput = @(
    [PSCustomObject]@{ DeviceName = 'Volume'; Manufacturer = 'Microsoft'; IsSigned = $false }
    [PSCustomObject]@{ DeviceName = 'Sketchy NIC'; Manufacturer = 'Unknown OEM'; IsSigned = $false }
)
$actionable = @(Get-ActionableUnsignedPnPDrivers -Drivers $unsignedFilterInput)
if ($actionable.Count -ne 1 -or $actionable[0].DeviceName -ne 'Sketchy NIC') {
    Write-Error 'Get-ActionableUnsignedPnPDrivers did not filter inbox Microsoft volume drivers.'
    exit 1
}

$allow = @(Get-CdeDriverFilterAllowlistNames)
foreach ($must in @('WdFilter', 'partmgr', 'volsnap', 'iorate', 'rdyboost')) {
    if (-not (Test-CdeDriverFilterAllowlisted -FilterName $must -Allowlist $allow)) {
        Write-Error "Driver filter allowlist missing stock name: $must"
        exit 1
    }
}
if (Test-CdeDriverFilterAllowlisted -FilterName 'TotallyFakeRootkitFlt' -Allowlist $allow) {
    Write-Error 'Driver filter allowlist unexpectedly contains fake name.'
    exit 1
}

Write-Host '  PASS: event log, driver list, unsigned-driver filtering, filter allowlist'
Write-Host 'Test-AuditCheckRobustness: PASS'
exit 0
