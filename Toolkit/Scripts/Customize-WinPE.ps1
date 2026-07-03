#Requires -RunAsAdministrator
<#
.SYNOPSIS
    CDE WinPE Customization Script - Phase 5
    Mounts boot.wim, injects CDE startnet.cmd, and commits.
.NOTES
    Run as Administrator. Requires Windows ADK (DISM).
#>

$CDE_ROOT  = "D:\Robert\Desktop\App Project Builds\Core Diagnostic Engine\Toolkit"
$WIM_PATH  = "$CDE_ROOT\sources\boot.wim"
$MOUNT_DIR = "$CDE_ROOT\Mount\WinPE"
$STARTNET  = "$CDE_ROOT\Mount\WinPEWork\startnet.cmd"

# Use the ADK's own DISM instead of the system DISM.
# System DISM (10.0.26100.5074+) cannot load the older hive format
# in the WinPE image (10.0.26100.1) - CBS fails with 0xD0000043.
# Prepending the ADK DISM directory makes PowerShell resolve 'Dism'
# to the ADK binary, which loads its own matching DLLs from the same folder.
$adkDismDir = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\DISM"
if (Test-Path $adkDismDir) {
    $env:PATH = "$adkDismDir;$env:PATH"
    $adkDismVer = (Get-Item "$adkDismDir\dism.exe").VersionInfo.FileVersion
    Write-Host "Using ADK DISM: $adkDismVer" -ForegroundColor DarkGray
} else {
    Write-Host "WARNING: ADK DISM not found - falling back to system DISM (may fail)" -ForegroundColor Yellow
}

