#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$coreDir = Join-Path $testsRoot '..\Core'
$fixturePath = Join-Path $testsRoot 'Fixtures\CstStructuredResultsFixture.json'

if (-not (Test-Path -LiteralPath $fixturePath)) {
    Write-Error "Fixture not found: $fixturePath"
    exit 1
}

$loaderPath = Join-Path $coreDir '..\..\App\ToolkitGUI\Services\CstStructuredResultsService.cs'
if (-not (Test-Path -LiteralPath $loaderPath)) {
    Write-Error 'CstStructuredResultsService.cs not found.'
    exit 1
}

# Validate fixture shape directly (service is C#; mirror rules here).
$artifact = Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json
$actionableTypes = @('Malware', 'Virus', 'PUP', 'PUM')
$actionable = @($artifact.Findings | Where-Object { $actionableTypes -contains $_.Type })
$all = @($artifact.Findings + @($artifact.SuppressedAuditFindings))

if ($actionable.Count -ne 1) {
    Write-Error "Expected 1 actionable finding, got $($actionable.Count)."
    exit 1
}

if ($all.Count -lt 3) {
    Write-Error "Expected at least 3 total findings in fixture."
    exit 1
}

if ([string]$artifact.ScanMode -ne 'ThreatScan') {
    Write-Error 'Fixture scan mode mismatch.'
    exit 1
}

if ([int]$artifact.Summary.ItemsScanned -ne 42) {
    Write-Error 'Fixture metadata mismatch.'
    exit 1
}

Write-Host 'Test-CstStructuredResults: PASS'
exit 0
