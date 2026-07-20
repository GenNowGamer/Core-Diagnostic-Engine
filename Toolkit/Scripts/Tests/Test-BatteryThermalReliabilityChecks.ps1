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

if ($failures.Count -gt 0) {
    Write-Host "Test-BatteryThermalReliabilityChecks: FAIL ($($failures.Count))"
    foreach ($f in $failures) { Write-Host "  - $f" }
    exit 1
}

Write-Host "Test-BatteryThermalReliabilityChecks: PASS ($passed assertions)"
exit 0
