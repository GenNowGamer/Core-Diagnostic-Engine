#Requires -Version 5.1
<#
.SYNOPSIS
    Evaluates CDE bench-run CSV results and emits PASS/FAIL using bench thresholds.
.DESCRIPTION
    Reads Docs\BenchLab\CDE_Bench_TestCase_Sheet.csv by default.
    Returns exit code 0 on PASS, 1 on FAIL.
#>
[CmdletBinding()]
param(
    [string]$CsvPath = '',
    [double]$MinDetectionRate = 0.95,
    [double]$MinRemediationRate = 0.95,
    [double]$MinRebootCleanRate = 0.95,
    [double]$MaxFalsePositiveRate = 0.02,
    [double]$MaxStabilityFailureRate = 0.02,
    [double]$MinAverageScenarioScore = 4.5
)

$ErrorActionPreference = 'Stop'

$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$toolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $testsDir '..\..'))
if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    $CsvPath = Join-Path $toolkitRoot 'Docs\BenchLab\CDE_Bench_TestCase_Sheet.csv'
}

if (-not (Test-Path -LiteralPath $CsvPath)) {
    Write-Host "[FAIL] Bench CSV not found: $CsvPath" -ForegroundColor Red
    exit 1
}

$rows = @(Import-Csv -LiteralPath $CsvPath)
$rows = @($rows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.ScenarioId) })
if ($rows.Count -eq 0) {
    Write-Host "[FAIL] Bench CSV has no scenario rows: $CsvPath" -ForegroundColor Red
    exit 1
}

$normalizedRows = @(
    foreach ($row in $rows) {
        $scoreDetection = 0
        $scoreRemediation = 0
        $scoreCleanReboot = 0
        $scenarioScore = 0.0
        $falsePositiveCount = 0
        $scanErrors = 0

        try { $scoreDetection = [int]$row.ScoreDetection } catch { }
        try { $scoreRemediation = [int]$row.ScoreRemediation } catch { }
        try { $scoreCleanReboot = [int]$row.ScoreCleanReboot } catch { }
        try { $scenarioScore = [double]$row.ScenarioScore } catch { }
        try { $falsePositiveCount = [int]$row.FalsePositiveCount } catch { }
        try { $scanErrors = [int]$row.ScanErrors } catch { }

        [PSCustomObject]@{
            Raw = $row
            ScoreDetection = $scoreDetection
            ScoreRemediation = $scoreRemediation
            ScoreCleanReboot = $scoreCleanReboot
            ScenarioScore = $scenarioScore
            FalsePositiveCount = $falsePositiveCount
            ScanErrors = $scanErrors
            CoverageStatus = [string]$row.CoverageStatus
            Tier = [string]$row.Tier
            ScenarioId = [string]$row.ScenarioId
        }
    }
)

$total = $normalizedRows.Count
$detectionPass = @($normalizedRows | Where-Object { $_.ScoreDetection -eq 1 }).Count
$remediationPass = @($normalizedRows | Where-Object { $_.ScoreRemediation -eq 1 }).Count
$rebootCleanPass = @($normalizedRows | Where-Object { $_.ScoreCleanReboot -eq 1 }).Count

$avgScore = 0.0
if ($total -gt 0) {
    $avgScore = (@($normalizedRows | ForEach-Object { $_.ScenarioScore }) | Measure-Object -Average).Average
}

$benignRows = @($normalizedRows | Where-Object { $_.Tier -match 'C' -or $_.ScenarioId -in @('S17') })
$benignCount = $benignRows.Count
$falsePositiveRows = @($benignRows | Where-Object { $_.FalsePositiveCount -gt 0 }).Count
$falsePositiveRate = if ($benignCount -gt 0) { $falsePositiveRows / $benignCount } else { 0.0 }

$stabilityFailures = @($normalizedRows | Where-Object {
    ($_.CoverageStatus -ne 'Full') -or ($_.ScanErrors -gt 0)
}).Count
$stabilityFailureRate = $stabilityFailures / $total

$detectionRate = $detectionPass / $total
$remediationRate = $remediationPass / $total
$rebootCleanRate = $rebootCleanPass / $total

$checks = @(
    [PSCustomObject]@{ Name='DetectionRate'; Value=$detectionRate; Pass=($detectionRate -ge $MinDetectionRate); Threshold=">= $MinDetectionRate" },
    [PSCustomObject]@{ Name='RemediationRate'; Value=$remediationRate; Pass=($remediationRate -ge $MinRemediationRate); Threshold=">= $MinRemediationRate" },
    [PSCustomObject]@{ Name='RebootCleanRate'; Value=$rebootCleanRate; Pass=($rebootCleanRate -ge $MinRebootCleanRate); Threshold=">= $MinRebootCleanRate" },
    [PSCustomObject]@{ Name='FalsePositiveRate'; Value=$falsePositiveRate; Pass=($falsePositiveRate -le $MaxFalsePositiveRate); Threshold="<= $MaxFalsePositiveRate" },
    [PSCustomObject]@{ Name='StabilityFailureRate'; Value=$stabilityFailureRate; Pass=($stabilityFailureRate -le $MaxStabilityFailureRate); Threshold="<= $MaxStabilityFailureRate" },
    [PSCustomObject]@{ Name='AverageScenarioScore'; Value=$avgScore; Pass=($avgScore -ge $MinAverageScenarioScore); Threshold=">= $MinAverageScenarioScore" }
)

Write-Host "`n=== CDE Bench Gate Summary ===" -ForegroundColor Cyan
Write-Host "CSV: $CsvPath"
Write-Host "Total Scenarios: $total"
Write-Host "Benign Corpus Rows: $benignCount"

foreach ($c in $checks) {
    $status = if ($c.Pass) { 'PASS' } else { 'FAIL' }
    $color = if ($c.Pass) { 'Green' } else { 'Red' }
    Write-Host ("[{0}] {1} = {2:N4} (threshold {3})" -f $status, $c.Name, [double]$c.Value, $c.Threshold) -ForegroundColor $color
}

$overall = (@($checks | Where-Object { -not $_.Pass }).Count -eq 0)
if ($overall) {
    Write-Host "`nBench Gate Result: PASS" -ForegroundColor Green
    exit 0
}

Write-Host "`nBench Gate Result: FAIL" -ForegroundColor Red
exit 1
