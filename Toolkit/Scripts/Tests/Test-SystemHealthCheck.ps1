#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $testsRoot '..\Workflows\SystemHealthCheck.ps1'

$selected = 'os_version,cpu_load,ram,disk_space'
$outputLines = @(& $scriptPath -SelectedChecks $selected 2>&1 | ForEach-Object { "$_" })
$jsonLine = $outputLines | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1

if ([string]::IsNullOrWhiteSpace($jsonLine)) {
    $logDir = Join-Path (Split-Path $testsRoot -Parent) '..\Logs'
    $latest = Get-ChildItem -Path $logDir -Filter 'SystemHealthCheck_*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) {
        $jsonLine = Get-Content -LiteralPath $latest.FullName -Raw
    }
}

if ([string]::IsNullOrWhiteSpace($jsonLine)) {
    Write-Error 'No workflow JSON found in output or logs.'
    exit 1
}

try {
    $json = $jsonLine | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse workflow JSON: $($_.Exception.Message)"
    exit 1
}

if ([string]$json.WorkflowName -ne 'SystemHealthCheck') {
    Write-Error "Unexpected workflow name: $($json.WorkflowName)"
    exit 1
}

if ($json.Steps.Count -lt 4) {
    Write-Error "Expected at least 4 steps, got $($json.Steps.Count)"
    exit 1
}

if ([string]::IsNullOrWhiteSpace([string]$json.OverallHealth)) {
    Write-Error 'OverallHealth not set'
    exit 1
}

Write-Host "Test-SystemHealthCheck: PASS ($($json.Steps.Count) steps, health=$($json.OverallHealth))"
exit 0
