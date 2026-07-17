# CDE Folder Structure Map (Post-Restructure)

> Historical snapshot note (2026-05-22): this map captures a prior restructuring phase plan.
> For current operational behavior, follow `README.md` and `session_handoff.md` at the Toolkit root.
> Current canonical source/build flow is `App/ToolkitGUI/` -> `App/Publish-ToolkitGUI.ps1` -> published GUI payload under `CDE/ToolkitGUI/bin/Release/net8.0-windows/` (not source).
> **Operational addendum (2026-07-17):** System Health uses `Scripts/Core/HealthFindings.ps1` plus `Config/EventFindingClusters.json` / `Scripts/Core/EventFindingClusters.ps1` for persisted structured findings and event correlation. Deep System `gpu_functional_tests` invokes the self-contained `App/CdeGpuDiagCli/` helper published beside ToolkitGUI. GUI/PDF retain detailed legacy output alongside scored findings.
> **Operational addendum (2026-07-03):** WinPE boot menu options 1–2 hand off to main `MainWindow` in-process (opaque shell; `WinPeStartupLog.cs` → `CDE\Runtime\winpe_startup.log`). GUI-only USB sync after `Publish-ToolkitGUI.ps1`; no `boot.wim` rebuild unless `startnet.cmd` changed.
> **Operational addendum (2026-07-01):** Operator PDFs only in `Logs\`; internal JSON/session logs under `CDE\Runtime\Data\` (`workflows`, `scans`, `cst`, `sessions`); work order case JSON under `CDE\Runtime\WorkOrders\` (cleared via **Dashboard → Clear Recent**, not Settings). GUI **Open Report** (no Save report / Open HTML). Dashboard **suggested path** from `SymptomFlows.json` keywords on work order generate; **Verify case** removed. Case timeline light-theme cards.
> **Operational addendum (2026-06-30):** Hijack & Scam Repair (`HijackRepair.ps1`, `HijackRepairFindings.ps1`, `HijackRepairView`); `TabularScanReportService` for PDF scan reports; System Health / Process Analyzer **Open Report**; MSIX startup-task executable resolution + package publisher signature in `MsixStartup.ps1`; Process Analyzer Investigation mode hides toolbar status banner.
> **Operational addendum (2026-06-26):** Startup Manager scheduled-task/GPO/MSIX/correlation modules; Post-Op eight-tool expansion via `PostOpCleanup.ps1`; Fast Fixes trimmed to 14 (DNS/icon/thumb cache in Post-Op only).
> **Operational addendum (2026-06-25):** Process Analyzer detail pane uses C# WMI enrichment (`ProcessWmiEnricher`); ToolkitGUI Release publish uses `PublishTrimmed=false` for reliable JSON model binding.

> **Operational addendum (2026-06-22):** PDF operator manual `HALP/CDE_User_Guide.pdf` from `Docs/UserGuide/` via `App/UserGuideGenerator` at publish; **Settings → Open User Guide**.

## Overview
CDE has been restructured to mirror MRI's proven architecture while preserving all existing CDE tools and applications. This document maps the new folder hierarchy and describes each component's purpose.

---

## Root-Level Directory Structure

```
CDE Beta_Test/
├── boot/                      # BIOS boot files (MBR/legacy boot)
├── EFI/                       # UEFI boot files (UEFI/GPT boot)
├── EZBOOT/                    # ElTorito boot images (optical media fallback)
├── isolinux/                  # ISOLINUX configuration (Linux boot fallback)
├── sources/                   # WinPE and OS source files
├── Diagnostics/               # Diagnostic tools (CDE consolidated)
├── Windows Tools/             # Windows utilities and repair tools
├── CDE/                       # Deployment/runtime mirror consumed by media sync
│   └── Runtime/               # WinPE session state + winpe_startup.log + internal Data\ (workflows/scans/cst/sessions) + WorkOrders\ (case JSON) + active_work_order.json
├── Scripts/                   # PowerShell modules and workflows
├── Config/                    # Configuration files
├── Deploy/                    # Deployment and build artifacts
├── Mount/                     # WinPE mount points
├── WinPE/                     # WinPE build scripts and customizations
├── HALP/                      # Help resources and utilities (incl. CDE_User_Guide.pdf)
├── Docs/                      # Authoring source (UserGuide Markdown → HALP PDF at publish)
├── Logs/                      # Operational logs
├── App/                       # Canonical source tree + publish scripts
├── Tools/                     # (Legacy - kept for reference, use /Diagnostics/ or /Windows Tools/)
└── autorun.inf               # ISO auto-execution configuration (TBD)
```

---

## Detailed Folder Descriptions

### 1. `/boot/` - BIOS Boot Files
**Purpose:** Contains all files needed for BIOS/MBR boot (legacy boot method)

```
boot/
├── BOOTMGR                    # 32-bit boot manager executable
├── BCD                        # Boot Configuration Database (BIOS variant)
├── BCDNTLDR                   # Legacy NTLDR compatibility
├── BOOT.SDI                   # System Deployment Image signature
├── bootsect.exe               # Boot sector patcher utility
├── en-us/
│   └── bootmgr.exe.mui       # Multilingual UI resources
└── resources/
    └── bootres.dll            # Boot resources library
