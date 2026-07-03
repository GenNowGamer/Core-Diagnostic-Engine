#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $testsRoot '..\Workflows\HardwareDiagnostics.ps1'

$outputLines = @(& $scriptPath -ToolName StorageTests -TestProfile Quick 2>&1 | ForEach-Object { "$_" })
$jsonLine = $outputLines | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1

if ([string]::IsNullOrWhiteSpace($jsonLine)) {
    Write-Error 'No workflow JSON found in HardwareDiagnostics output.'
    exit 1
}

try {
    $json = $jsonLine | ConvertFrom-Json
} catch {
    Write-Error "Failed to parse workflow JSON: $($_.Exception.Message)"
    exit 1
}

$targetedSteps = @($json.Steps | Where-Object {
    ([string]$_.Name) -match 'Targeted Read Test$'
})

if ($targetedSteps.Count -eq 0) {
    Write-Error 'No Targeted Read Test steps found.'
    exit 1
}

$lengthUnavailable = @($targetedSteps | Where-Object {
    ([string]$_.Output) -match 'Drive length unavailable'
})

$int32Overflow = @($json.Steps | Where-Object {
    ([string]$_.Output) -match 'too large or too small for an Int32'
})

if ($int32Overflow.Count -gt 0) {
    Write-Error ('Storage tests hit Int32 overflow on large drives ({0} step(s)).' -f $int32Overflow.Count)
    exit 1
}

$linearPassed = @($json.Steps | Where-Object {
    ([string]$_.Name) -match 'Linear Read Test$' -and
    ([string]$_.Status) -eq 'Pass' -and
    ([string]$_.Output) -match 'Passed: .* MB linear read'
})

if ($linearPassed.Count -gt 0 -and $lengthUnavailable.Count -gt 0) {
    Write-Error ('Targeted Read reported drive length unavailable on {0} drive(s) while linear reads passed on {1} drive(s).' -f $lengthUnavailable.Count, $linearPassed.Count)
    exit 1
}

$failedTargeted = @($targetedSteps | Where-Object { ([string]$_.Status) -eq 'Fail' })
$passedTargeted = @($targetedSteps | Where-Object { ([string]$_.Status) -eq 'Pass' })
$skippedTargeted = @($targetedSteps | Where-Object {
    ([string]$_.Output) -match 'Skipped: Access denied'
})

Write-Host ("Test-HardwareStorageTargetedRead: PASS (targeted pass={0}, skip={1}, fail={2}, workflow health={3})" -f `
    $passedTargeted.Count, $skippedTargeted.Count, $failedTargeted.Count, $json.OverallHealth)
exit 0
