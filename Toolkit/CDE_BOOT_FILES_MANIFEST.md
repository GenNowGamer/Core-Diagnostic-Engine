# CDE Boot Files Acquisition Manifest
# Phase 3 Reference Document
# Last Updated: 2026-05-15

> Historical phase reference note (2026-05-22): this manifest reflects the acquisition plan state at that time.
> Current operational boot/build behavior is documented in Toolkit `README.md` and `session_handoff.md`.

## Overview
This document lists all boot files that must be acquired from Windows 10 sources (ADK or installation media)
and specifies their target locations in the CDE folder structure.

---

## SECTION 1: BIOS Boot Files (/boot/)

These files enable legacy BIOS/MBR boot method for older systems and compatibility.

### 1.1 Boot Manager Executable
**File Name:** BOOTMGR
**Source:** Windows 10 installation media (root directory) OR Windows ADK
**Target Location:** d:\Robert\Desktop\CDE Beta_Test\BOOTMGR (root)
**Size:** ~390 KB
**Description:** 32-bit boot manager that loads and executes BCD configuration. Must be at ISO/USB root.
**Validation:** File signature: "MZ" (MZ header for PE executable)

### 1.2 Boot Configuration Database (BIOS Variant)
**File Name:** BCD
**Source:** Windows 10 installation media (/sources/x64/) OR Windows ADK
**Target Location:** d:\Robert\Desktop\CDE Beta_Test\boot\BCD
**Size:** ~20-30 KB
**Description:** Binary registry hive defining BIOS boot options, boot timeout, default entry, and menu display settings.
**Generation Method:** Can be extracted from source media or generated via bcdedit.exe on Windows 10 system.
**Validation:** Binary file (hex dump should start with "regf" for registry format)
**BCD Entries to Configure (Phase 4):**
  - Default boot: {default} → Windows PE boot.wim with ToolkitGUI launch
  - Alternative: {memorydiag} → Memory test option
  - Alternative: {bootmgr} → Shell access option

### 1.3 Legacy NTLDR Compatibility
**File Name:** BCDNTLDR
**Source:** Windows 10 installation media (/boot/) OR Windows ADK
**Target Location:** d:\Robert\Desktop\CDE Beta_Test\boot\BCDNTLDR
**Size:** ~20-30 KB
**Description:** Legacy fallback for NT 4.0, 2000, XP systems that don't understand modern BCD.
**Validation:** Binary file (should be similar size to BCD)
**Note:** Can sometimes be omitted for modern systems only; included for maximum compatibility.

### 1.4 System Deployment Image Signature
**File Name:** BOOT.SDI
**Source:** Windows 10 installation media (/boot/) OR Windows ADK
**Target Location:** d:\Robert\Desktop\CDE Beta_Test\boot\BOOT.SDI
**Size:** ~2 KB
**Description:** Signature/verification file for boot system validation.
**Validation:** Binary file

### 1.5 Boot Sector Patcher
**File Name:** bootsect.exe
**Source:** Windows 10 installation media (/boot/) OR Windows ADK
**Target Location:** d:\Robert\Desktop\CDE Beta_Test\boot\bootsect.exe
**Size:** ~100 KB
**Description:** Utility for repairing/patching boot sectors. Useful for automated recovery operations.
**Validation:** PE executable (MZ header)

### 1.6 Multilingual UI Resources
**File Name:** bootmgr.exe.mui
**Source:** Windows 10 installation media (/boot/en-us/) OR Windows ADK
**Target Location:** d:\Robert\Desktop\CDE Beta_Test\boot\en-us\bootmgr.exe.mui
**Size:** ~20-50 KB
**Description:** English UI strings and resources for boot manager display.
**Validation:** Binary resource file (.MUI format)
**Additional Languages (if needed):**
  - es-es/bootmgr.exe.mui (Spanish)
  - fr-fr/bootmgr.exe.mui (French)