```

**Source:** Windows 10 installation media or Windows ADK
**Status:** Files to be acquired in Phase 3

---

### 2. `/EFI/` - UEFI Boot Files
**Purpose:** Contains all files for UEFI/GPT boot (modern boot method)

```
EFI/
├── boot/
│   ├── bootx64.efi           # rEFInd fallback launcher (UEFI removable path)
│   ├── refind.conf           # Active CDE rEFInd menu config
│   └── icons/                # Required rEFInd graphical menu assets
├── refind/
│   └── refind_x64.efi        # rEFInd source binary copied to EFI\boot\bootx64.efi
├── CDE/
│   ├── CHUPrep.efi           # rEFInd CHU entry — console prep, chainloads CoreDiag.efi
│   ├── CoreDiag.efi          # CHU main pre-boot application
│   ├── CDEBoot.efi           # Windows Boot Manager BOOTAPP chainload (legacy path)
│   └── memtest.efi           # Memory diagnostic payload
├── CoreDiag/                 # CHU runtime output (created on CDEDATA / toolkit volume at test time)
│   ├── Logs/                 # UEFI session .log files
│   └── Results/              # Exported JSON result files
└── microsoft/
    └── boot/
    ├── BCD               # UEFI-specific Boot Configuration Database
    ├── bootmgfw.efi      # Windows Boot Manager used for WinPE entry
    ├── cdboot.efi        # CD/DVD UEFI boot loader
    └── efisys.bin        # EFI system partition image
```

**Source:** Windows 10 installation media or Windows ADK
**Status:** Files to be acquired in Phase 3

---

### 3. `/EZBOOT/` - ElTorito Boot Images
**Purpose:** Legacy optical media boot support (CD/DVD fallback)

```
EZBOOT/
├── LOADER.BIN               # Primary 512-byte boot loader
├── DEFAULT.EZB              # Default ElTorito boot configuration
├── CDE.EZB                  # CDE main boot image (ElTorito)
├── MEMDIAG.EZB              # Memory diagnostic boot option
├── DBAN.IMA                 # DBAN disk wiper image (optional)
├── MRIPE.BIF                # Boot image file catalog
└── OPRE.BIF                 # Optional boot image file catalog
```

**Purpose:** Provides boot options when ISO mounted on optical drive
**Status:** Structure ready, files to be created in Phase 2-3

---

### 4. `/isolinux/` - Linux Boot Fallback
**Purpose:** ISOLINUX/SYSLINUX configuration for maximum boot compatibility

```
isolinux/
├── isolinux.cfg             # ISOLINUX boot menu configuration
├── syslinux.cfg             # SYSLINUX variant (USB boot)
├── BOOT.CAT                 # El Torito boot catalog
├── BOOT.MSG                 # Boot menu text display
├── vmlinuz                  # Compressed Linux kernel (optional)
├── initrd.cgz               # Initial ramdisk filesystem
└── scsi.cgz                 # SCSI controller drivers (if needed)
```

**Purpose:** Provides fallback boot method for older systems
**Status:** Configuration to be created in Phase 2, kernels to be acquired in Phase 3

---

### 5. `/sources/` - WinPE and OS Sources
**Purpose:** Contains Windows PE boot images and OS installation sources

```
sources/
└── x64/
    ├── boot.wim             # Windows 10 WinPE 64-bit boot image
    ├── install.wim          # (Optional) Windows installation image
    ├── ENGLISH_UNITED_STATES.BAT
    ├── SPANISH_SPAIN.BAT    # (Language pack options)
    ├── SPANISH_MEXICO.BAT
    └── FRENCH_CANADA.BAT
