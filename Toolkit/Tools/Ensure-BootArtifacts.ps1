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
$toolkitRoot = Split-Path -Parent $here
$destDir = Join-Path $here "Boot\WinMemoryDiag"
$dest = Join-Path $destDir "memtest.efi"
$efiCdeDest = Join-Path $toolkitRoot "EFI\CDE\memtest.efi"
$sources = @(
    Join-Path $toolkitRoot "EFI\CDE\memtest.efi"
    Join-Path $env:WINDIR "Boot\EFI\memtest.efi"
    Join-Path $env:SystemRoot "Boot\EFI\memtest.efi"
    Join-Path $toolkitRoot "EFI\microsoft\boot\memtest.efi"
) | Select-Object -Unique

New-Item -ItemType Directory -Force -Path $destDir | Out-Null

$copied = $false
foreach ($src in $sources) {
    if (Test-Path -LiteralPath $src -PathType Leaf) {
        if ($src -ne $dest) {
            Copy-Item -LiteralPath $src -Destination $dest -Force
        }
        Write-Host "Copied memtest.efi from $src -> $dest"
        $copied = $true
        break
    }
}

if ($copied -and (Test-Path -LiteralPath $dest -PathType Leaf)) {
    $efiCdeDir = Split-Path -Parent $efiCdeDest
    if (Test-Path -LiteralPath $efiCdeDir -PathType Container) {
        if ($dest -ne $efiCdeDest) {
            Copy-Item -LiteralPath $dest -Destination $efiCdeDest -Force
        }
    }
}

if (-not $copied) {
    Write-Warning "memtest.efi not found under $($sources -join ', '). Install Windows ADK host files or copy memtest.efi manually to:`n  $dest"
}

& (Join-Path $here "update_tools_manifest.ps1")
Write-Host "Done."
