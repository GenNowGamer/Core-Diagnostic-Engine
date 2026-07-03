#Requires -RunAsAdministrator
<#
.SYNOPSIS
    CDE ISO Creation Script - Phase 6
    Builds a bootable ISO using oscdimg.exe (BIOS + UEFI dual boot)
.DESCRIPTION
    Uses ADK's oscdimg.exe to create a hybrid ISO:
    - BIOS boot via etfsboot.com (El Torito, no-emulation)
    - UEFI boot via EFI\boot\bootx64.efi (rEFInd launcher path)
.NOTES
    Run as Administrator.
    Requires: HALP\oscdimg.exe, HALP\etfsboot.com, EFI\boot\bootx64.efi
#>

param(
    [string]$OutputPath = "",
    [switch]$NoPrompt
)

$CDE_ROOT  = Split-Path -Parent $PSScriptRoot
$OSCDIMG   = "$CDE_ROOT\HALP\oscdimg.exe"
$ETFSBOOT  = "$CDE_ROOT\HALP\etfsboot.com"
$UEFIBOOT  = "$CDE_ROOT\EFI\boot\bootx64.efi"
$DEPLOY    = "$CDE_ROOT\Deploy"
$TIMESTAMP = Get-Date -Format "yyyyMMdd_HHmmss"

if (-not $OutputPath) {
    $OutputPath = "$DEPLOY\CDE_Diagnostic_Suite_$TIMESTAMP.iso"
}

