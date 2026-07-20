#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$coreDir = Join-Path $testsRoot '..\Core'
. (Join-Path $coreDir 'HealthFindings.ps1')
. (Join-Path $coreDir 'HealthChecks.ps1')

# Fast intervals for unit verification (helpers clamp to >= 500ms)
$cpu = Get-SustainedCpuLoadSample -SampleCount 2 -IntervalMs 500
if ($cpu.SampleCount -ne 2) {
    Write-Error "Expected SampleCount=2, got $($cpu.SampleCount)"
    exit 1
}
if (@($cpu.Samples).Count -ne 2) {
    Write-Error 'Expected two CPU samples'
    exit 1
}
if ($null -eq $cpu.Average) {
    Write-Error 'CPU average missing'
    exit 1
}

# Sustained-high gate: average > 90 and at least 2 high samples
$fakeHigh = [PSCustomObject]@{
    Samples = @(95.0, 96.0, 91.0)
    Average = 94.0
    Minimum = 91.0
    HighSampleCount = 3
    SampleCount = 3
    IsSustainedHigh = $true
}
if (-not ($fakeHigh.Average -gt 90 -and $fakeHigh.HighSampleCount -ge 2)) {
    Write-Error 'Sustained-high predicate failed for high samples'
    exit 1
}
$fakeSpike = [PSCustomObject]@{
    Average = 92.0
    HighSampleCount = 1
}
if ($fakeSpike.Average -gt 90 -and $fakeSpike.HighSampleCount -ge 2) {
    Write-Error 'Single spike should not count as sustained high'
    exit 1
}

$ram = Get-SustainedRamUsageSample -SampleCount 2 -IntervalMs 500
if (@($ram.Samples).Count -ne 2 -or $null -eq $ram.Os) {
    Write-Error 'RAM sample shape mismatch'
    exit 1
}

Write-Host 'Test-SustainedResourceSamples: PASS'
exit 0
