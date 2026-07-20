#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$coreDir = Join-Path $testsRoot '..\Core'
. (Join-Path $coreDir 'HealthFindings.ps1')
. (Join-Path $coreDir 'HealthFindingCorroboration.ps1')

function Assert-Eq([string]$Name, $Expected, $Actual) {
    if ("$Expected" -ne "$Actual") {
        Write-Error "$Name expected=$Expected actual=$Actual"
        exit 1
    }
    Write-Host "PASS: $Name"
}

Assert-Eq 'ConfirmedFault floor' 90 (
    Get-CalibratedHealthFindingConfidence -Classification 'ConfirmedFault' -Confidence 80 -Status 'Fail'
)
Assert-Eq 'CorroboratedSuspect floor' 75 (
    Get-CalibratedHealthFindingConfidence -Classification 'CorroboratedSuspect' -Confidence 70 -Status 'Warn'
)
Assert-Eq 'SingleSignal unchanged' 80 (
    Get-CalibratedHealthFindingConfidence -Classification 'SingleSignal' -Confidence 80 -Status 'Warn'
)
Assert-Eq 'Inventory Info noise cap' 40 (
    Get-CalibratedHealthFindingConfidence -Classification 'Inventory' -Confidence 85 -Status 'Info'
)
Assert-Eq 'Inventory Pass unchanged' 85 (
    Get-CalibratedHealthFindingConfidence -Classification 'Inventory' -Confidence 85 -Status 'Pass'
)
Assert-Eq 'ExpectedLimitation floor' 85 (
    Get-CalibratedHealthFindingConfidence -Classification 'ExpectedLimitation' -Confidence 60 -Status 'Info'
)
Assert-Eq 'Incomplete floor' 90 (
    Get-CalibratedHealthFindingConfidence -Classification 'Incomplete' -Confidence 50 -Status 'N/A'
)

$inv = New-HealthFinding -FindingId 'event.unclassified_overflow' -CheckId 'critical_events_7d' `
    -Finding 'Other errors' -Severity 'Info' -Confidence 85 -Status 'Info' -Classification 'Inventory'
$fault = New-HealthFinding -FindingId 'event.bugcheck' -CheckId 'critical_events_7d' `
    -Finding 'BSOD' -Severity 'Critical' -Confidence 80 -Status 'Fail' -Classification 'ConfirmedFault'

$step = @{
    Name = 'CriticalEvents'; Status = 'Fail'; Detail = 'test'; Output = 'body'; CheckId = 'critical_events_7d'
}
Add-HealthFindingsToStep -Step $step -Findings @($inv, $fault) -SummaryText 'test'
$wf = [PSCustomObject]@{ Steps = [System.Collections.ArrayList]@([PSCustomObject]$step) }

$n = Invoke-HealthFindingConfidenceCalibration -WorkflowResult $wf
if ($n -lt 2) {
    Write-Error "Expected at least 2 confidence adjustments, got $n"
    exit 1
}

$after = @($wf.Steps[0].StructuredFindings)
$invAfter = @($after | Where-Object { $_.findingId -eq 'event.unclassified_overflow' })[0]
$faultAfter = @($after | Where-Object { $_.findingId -eq 'event.bugcheck' })[0]
Assert-Eq 'Workflow Inventory capped' 40 $invAfter.confidence
Assert-Eq 'Workflow ConfirmedFault floored' 90 $faultAfter.confidence

Write-Host 'Test-HealthFindingConfidenceCalibration: PASS'
exit 0
