#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $testsRoot '..\Workflows\SystemHealthCheck.ps1'
$coreDir = Join-Path $testsRoot '..\Core'
$catalogPath = Join-Path $testsRoot '..\..\Config\HealthCheckCatalog.json'

. (Join-Path $coreDir 'HealthCheckOrchestrator.ps1')
$catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json

function Get-WorkflowJsonFromOutput {
    param([string[]]$OutputLines)

    $jsonLine = $OutputLines | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1
    if (-not [string]::IsNullOrWhiteSpace($jsonLine)) {
        return $jsonLine
    }

    $logDir = Join-Path (Split-Path $testsRoot -Parent) '..\Logs'
    $logDir = [IO.Path]::GetFullPath($logDir)
    $latest = Get-ChildItem -Path $logDir -Filter 'SystemHealthCheck_*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) {
        return Get-Content -LiteralPath $latest.FullName -Raw
    }

    return $null
}

function Test-SystemHealthPreset {
    param(
        [string]$PresetName
    )

    $expectedCount = @($catalog.presets.$PresetName).Count
    if ($expectedCount -eq 0) {
        Write-Error "Preset '$PresetName' is empty or missing in catalog."
        exit 1
    }

    $outputLines = @(& $scriptPath -Preset $PresetName 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Write-Error "SystemHealthCheck -Preset $PresetName failed with exit code $LASTEXITCODE"
        exit 1
    }

    $jsonLine = Get-WorkflowJsonFromOutput -OutputLines $outputLines
    if ([string]::IsNullOrWhiteSpace($jsonLine)) {
        Write-Error "No workflow JSON found for preset '$PresetName'."
        exit 1
    }

    try {
        $json = $jsonLine | ConvertFrom-Json
    } catch {
        Write-Error "Failed to parse workflow JSON for preset '$PresetName': $($_.Exception.Message)"
        exit 1
    }

    if ([string]$json.WorkflowName -ne 'SystemHealthCheck') {
        Write-Error "Preset '$PresetName' unexpected workflow name: $($json.WorkflowName)"
        exit 1
    }

    if ($json.Steps.Count -lt $expectedCount) {
        Write-Error "Preset '$PresetName' expected at least $expectedCount steps, got $($json.Steps.Count)"
        exit 1
    }

    if ([string]::IsNullOrWhiteSpace([string]$json.OverallHealth)) {
        Write-Error "Preset '$PresetName' did not set OverallHealth"
        exit 1
    }

    Write-Host "  PASS preset=$PresetName steps=$($json.Steps.Count) health=$($json.OverallHealth)"
}

Test-SystemHealthPreset -PresetName 'quick_vitals'
Test-SystemHealthPreset -PresetName 'deep_system'

Write-Host 'Test-SystemHealthCheckPresets: PASS'
exit 0
