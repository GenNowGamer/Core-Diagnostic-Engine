#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $testsRoot '..\Workflows\HardwareDiagnostics.ps1'

$outputLines = @(& $scriptPath -ToolName CstScan -TestProfile Quick 2>&1 | ForEach-Object { "$_" })
$text = ($outputLines -join "`n").Trim()

if ([string]::IsNullOrWhiteSpace($text)) {
    Write-Error 'HardwareDiagnostics CstScan returned no output.'
    exit 1
}

$jsonLine = $outputLines | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1
if ([string]::IsNullOrWhiteSpace($jsonLine)) {
    $jsonStart = $text.LastIndexOf('{')
    if ($jsonStart -lt 0) {
        Write-Error 'No JSON object found in CstScan output.'
        exit 1
    }
    $jsonLine = $text.Substring($jsonStart)
}

try {
    $json = $jsonLine | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse CstScan JSON: $($_.Exception.Message)"
    exit 1
}

if ($json.WorkflowName -ne 'HardwareDiag_CST') {
    Write-Error "Expected WorkflowName HardwareDiag_CST, got '$($json.WorkflowName)'."
    exit 1
}

if (-not $json.Steps -or $json.Steps.Count -eq 0) {
    Write-Error 'CstScan JSON has no steps.'
    exit 1
}

$cstStep = $json.Steps | Where-Object { $_.Name -eq 'CoreSecurityTool' } | Select-Object -First 1
if (-not $cstStep) {
    Write-Error 'CstScan workflow JSON missing CoreSecurityTool step.'
    exit 1
}

Write-Host "Test-HardwareDiagnosticsCst: PASS (workflow=$($json.WorkflowName), CoreSecurityTool status=$($cstStep.Status))"
exit 0
