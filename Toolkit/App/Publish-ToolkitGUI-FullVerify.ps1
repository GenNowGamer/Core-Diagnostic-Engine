#Requires -Version 5.1
<#
.SYNOPSIS
    Runs compile-only publish, then executes the full CDE verification pipeline.

.DESCRIPTION
    Wrapper for operators who want a single command for publish + full validation.
    Publish-ToolkitGUI.ps1 now performs compile/sync only. This script adds the
    full verification gate by invoking Publish-Verify-Toolkit.ps1.
#>
param(
    [switch]$Clean,
    [switch]$Force,
    [switch]$SkipRegression,
    [switch]$SkipValidateTools,
    [switch]$SkipCstGates,
    [switch]$SkipChuHash,
    [string]$OutputJsonPath = ''
)

$ErrorActionPreference = 'Stop'
$appDir = Split-Path $MyInvocation.MyCommand.Path -Parent

$publishScript = Join-Path $appDir 'Publish-ToolkitGUI.ps1'
$publishArgs = @{}
if ($Clean) { $publishArgs.Clean = $true }
if ($Force) { $publishArgs.Force = $true }

& $publishScript @publishArgs
if ($LASTEXITCODE -ne 0) {
    throw "Publish-ToolkitGUI.ps1 failed with exit code $LASTEXITCODE"
}

Write-Host "`nRunning full verification pipeline..." -ForegroundColor Cyan
$verifyScript = Join-Path $appDir 'Publish-Verify-Toolkit.ps1'
$verifyArgs = @{}
if ($SkipRegression) { $verifyArgs.SkipRegression = $true }
if ($SkipValidateTools) { $verifyArgs.SkipValidateTools = $true }
if ($SkipCstGates) { $verifyArgs.SkipCstGates = $true }
if ($SkipChuHash) { $verifyArgs.SkipChuHash = $true }
if (-not [string]::IsNullOrWhiteSpace($OutputJsonPath)) { $verifyArgs.OutputJsonPath = $OutputJsonPath }

& $verifyScript @verifyArgs
if ($LASTEXITCODE -ne 0) {
    throw "Publish-Verify-Toolkit.ps1 failed with exit code $LASTEXITCODE"
}

Write-Host "`nFull publish + verification complete." -ForegroundColor Green
