#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $testsRoot '..\Workflows\HardwareDiagnostics.ps1'

$outputLines = @(& $scriptPath -ToolName StorageTests -TestProfile Quick 2>&1 | ForEach-Object { "$_" })
$jsonLine = $outputLines | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1

if ([string]::IsNullOrWhiteSpace($jsonLine)) {
    $text = ($outputLines -join "`n").Trim()
    $jsonStart = $text.LastIndexOf('{"WorkflowName"')
    if ($jsonStart -lt 0) { $jsonStart = $text.LastIndexOf('{') }
    if ($jsonStart -lt 0) {
        Write-Error 'No workflow JSON found in HardwareDiagnostics output.'
        exit 1
    }
    $jsonLine = $text.Substring($jsonStart)
}

try {
    $json = $jsonLine | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse workflow JSON: $($_.Exception.Message)"
    exit 1
}

$driveSteps = @($json.Steps | Where-Object {
    ([string]$_.Name) -match '^Drive \d+:'
})
if ($driveSteps.Count -eq 0) {
    Write-Error 'Expected at least one Drive N: step in workflow JSON.'
    exit 1
}

$withPhysicalPath = @($json.Steps | Where-Object {
    ([string]$_.Output) -match 'PHYSICALDRIVE\d+'
})
if ($withPhysicalPath.Count -eq 0) {
    Write-Error 'Expected PHYSICALDRIVEn in at least one step output.'
    exit 1
}

$header = @($json.Steps | Where-Object {
    ([string]$_.Name) -match '^Drive \d+: .+ \(\d+(\.\d+)? GB\)$' -and
    ([string]$_.Output) -match '\| \\\\.\\PHYSICALDRIVE\d+'
}) | Select-Object -First 1
if (-not $header) {
    Write-Error 'Expected a device header step with drive title and PHYSICALDRIVE path.'
    exit 1
}

Write-Host "Test-HardwareStorageDriveLabels: PASS ($($json.Steps.Count) steps, $($driveSteps.Count) drive-scoped entries)"
exit 0