function Write-Step($msg) { Write-Host "`n[STEP] $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "[OK]   $msg" -ForegroundColor Green }
function Write-Fail($msg) { Write-Host "[FAIL] $msg" -ForegroundColor Red; exit 1 }

Write-Host "`nCDE ISO Builder" -ForegroundColor Yellow
Write-Host "================" -ForegroundColor Yellow
Write-Host "  Source: $CDE_ROOT"
Write-Host "  Output: $OutputPath"

$refindMain = "$CDE_ROOT\EFI\refind\refind_x64.efi"

# Keep source-tree UEFI fallback deterministic: bootx64.efi must be rEFInd.
if (-not (Test-Path $refindMain)) {
    Write-Fail "Missing required rEFInd binary: $refindMain"
}

Copy-Item -LiteralPath $refindMain -Destination $UEFIBOOT -Force
$srcHash = (Get-FileHash -LiteralPath $refindMain -Algorithm SHA256).Hash
$dstHash = (Get-FileHash -LiteralPath $UEFIBOOT -Algorithm SHA256).Hash
if ($srcHash -ne $dstHash) {
    Write-Fail "UEFI fallback normalization failed: EFI\\boot\\bootx64.efi does not match EFI\\refind\\refind_x64.efi"
}
Write-OK "UEFI fallback launcher normalized to rEFInd in source tree"

# ---------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------
Write-Step "Pre-flight checks"

$required = @{
    "oscdimg.exe"           = $OSCDIMG
    "etfsboot.com"          = $ETFSBOOT
    "EFI\refind\refind_x64.efi" = "$CDE_ROOT\EFI\refind\refind_x64.efi"
    "EFI\boot\refind.conf"      = "$CDE_ROOT\EFI\boot\refind.conf"
    "EFI\microsoft\boot\bootmgfw.efi" = "$CDE_ROOT\EFI\microsoft\boot\bootmgfw.efi"
    "EFI\CDE\CoreDiag.efi"      = "$CDE_ROOT\EFI\CDE\CoreDiag.efi"
    "EFI\CDE\memtest.efi"       = "$CDE_ROOT\EFI\CDE\memtest.efi"
    "bootmgr"               = "$CDE_ROOT\bootmgr"
    "bootmgr.efi"           = "$CDE_ROOT\bootmgr.efi"
    "boot\BCD"              = "$CDE_ROOT\boot\BCD"
    "boot\BOOT.SDI"         = "$CDE_ROOT\boot\BOOT.SDI"
    "EFI\boot\bootx64.efi"  = "$CDE_ROOT\EFI\boot\bootx64.efi"
    "EFI\microsoft\boot\BCD"= "$CDE_ROOT\EFI\microsoft\boot\BCD"
    "sources\boot.wim"      = "$CDE_ROOT\sources\boot.wim"
    "CDE.exe"               = "$CDE_ROOT\CDE.exe"
    "Scripts\Launch\CDE_Portable.bat" = "$CDE_ROOT\Scripts\Launch\CDE_Portable.bat"
}

$requiredDirs = @{
    "EFI\boot\icons" = "$CDE_ROOT\EFI\boot\icons"
}

$missingFiles = @()
foreach ($entry in $required.GetEnumerator()) {
    if (Test-Path $entry.Value) {
        $kb = [math]::Round((Get-Item $entry.Value).Length / 1KB)
        Write-Host ("  [OK]  {0,-30} ({1} KB)" -f $entry.Key, $kb)
    } else {
        Write-Host ("  [!!]  {0,-30} MISSING" -f $entry.Key) -ForegroundColor Red
        $missingFiles += $entry.Key
    }
}

foreach ($entry in $requiredDirs.GetEnumerator()) {
    if (Test-Path $entry.Value) {
        Write-Host ("  [OK]  {0,-30} (dir)" -f $entry.Key)
    } else {
        Write-Host ("  [!!]  {0,-30} MISSING" -f $entry.Key) -ForegroundColor Red
        $missingFiles += $entry.Key
    }
}

if ($missingFiles.Count -gt 0) {
    Write-Fail "Missing $($missingFiles.Count) required file(s). Cannot build ISO."
}
Write-OK "All required files present"

# ---------------------------------------------------------------
# Ensure Deploy output folder exists
# ---------------------------------------------------------------
Write-Step "Preparing output folder"
if (-not (Test-Path $DEPLOY)) { New-Item $DEPLOY -ItemType Directory | Out-Null }
Write-OK "Output folder: $DEPLOY"

# ---------------------------------------------------------------
# Stage filtered ISO source tree (exclude volatile/build directories)
# ---------------------------------------------------------------
Write-Step "Staging ISO source tree..."

$stageRoot = Join-Path $env:TEMP ("cde_iso_stage_" + [guid]::NewGuid().ToString("N"))
New-Item -Path $stageRoot -ItemType Directory -Force | Out-Null

# Exclude volatile, dev-only, and build-only folders from ISO content.
$excludeDirs = @(
    "$CDE_ROOT\Deploy",           # ISO output — not needed inside ISO
    "$CDE_ROOT\Mount",            # DISM working directory
    "$CDE_ROOT\Logs",             # Runtime logs
    "$CDE_ROOT\.git",             # Repo metadata
    "$CDE_ROOT\App",              # .NET source code — deployed app is in CDE\
    "$CDE_ROOT\Tools\Deploy",     # Large binary deploy artifacts (gitignored)
    "$CDE_ROOT\Tools\.staging"    # Tool staging temp directory
)

# Exclude dev-only files that have no purpose on a bootable USB
$excludeFiles = @(
    "*.md",
    ".gitignore",
    "script_output.txt",
    "CreateISO.vbs",
    "PrepareUSB.vbs",
    "SyncUSB.bat",
    "CreateISO.ps1",
    "Customize-WinPE.ps1",
    "Prepare-BootableUSB.ps1",
    "update_script.ps1",
    "do_update.ps1"
)

& robocopy $CDE_ROOT $stageRoot /E /XD @excludeDirs /XF @excludeFiles /NFL /NDL /NJH /NJS /R:2 /W:1 | Out-Null
$stageCopyExit = $LASTEXITCODE
if ($stageCopyExit -gt 7) {
    Write-Fail "Failed to stage ISO source tree (robocopy exit $stageCopyExit)"
}

Write-OK "Staging complete: $stageRoot"

# ---------------------------------------------------------------
# Build ISO with oscdimg
# ---------------------------------------------------------------
Write-Step "Building dual-boot ISO (BIOS + UEFI)..."
Write-Host "  This may take several minutes for a large ISO..."

# oscdimg parameters:
#   -bootdata:2   = two boot entries
#   #p0,e,b       = BIOS: platform 0, no-emulation, boot sector file
#   #pEF,e,b      = UEFI: platform EF, no-emulation, EFI boot sector
#   -u2           = UDF file system (required for large files and UEFI)
#   -udfver102    = UDF version 1.02 (broadest compatibility)
#   -o            = Optimize by single-instancing identical files
#   -h            = Include hidden files
#   -m            = Ignore maximum image size
#   -l            = Volume label

$volLabel   = "CDE_DIAGNOSTIC"
$bootData   = "2#p0,e,b`"$ETFSBOOT`"#pEF,e,b`"$UEFIBOOT`""

$oscdimgArgs = @(
    "-bootdata:$bootData",
    "-u2",
    "-udfver102",
    "-o",
    "-h",
    "-m",
    "-l$volLabel",
    "`"$stageRoot`"",
    "`"$OutputPath`""
)

Write-Host "`n  oscdimg command:"
Write-Host "  $OSCDIMG $($oscdimgArgs -join ' ')" -ForegroundColor DarkGray
Write-Host ""

$proc = Start-Process -FilePath $OSCDIMG `
    -ArgumentList $oscdimgArgs `
    -Wait -PassThru -NoNewWindow

if ($proc.ExitCode -ne 0) {
    Write-Fail "oscdimg failed with exit code $($proc.ExitCode)"
}

# Cleanup staging tree
if (Test-Path $stageRoot) {
    Remove-Item $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------
# Report
# ---------------------------------------------------------------
$isoItem = Get-Item $OutputPath
$isoMB   = [math]::Round($isoItem.Length / 1MB, 0)
$isoGB   = [math]::Round($isoItem.Length / 1GB, 2)

Write-Host "`n================================================================" -ForegroundColor Green
Write-Host "  ISO BUILD COMPLETE" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  File:    $OutputPath"
Write-Host "  Size:    $isoMB MB  ($isoGB GB)"
Write-Host "  Label:   $volLabel"
Write-Host "  Boots:   BIOS (etfsboot.com) + UEFI (EFI\\boot\\bootx64.efi)"
Write-Host "  UEFI launcher: rEFInd (menu config in EFI\\boot\\refind.conf)"
Write-Host "  rEFInd entries: WinPE (bootmgfw.efi), CHU (CoreDiag.efi), MemDiag (EFI\\CDE\\memtest.efi)"
Write-Host ""
Write-Host "  To create bootable USB from this ISO:"
Write-Host "  1. Run: .\Scripts\Prepare-BootableUSB.ps1 -IsoPath `"$OutputPath`""
Write-Host "  2. On Windows, launch from media root using CDE.exe"
Write-Host "     Fallback launcher: Scripts\Launch\CDE_Portable.bat"
Write-Host "  OR manually:"
Write-Host "  1. Open Diskpart as Admin"
Write-Host "  2. list disk  ->  select disk [USB#]"
Write-Host "  3. clean  ->  create part primary  ->  active"
Write-Host "  4. format fs=fat32 quick  ->  assign letter=Z"
Write-Host "  5. xcopy /s /e /h /f `"$CDE_ROOT\*`" Z:\"
Write-Host "================================================================`n" -ForegroundColor Green
