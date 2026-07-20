#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for HW Incomplete status + confirm-on-Fail (P1-3).
#>
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$workflows = Join-Path $testsRoot '..\Workflows'
$coreDir = Join-Path $testsRoot '..\Core'
Import-Module (Join-Path $coreDir 'Toolkit.Core.psm1') -Force -DisableNameChecking
. (Join-Path $workflows 'HardwareCommon.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

function Assert-True([string]$Name, [bool]$Condition) {
    if ($Condition) {
        $script:passed++
        Write-Host "PASS: $Name"
        return
    }
    $script:failures.Add($Name) | Out-Null
    Write-Host "FAIL: $Name"
}

function Assert-Eq([string]$Name, $Expected, $Actual) {
    if ("$Expected" -eq "$Actual") {
        $script:passed++
        Write-Host "PASS: $Name"
        return
    }
    $script:failures.Add("$Name :: expected=$Expected actual=$Actual") | Out-Null
    Write-Host "FAIL: $Name :: expected=$Expected actual=$Actual"
}

Write-Host 'Test-HwIncompleteAndConfirmOnFail'

Assert-True -Name 'Failed string is hard fail' -Condition (Test-HwTestResultIsHardFail -TestResult 'Failed: bit error')
Assert-True -Name 'Bool false is hard fail' -Condition (Test-HwTestResultIsHardFail -TestResult $false)
Assert-True -Name 'Passed not hard fail' -Condition (-not (Test-HwTestResultIsHardFail -TestResult 'Passed: ok'))
Assert-True -Name 'Warn not hard fail' -Condition (-not (Test-HwTestResultIsHardFail -TestResult 'Warn: soft'))
Assert-True -Name 'Incomplete not hard fail' -Condition (-not (Test-HwTestResultIsHardFail -TestResult 'Incomplete: coverage'))

$script:HwProfileName = 'Quick'
$script:HwProfileParams = @{ failOnSkipInExtended = $false }
$script:HwGlobalTotal = 2
$script:HwGlobalDone = 0
$script:HwStorageElevationWarn = $false
$script:HwStorageSkippedInRun = $false

# Confirm-on-Fail: first Fail, second Pass → Warn
$calls = [ref]0
$r1 = [PSCustomObject]@{ Steps = [System.Collections.Generic.List[object]]::new() }
$counter = [ref]0
Invoke-SingleTest -Category 'CPU' -TestName 'FlakyConfirm' -Result $r1 -Counter $counter -Total 1 -Phase 't' -TestAction {
    $calls.Value++
    if ($calls.Value -eq 1) { return 'Failed: intermittent' }
    return 'Passed: stable'
}
Assert-Eq -Name 'Confirm-on-Fail step status' -Expected 'Warn' -Actual $r1.Steps[0].Status
Assert-True -Name 'Confirm-on-Fail detail notes retry' -Condition ([string]$r1.Steps[0].Detail -match 'confirmed Pass on retry')
Assert-Eq -Name 'Confirm-on-Fail called twice' -Expected '2' -Actual ([string]$calls.Value)

# Persistent Fail stays Fail (two Failed results)
$calls2 = [ref]0
$r2 = [PSCustomObject]@{ Steps = [System.Collections.Generic.List[object]]::new() }
$counter2 = [ref]0
Invoke-SingleTest -Category 'CPU' -TestName 'HardFail' -Result $r2 -Counter $counter2 -Total 1 -Phase 't' -TestAction {
    $calls2.Value++
    return 'Failed: stuck'
}
Assert-Eq -Name 'Persistent Fail status' -Expected 'Fail' -Actual $r2.Steps[0].Status
Assert-Eq -Name 'Persistent Fail retried once' -Expected '2' -Actual ([string]$calls2.Value)

# Incomplete: prefix → Incomplete step (not Pass, not Fail)
$r3 = [PSCustomObject]@{ Steps = [System.Collections.Generic.List[object]]::new() }
$counter3 = [ref]0
Invoke-SingleTest -Category 'Memory' -TestName 'CoverageGap' -Result $r3 -Counter $counter3 -Total 1 -Phase 't' -TestAction {
    return 'Incomplete: 8% of installed RAM — run CHU'
}
Assert-Eq -Name 'Incomplete step status' -Expected 'Incomplete' -Actual $r3.Steps[0].Status
Assert-True -Name 'Incomplete detail preserved' -Condition ([string]$r3.Steps[0].Detail -match 'CHU')

# Incomplete-only run → HealthyWithNotes
Assert-Eq -Name 'Incomplete overall HealthyWithNotes' -Expected 'HealthyWithNotes' -Actual (
    Get-WorkflowOverallHealth -Steps @($r3.Steps[0])
)

if ($failures.Count -gt 0) {
    Write-Host "Test-HwIncompleteAndConfirmOnFail: FAIL ($($failures.Count))"
    foreach ($f in $failures) { Write-Host "  - $f" }
    exit 1
}

Write-Host "Test-HwIncompleteAndConfirmOnFail: PASS ($passed assertions)"
exit 0