function Write-Step($msg) { Write-Host "`n[STEP] $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "[OK]   $msg" -ForegroundColor Green }
function Write-Fail($msg) { Write-Host "[FAIL] $msg" -ForegroundColor Red; exit 1 }

Write-Host "`nCDE WinPE Customization Script" -ForegroundColor Yellow
Write-Host "================================" -ForegroundColor Yellow

# ---------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------
Write-Step "Pre-flight checks"

if (-not (Test-Path $WIM_PATH))  { Write-Fail "boot.wim not found at: $WIM_PATH" }
if (-not (Test-Path $STARTNET))  { Write-Fail "startnet.cmd not found at: $STARTNET" }
if (-not (Test-Path $MOUNT_DIR)) { New-Item $MOUNT_DIR -ItemType Directory | Out-Null }

# Replace boot.wim with the fresh ADK base image so that the CBS schema.dat
# is compatible with the ADK package .cabs. The current boot.wim's schema.dat
# cannot be loaded by CBS, blocking all /Add-Package operations.
$adkWimSrc = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\en-us\winpe.wim"
if (Test-Path $adkWimSrc) {
    Write-Host "  Refreshing boot.wim from fresh ADK base image..."
    Copy-Item $adkWimSrc $WIM_PATH -Force
    Write-Host "  boot.wim refreshed ($([math]::Round((Get-Item $WIM_PATH).Length/1MB,0)) MB)" -ForegroundColor Green
} else {
    Write-Host "  WARNING: ADK winpe.wim not found at: $adkWimSrc" -ForegroundColor Yellow
    Write-Host "           Proceeding with existing boot.wim (package install may fail)"
}

# Ensure mount dir is empty / clean any stale mounts
$stale = Dism /Get-MountedImageInfo 2>$null | Select-String ([regex]::Escape($MOUNT_DIR))
if ($stale) {
    Write-Host "  Cleaning stale DISM mount at $MOUNT_DIR ..."
    Dism /Unmount-Image /MountDir:"$MOUNT_DIR" /Discard | Out-Null
}
$existingFiles = Get-ChildItem $MOUNT_DIR -ErrorAction SilentlyContinue
if ($existingFiles) {
    Get-ChildItem $MOUNT_DIR | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

Write-OK "Pre-flight OK"

# ---------------------------------------------------------------
# Mount boot.wim
# ---------------------------------------------------------------
Write-Step "Mounting boot.wim (Index 1)..."
Dism /Mount-Image /ImageFile:"$WIM_PATH" /Index:1 /MountDir:"$MOUNT_DIR"
if ($LASTEXITCODE -ne 0) { Write-Fail "DISM mount failed (exit $LASTEXITCODE)" }
Write-OK "Mounted at $MOUNT_DIR"

# ---------------------------------------------------------------
# Add PowerShell optional components (required for all PS1 scripts)
# Dependency order: WMI -> NetFx -> Scripting -> PowerShell
# ---------------------------------------------------------------
Write-Step "Adding PowerShell optional components..."
$ocPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs"

if (-not (Test-Path $ocPath)) {
    Write-Host "  ERROR: ADK WinPE_OCs not found at:" -ForegroundColor Red
    Write-Host "         $ocPath"
    Write-Host "  Install the Windows ADK + WinPE add-on and re-run this script."
    Dism /Unmount-Image /MountDir:"$MOUNT_DIR" /Discard | Out-Null
    exit 1
}

# WinPE-StorageWMI requires WMI/NetFx/Scripting/PowerShell first (Microsoft OC dependency chain).
$packages = @('WinPE-WMI', 'WinPE-NetFx', 'WinPE-Scripting', 'WinPE-PowerShell', 'WinPE-StorageWMI')
foreach ($pkg in $packages) {
    Write-Host "  Adding $pkg ..."
    $cab = "$ocPath\$pkg.cab"
    $out = Dism /Add-Package /Image:"$MOUNT_DIR" /PackagePath:"$cab" 2>&1
    if ($LASTEXITCODE -ne 0) {
        # Exit 0x800f0805 = already installed -- not a real error
        $msg = ($out | Select-String 'already' | Select-Object -First 1)
        if ($msg) { Write-Host "    ($pkg already installed, skipping)" -ForegroundColor DarkGray }
        else {
            Write-Host "  --- DISM output for $pkg ---" -ForegroundColor Yellow
            $out | ForEach-Object { Write-Host "  $_" }
            Write-Fail "Failed to add $pkg (exit $LASTEXITCODE)"
        }
    } else { Write-Host "    $pkg OK" -ForegroundColor Green }

    $langCab = "$ocPath\en-us\${pkg}_en-us.cab"
    if (Test-Path $langCab) {
        $out = Dism /Add-Package /Image:"$MOUNT_DIR" /PackagePath:"$langCab" 2>&1
        if ($LASTEXITCODE -ne 0) {
            $msg = ($out | Select-String 'already' | Select-Object -First 1)
            if (-not $msg) {
                Write-Host "  --- DISM output for $pkg en-us ---" -ForegroundColor Yellow
                $out | ForEach-Object { Write-Host "  $_" }
                Write-Fail "Failed to add $pkg en-us (exit $LASTEXITCODE)"
            }
        }
    }
}
Write-OK "PowerShell components added"

# ---------------------------------------------------------------
# Inject startnet.cmd
# ---------------------------------------------------------------
Write-Step "Injecting startnet.cmd..."
$targetDir = "$MOUNT_DIR\Windows\System32"
if (-not (Test-Path $targetDir)) { Write-Fail "Target dir not found: $targetDir (WIM may be wrong index)" }

# Backup original startnet.cmd
$origStartnet = "$targetDir\startnet.cmd"
if (Test-Path $origStartnet) {
    $backup = "$targetDir\startnet_original.cmd"
    Copy-Item $origStartnet $backup -Force
    Write-Host "  Original startnet.cmd backed up as startnet_original.cmd"
}

# Inject CDE startnet.cmd
Copy-Item $STARTNET $origStartnet -Force
Write-OK "startnet.cmd injected"

# ---------------------------------------------------------------
# Inject bootsect.exe from ADK
# bootsect.exe is NOT included in ADK winpe.wim by default.
# CDE uses it as the WinPE-compatible replacement for bootrec /fixmbr
# and bootrec /fixboot (both WinRE-only tools not in standard WinPE).
# ---------------------------------------------------------------
Write-Step "Injecting bootsect.exe from ADK..."
$bootsectSrc = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\BCDBoot\bootsect.exe"
if (Test-Path $bootsectSrc) {
    # Copy-Item fails on DISM-mounted WinPE System32 due to ACL restrictions.
    # robocopy /B uses SeBackupPrivilege to bypass them.
    $srcDir = Split-Path $bootsectSrc -Parent
    $dstDir = "$MOUNT_DIR\Windows\System32"
    $null = robocopy $srcDir $dstDir "bootsect.exe" /B /NJH /NJS /NFL /NDL 2>&1
    # robocopy exit codes 0-7 = success (1=copied, 3=copied+extra, etc.)
    if ($LASTEXITCODE -ge 8) {
        Write-Host "  WARNING: robocopy failed (exit $LASTEXITCODE) -- bootsect.exe NOT injected." -ForegroundColor Yellow
        Write-Host "           FixMBR and FixBoot tools will fail in WinPE without it." -ForegroundColor Yellow
    } else {
        $bootsectKB = [math]::Round((Get-Item $bootsectSrc).Length / 1KB, 0)
        Write-OK "bootsect.exe injected ($bootsectKB KB) - enables FixMBR and FixBoot in WinPE"
    }
} else {
    Write-Host "  WARNING: bootsect.exe not found at: $bootsectSrc" -ForegroundColor Yellow
    Write-Host "           Install Windows ADK (Deployment Tools) and re-run." -ForegroundColor Yellow
    Write-Host "           Without it, FixMBR and FixBoot tools will fail in WinPE." -ForegroundColor Yellow
}

# ---------------------------------------------------------------
# Optional: Add CDE PowerShell modules to WinPE
# ---------------------------------------------------------------
Write-Step "Checking for CDE PowerShell modules..."
$psModSource = "$CDE_ROOT\Scripts\Core"
$psModDest   = "$MOUNT_DIR\Windows\System32\WindowsPowerShell\v1.0\Modules\CDECore"

if (Test-Path "$psModSource\Toolkit.Core.psm1") {
    New-Item $psModDest -ItemType Directory -Force | Out-Null
    Copy-Item "$psModSource\Toolkit.Core.psm1" "$psModDest\CDECore.psm1" -Force
    # Create module manifest stub
    $manifest  = "@{"
    $manifest += "`n    ModuleVersion = '1.0.0'"
    $manifest += "`n    RootModule    = 'CDECore.psm1'"
    $manifest += "`n    GUID          = '$((New-Guid).ToString())'"
    $manifest += "`n    Description   = 'CDE Diagnostic Suite Core Module'"
    $manifest += "`n}"
    $manifest | Out-File "$psModDest\CDECore.psd1" -Encoding ASCII
    Write-OK "Toolkit.Core.psm1 added to WinPE as CDECore module"
} else {
    Write-Host "  (Toolkit.Core.psm1 not found, skipping)"
}

# ---------------------------------------------------------------
# Optional: Inject storage controller drivers (Intel RST/VMD, etc.)
# Required so WinPE can see drives behind RAID/VMD controllers and so the
# S.M.A.R.T. Analyzer can enumerate them. Drop extracted vendor .inf driver
# packages into Drivers\Storage (any subfolder layout) and they get added here.
# ---------------------------------------------------------------
Write-Step "Checking for storage controller drivers..."
$driverSource = "$CDE_ROOT\Drivers\Storage"
if (Test-Path $driverSource) {
    $infCount = @(Get-ChildItem $driverSource -Recurse -Filter *.inf -ErrorAction SilentlyContinue).Count
    if ($infCount -gt 0) {
        Write-Host "  Found $infCount driver(s) - injecting with DISM /Add-Driver /Recurse ..."
        $out = Dism /Image:"$MOUNT_DIR" /Add-Driver /Driver:"$driverSource" /Recurse /ForceUnsigned 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  --- DISM driver output ---" -ForegroundColor Yellow
            $out | ForEach-Object { Write-Host "  $_" }
            Write-Host "  WARNING: One or more drivers failed to inject (exit $LASTEXITCODE)." -ForegroundColor Yellow
        } else {
            Write-OK "Storage drivers injected ($infCount .inf package(s))"
        }
    } else {
        Write-Host "  (Drivers\Storage exists but contains no .inf files, skipping)"
    }
} else {
    Write-Host "  (Drivers\Storage folder not present, skipping driver injection)"
}

# ---------------------------------------------------------------
# Optional: Inject network (NIC) drivers for Ethernet connectivity.
# Required so WinPE can obtain an IP via DHCP and bundled tools (e.g. the
# Firefox browser) can reach the network. Wi-Fi is NOT supported in WinPE;
# this is Ethernet / USB-Ethernet only. Drop extracted vendor .inf driver
# packages into Drivers\Network (any subfolder layout) and they get added here.
# ---------------------------------------------------------------
Write-Step "Checking for network (NIC) drivers..."
$netDriverSource = "$CDE_ROOT\Drivers\Network"
if (Test-Path $netDriverSource) {
    $netInfCount = @(Get-ChildItem $netDriverSource -Recurse -Filter *.inf -ErrorAction SilentlyContinue).Count
    if ($netInfCount -gt 0) {
        Write-Host "  Found $netInfCount driver(s) - injecting with DISM /Add-Driver /Recurse ..."
        $netOut = Dism /Image:"$MOUNT_DIR" /Add-Driver /Driver:"$netDriverSource" /Recurse /ForceUnsigned 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  --- DISM driver output ---" -ForegroundColor Yellow
            $netOut | ForEach-Object { Write-Host "  $_" }
            Write-Host "  WARNING: One or more drivers failed to inject (exit $LASTEXITCODE)." -ForegroundColor Yellow
        } else {
            Write-OK "Network drivers injected ($netInfCount .inf package(s))"
        }
    } else {
        Write-Host "  (Drivers\Network exists but contains no .inf files, skipping)"
    }
} else {
    Write-Host "  (Drivers\Network folder not present, skipping driver injection)"
}