```

**Purpose:** WinPE is the boot kernel for both BIOS and UEFI; provides WinPE-native diagnostic environment
**Status:** To be created in Phase 5 using Windows ADK

---

### 6. `/Diagnostics/` - Diagnostic Tools (CDE)
**Purpose:** Reorganized CDE diagnostic utilities in MRI-like structure

```
Diagnostics/
├── Hardware/                # Hardware diagnostic tools (empty - ready for expansion)
├── Memory/                  # Memory test tools
│   ├── CoreHardwareUtility/ # UEFI diagnostics (moved from Tools/Boot/)
│   │   └── CoreDiag.efi
│   ├── MemTest86/          # Memory test boot image (moved from Tools/Boot/)
│   │   └── memtest86-usb.img   # optional vendor USB image — not in Git (~1 GB)
│   └── WinMemoryDiag/      # Windows memory diagnostic (moved from Tools/Boot/)
│       └── memtest.efi
├── Storage/                # Storage/disk utilities (empty - ready for expansion)
├── Utils/                  # General utilities (empty - ready for expansion)
└── Malware/                # Malware scanning tools (empty - ready for expansion)
```

**Current Contents:** Memory diagnostic tools moved from `/Tools/Boot/`
**Status:** Structure ready, tools relocated (Phase 1 complete)

---

### 7. `/Windows Tools/` - System Utilities and Repair
**Purpose:** Windows-specific repair and utility applications

```
Windows Tools/
├── Utilities/              # Utility applications
│   └── 7Zip/              # 7-Zip command-line tools (moved from Tools/Utils/)
│       ├── 7z.exe
│       ├── 7z.dll
│       └── ... other 7-Zip files
├── Repair/                # OS repair and recovery tools (empty - ready for expansion)
│   ├── Boot Repair/       # Boot file repair utilities
│   ├── Registry Repair/   # Registry recovery tools
│   └── MBR Repair/        # MBR/UEFI repair tools
└── Debugging/             # Windows debugging tools (empty - ready for expansion)
```

**Current Contents:** 7-Zip moved from `/Tools/Utils/`
**Planned:** Boot repair tools, registry recovery, driver repair utilities
**Status:** Structure ready, initial tools relocated (Phase 1 complete)

---

### 8. `/CDE/` - Deployment/Runtime Mirror
**Purpose:** Published runtime output and deployment artifacts consumed by media sync

```
CDE/
├── ToolkitGUI/            # Main WPF GUI application project
│   ├── bin/
│   │   ├── Debug/
│   │   └── Release/
│   │       └── net8.0-windows/
│   │           └── ToolkitGUI.exe    # Primary executable
│   ├── ToolkitGUI.csproj
│   ├── ToolkitGUI.xaml
│   ├── App.xaml
│   ├── RuntimeConfigContext.cs       # Environment detection
│   ├── MainWindow.xaml
│   ├── BootUptimeHelper.cs         # Banner uptime (Uptime: Xd Xh Xm; Event 12 / 6005 / WMI)
│   ├── OfflineRuntimePaths.cs      # CDE\Runtime session file paths (WinPE)
│   ├── PowerShellArgumentHelper.cs # Safe quoting for powershell.exe / robocopy workflow args
│   ├── Models/
│   ├── Services/          # WorkflowReportPdfService, WorkflowResultFormatter, CstRemediationService, ShellFileOpenHelper, WorkflowStepLabelHelper, …
│   ├── ViewModels/        # includes DiagAndRepairViewModel, SystemHealthViewModel, CdeWorkflowRunnerViewModel
│   └── Views/             # includes DiagAndRepairView, SystemHealthView, CstFindingsOperatorDialog, ToolsLibraryView
├── Data/                  # Application resource data
├── Tools_Management/      # Tool management scripts and manifests
│   ├── ToolCatalog.xml   # Tool definitions
│   ├── tools_manifest.json  # Tool metadata with SHA256 checksums
│   ├── update_tools_manifest.ps1  # Update manifest script
│   ├── Ensure-BootArtifacts.ps1   # Boot artifact verification
│   └── THIRD_PARTY_TOOL_ONBOARDING.md
├── ToolkitGUI.sln        # Visual Studio solution file
└── Publish-ToolkitGUI.ps1  # Automated build/publish script
```

**Purpose:** Mirrors published ToolkitGUI/runtime content for deployment paths
**Status:** Populated by `App/Publish-ToolkitGUI.ps1` in the current build flow

---

### 9. `/Scripts/` - PowerShell Automation
**Purpose:** PowerShell modules and workflow automation

```
Scripts/
├── Core/
│   ├── Toolkit.Core.psm1  # Core module (environment detection, logging, Get-CdeBootUptimeInfo, Format-WindowsUpdateStack)
│   ├── Toolkit.Elevation.psm1  # UAC relay + workflow step status helpers
│   ├── OfflineSamAccount.psm1  # Offline SAM Administrator enable + NT hash (account recovery)
│   ├── StartupRisk.ps1  # Shared startup path/risk scoring, Winlogon, GPO Run, MSIX audit (Startup Manager + audit_startup)
│   ├── MsixStartup.ps1  # MSIX startup task discovery, manifest executable resolution, package signature/analysis
│   ├── StartupApproved.ps1  # Task Manager StartupApproved hive sync for Run keys + startup folder
│   ├── StartupScheduledTask.ps1  # Logon/boot scheduled tasks; \Microsoft\* filter
│   ├── StartupCorrelation.ps1  # Cross-mechanism duplicate persistence grouping
│   ├── PostOpCleanup.ps1  # Icon/thumb cache, DNS flush, proxy reset, hosts restore, restart Explorer
│   ├── ExtensionDiscovery.ps1  # Startup Manager Extensions tab (CLSID, Chromium, Firefox)
│   ├── OfflineRuntime.ps1  # CDE\Runtime paths, offline session validation/cleanup
│   ├── ShadowCopyBrowse.ps1  # File Manager VSS list/mount (full Windows; all snapshots, newest-first)
│   ├── HealthCheckOrchestrator.ps1  # System Health Check catalog, phase lines, child workflow merge
│   ├── HealthChecks.ps1     # Quick vitals / deep system dispatchers (incl. Windows Update + GPU functional tests)
│   ├── HealthFindings.ps1   # Canonical structured finding schema, markers, status rollup
│   ├── EventFindingClusters.ps1 # Event-log correlation and confidence scoring
│   ├── SystemAuditChecks.ps1  # Shared audit functions (System Health Check audit_* checks)
│   ├── SecurityAuditChecks.ps1  # Shared security audit functions (System Health Check sec_* checks)
│   ├── ProcessAnalyzer.Core.ps1  # Process list/detail helpers, risk heuristics, CST invoke (Process Analyzer)
│   ├── HijackRepairChecks.ps1  # Hijack scan category checks (browser, network, security, startup, remote)
│   ├── HijackRepairFindings.ps1  # Hijack scan orchestration + tagged [HIJACK:FINDING] output
│   ├── HijackRepairHelpers.ps1  # Hijack repair actions (browser policy, hosts, Defender RTP, Winlogon, etc.)
│   └── WinPE_OfflineStartup.ps1  # WinPE boot initialization
└── Workflows/
    ├── BackupAndImage.ps1
    ├── HardwareDiagnostics.ps1   # Diag & Repair: CPU/Memory/Storage + optional CST (Quick|Extended; -ToolName CstScan)
    ├── FastFixes.ps1      # 14 verified one-click fixes (DNS/icon/thumb cache in Post-Op)
    ├── EnableOfflineAdministrator.ps1  # Tools Library cde_workflow (WinPE + offline SAM)
    ├── MalwareSweep.ps1   # Malware Cleanup: DefenderScan, CoreSecurityTool, UpdateHashIOCs
    ├── OSRepair.ps1
    ├── PostOp.ps1   # Post-Op Cleanup (8 tools: browser cache, services, file assoc, shell caches, DNS/proxy, hosts, restart Explorer)
    ├── ProcessAnalyzer.ps1   # Process Analyzer: List, Detail, Kill, CstScan, Export
    ├── HijackRepair.ps1   # Hijack & Scam Repair: Scan, Repair, Quick Repairs, Generate-Report
    ├── StartupManager.ps1
    ├── SystemHealthCheck.ps1  # Catalog-driven multi-check health orchestrator (audit_* + sec_* via shared Core modules)
    ├── TempFileCleaner.ps1
    ├── UninstallManager.ps1
    └── ValidateTools.ps1
