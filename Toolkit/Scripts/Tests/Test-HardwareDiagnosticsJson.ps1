#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $testsRoot '..\Workflows\HardwareDiagnostics.ps1'

$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
$runner = if ($pwshCmd) { $pwshCmd.Source } else { 'powershell.exe' }

$outputLines = @(& $runner -NoProfile -ExecutionPolicy Bypass -File $scriptPath -ToolName CpuTests -TestProfile Quick 2>&1 | ForEach-Object { "$_" })
$text = ($outputLines -join "`n").Trim()

if ([string]::IsNullOrWhiteSpace($text)) {
    Write-Error 'HardwareDiagnostics returned no output.'
    exit 1
}

$jsonLine = $outputLines | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1
if ([string]::IsNullOrWhiteSpace($jsonLine)) {
    $jsonStart = $text.LastIndexOf('{')
    if ($jsonStart -lt 0) {
        Write-Error 'No JSON object found in HardwareDiagnostics output.'
        exit 1
    }
    $jsonLine = $text.Substring($jsonStart)
}

try {
    $json = $jsonLine | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse HardwareDiagnostics JSON: $($_.Exception.Message)"
    exit 1
}

if (-not $json.Steps -or $json.Steps.Count -eq 0) {
    Write-Error 'HardwareDiagnostics JSON has no steps.'
    exit 1
}

if ([string]::IsNullOrWhiteSpace([string]$json.OverallHealth)) {
    Write-Error 'OverallHealth not set on HardwareDiagnostics workflow.'
    exit 1
}

Write-Host "Test-HardwareDiagnosticsJson: PASS ($($json.WorkflowName), $($json.Steps.Count) steps, health=$($json.OverallHealth))"
exit 0
