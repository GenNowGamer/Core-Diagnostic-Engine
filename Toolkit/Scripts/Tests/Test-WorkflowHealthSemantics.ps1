#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for workflow health helpers in Toolkit.Core.psm1.
#>

$ErrorActionPreference = 'Stop'

$coreModule = Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Core\Toolkit.Core.psm1'
Import-Module $coreModule -Force -DisableNameChecking

$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

function Assert-equal {
    param(
        [string]$Name,
        [string]$Expected,
        [string]$Actual
    )

    if ($Expected -ne $Actual) {
        $failures.Add("$Name expected '$Expected' but was '$Actual'") | Out-Null
        Write-Host "FAIL: $Name" -ForegroundColor Red
        return
    }

    $script:passed++
    Write-Host "PASS: $Name" -ForegroundColor Green
}

function New-TestStep {
    param([string]$Name, [string]$Status)
    [PSCustomObject]@{ Name = $Name; Status = $Status }
}

# Scalar .Count trap: one Warn step must not report Healthy via unsafe count.
$oneWarn = @(New-TestStep -Name 'OnlyWarn' -Status 'Warn')
$unsafeWarnCount = ($oneWarn | Where-Object { $_.Status -eq 'Warn' }).Count
$safeWarnCount = @($oneWarn | Where-Object { $_.Status -eq 'Warn' }).Count
Assert-equal -Name 'Unsafe scalar warn count is unreliable' -Expected '1' -Actual ([string]$safeWarnCount)
if ($null -eq $unsafeWarnCount -or $unsafeWarnCount -ne 1) {
    $passed++
    Write-Host 'PASS: Unsafe scalar warn count demonstrates PS 5.1 trap' -ForegroundColor Green
} else {
    $failures.Add('Expected unsafe scalar .Count to fail on single-object pipeline') | Out-Null
    Write-Host 'FAIL: Unsafe scalar warn count trap not reproduced' -ForegroundColor Red
}

Assert-equal -Name 'Healthy when no issues' -Expected 'Healthy' -Actual (Get-WorkflowOverallHealth -Steps @(
    (New-TestStep -Name 'A' -Status 'Pass'),
    (New-TestStep -Name 'B' -Status 'Skip')
))

Assert-equal -Name 'Warning with one Warn' -Expected 'Warning' -Actual (Get-WorkflowOverallHealth -Steps @(
    (New-TestStep -Name 'A' -Status 'Pass'),
    (New-TestStep -Name 'B' -Status 'Warn')
))

Assert-equal -Name 'Critical with one Fail' -Expected 'Critical' -Actual (Get-WorkflowOverallHealth -Steps @(
    (New-TestStep -Name 'A' -Status 'Warn'),
    (New-TestStep -Name 'B' -Status 'Fail')
))

Assert-equal -Name 'Critical beats Warn' -Expected 'Critical' -Actual (Get-WorkflowOverallHealth -Steps @(
    (New-TestStep -Name 'A' -Status 'Fail')
))

# Soft/hard: ExpectedLimitation alone → HealthyWithNotes (not Warning)
$limitationStep = [PSCustomObject]@{
    Name = 'UsbSmart'
    Status = 'Pass'
    StructuredFindings = @(
        [PSCustomObject]@{
            findingId = 'smart.usb_limitation'
            status = 'Info'
            severity = 'Info'
            confidence = 95
            classification = 'ExpectedLimitation'
        }
    )
}
Assert-equal -Name 'HealthyWithNotes for ExpectedLimitation' -Expected 'HealthyWithNotes' -Actual (
    Get-WorkflowOverallHealth -Steps @($limitationStep)
)

$singleSignalStep = [PSCustomObject]@{
    Name = 'Activation'
    Status = 'Warn'
    StructuredFindings = @(
        [PSCustomObject]@{
            findingId = 'activation.not_activated'
            status = 'Warn'
            severity = 'Medium'
            confidence = 80
            classification = 'SingleSignal'
        }
    )
}
Assert-equal -Name 'Warning for SingleSignal Warn' -Expected 'Warning' -Actual (
    Get-WorkflowOverallHealth -Steps @($singleSignalStep)
)

$mixed = @(
    $limitationStep,
    [PSCustomObject]@{
        Name = 'Bsod'
        Status = 'Fail'
        StructuredFindings = @(
            [PSCustomObject]@{
                findingId = 'event.bugcheck'
                status = 'Fail'
                severity = 'Critical'
                confidence = 98
                classification = 'ConfirmedFault'
            }
        )
    }
)
Assert-equal -Name 'Critical beats HealthyWithNotes' -Expected 'Critical' -Actual (
    Get-WorkflowOverallHealth -Steps $mixed
)

Assert-equal -Name 'HealthyWithNotes for Incomplete step' -Expected 'HealthyWithNotes' -Actual (
    Get-WorkflowOverallHealth -Steps @(
        [PSCustomObject]@{ Name = 'MemCoverage'; Status = 'Incomplete' }
    )
)

$workflow = [PSCustomObject]@{
    WorkflowName = 'TestWorkflow'
    Steps = [System.Collections.Generic.List[object]]::new()
}
$workflow.Steps.Add((New-TestStep -Name 'WarnOnly' -Status 'Warn')) | Out-Null
$health = Set-WorkflowOverallHealth -WorkflowResult $workflow
Assert-equal -Name 'Set-WorkflowOverallHealth attaches Warning' -Expected 'Warning' -Actual $health
Assert-equal -Name 'Set-WorkflowOverallHealth property' -Expected 'Warning' -Actual ([string]$workflow.OverallHealth)

$counts = Get-WorkflowStepCounts -Steps @(
    (New-TestStep -Name 'P' -Status 'Pass'),
    (New-TestStep -Name 'W' -Status 'Warn'),
    (New-TestStep -Name 'F' -Status 'Fail'),
    (New-TestStep -Name 'S' -Status 'Skip')
)
Assert-equal -Name 'Step counts Pass' -Expected '1' -Actual ([string]$counts.Pass)
Assert-equal -Name 'Step counts Warn' -Expected '1' -Actual ([string]$counts.Warn)
Assert-equal -Name 'Step counts Fail' -Expected '1' -Actual ([string]$counts.Fail)
Assert-equal -Name 'Step counts Skip' -Expected '1' -Actual ([string]$counts.Skip)

Write-Host "`n--- SUMMARY ---" -ForegroundColor Cyan
Write-Host "Passed: $passed"
Write-Host "Failed: $($failures.Count)"
if ($failures.Count -gt 0) {
    foreach ($failure in $failures) {
        Write-Host "  $failure" -ForegroundColor Red
    }
    exit 1
}

exit 0
