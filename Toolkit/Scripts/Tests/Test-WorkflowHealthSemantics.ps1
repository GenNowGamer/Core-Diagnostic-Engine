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

function Assert-Equal {
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
Assert-Equal -Name 'Unsafe scalar warn count is unreliable' -Expected '1' -Actual ([string]$safeWarnCount)
if ($null -eq $unsafeWarnCount -or $unsafeWarnCount -ne 1) {
    $passed++
    Write-Host 'PASS: Unsafe scalar warn count demonstrates PS 5.1 trap' -ForegroundColor Green
} else {
    $failures.Add('Expected unsafe scalar .Count to fail on single-object pipeline') | Out-Null
    Write-Host 'FAIL: Unsafe scalar warn count trap not reproduced' -ForegroundColor Red
}

Assert-Equal -Name 'Healthy when no issues' -Expected 'Healthy' -Actual (Get-WorkflowOverallHealth -Steps @(
    (New-TestStep -Name 'A' -Status 'Pass'),
    (New-TestStep -Name 'B' -Status 'Skip')
))

Assert-Equal -Name 'Warning with one Warn' -Expected 'Warning' -Actual (Get-WorkflowOverallHealth -Steps @(
    (New-TestStep -Name 'A' -Status 'Pass'),
    (New-TestStep -Name 'B' -Status 'Warn')
))

Assert-Equal -Name 'Critical with one Fail' -Expected 'Critical' -Actual (Get-WorkflowOverallHealth -Steps @(
    (New-TestStep -Name 'A' -Status 'Warn'),
    (New-TestStep -Name 'B' -Status 'Fail')
))

Assert-Equal -Name 'Critical beats Warn' -Expected 'Critical' -Actual (Get-WorkflowOverallHealth -Steps @(
    (New-TestStep -Name 'A' -Status 'Fail')
))

$workflow = [PSCustomObject]@{
    WorkflowName = 'TestWorkflow'
    Steps = [System.Collections.Generic.List[object]]::new()
}
$workflow.Steps.Add((New-TestStep -Name 'WarnOnly' -Status 'Warn')) | Out-Null
$health = Set-WorkflowOverallHealth -WorkflowResult $workflow
Assert-Equal -Name 'Set-WorkflowOverallHealth attaches Warning' -Expected 'Warning' -Actual $health
Assert-Equal -Name 'Set-WorkflowOverallHealth property' -Expected 'Warning' -Actual ([string]$workflow.OverallHealth)

$counts = Get-WorkflowStepCounts -Steps @(
    (New-TestStep -Name 'P' -Status 'Pass'),
    (New-TestStep -Name 'W' -Status 'Warn'),
    (New-TestStep -Name 'F' -Status 'Fail'),
    (New-TestStep -Name 'S' -Status 'Skip')
)
Assert-Equal -Name 'Step counts Pass' -Expected '1' -Actual ([string]$counts.Pass)
Assert-Equal -Name 'Step counts Warn' -Expected '1' -Actual ([string]$counts.Warn)
Assert-Equal -Name 'Step counts Fail' -Expected '1' -Actual ([string]$counts.Fail)
Assert-Equal -Name 'Step counts Skip' -Expected '1' -Actual ([string]$counts.Skip)

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
