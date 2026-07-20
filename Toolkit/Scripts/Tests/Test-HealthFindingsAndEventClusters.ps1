#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$coreDir = Join-Path $testsRoot '..\Core'
. (Join-Path $coreDir 'HealthFindings.ps1')
. (Join-Path $coreDir 'EventFindingClusters.ps1')

$passFinding = New-HealthFinding -FindingId 'health.cpu.load_ok' -CheckId 'cpu_load' `
    -Finding 'CPU ok' -Severity 'Info' -Confidence 80 -Status 'Pass'
$warnFinding = New-HealthFinding -FindingId 'health.cpu.high_load' -CheckId 'cpu_load' `
    -Finding 'CPU high' -Severity 'High' -Confidence 90 -Status 'Warn'
$status = Get-HealthStepStatusFromFindings -Findings @($passFinding, $warnFinding)
if ($status -ne 'Warn') {
    Write-Error "Expected Warn rollup, got $status"
    exit 1
}

if ($passFinding.classification -ne 'Inventory') {
    Write-Error "Expected Pass finding Classification=Inventory, got $($passFinding.classification)"
    exit 1
}
if ($warnFinding.classification -ne 'CorroboratedSuspect') {
    Write-Error "Expected High/90 Warn Classification=CorroboratedSuspect, got $($warnFinding.classification)"
    exit 1
}
if (-not (Test-HealthFindingRequiresAttention -Classification $warnFinding.classification -Status $warnFinding.status -Severity $warnFinding.severity -Confidence $warnFinding.confidence)) {
    Write-Error 'CorroboratedSuspect Warn should require attention'
    exit 1
}
if (Test-HealthFindingRequiresAttention -Classification $passFinding.classification -Status $passFinding.status -Severity $passFinding.severity -Confidence $passFinding.confidence) {
    Write-Error 'Inventory Pass should not require attention'
    exit 1
}

$single = New-HealthFinding -FindingId 'health.disk.low_space' -CheckId 'disk_space' `
    -Finding 'Low disk' -Severity 'Medium' -Confidence 80 -Status 'Warn'
if ($single.classification -ne 'SingleSignal') {
    Write-Error "Expected Medium Warn Classification=SingleSignal, got $($single.classification)"
    exit 1
}

$fail = New-HealthFinding -FindingId 'event.system_crash' -CheckId 'critical_events_7d' `
    -Finding 'BSOD' -Severity 'Critical' -Confidence 98 -Status 'Fail'
if ($fail.classification -ne 'ConfirmedFault') {
    Write-Error "Expected Fail Classification=ConfirmedFault, got $($fail.classification)"
    exit 1
}

