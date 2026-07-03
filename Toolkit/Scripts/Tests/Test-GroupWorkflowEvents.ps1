#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for Group-WorkflowEvents and Format-WorkflowEventSummaryText.
#>

$ErrorActionPreference = 'Stop'

$coreModule = Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Core\Toolkit.Core.psm1'
Import-Module $coreModule -Force -DisableNameChecking

$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if (-not $Condition) {
        $failures.Add("$Name $Detail") | Out-Null
        Write-Host "FAIL: $Name $Detail" -ForegroundColor Red
        return
    }
    $script:passed++
    Write-Host "PASS: $Name" -ForegroundColor Green
}

$empty = Group-WorkflowEvents -Events @()
Assert-True -Name 'Empty input returns no groups' -Condition ($empty.Count -eq 0)

$now = Get-Date
$events = @(
    [PSCustomObject]@{ TimeCreated = $now; ProviderName = 'VSS'; Id = 13; Message = 'Access denied A' },
    [PSCustomObject]@{ TimeCreated = $now.AddMinutes(-1); ProviderName = 'VSS'; Id = 13; Message = 'Access denied B' },
    [PSCustomObject]@{ TimeCreated = $now.AddMinutes(-2); ProviderName = 'Application Error'; Id = 1000; Message = 'Faulting app' }
)

$groups = @(Group-WorkflowEvents -Events $events)
Assert-True -Name 'Groups by provider and id' -Condition ($groups.Count -eq 2)

$vssGroup = @($groups | Where-Object { $_.ProviderName -eq 'VSS' -and $_.Id -eq 13 } | Select-Object -First 1)[0]
Assert-True -Name 'VSS group exists' -Condition ($null -ne $vssGroup)
Assert-True -Name 'VSS Count property' -Condition ($vssGroup.Count -eq 2)
Assert-True -Name 'Sample message present' -Condition (-not [string]::IsNullOrWhiteSpace($vssGroup.SampleMessage))

$longMessage = 'x' * 250
$longEvents = @(
    [PSCustomObject]@{ TimeCreated = $now; ProviderName = 'Test'; Id = 1; Message = $longMessage }
)
$longGroup = (Group-WorkflowEvents -Events $longEvents)[0]
Assert-True -Name 'Sample message truncated' -Condition ($longGroup.SampleMessage.Length -le 203)

$summaryText = Format-WorkflowEventSummaryText -EventSummary $groups -EventCount 3
Assert-True -Name 'Summary mentions event count' -Condition ($summaryText -like '3 event(s)*')
Assert-True -Name 'Summary mentions group count' -Condition ($summaryText -like '*2 group(s)*')

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
