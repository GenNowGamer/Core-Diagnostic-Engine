#Requires -Version 5.1
<#
.SYNOPSIS
    Launches a pre-boot diagnostic tool from the CDE WinPE boot menu.

.DESCRIPTION
    Two different launch mechanisms depending on the tool:

    CHU (Core Hardware Utility - EDK2 UEFI application):
        The Windows Boot Manager (WBM) cannot launch non-Microsoft UEFI apps.
        It tries, but fails with STATUS_INVALID_IMAGE_FORMAT (0xc000007b).
        Fix: use the UEFI firmware BootNext mechanism.
          1. Creates a temporary BCD entry "CDE:CHU" in the laptop's LIVE BCD
             pointing to \EFI\CDE\CoreDiag.efi on the USB.
          2. Runs: bcdedit /set {fwbootmgr} bootsequence {guid}
             This writes BootNext to the UEFI NVRAM via EFI Runtime Services,
             telling the firmware to load that entry on the very next boot ONLY.
          3. Reboots. The UEFI firmware reads BootNext and loads CoreDiag.efi
             DIRECTLY - bypassing Windows Boot Manager entirely.
          4. BootNext is automatically consumed (deleted from NVRAM) after use.
          5. Any subsequent restart (from CHU menu or after exit) resumes
             the normal BootOrder: USB -> WBM -> WinPE -> CDE menu.
        bootx64.efi is NEVER touched. No restore logic needed.

    MemDiag (memtest.efi - Microsoft Windows Boot Application):
        Sets {memdiag} as a one-time BootSequence in the USB BCD.
        WBM can launch {memdiag} because it IS a Windows Boot Application.

.PARAMETER Tool
    CHU      - Core Hardware Utility (CoreDiag.efi, UNSIGNED - Secure Boot must be OFF)
    MemDiag  - Windows Memory Diagnostic (memtest.efi, Microsoft-signed)

.NOTES
    Requires CDE_ROOT environment variable to be set (done by startnet.cmd).
    CHU modifies the laptop's LIVE BCD and UEFI NVRAM (not the USB BCD).
    The CDE:CHU BCD entry is cleaned up at the start of the next CHU run.
#>
param(
    [Parameter(Mandatory)]
    [ValidateSet('CHU', 'MemDiag')]
    [string]$Tool
)

$toolDisplayName = switch ($Tool) {
    'CHU'     { 'Core Hardware Utility' }
    'MemDiag' { 'Windows Memory Diagnostic' }
}

Write-Host ""
Write-Host "  ============================================================"
Write-Host "   Pre-Boot Launch: $toolDisplayName"
Write-Host "  ============================================================"
Write-Host ""

# --- Validate environment ----------------------------------------------------
if (-not $env:CDE_ROOT) {
    Write-Host "  ERROR: CDE_ROOT is not set." -ForegroundColor Red
    Read-Host "  Press Enter to return to the menu"
    exit 1
}

$logDir = Join-Path $env:CDE_ROOT 'CDE\Runtime\Data\sessions'
if (-not (Test-Path $logDir)) { New-Item $logDir -ItemType Directory -Force | Out-Null }
$logFile = Join-Path $logDir "PreBootTool_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log([string]$msg, [string]$color = '') {
    $msg | Add-Content $logFile -ErrorAction SilentlyContinue
    if ($color) { Write-Host $msg -ForegroundColor $color } else { Write-Host $msg }
}

Write-Log "  CDE_ROOT : $env:CDE_ROOT"
Write-Log "  Log file : $logFile"