### 1.7 Boot Resources Library
**File Name:** bootres.dll
**Source:** Windows 10 installation media (/boot/resources/) OR Windows ADK
**Target Location:** d:\Robert\Desktop\CDE Beta_Test\boot\resources\bootres.dll
**Size:** ~50-100 KB
**Description:** Boot system resource library (graphics, fonts, error messages).
**Validation:** PE DLL (MZ header)

---

## SECTION 2: UEFI Boot Files (/EFI/)

These files enable modern UEFI/GPT boot method for contemporary systems.

### 2.1 UEFI Boot Loader
**File Name:** bootx64.efi
**Source:** Copied from rEFInd launcher (EFI\refind\refind_x64.efi) during USB preparation
**Target Location:** d:\Robert\Desktop\CDE Beta_Test\EFI\boot\bootx64.efi
**Size:** Matches rEFInd binary build size
**Description:** UEFI removable-media fallback loader. This path is owned by rEFInd and launches the CDE rEFInd menu.
**Validation:** UEFI executable (file signature should be "MZ" followed by PE headers)
**UEFI Compliance:** Must support:
  - UEFI 2.3+ specification
  - 64-bit x64 architecture
  - GPT partition table

### 2.1.1 rEFInd Configuration
**File Name:** refind.conf
**Source:** Repository-managed configuration template
**Target Location:** d:\Robert\Desktop\CDE Beta_Test\EFI\boot\refind.conf
**Description:** Deterministic CDE rEFInd menu (WinPE, CHU, MemDiag) and boot policy (timeout, scan mode).
**Validation:** Plain-text config with valid loader paths present on deployed media.

### 2.1.2 rEFInd Icons
**File Name:** icons\*
**Source:** rEFInd binary distribution
**Target Location:** d:\Robert\Desktop\CDE Beta_Test\EFI\boot\icons\
**Description:** Required icon set for graphical rEFInd rendering. If missing, rEFInd falls back to text-only mode.
**Validation:** Directory present with PNG icon assets and README/license files.

### 2.2 UEFI Boot Configuration Database
**File Name:** BCD
**Source:** Windows 10 installation media (/EFI/Microsoft/Boot/) OR Windows ADK
**Target Location:** d:\Robert\Desktop\CDE Beta_Test\EFI\microsoft\boot\BCD
**Size:** ~20-30 KB
**Description:** UEFI-specific BCD registry defining UEFI boot options, Windows PE loader, and boot menu.
**Generation Method:** Extract from source media or generate via bcdedit.exe on UEFI-capable system.
**Validation:** Binary registry file (hex dump should start with "regf")
**BCD Entries to Configure (Phase 4):**
  - Default: UEFI Windows PE boot (matching BIOS BCD structure)
  - Boot path: \sources\boot.wim (Windows PE kernel)
  - Application: \windows\system32\boot\winload.efi

### 2.3 CD/DVD UEFI Boot Loader
**File Name:** cdboot.efi
**Source:** Windows 10 installation media (/EFI/Microsoft/Boot/) OR Windows ADK
**Target Location:** d:\Robert\Desktop\CDE Beta_Test\EFI\microsoft\boot\cdboot.efi
**Size:** ~800 KB - 1.5 MB
**Description:** UEFI boot loader optimized for CD/DVD media (optical media boot).
**Validation:** UEFI executable
**Use Case:** When ISO is burned to CD/DVD and booted in UEFI mode.

### 2.4 EFI System Partition Image
**File Name:** efisys.bin
**Source:** Windows 10 installation media (/EFI/Microsoft/Boot/) OR Windows ADK
**Target Location:** d:\Robert\Desktop\CDE Beta_Test\EFI\microsoft\boot\efisys.bin
**Size:** ~4-5 MB
**Description:** EFI System Partition image for bootable USB creation. Contains minimal FAT32 filesystem with UEFI boot files.
**Validation:** Binary image file (begins with FAT32 filesystem signature)
**Usage:** During USB creation, this image is written to USB EFI partition.

---

## SECTION 3: Windows PE Boot Image (/sources/x64/)

The actual bootable kernel that runs both in BIOS and UEFI environments.

