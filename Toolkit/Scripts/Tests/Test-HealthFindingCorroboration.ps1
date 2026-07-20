#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$coreDir = Join-Path $testsRoot '..\Core'
. (Join-Path $coreDir 'HealthFindings.ps1')
. (Join-Path $coreDir 'HealthFindingCorroboration.ps1')

$disk = New-HealthFinding -FindingId 'event.disk_instability' -CheckId 'critical_events_7d' `
    -Finding 'Disk / Storage Instability' -Severity 'High' -Confidence 80 -Status 'Warn' -Classification 'SingleSignal'
$whea = New-HealthFinding -FindingId 'event.whea_uncorrected_error' -CheckId 'critical_events_7d' `
    -Finding 'WHEA Uncorrected' -Severity 'High' -Confidence 90 -Status 'Warn' -Classification 'CorroboratedSuspect'

$step = @{
    Name = 'CriticalEvents'; Status = 'Warn'; Detail = 'test'; Output = 'body'; CheckId = 'critical_events_7d'
}
Add-HealthFindingsToStep -Step $step -Findings @($disk, $whea) -SummaryText 'test'

$wf = [PSCustomObject]@{
    Steps = [System.Collections.ArrayList]@([PSCustomObject]$step)
}

$changed = Invoke-HealthFindingCorroboration -WorkflowResult $wf
if ($changed -lt 1) {
    Write-Error "Expected corroboration changes, got $changed"
    exit 1
}

$after = @($wf.Steps[0].StructuredFindings)
$diskAfter = @($after | Where-Object { $_.findingId -eq 'event.disk_instability' })[0]
$wheaAfter = @($after | Where-Object { $_.findingId -eq 'event.whea_uncorrected_error' })[0]
if ($diskAfter.classification -ne 'CorroboratedSuspect') {
    Write-Error "Disk should promote to CorroboratedSuspect, got $($diskAfter.classification)"
    exit 1
}
if ($wheaAfter.classification -ne 'ConfirmedFault' -or $wheaAfter.status -ne 'Fail') {
    Write-Error "WHEA uncorrected + disk should promote to ConfirmedFault/Fail"
    exit 1
}

Write-Host 'Test-HealthFindingCorroboration: PASS'
exit 0