```

**Removed workflows (2026-06-26 Phase 1):** `QuickHealth.ps1`, `DeepDiagnostics.ps1`, `SystemAudit.ps1` — superseded by `SystemHealthCheck.ps1`.

**Purpose:** Modular PowerShell workflows for diagnostics, repair, and automation
**Status:** All workflows present; path references updated for new structure (Phase 1 complete)

---

### 10. `/Config/` - Configuration Files
**Purpose:** Runtime configuration for CDE behavior

```
Config/
├── global.ini            # MRI-like runtime profile
│                         # - Localization (Language, Region)
│                         # - Runtime (LogLevel, Environment mode)
│                         # - BootBehavior (DefaultBootOption, MenuTimeout)
│                         # - Tools (AutoDiscoverTools, ValidateTools)
│                         # - Logging (LogPath, MaxLogAge)
│
├── HealthCheckCatalog.json  # System Health catalog/presets/actions; includes separate gpu_info + gpu_functional_tests
├── EventFindingClusters.json # Event correlation rules, scoring, suppressors, recommendations
└── settings.json         # Toolkit settings
                         # - ToolkitRoot, LogsRoot, ToolsRoot paths
                         # - DiagnosticsRoot, WindowsToolsRoot paths
                         # - BootFilesRoot, WinPERoot, DeployRoot paths
                         # - RobocopyThreads, MaxLogAgeDays
                         # - ScanTargetDrive, DefaultBackupDestination