### 3.1 Windows PE Boot Image
**File Name:** boot.wim
**Source:** Windows 10 ADK (Windows Assessment and Deployment Kit) - Primary source
**Alternate Source:** Windows 10 installation media (not recommended - less flexible)
**Target Location:** d:\Robert\Desktop\CDE Beta_Test\sources\x64\boot.wim
**Size:** ~300-400 MB (compressed)
**Description:** Windows PE 10 (64-bit) boot image. Minimal OS kernel that runs entirely in RAM. Serves as boot environment for all diagnostics.
**Generation Method:**
  1. Download Windows 10 ADK from Microsoft (https://docs.microsoft.com/en-us/windows-hardware/get-started/adk-install)
  2. Install "Windows PE" component (others optional)
  3. Use DISM + Copype utilities to generate boot.wim
  4. Customize boot.wim with CDE tools/scripts (Phase 5)
**Validation:**
  - File format: .wim (Windows Imaging Format)
  - Can be mounted with ImageX or DISM
  - Contains single boot image (recommended) or multiple if different architectures needed
**Customization (Phase 5):**
  - Mount boot.wim with DISM
  - Add PowerShell modules (Toolkit.Core.psm1)
  - Add ToolkitGUI.exe and supporting .NET assemblies
  - Add tool manifests and configuration
  - Add WinPE startup scripts (startnet.cmd)
  - Unmount and commit changes
  - Result: ~600-800 MB customized boot.wim

### 3.2 Optional Language Packs (for multi-language support)
**Files:**
  - es-es.7z (Spanish language pack)
  - fr-fr.7z (French language pack)
**Source:** Windows ADK language packs (optional)
**Target Location:** d:\Robert\Desktop\CDE Beta_Test\sources\x64\
**Description:** Compressed language resource packs for non-English UI in WinPE.
**Status:** Optional - not required for English-only operation

---

## SECTION 4: ElTorito Boot Images (/EZBOOT/)

Legacy optical media (CD/DVD) boot support using El Torito standard.

### 4.1 ElTorito Boot Loader
**File Name:** LOADER.BIN
**Source:** Generated by oscdimg.exe (Windows OEM tool) - see section 4.5
**Target Location:** d:\Robert\Desktop\CDE Beta_Test\EZBOOT\LOADER.BIN
**Size:** 512 bytes (exactly)
**Description:** Primary El Torito boot loader for BIOS systems booting from CD/DVD. Exactly 512 bytes (one sector).
**Validation:** Binary file, exactly 512 bytes
**Generation:** Automatically created by oscdimg.exe during ISO generation (Phase 6)

### 4.2 Default ElTorito Boot Entry
**File Name:** DEFAULT.EZB
**Source:** Windows 10 installation media (/boot/bios/) OR generated
**Target Location:** d:\Robert\Desktop\CDE Beta_Test\EZBOOT\DEFAULT.EZB
**Size:** Variable (typically 512 bytes - 2 KB)
**Description:** Default ElTorito boot option when ISO mounted on CD/DVD.
**Note:** Often identical to LOADER.BIN or reference to it.

### 4.3 CDE Main Boot Option
**File Name:** CDE.EZB
**Source:** Custom - based on boot.wim or generated boot image
**Target Location:** d:\Robert\Desktop\CDE Beta_Test\EZBOOT\CDE.EZB
**Size:** ~32 MB (boot image)
**Description:** CDE-specific ElTorito boot image for optical media. Contains minimal boot environment.
**Generation (Phase 5):** Extract first 32MB of boot.wim or create minimal boot image from WinPE kernel.

### 4.4 Memory Diagnostic Option
**File Name:** MEMDIAG.EZB
**Source:** Windows 10 installation media (/sources/recovery/winre.wim) OR custom
**Target Location:** d:\Robert\Desktop\CDE Beta_Test\EZBOOT\MEMDIAG.EZB
**Size:** ~20-30 MB (boot image)
**Description:** Alternative ElTorito boot option for memory diagnostics without full Windows PE.
**Status:** Optional but recommended for redundant boot options.

### 4.5 Boot Image File Catalogs
**File Name(s):** MRIPE.BIF, OPRE.BIF
**Source:** Documentation/reference files (can be generated)
**Target Location:** d:\Robert\Desktop\CDE Beta_Test\EZBOOT\
**Description:** Boot image file catalogs. Reference documentation for El Torito boot images available.
**Status:** Informational only - not required for functionality.

---

## SECTION 5: Linux/ISOLINUX Boot (Optional - /isolinux/)

Maximum boot compatibility via ISOLINUX bootloader.

### 5.1 Linux Kernel (vmlinuz)
**File Name:** vmlinuz (compressed Linux kernel)
**Source:** Syslinux/ISOLINUX project OR Linux distribution
**Target Location:** d:\Robert\Desktop\CDE Beta_Test\isolinux\vmlinuz
**Size:** ~5-10 MB
**Description:** Compressed Linux kernel for maximum hardware compatibility fallback.
**Status:** Optional - included for complete boot compatibility but not essential if BIOS/UEFI boot sufficient.
**Rationale:** Some very old or exotic hardware may only boot via ISOLINUX Linux kernel.

### 5.2 Initial Ramdisk (initrd.cgz)
**File Name:** initrd.cgz (compressed initial ramdisk)
**Source:** Syslinux/ISOLINUX project OR custom
**Target Location:** d:\Robert\Desktop\CDE Beta_Test\isolinux\initrd.cgz
**Size:** ~20-50 MB
**Description:** Base filesystem and drivers for Linux boot environment.

### 5.3 SCSI Drivers (scsi.cgz)
**File Name:** scsi.cgz (SCSI controller drivers)
**Source:** Syslinux/ISOLINUX project
**Target Location:** d:\Robert\Desktop\CDE Beta_Test\isolinux\scsi.cgz
**Size:** ~5-10 MB
**Description:** SCSI/SAS controller support drivers. Loaded alongside initrd.cgz.
**Status:** Optional - only needed if SCSI-attached storage must be supported in Linux boot mode.

---

## SECTION 6: ISO Creation Utilities (/HALP/)

Tools needed to generate bootable ISO images.

### 6.1 oscdimg.exe (Windows OEM CD/DVD Imaging Tool)
**File Name:** oscdimg.exe
**Source:** Windows ADK for Windows 10 OR Windows OEM toolkit
**Target Location:** d:\Robert\Desktop\CDE Beta_Test\HALP\oscdimg.exe
**Size:** ~1-2 MB
**Description:** Microsoft's official CD/DVD image creation tool. Used by CreateISO.ps1 to generate bootable ISOs with multi-boot support (BIOS + UEFI).
**Command Line (Phase 6):**
```
oscdimg.exe -bootdata:2#p0,e,b"BOOTMGR" -bootdata:2#pEFI,e,b"bootmgr.efi" -u2 -udfver102 [CDEROOT] [OUTPUT.iso]
```
**Parameters:**
  - `-bootdata:2#p0,e,b"BOOTMGR"` = BIOS boot entry using BOOTMGR
  - `-bootdata:2#pEFI,e,b"bootmgr.efi"` = UEFI boot entry using bootmgr.efi
  - `-u2` = Enable Joliet extensions (long filenames)
  - `-udfver102` = Enable UDF 1.02 (required for bootable DVD)
**Validation:** Executable file (PE format, MZ header)
**Alternative:** ImgBurn (free, but requires manual setup)

---

## SECTION 7: Acquisition Workflow (Phase 3 Implementation)

### Step 1: Download Windows 10 ADK
1. Visit: https://docs.microsoft.com/en-us/windows-hardware/get-started/adk-install
2. Download ADK for Windows 10 (matching your Windows 10 version, e.g., 22H2)
3. Run installer: adksetup.exe
4. Select components to install:
   - ✅ Deployment Tools (required for DISM, oscdimg)
   - ✅ Windows PE (required for PE kernel and boot files)
   - ☐ Windows Performance Toolkit (optional)
   - ☐ UEFI Validation Toolkit (optional)
5. Installation directory typically: C:\Program Files (x86)\Windows Kits\10

### Step 2: Extract Boot Files from ADK
```powershell
# Paths (adjust for your ADK version):
$adkPath = "C:\Program Files (x86)\Windows Kits\10"

# Copy BIOS boot files:
Copy-Item "$adkPath\Assessment and Deployment Kit\Deployment Tools\$arch\OSCDIMG.EXE" `
          "d:\Robert\Desktop\CDE Beta_Test\HALP\oscdimg.exe" -Force

# Copy Windows PE for boot.wim:
Copy-Item "$adkPath\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\*" `
          "d:\Robert\Desktop\CDE Beta_Test\sources\x64\" -Recurse -Force
```

### Step 3: Extract from Windows 10 Installation Media
If ADK doesn't have all files, extract from Windows 10 ISO:
```powershell
# Mount Windows 10 ISO
$iso = "E:\"  # Drive letter of mounted ISO

# Copy boot files:
Copy-Item "$iso\boot\*" "d:\Robert\Desktop\CDE Beta_Test\boot\" -Recurse -Force
Copy-Item "$iso\EFI\*" "d:\Robert\Desktop\CDE Beta_Test\EFI\" -Recurse -Force
Copy-Item "$iso\sources\boot.wim" "d:\Robert\Desktop\CDE Beta_Test\sources\x64\" -Force
```

### Step 4: Validation Checklist
- [ ] BOOTMGR exists at root (390 KB)
- [ ] boot\BCD exists (20-30 KB)
- [ ] boot\en-us\bootmgr.exe.mui exists
- [ ] boot\resources\bootres.dll exists
- [ ] EFI\boot\bootx64.efi exists (800 KB - 1.5 MB)
- [ ] EFI\microsoft\boot\BCD exists (20-30 KB)
- [ ] EFI\microsoft\boot\cdboot.efi exists
- [ ] EFI\microsoft\boot\efisys.bin exists (4-5 MB)
- [ ] sources\x64\boot.wim exists (300-400 MB)
- [ ] HALP\oscdimg.exe exists (1-2 MB)

---

## SECTION 8: Known Issues & Workarounds

### Issue: BCD files not in ADK
**Workaround:** Extract from Windows 10 installation media or generate via bcdedit on Windows 10 system

### Issue: boot.wim customization complex
**Workaround:** Use DISM tool (included with ADK):
```powershell
dism /Mount-Wim /WimFile:boot.wim /Index:1 /MountDir:mount_point
# Make changes...
dism /Unmount-Wim /MountDir:mount_point /Commit
```

### Issue: oscdimg.exe not in ADK
**Workaround:** Download from Windows 10 OEM toolkit or use alternative (ImgBurn)

### Issue: UEFI boot not working after ISO generation
**Workaround:** Ensure bootmgr.efi and EFI\microsoft\boot\ hierarchy correctly populated before oscdimg.exe execution

---

## Summary: Files by Source

| Source | Files | Quantity |
|--------|-------|----------|
| **Windows 10 ADK** | boot.wim, oscdimg.exe | 2 (critical) |
| **Windows 10 Installation Media** | BOOTMGR, BCD, EFI files, boot* files | 10+ (essential) |
| **CDE (Local)** | isolinux.cfg, syslinux.cfg, BOOT.MSG | 3 (already created) |
| **Custom Generated** | CDE.EZB, boot image files | 2-3 (Phase 5) |
| **OPTIONAL** | vmlinuz, initrd.cgz, scsi.cgz, language packs | 4+ (for extended compatibility) |

**Total files needed for minimal functional CDE:** ~15-20 files
**Total files for full compatibility:** ~25-30 files
**Total size (uncompressed):** ~1-2 GB
**Total size (ISO):** ~1-1.5 GB

---

## Next Steps
1. Download Windows 10 ADK
2. Extract boot files per workflow above
3. Validate all files present
4. Proceed to Phase 4: Boot menu configuration

