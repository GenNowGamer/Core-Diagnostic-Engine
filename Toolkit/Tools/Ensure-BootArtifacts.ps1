<#
.SYNOPSIS
  Copies Microsoft memtest.efi from the local Windows installation into CDE Boot\WinMemoryDiag,
  then refreshes tools_manifest.json.

.EXAMPLE
  .\Ensure-BootArtifacts.ps1
#>
param()

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$destDir = Join-Path $here "Boot\WinMemoryDiag"
$dest = Join-Path $destDir "memtest.efi"
$sources = @(
    Join-Path $env:WINDIR "Boot\EFI\memtest.efi"
    Join-Path $env:SystemRoot "Boot\EFI\memtest.efi"
) | Select-Object -Unique

New-Item -ItemType Directory -Force -Path $destDir | Out-Null

$copied = $false
foreach ($src in $sources) {
    if (Test-Path -LiteralPath $src -PathType Leaf) {
        Copy-Item -LiteralPath $src -Destination $dest -Force
        Write-Host "Copied memtest.efi from $src -> $dest"
        $copied = $true
        break
    }
}

if (-not $copied) {
    Write-Warning "memtest.efi not found under $($sources -join ', '). Install Windows ADK host files or copy memtest.efi manually to:`n  $dest"
}

& (Join-Path $here "update_tools_manifest.ps1")
Write-Host "Done."