# ---------------------------------------------------------------
# Unmount and commit changes
# ---------------------------------------------------------------
Write-Step "Unmounting and committing changes to boot.wim..."
Dism /Unmount-Image /MountDir:"$MOUNT_DIR" /Commit
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Commit failed. Attempting discard..." -ForegroundColor Yellow
    Dism /Unmount-Image /MountDir:"$MOUNT_DIR" /Discard
    Write-Fail "DISM commit failed (exit $LASTEXITCODE)"
}
Write-OK "boot.wim updated and committed"

# ---------------------------------------------------------------
# Report
# ---------------------------------------------------------------
$wimSize = [math]::Round((Get-Item $WIM_PATH).Length / 1MB, 0)
Write-Host "`n================================================================" -ForegroundColor Green
Write-Host "  WinPE Customization COMPLETE" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  boot.wim: $WIM_PATH ($wimSize MB)"
Write-Host "  startnet.cmd: INJECTED (CDE Boot Menu)"
Write-Host "  Module:       CDECore.psm1 in WinPE modules"
Write-Host "`n  Next steps:"
Write-Host "  1. Run CreateISO.ps1 to generate CDE ISO"
Write-Host "  2. Or run Prepare-BootableUSB.ps1 for USB deployment"
Write-Host "================================================================`n" -ForegroundColor Green