```

**Status:** Both files updated to reference new folder structure (Phase 1 complete)

---

### 11. `/Deploy/` - Deployment Artifacts
**Purpose:** Build outputs and deployment configurations

```
Deploy/
├── WinPE.iso            # Bootable WinPE environment ISO
├── CustomWinPE.iso      # Custom WinPE variant ISO
├── CDE-Final.iso        # Final bootable CDE ISO (to be created in Phase 6)
└── HyperV/              # Hyper-V VM configuration for testing
    └── CDE-Sandbox/
```

**Purpose:** Store bootable ISO images and VM configurations
**Status:** WinPE ISOs already present; CDE-Final.iso to be created in Phase 6

---

### 12. `/Mount/` - WinPE Mount Points
**Purpose:** Temporary mount directories for WinPE image manipulation

```
Mount/
├── WinPE/              # WinPE image mount point
└── WinPEWork/          # WinPE work/staging directory
```

**Purpose:** Used during WinPE customization and boot image building
**Status:** Empty, ready for use

---

### 13. `/WinPE/` - WinPE Build Scripts
**Purpose:** Windows PE customization and build automation

```
WinPE/
├── build_winpe.ps1     # WinPE image builder script
├── run_build_winpe.ps1.txt  # Build runner documentation
├── verify_build_syntax.ps1  # Syntax validation script
├── CustomWinPE.iso     # Output from build_winpe.ps1
├── WinPE_Global_Config_Template.ini     # WinPE config template
├── WinPE_AppCatalog_Template.xml        # App catalog template
├── WinPE_Autorun_Template.inf           # Auto-run template
├── MRI_Like_Layout.md   # Reference architecture documentation
├── WinPE_FolderLayout_Checklist.md      # Structure checklist
└── Customizations/     # WinPE customization layer (empty)
```

**Purpose:** Build and customize Windows 10 WinPE environment with CDE tools
**Status:** Scripts and templates present; to be updated in Phase 5 for new structure

---

### 14. `/HALP/` - Help and Resources
**Purpose:** Documentation, help resources, and utilities

```
HALP/
├── CDE_User_Guide.pdf           # Operator manual (generated from Docs/UserGuide at publish)
├── oscdimg.exe         # Windows OEM CD/DVD imaging tool
├── How To Create Stand-Alone Media.url  # Documentation link
├── How To Create Bootable Media.md      # Bootable USB/ISO guide (TBD)
├── MRI BDE Online Help.url              # Reference documentation link
├── Geek Squad Forums.url                # Help forum link
└── ImgBurn.url                          # Alternative ISO burning tool link
```

**Purpose:** Help documentation and ISO creation utilities
**Status:** `CDE_User_Guide.pdf` generated on canonical publish; oscdimg.exe and legacy `.url` links retained

---

### 14b. `/Docs/UserGuide/` - User Guide Source
**Purpose:** Markdown chapters and `manifest.json` for the operator PDF

```
Docs/UserGuide/
├── manifest.json              # Title, subtitle, chapter order
├── 00_Cover.md
├── 01_Introduction.md … 10_Reference.md
```

**Build:** `App/UserGuideGenerator` (Markdig + QuestPDF) → `HALP/CDE_User_Guide.pdf`  
**GUI:** **Settings → Open User Guide** opens the PDF from toolkit media

---

### 15. `/Logs/` - Operator PDF Deliverables
**Purpose:** Printable PDF reports for operators and customers (internal JSON lives under `CDE/Runtime/Data/`)

```
Logs/
└── [Workflow|Scan]_[TIMESTAMP].pdf    # QuestPDF operator deliverable (GUI Open Report)
```

**Internal data (not in Logs):**
```
CDE/Runtime/Data/
├── workflows/     # Workflow JSON (step details, health summaries)
├── scans/         # Hijack & Scam Repair / Process Analyzer JSON
├── cst/           # Process Analyzer CST single-file scan JSON
└── sessions/      # PowerShell session .log files
```

**Purpose:** Operator-facing PDFs only; structured data for app plumbing stays under `CDE/Runtime/Data/`  
**Clear from GUI:** **Settings → Clear Test & Scan Logs** (CHU `EFI/CoreDiag/Logs` and `Results`, operator PDFs in `Logs/`, and `CDE/Runtime/Data/` on toolkit media). Work order case JSON: **Dashboard → Recent work orders → Clear Recent** (`CDE/Runtime/WorkOrders/` only; closed-case PDFs in `WorkOrders/` kept).  
**Status:** Existing logs preserved, new logs created at runtime

---

### 15b. `/CDE/Runtime/WorkOrders/` and `/WorkOrders/` — Case records
**Purpose:** Internal work order JSON (open and closed) vs operator deliverable PDF on close

```
CDE/Runtime/
├── WorkOrders/              # {CaseId}.json — case timeline, runs, guidance (GUI + PS)
└── active_work_order.json   # Pointer to the open case

