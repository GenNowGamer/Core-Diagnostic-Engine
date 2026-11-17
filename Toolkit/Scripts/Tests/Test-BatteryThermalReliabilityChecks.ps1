#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$coreDir = Join-Path $testsRoot '..\Core'
Import-Module (Join-Path $coreDir 'Toolkit.Core.psm1') -Force -DisableNameChecking
. (Join-Path $coreDir 'HealthFindings.ps1')
. (Join-Path $coreDir 'HealthChecks.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

function Assert-True([string]$Name, [bool]$Condition) {
    if ($Condition) { $script:passed++; Write-Host "PASS: $Name"; return }
    $script:failures.Add($Name) | Out-Null
    Write-Host "FAIL: $Name"
}

Write-Host 'Test-BatteryThermalReliabilityChecks'

# Battery helper always returns an object
$snap = Get-BatteryHealthSnapshot
Assert-True -Name 'Battery snapshot has HasBattery property' -Condition ($null -ne $snap.PSObject.Properties['HasBattery'])
Assert-True -Name 'Battery HealthPercent null or 0-150' -Condition (
    $null -eq $snap.HealthPercent -or ($snap.HealthPercent -ge 0 -and $snap.HealthPercent -le 150)
)

# Dispatch map includes new checks
$map = Get-HealthCheckStepDispatchMap
Assert-True -Name 'battery_health registered' -Condition $map.ContainsKey('battery_health')
Assert-True -Name 'thermal_events registered' -Condition $map.ContainsKey('thermal_events')
Assert-True -Name 'reliability_monitor registered' -Condition $map.ContainsKey('reliability_monitor')

# Invoke checks against a fake workflow (Windows only)
if ((Get-EnvironmentMode) -eq 'Windows') {
    $r = [PSCustomObject]@{ Steps = [System.Collections.Generic.List[object]]::new() }
    & $map['battery_health'] $r @{ WorkflowsDir = '' }
    Assert-True -Name 'battery_health added a step' -Condition ($r.Steps.Count -ge 1)
    Assert-True -Name 'battery_health CheckId' -Condition ($r.Steps[-1].CheckId -eq 'battery_health')

    $r2 = [PSCustomObject]@{ Steps = [System.Collections.Generic.List[object]]::new() }
    & $map['thermal_events'] $r2 @{ WorkflowsDir = '' }
    Assert-True -Name 'thermal_events added a step' -Condition ($r2.Steps.Count -ge 1)

    $r3 = [PSCustomObject]@{ Steps = [System.Collections.Generic.List[object]]::new() }
    & $map['reliability_monitor'] $r3 @{ WorkflowsDir = '' }
    Assert-True -Name 'reliability_monitor added a step' -Condition ($r3.Steps.Count -ge 1)
}
else {
    Write-Host 'SKIP live invoke (not Windows)'
}

# Grouping + paired crash-burst deduplication
$t0 = Get-Date '2026-11-12 11:02:28'
$mockRecs = @(
    [PSCustomObject]@{ TimeGenerated = $t0; SourceName = 'Application Error'; EventIdentifier = 1000; ProductName = 'CropperKeeper.exe'; Message = '0xe0434352' },
    [PSCustomObject]@{ TimeGenerated = $t0.AddSeconds(3); SourceName = 'Application Error'; EventIdentifier = 1000; ProductName = 'CropperKeeper.exe'; Message = '0xc000041d' },
    [PSCustomObject]@{ TimeGenerated = $t0.AddHours(12); SourceName = 'Application Error'; EventIdentifier = 1000; ProductName = 'CropperKeeper.exe'; Message = '0xe0434352' },
    [PSCustomObject]@{ TimeGenerated = $t0.AddHours(12).AddSeconds(3); SourceName = 'Application Error'; EventIdentifier = 1000; ProductName = 'CropperKeeper.exe'; Message = '0xc000041d' },
    [PSCustomObject]@{ TimeGenerated = $t0.AddDays(4); SourceName = 'Microsoft-Windows-WER-SystemErrorReporting'; EventIdentifier = 1001; ProductName = 'Windows'; Message = 'The computer has rebooted from a bugcheck.  The bugcheck was: 0x0000009f (0x4).' }
)
$grouped = Group-ReliabilityFailureRecords -Records $mockRecs
Assert-True -Name 'Grouped raw count is 5' -Condition ($grouped.RawCount -eq 5)
Assert-True -Name 'Grouped distinct count deduplicates paired bursts to 3' -Condition ($grouped.DistinctCount -eq 3)
Assert-True -Name 'BugCheck label extracted' -Condition (@($grouped.Groups | Where-Object { $_.Label -eq 'Windows BugCheck 0x0000009f' }).Count -eq 1)

if ($failures.Count -gt 0) {
    Write-Host "Test-BatteryThermalReliabilityChecks: FAIL ($($failures.Count))"
    foreach ($f in $failures) { Write-Host "  - $f" }
    exit 1
}

Write-Host "Test-BatteryThermalReliabilityChecks: PASS ($passed assertions)"
exit 0
