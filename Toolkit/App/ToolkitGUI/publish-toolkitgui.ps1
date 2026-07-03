#!/usr/bin/env pwsh
param(
    [switch]$NoClean,
    [switch]$Quiet
)
$ErrorActionPreference = "Stop"
$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ReleaseDir = Join-Path $ProjectDir "bin\Release"
$OutputDir = Join-Path $ProjectDir "bin\Release\net8.0-windows"
$StagingDir = Join-Path $ReleaseDir "publish-staging\win-x64"
$ExePath = Join-Path $OutputDir "ToolkitGUI.exe"

Write-Host "ToolkitGUI Publish Script" -ForegroundColor Cyan

# Ensure files are not locked by a running instance.
Get-Process ToolkitGUI -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

if (-not $NoClean) {
    if (Test-Path $ReleaseDir) {
        Remove-Item $ReleaseDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Publish to a deterministic staging folder, then mirror to launcher folder.
dotnet publish ToolkitGUI.csproj -c Release -r win-x64 --self-contained true -o "$StagingDir" | Out-Null

if (Test-Path $OutputDir) {
    Remove-Item $OutputDir -Recurse -Force -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
Copy-Item -Path (Join-Path $StagingDir "*") -Destination $OutputDir -Recurse -Force

if (Test-Path $ExePath) {
    $fileInfo = Get-Item $ExePath
    Write-Host "✅ SUCCESS" -ForegroundColor Green
    Write-Host "Path: $($fileInfo.FullName)"
    Write-Host "Size: $($fileInfo.Length) bytes"
    Write-Host "Timestamp: $($fileInfo.LastWriteTime)"
} else {
    Write-Host "❌ FAILED" -ForegroundColor Red
}