# =============================================================================
# CHU - Core Hardware Utility
# Use UEFI firmware BootNext to load CDEBoot.efi directly, bypassing WBM.
# This writes to the laptop's LIVE BCD and UEFI NVRAM (not the USB BCD).
# =============================================================================
if ($Tool -eq 'CHU') {

    $coreEfi     = "$env:CDE_ROOT\EFI\CDE\CDEBoot.efi"
    $driveLetter = $env:CDE_ROOT.Substring(0, 1)

    Write-Log ""
    Write-Log "  NOTE: CDEBoot.efi is unsigned." 'Yellow'
    Write-Log "        UEFI Secure Boot MUST be DISABLED or CHU will fail." 'Yellow'
    Write-Log ""

    if (-not (Test-Path $coreEfi)) {
        Write-Log "  ERROR: CDEBoot.efi not found at: $coreEfi" 'Red'
        Read-Host "  Press Enter to return to the menu"
        exit 1
    }

    # --- Step 1: Clean up any leftover CDE:CHU entry from a previous run ----
    Write-Log "  [1/4] Checking for leftover CDE:CHU BCD entry..."
    $allEntries  = & bcdedit /enum all 2>&1
    $currentGuid = $null
    foreach ($line in $allEntries) {
        if ($line -match '\{[0-9a-fA-F\-]+\}') { $currentGuid = $line.Trim() }
        if ($line -match 'CDE:CHU' -and $currentGuid) {
            Write-Log "        Removing old entry $currentGuid..." 'Yellow'
            & bcdedit /delete $currentGuid /cleanup 2>&1 | Out-Null
            $currentGuid = $null
        }
    }

    # --- Step 2: Create a new BCD entry in the LIVE BCD ---------------------
    Write-Log "  [2/4] Creating UEFI boot entry for CDEBoot.efi in live BCD..."
    $createOut  = & bcdedit /create /d "CDE:CHU" /application BOOTAPP 2>&1
    $createText = $createOut -join ' '
    Write-Log "        $createText"

    $guidMatch = [regex]::Match($createText,
        '\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}')
    if (-not $guidMatch.Success) {
        Write-Log "  ERROR: bcdedit /create returned no GUID. Cannot continue." 'Red'
        Read-Host "  Press Enter to return to the menu"
        exit 1
    }
    $guid = $guidMatch.Value
    Write-Log "        GUID: $guid" 'Green'

    $r1 = & bcdedit /set $guid device "partition=$($driveLetter):" 2>&1
    $r2 = & bcdedit /set $guid path '\EFI\CDE\CDEBoot.efi' 2>&1
    Write-Log "        device -> $($r1 -join ' ')"
    Write-Log "        path   -> $($r2 -join ' ')"

    # --- Step 3: Set UEFI BootNext via {fwbootmgr} --------------------------
    # This writes the BootNext variable to UEFI NVRAM via EFI Runtime Services.
    # The UEFI firmware will load CDEBoot.efi on the next boot ONLY.
    # BootNext is auto-consumed after one use; normal BootOrder then resumes.
    Write-Log ""
    Write-Log "  [3/4] Writing UEFI BootNext: {fwbootmgr} bootsequence -> $guid"

    # {fwbootmgr} must exist in the live BCD before bcdedit can write to UEFI NVRAM.
    # The USB BCD only has {bootmgr}/{default}/{memdiag} - no {fwbootmgr} - so create it.
    $fwbmCheck = & bcdedit /enum '{fwbootmgr}' 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "        {fwbootmgr} not in live BCD - creating it..." 'Yellow'
        $fwCreate = & bcdedit /create '{fwbootmgr}' /d "UEFI Firmware Boot Manager" 2>&1
        Write-Log "        $($fwCreate -join ' ')"
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  ERROR: Could not create {fwbootmgr} in live BCD." 'Red'
            & bcdedit /delete $guid /cleanup 2>&1 | Out-Null
            Read-Host "  Press Enter to return to the menu"
            exit 1
        }
    }

    $bsResult = & bcdedit /set '{fwbootmgr}' bootsequence $guid 2>&1
    $bsText   = $bsResult -join ' '
    Write-Log "        bcdedit: $bsText"

    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ERROR: Failed to set BootNext (exit $LASTEXITCODE)." 'Red'
        & bcdedit /delete $guid /cleanup 2>&1 | Out-Null
        Read-Host "  Press Enter to return to the menu"
        exit 1
    }
    Write-Log "        BootNext written to UEFI NVRAM." 'Green'

    # --- Step 4: Reboot ------------------------------------------------------
    Write-Log ""
    Write-Log "  [4/4] Ready."
    Write-Log ""
    Write-Log "  ============================================================"
    Write-Log "   Rebooting into: CDE Pre-Boot Launcher (CDEBoot.efi)"
    Write-Log "   UEFI firmware loads CDEBoot.efi via BootNext (one-time)."
    Write-Log "   bootx64.efi (WBM) is untouched - no file swap."
    Write-Log "   BootNext auto-clears after CHU loads."
    Write-Log "   Restart or exit from CHU -> normal boot order resumes:"
    Write-Log "   USB -> WBM -> WinPE -> CDE menu."
    Write-Log "  ============================================================"
    Write-Log ""
    Write-Log "  Rebooting in 5 seconds  (Ctrl+C to cancel)..."
    Start-Sleep -Seconds 5

    Write-Log "  Calling wpeutil reboot..."
    $wpeResult = & wpeutil reboot 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  wpeutil reboot failed ($LASTEXITCODE): $($wpeResult -join ' ')  -- trying shutdown /r ..." 'Yellow'
        & shutdown /r /t 0
        if ($LASTEXITCODE -ne 0) {
            Write-Log "  ERROR: Both reboot methods failed. Please reboot manually." 'Red'
            Read-Host "  Press Enter to return to the menu"
        }
    }
    exit 0
}

