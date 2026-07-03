#Requires -Version 5.1
<#
.SYNOPSIS
    Local orchestrator for a full CDE toolkit build and verification.
.PARAMETER UsbDrive
    Optional drive letter (e.g. E:) passed to SyncUSB.bat after publish.
.PARAMETER BuildChu
    Run BUILD_CHU_UEFI.ps1 before publish (requires CHU toolchain).
.PARAMETER SkipVerify
    Skip Publish-Verify-Toolkit.ps1.
#>
param(
    [string]$UsbDrive = '',
    [switch]$BuildChu,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
$appDir = Split-Path $MyInvocation.MyCommand.Path -Parent
$toolkitRoot = [System.IO.Path]::GetFullPath((Join-Path $appDir '..'))

if ($BuildChu) {
    $chuScript = Join-Path $toolkitRoot 'Scripts\BUILD_CHU_UEFI.ps1'
    if (-not (Test-Path -LiteralPath $chuScript)) {
        throw "CHU build script not found: $chuScript"
    }

    $manifestPath = Join-Path $toolkitRoot 'Tools\tools_manifest.json'
    & $chuScript -CdeManifestPath $manifestPath
    if ($LASTEXITCODE -ne 0) {
        throw "BUILD_CHU_UEFI.ps1 failed with exit code $LASTEXITCODE"
    }
}

$publishScript = Join-Path $appDir 'Publish-ToolkitGUI.ps1'
if ($SkipVerify) {
    & $publishScript -SkipVerify
} else {
    & $publishScript
}
if ($LASTEXITCODE -ne 0) {
    throw "Publish-ToolkitGUI.ps1 failed with exit code $LASTEXITCODE"
}

if (-not $SkipVerify) {
    $verifyScript = Join-Path $appDir 'Publish-Verify-Toolkit.ps1'
    & $verifyScript
    if ($LASTEXITCODE -ne 0) {
        throw "Publish-Verify-Toolkit.ps1 failed with exit code $LASTEXITCODE"
    }
}

if (-not [string]::IsNullOrWhiteSpace($UsbDrive)) {
    $syncBat = Join-Path $toolkitRoot 'SyncUSB.bat'
    if (-not (Test-Path -LiteralPath $syncBat)) {
        throw "SyncUSB.bat not found: $syncBat"
    }

    $drive = $UsbDrive.Trim().TrimEnd(':')
    cmd.exe /c "`"$syncBat`" $drive`:"
    if ($LASTEXITCODE -ne 0) {
        throw "SyncUSB.bat failed with exit code $LASTEXITCODE"
    }
}

$launcher = Join-Path $toolkitRoot 'CDE.exe'
Write-Host "`nBuild-CDE-Toolkit complete." -ForegroundColor Green
if (Test-Path -LiteralPath $launcher) {
    Write-Host ("  CDE.exe LastWrite: {0}" -f (Get-Item -LiteralPath $launcher).LastWriteTime)
}
