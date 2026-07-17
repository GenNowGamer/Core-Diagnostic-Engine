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

$unmatched = @(
    [PSCustomObject]@{ Source = 'SomeApp'; EventID = 9999; TimeGenerated = (Get-Date).AddMinutes(-5); Message = 'mystery error'; Count = 3; LogName = 'Application' }
)
$residual = @(Invoke-EventFindingClustering -CheckId 'event_errors_24h' -Events $unmatched)
if (@($residual | Where-Object { $_.findingId -like 'event.unclassified*' }).Count -lt 1) {
    Write-Error "Expected unclassified residual finding"
    exit 1
}

Write-Host 'Test-HealthFindingsAndEventClusters: PASS'
exit 0
