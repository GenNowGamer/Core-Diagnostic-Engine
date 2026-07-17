#Requires -Version 5.1
<#
.SYNOPSIS
    Post-publish verification gate for the CDE toolkit (local CI).
.PARAMETER SkipRegression
    Skip Invoke-CdeRegressionSuite.ps1 (not recommended).
.PARAMETER SkipValidateTools
    Skip ValidateTools.ps1 workflow smoke.
.PARAMETER SkipCstGates
    Skip CST Validate-CstReleaseGates.ps1 when CST source is present.
.PARAMETER SkipChuHash
    Skip CoreDiag.efi SHA256 manifest check.
#>
param(
    [switch]$SkipRegression,
    [switch]$SkipValidateTools,
    [switch]$SkipCstGates,
    [switch]$SkipChuHash,
    [string]$OutputJsonPath = ''
)

$ErrorActionPreference = 'Stop'

$appDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$toolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $appDir '..'))
$testsRoot = Join-Path $toolkitRoot 'Scripts\Tests'
$verifyRoot = Join-Path $toolkitRoot 'CDE\Runtime\Data'
New-Item -ItemType Directory -Path $verifyRoot -Force | Out-Null

if ([string]::IsNullOrWhiteSpace($OutputJsonPath)) {
    $OutputJsonPath = Join-Path $verifyRoot ("publish_verify_{0}.json" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
}

$results = [System.Collections.Generic.List[object]]::new()

function Add-VerifyResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Detail = ''
    )
    $results.Add([PSCustomObject]@{
        Name   = $Name
        Status = if ($Passed) { 'PASS' } else { 'FAIL' }
        Detail = $Detail
    }) | Out-Null
    $color = if ($Passed) { 'Green' } else { 'Red' }
    Write-Host ("[{0}] {1}" -f $(if ($Passed) { 'PASS' } else { 'FAIL' }), $Name) -ForegroundColor $color
    if ($Detail) { Write-Host "  $Detail" }
}

if (-not $SkipRegression) {
    Write-Host "`n=== Regression suite ===" -ForegroundColor Cyan
    $regressionScript = Join-Path $testsRoot 'Invoke-CdeRegressionSuite.ps1'
    & $regressionScript -IncludeWorkflowSmoke
    Add-VerifyResult -Name 'RegressionSuite' -Passed ($LASTEXITCODE -eq 0) -Detail "ExitCode=$LASTEXITCODE"
} else {
    Add-VerifyResult -Name 'RegressionSuite' -Passed $true -Detail 'Skipped'
}

if (-not $SkipValidateTools) {
    Write-Host "`n=== ValidateTools ===" -ForegroundColor Cyan
    $validateScript = Join-Path $toolkitRoot 'Scripts\Workflows\ValidateTools.ps1'
    & $validateScript
    Add-VerifyResult -Name 'ValidateTools' -Passed ($LASTEXITCODE -eq 0) -Detail "ExitCode=$LASTEXITCODE"
} else {
    Add-VerifyResult -Name 'ValidateTools' -Passed $true -Detail 'Skipped'
}

if (-not $SkipCstGates) {
    Write-Host "`n=== CST release gates ===" -ForegroundColor Cyan
    $cstCandidates = @(
        [System.IO.Path]::GetFullPath((Join-Path $appDir '..\..\..\Core Security Tool\CST\Validate-CstReleaseGates.ps1')),
        [System.IO.Path]::GetFullPath((Join-Path $appDir '..\..\Core Security Tool\CST\Validate-CstReleaseGates.ps1'))
    )
    $cstGate = $cstCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($cstGate) {
        & $cstGate -SkipMinuteCapTest
        Add-VerifyResult -Name 'CstReleaseGates' -Passed ($LASTEXITCODE -eq 0) -Detail $cstGate
    } else {
        Add-VerifyResult -Name 'CstReleaseGates' -Passed $false -Detail 'Validate-CstReleaseGates.ps1 not found in sibling CST repo'
    }
} else {
    Add-VerifyResult -Name 'CstReleaseGates' -Passed $true -Detail 'Skipped'
}