$incomplete = New-HealthFinding -FindingId 'gpu.na' -CheckId 'gpu_functional_tests' `
    -Finding 'N/A in WinPE' -Severity 'Info' -Confidence 100 -Status 'N/A'
if ($incomplete.classification -ne 'Incomplete') {
    Write-Error "Expected N/A Classification=Incomplete, got $($incomplete.classification)"
    exit 1
}
if (Test-HealthFindingRequiresAttention -Classification $incomplete.classification -Status $incomplete.status) {
    Write-Error 'Incomplete should not require attention'
    exit 1
}

$limited = New-HealthFinding -FindingId 'smart.usb' -CheckId 'disk_smart' `
    -Finding 'USB SMART unavailable' -Severity 'Info' -Confidence 95 -Status 'Info' `
    -Classification 'ExpectedLimitation'
if ($limited.classification -ne 'ExpectedLimitation') {
    Write-Error "Expected explicit ExpectedLimitation, got $($limited.classification)"
    exit 1
}
if (Test-HealthFindingRequiresAttention -Classification $limited.classification -Status $limited.status) {
    Write-Error 'ExpectedLimitation should not require attention'
    exit 1
}

$step = @{ Name = 'CPULoad'; Status = 'Pass'; Detail = 'test'; Output = 'summary'; CheckId = 'cpu_load' }
Add-HealthFindingsToStep -Step $step -Findings @($warnFinding) -SummaryText 'summary'
if ($step.Status -ne 'Warn') {
    Write-Error "Add-HealthFindingsToStep did not set Warn"
    exit 1
}
if ($step.Output -notmatch '\[HEALTH:FINDING\]') {
    Write-Error "Expected HEALTH:FINDING marker in output"
    exit 1
}
if ($step.Output -notmatch '"classification":"CorroboratedSuspect"') {
    Write-Error 'Expected classification in HEALTH:FINDING marker JSON'
    exit 1
}

$events = @(
    [PSCustomObject]@{ Source = 'Microsoft-Windows-Kernel-Power'; EventID = 41; TimeGenerated = (Get-Date).AddMinutes(-2); Message = 'kernel power'; Count = 1; LogName = 'System' }
    [PSCustomObject]@{ Source = 'EventLog'; EventID = 6008; TimeGenerated = (Get-Date).AddMinutes(-1); Message = 'unexpected shutdown'; Count = 1; LogName = 'System' }
)
$clusters = @(Invoke-EventFindingClustering -CheckId 'audit_event_logs' -Events $events)
$shutdown = @($clusters | Where-Object { $_.findingId -eq 'event.unexpected_shutdown' })
if ($shutdown.Count -ne 1) {
    Write-Error "Expected unexpected_shutdown cluster"
    exit 1
}
if ([int]$shutdown[0].confidence -lt 70) {
    Write-Error "Expected high confidence for shutdown cluster"
    exit 1
}
if ($shutdown[0].classification -notin @('CorroboratedSuspect', 'SingleSignal', 'ConfirmedFault')) {
    Write-Error "Unexpected shutdown classification: $($shutdown[0].classification)"
    exit 1
}

$planned = @(
    [PSCustomObject]@{ Source = 'Microsoft-Windows-Kernel-Power'; EventID = 41; TimeGenerated = (Get-Date).AddMinutes(-2); Message = 'kernel power'; Count = 1; LogName = 'System' }
    [PSCustomObject]@{ Source = 'EventLog'; EventID = 6008; TimeGenerated = (Get-Date).AddMinutes(-1); Message = 'unexpected shutdown'; Count = 1; LogName = 'System' }
    [PSCustomObject]@{ Source = 'User32'; EventID = 1074; TimeGenerated = (Get-Date).AddMinutes(-3); Message = 'planned'; Count = 1; LogName = 'System' }
)
$suppressed = @(Invoke-EventFindingClustering -CheckId 'audit_event_logs' -Events $planned)
if (@($suppressed | Where-Object { $_.findingId -eq 'event.unexpected_shutdown' }).Count -ne 0) {
    Write-Error "Planned restart should suppress unexpected_shutdown"
    exit 1
}

$inventory = New-InventoryHealthFinding -CheckId 'os_version' -Finding 'Windows 11' -Evidence @('Build 26100')
if ($inventory.findingId -ne 'inventory.os_version' -or $inventory.status -ne 'Info') {
    Write-Error "New-InventoryHealthFinding shape mismatch"
    exit 1
}
if ($inventory.classification -ne 'Inventory') {
    Write-Error "Inventory helper should set Classification=Inventory"
    exit 1
}

$unmatched = @(
    [PSCustomObject]@{ Source = 'SomeApp'; EventID = 9999; TimeGenerated = (Get-Date).AddMinutes(-5); Message = 'mystery error'; Count = 3; LogName = 'Application' }
)
$residual = @(Invoke-EventFindingClustering -CheckId 'event_errors_24h' -Events $unmatched)
$unclassified = @($residual | Where-Object { $_.findingId -like 'event.unclassified*' })
if ($unclassified.Count -lt 1) {
    Write-Error "Expected unclassified residual finding"
    exit 1
}
if ($unclassified[0].classification -ne 'Inventory') {
    Write-Error "Unclassified residuals should be Inventory (not attention-worthy)"
    exit 1
}
if (Test-HealthFindingRequiresAttention -Classification $unclassified[0].classification -Status $unclassified[0].status -Severity $unclassified[0].severity -Confidence $unclassified[0].confidence) {
    Write-Error 'Unclassified Inventory residual should not require attention'
    exit 1
}

# --- P0-2: frequency gates, WHEA split, residual cap ---

$oneDisk = @(
    [PSCustomObject]@{ Source = 'Disk'; EventID = 153; TimeGenerated = (Get-Date).AddMinutes(-5); Message = 'reset'; Count = 1; LogName = 'System' }
)
$diskOnce = @(Invoke-EventFindingClustering -CheckId 'critical_events_7d' -Events $oneDisk)
if (@($diskOnce | Where-Object { $_.findingId -eq 'event.disk_instability' }).Count -ne 0) {
    Write-Error 'Single Disk 153 should not raise disk_instability (minEventCount=2)'
    exit 1
}

$twoDisk = @(
    [PSCustomObject]@{ Source = 'Disk'; EventID = 153; TimeGenerated = (Get-Date).AddMinutes(-5); Message = 'reset1'; Count = 1; LogName = 'System' }
    [PSCustomObject]@{ Source = 'Disk'; EventID = 153; TimeGenerated = (Get-Date).AddMinutes(-4); Message = 'reset2'; Count = 1; LogName = 'System' }
)
$diskTwice = @(Invoke-EventFindingClustering -CheckId 'critical_events_7d' -Events $twoDisk)
if (@($diskTwice | Where-Object { $_.findingId -eq 'event.disk_instability' }).Count -ne 1) {
    Write-Error 'Two Disk 153 events should raise disk_instability'
    exit 1
}

$oneAppCrash = @(
    [PSCustomObject]@{ Source = 'Application Error'; EventID = 1000; TimeGenerated = (Get-Date).AddMinutes(-2); Message = 'faulting'; Count = 1; LogName = 'Application' }
)
$appOnce = @(Invoke-EventFindingClustering -CheckId 'audit_event_logs' -Events $oneAppCrash)
if (@($appOnce | Where-Object { $_.findingId -eq 'event.application_crash' }).Count -ne 0) {
    Write-Error 'Single Application Error 1000 should not raise application_crash (minEventCount=3)'
    exit 1
}

$wheaCorrectedOnce = @(
    [PSCustomObject]@{ Source = 'Microsoft-Windows-WHEA-Logger'; EventID = 17; TimeGenerated = (Get-Date).AddMinutes(-3); Message = 'corrected'; Count = 1; LogName = 'System' }
)
$wheaSoft = @(Invoke-EventFindingClustering -CheckId 'critical_events_7d' -Events $wheaCorrectedOnce)
if (@($wheaSoft | Where-Object { $_.findingId -like 'event.whea*' }).Count -ne 0) {
    Write-Error 'Single corrected WHEA 17 should not raise a WHEA finding (minEventCount=3)'
    exit 1
}

$wheaCorrectedBurst = @(
    1..3 | ForEach-Object {
        [PSCustomObject]@{ Source = 'Microsoft-Windows-WHEA-Logger'; EventID = 17; TimeGenerated = (Get-Date).AddMinutes(-$_); Message = "corrected $_"; Count = 1; LogName = 'System' }
    }
)
$wheaBurst = @(Invoke-EventFindingClustering -CheckId 'critical_events_7d' -Events $wheaCorrectedBurst)
$correctedHit = @($wheaBurst | Where-Object { $_.findingId -eq 'event.whea_corrected_error' })
if ($correctedHit.Count -ne 1) {
    Write-Error 'Three corrected WHEA 17 events should raise whea_corrected_error'
    exit 1
}
if ($correctedHit[0].severity -ne 'Medium') {
    Write-Error "Expected Medium severity for corrected WHEA, got $($correctedHit[0].severity)"
    exit 1
}

$wheaFatal = @(
    [PSCustomObject]@{ Source = 'Microsoft-Windows-WHEA-Logger'; EventID = 18; TimeGenerated = (Get-Date).AddMinutes(-2); Message = 'fatal'; Count = 1; LogName = 'System' }
)
$wheaHard = @(Invoke-EventFindingClustering -CheckId 'critical_events_7d' -Events $wheaFatal)
$uncorrectedHit = @($wheaHard | Where-Object { $_.findingId -eq 'event.whea_uncorrected_error' })
if ($uncorrectedHit.Count -ne 1) {
    Write-Error 'WHEA 18 should raise whea_uncorrected_error immediately'
    exit 1
}
if ($uncorrectedHit[0].severity -ne 'High') {
    Write-Error "Expected High severity for uncorrected WHEA, got $($uncorrectedHit[0].severity)"
    exit 1
}

$manyResiduals = @(
    1..8 | ForEach-Object {
        [PSCustomObject]@{ Source = ("NoiseApp$_"); EventID = (9000 + $_); TimeGenerated = (Get-Date).AddMinutes(-$_); Message = "noise $_"; Count = $_; LogName = 'Application' }
    }
)
$capped = @(Invoke-EventFindingClustering -CheckId 'event_errors_24h' -Events $manyResiduals)
$detailResiduals = @($capped | Where-Object { $_.findingId -like 'event.unclassified.*' -and $_.findingId -ne 'event.unclassified.aggregate' })
$aggregate = @($capped | Where-Object { $_.findingId -eq 'event.unclassified.aggregate' })
if ($detailResiduals.Count -ne 5) {
    Write-Error "Expected 5 detailed unclassified residuals, got $($detailResiduals.Count)"
    exit 1
}
if ($aggregate.Count -ne 1) {
    Write-Error 'Expected one aggregate unclassified residual finding'
    exit 1
}

Write-Host 'Test-HealthFindingsAndEventClusters: PASS'
exit 0