WorkOrders/                  # Toolkit root (operator-facing)
└── {CaseId}.pdf             # Generated on Close Work Order only
```

**Clear from GUI:** **Dashboard → Clear Recent** removes JSON under `CDE/Runtime/WorkOrders/`; does not delete `WorkOrders/*.pdf`

---

### 16. `/App/` - Canonical Source and Build Scripts
**Purpose:** Authoritative ToolkitGUI source tree and publish pipeline scripts

```
App/
├── ToolkitGUI/         # Source project edited for all GUI changes
│   ├── Services/       # PDF export, TabularScanReportService, result formatting, ProcessWmiEnricher, ProcessAnalyzerCstResultService, ResultLogCleanupService, WorkOrderService (ClearRecentInternalWorkOrderRecords), …
│   └── Views/          # HijackRepairView, ProcessAnalyzerView, ProcessAnalyzerCstResultDialog, SettingsView, DashboardView (Clear Recent), CoreSecurityToolConfigDialog, …
├── CdeGpuDiagCli/      # Self-contained GPU probe/functional-test helper (probe, test-all)
├── UserGuideGenerator/ # Console: Docs/UserGuide → HALP/CDE_User_Guide.pdf (not linked into ToolkitGUI — Markdig conflict)
├── ToolkitGUI.sln      # Source solution
└── Publish-ToolkitGUI.ps1  # Canonical publish: GUI + CST sync + user guide PDF
```

**Status:** Active/canonical in current implementation; publish mirrors GUI output into `/CDE/`, CST into `/Security/CST/`, and regenerates `/HALP/CDE_User_Guide.pdf`

---

### 16b. `/Security/CST/` - Core Security Tool Runtime Mirror
**Purpose:** Deployed CST PowerShell engine consumed by Malware Cleanup / `MalwareSweep.ps1` (source of truth: `Core Security Tool\CST\`)

```
Security/CST/
├── CoreSecurityTool.ps1
├── CoreSecurityTool.psm1
├── Cst.KnownGood.ps1          # Known-good store + content-scan skip helpers
├── rules/
│   ├── rules.json             # Includes knownGoodPolicy, onlineReputation caps
│   ├── baselines/             # SHA-256 sidecars (profile-matched at scan time)
│   │   └── win11_23h2_amd64.json
│   └── goodware.db            # Optional SQLite NSRL-scale store (when published)
└── updates/                   # e.g. Update-CstRulesFromGitHub.ps1
```

**Sync:** `App/Publish-ToolkitGUI.ps1` copies from sibling `Core Security Tool\CST\` after GUI publish.

---

### 17. `/Tools/` - Legacy Reference (Deprecated)
**Purpose:** Kept for backwards compatibility; tools reorganized to specific categories

```
Tools/
├── Boot/               # (Content moved to /Diagnostics/Memory/ and /boot/)
├── Hardware/           # (Empty; content would go to /Diagnostics/Hardware/)
├── Utils/              # (Content moved to /Windows Tools/Utilities/)
├── Malware/            # (Empty; tools would go to /Diagnostics/Malware/)
├── Network/            # (Empty placeholder)
├── Imaging/            # (Empty placeholder)
├── OS/                 # (Empty placeholder)
├── .staging/           # (Temporary staging area)
├── ToolCatalog.xml     # (Moved to /CDE/Tools_Management/)
├── tools_manifest.json # (Moved to /CDE/Tools_Management/)
└── update_tools_manifest.ps1  # (Moved to /CDE/Tools_Management/)
```

**Status:** Deprecated; all functional tools reorganized; structure retained for reference

---

## Configuration Path Resolution

### Environment Variables
- `$env:TOOLKIT_ROOT` - Set by WinPE startup; defaults to script parent directory
- Used by PowerShell modules to resolve paths dynamically

### Path Resolution (Toolkit.Core.psm1)
- **ToolkitRoot:** Derived from `$PSScriptRoot` or `$env:TOOLKIT_ROOT`
- **LogsRoot:** `$ToolkitRoot\Logs`
- **ConfigPath:** `$ToolkitRoot\Config\settings.json`
- **DiagnosticsRoot:** `$ToolkitRoot\Diagnostics`
- **WindowsToolsRoot:** `$ToolkitRoot\Windows Tools`
- **BootFilesRoot:** `$ToolkitRoot\boot`
- **WinPERoot:** `$ToolkitRoot\WinPE`
- **DeployRoot:** `$ToolkitRoot\Deploy`

### Tool Path Resolution
- New function: `Resolve-ToolPath -ToolName [name] -Category [category]`
- Searches: Diagnostics/[Category], Diagnostics, Windows Tools, boot, sources/x64
- Returns full path or `$null` if not found
- Used by workflows to dynamically locate tools

---

## Comparison: Old vs New Structure

| Old Path | New Path | Purpose |
|----------|----------|---------|
| /Tools/Boot/CoreHardwareUtility | /Diagnostics/Memory/CoreHardwareUtility | Hardware diagnostics (UEFI) |
| /Tools/Boot/WinMemoryDiag | /Diagnostics/Memory/WinMemoryDiag | Memory testing |
| /Tools/Boot/MemTest86 | /Diagnostics/Memory/MemTest86 | Memory diagnostic images |
| /Tools/Utils/7Zip | /Windows Tools/Utilities/7Zip | Compression utility |
| /Tools/ToolCatalog.xml | /CDE/Tools_Management/ToolCatalog.xml | Tool registry |
| /Tools/tools_manifest.json | /CDE/Tools_Management/tools_manifest.json | Tool metadata |
| /App/ToolkitGUI | /CDE/ToolkitGUI/bin/Release/net8.0-windows | Published GUI payload (source edits in App/ only) |
| (none) | /boot, /EFI, /EZBOOT | Boot infrastructure (MRI pattern) |

---

## Phase Implementation Timeline

| Phase | Task | Folder Impact | Status |
|-------|------|----------------|--------|
| **1** | Create MRI-like structure | All folders created | ✅ COMPLETE |
| **1** | Relocate tools | /Diagnostics, /Windows Tools | ✅ COMPLETE |
| **1** | Update configurations | /Config | ✅ COMPLETE |
| **2** | Design boot architecture | /boot, /EFI, /EZBOOT, /isolinux | 🟡 IN PROGRESS |
| **3** | Acquire boot files | /boot, /EFI, /sources/x64 | ⏳ PENDING |
| **4** | Boot menu configuration | /boot/BCD, /EFI/.../BCD | ⏳ PENDING |
| **5** | WinPE integration | /sources/x64/boot.wim, /WinPE | ⏳ PENDING |
| **6** | ISO creation script | /Deploy/CDE-Final.iso | ⏳ PENDING |
| **7** | Tool manifest update | /CDE/Tools_Management | ⏳ PENDING |
| **8** | Portable mode support | /CDE/*.ps1, /CDE/*.bat | ⏳ PENDING |
| **9** | Cross-validation | All | ⏳ PENDING |
| **10** | ISO build & USB test | /Deploy | ⏳ PENDING |

---

## Next Steps

1. **Phase 2:** Design complete boot architecture (boot chains, menu options)
2. **Phase 3:** Acquire Windows 10 ADK and extract boot files
3. **Phase 4:** Configure BCD for multi-boot scenarios
4. **Phase 5:** Customize Windows 10 WinPE with CDE tools
5. **Phase 6:** Build ISO creation PowerShell script
6. **Phase 7-10:** Continue implementation phases

---

## Key Differences from MRI

While CDE now mirrors MRI's folder organization:
- **CDE keeps its own tools** - Not copying MRI's PC-Doctor, Prime95, Acronis, etc.
- **CDE keeps PowerShell workflows** - More modern than MRI's batch scripts
- **CDE keeps ToolkitGUI** - MRI.exe equivalent, but CDE's native .NET application
- **CDE targets Windows 10 WinPE** - MRI uses older WinPE 5.1 (Server 2012 R2)
- **CDE keeps dual-mode capability** - Both bootable (WinPE) and portable (Windows native)

This provides the proven architecture of MRI with the modern tooling and flexibility of CDE.