if (-not $SkipChuHash) {
    Write-Host "`n=== CHU EFI manifest hash ===" -ForegroundColor Cyan
    $manifestPath = Join-Path $toolkitRoot 'Tools\tools_manifest.json'
    $efiCandidates = @(
        (Join-Path $toolkitRoot 'EFI\CDE\CoreDiag.efi'),
        (Join-Path $toolkitRoot 'Boot\CoreHardwareUtility\CoreDiag.efi')
    )
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        Add-VerifyResult -Name 'ChuManifestHash' -Passed $false -Detail "Manifest not found: $manifestPath"
    } else {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $entry = @($manifest.entries | Where-Object { [string]$_.relativePath -like '*CoreDiag.efi' }) | Select-Object -First 1
        $efiPath = $efiCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $entry) {
            Add-VerifyResult -Name 'ChuManifestHash' -Passed $false -Detail 'No CoreDiag.efi entry in tools_manifest.json'
        } elseif (-not $efiPath) {
            Add-VerifyResult -Name 'ChuManifestHash' -Passed $true -Detail 'CoreDiag.efi not staged (skipped). Run BUILD_CHU_UEFI.ps1 -CdeManifestPath ...'
        } else {
            $hash = (Get-FileHash -LiteralPath $efiPath -Algorithm SHA256).Hash.ToUpperInvariant()
            $expected = [string]$entry.sha256
            $ok = $hash -eq $expected
            Add-VerifyResult -Name 'ChuManifestHash' -Passed $ok -Detail "File=$efiPath Expected=$expected Actual=$hash"
        }
    }
} else {
    Add-VerifyResult -Name 'ChuManifestHash' -Passed $true -Detail 'Skipped'
}

Write-Host "`n=== CdeCpuSimdCli payload ===" -ForegroundColor Cyan
$simdCliPath = Join-Path $toolkitRoot 'CDE\ToolkitGUI\bin\Release\net8.0-windows\CdeCpuSimdCli.exe'
if (-not (Test-Path -LiteralPath $simdCliPath)) {
    Add-VerifyResult -Name 'CdeCpuSimdCli' -Passed $false -Detail "Missing: $simdCliPath"
} else {
    $env:TOOLKIT_ROOT = $toolkitRoot
    $simdTest = Join-Path $testsRoot 'Test-CpuSimdEnginePs5.ps1'
    & $simdTest
    Add-VerifyResult -Name 'CdeCpuSimdCli' -Passed ($LASTEXITCODE -eq 0) -Detail $simdCliPath
}

Write-Host "`n=== CdeGpuDiagCli payload ===" -ForegroundColor Cyan
$gpuCliPath = Join-Path $toolkitRoot 'CDE\ToolkitGUI\bin\Release\net8.0-windows\CdeGpuDiagCli.exe'
if (-not (Test-Path -LiteralPath $gpuCliPath)) {
    Add-VerifyResult -Name 'CdeGpuDiagCli' -Passed $false -Detail "Missing: $gpuCliPath"
} else {
    & $gpuCliPath probe | Out-Null
    Add-VerifyResult -Name 'CdeGpuDiagCli' -Passed ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3) -Detail $gpuCliPath
}

Write-Host "`n=== GUI unit tests (dotnet test) ===" -ForegroundColor Cyan
$slnPath = Join-Path $appDir 'ToolkitGUI.sln'
if (Test-Path -LiteralPath $slnPath) {
    dotnet test $slnPath -c Release --no-restore 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        dotnet test $slnPath -c Release 2>&1 | Out-Host
    }
    Add-VerifyResult -Name 'GuiUnitTests' -Passed ($LASTEXITCODE -eq 0) -Detail "ExitCode=$LASTEXITCODE"
} else {
    Add-VerifyResult -Name 'GuiUnitTests' -Passed $false -Detail "Solution not found: $slnPath"
}

$failed = @($results | Where-Object { $_.Status -ne 'PASS' }).Count
$summary = [PSCustomObject]@{
    VerifiedAt = (Get-Date).ToString('o')
    ToolkitRoot = $toolkitRoot
    FailedCount = $failed
    Results = @($results)
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputJsonPath -Encoding UTF8
Write-Host "`nWrote verification report: $OutputJsonPath" -ForegroundColor Cyan

if ($failed -gt 0) {
    Write-Host "Publish verification FAILED ($failed check(s))." -ForegroundColor Red
    exit 1
}

Write-Host 'Publish verification PASSED.' -ForegroundColor Green
exit 0