# =============================================================================
# MemDiag - Windows Memory Diagnostic
# Use the built-in {memdiag} BCD entry (WINDOWSMEMORYDIAGNOSTIC type).
# This IS a Windows Boot Application so WBM can launch it correctly.
# =============================================================================

$usbBcdPath = "$env:CDE_ROOT\EFI\microsoft\boot\BCD"
if (-not (Test-Path $usbBcdPath)) {
    Write-Log "  ERROR: USB BCD not found at: $usbBcdPath" 'Red'
    Read-Host "  Press Enter to return to the menu"
    exit 1
}

Write-Log "  USB BCD  : $usbBcdPath"
Write-Log ""
Write-Log "  [1/3] Using built-in {memdiag} Windows Boot Application entry..."

# {memdiag} is always present in the USB BCD - it is created automatically
# by bcdedit when the BCD is initialised and points to memtest.efi.
$bcdLines = & bcdedit /store "$usbBcdPath" /enum all 2>&1
$hasMem   = $bcdLines | Where-Object { $_ -match '\{memdiag\}' }
if ($hasMem) {
    Write-Log "        {memdiag} confirmed in USB BCD." 'Green'
} else {
    Write-Log "        WARNING: {memdiag} not found in USB BCD." 'Yellow'
    Write-Log "        The reboot may not launch Memory Diagnostic."
}

Write-Log ""
Write-Log "  [2/3] Setting one-time BootSequence -> {memdiag} in USB BCD..."
$result = & bcdedit /store "$usbBcdPath" /bootsequence '{memdiag}' 2>&1
Write-Log "        bcdedit: $($result -join ' ')"

if ($LASTEXITCODE -ne 0) {
    Write-Log "  ERROR: bcdedit /bootsequence failed (exit $LASTEXITCODE)." 'Red'
    Read-Host "  Press Enter to return to the menu"
    exit 1
}

Write-Log ""
Write-Log "  [3/3] Verifying BootSequence in USB BCD {bootmgr}..."
$bmLines = & bcdedit /store "$usbBcdPath" /enum '{bootmgr}' 2>&1
$seqLine = $bmLines | Where-Object { $_ -match 'bootsequence' }
if ($seqLine) {
    Write-Log "        $($seqLine.Trim())" 'Green'
} else {
    Write-Log "        WARNING: BootSequence not visible in {bootmgr}." 'Yellow'
}

Write-Log ""
Write-Log "  ============================================================"
Write-Log "   Rebooting into: Windows Memory Diagnostic"
Write-Log "   USB Boot Manager will auto-select memtest on next boot."
Write-Log "   After the test, reboot from USB to return to CDE."
Write-Log "  ============================================================"
Write-Log ""
Write-Log "  Rebooting in 5 seconds  (Ctrl+C to cancel)..."
Start-Sleep -Seconds 5

Write-Log "  Calling wpeutil reboot..."
$wpeResult = & wpeutil reboot 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Log "  wpeutil reboot failed ($LASTEXITCODE): $($wpeResult -join ' ')  -- trying shutdown /r ..." 'Yellow'
    & shutdown /r /t 0
    if ($LASTEXITCODE -ne 0) {
        Write-Log "  ERROR: Both reboot methods failed. Please reboot manually." 'Red'
        Read-Host "  Press Enter to return to the menu"
    }
}
