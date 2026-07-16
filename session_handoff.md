# Session handoff — Core Diagnostic Engine

**Last updated:** 2026-07-16  
**Context:** Boot validation uses the CDE USB toolkit workflow (rEFInd pre-boot menu, WinPE, CHU, memtest) on real hardware.

## 2026-07-16 update — Startup services, Post-Op hosts, health checks, lab

- **Startup Manager Services** — Added service-specific risk/suspicion analysis and **RISK** display; **Suspicious only** now filters Services. Eligible suspicious or unprotected third-party services support confirmed **Delete** (`sc.exe delete` after stop); protected Windows hosts/services, drivers, Windows-folder services, and offline sessions remain blocked. Registry metadata fallback works without `CimCmdlets`; blank WPF add-row removed. Tests: `Test-StartupManagerCoverage.ps1` (**64/64**).
- **Post-Op Restore Hosts File** — Live `%SystemRoot%` targeting, read-only clearing, direct write, elevation environment propagation, and useful failed-step output. Tests: `Test-PostOpCleanup.ps1` (**15/15**).
- **C06 lab verification** — All injected infection artifacts were removed on `w11-infect-lab`; only inert BenchLab state metadata (`state\complex\C06.json`) remained. Latest service/grid build was canonically published and pushed (`HV_CDE_PUSH_OK`).

- **System Health Check** — Findings list sorts by catalog `findingsDisplayOrder` (Activation → Remote Access). Removed duplicate `audit_system_info` check (use Quick Vitals `system_info`). Startup Entry Audit review panel deduped (Needs review cards + compact Verified list; no triple-stacked entries).
- **Scheduled Tasks Audit** — Replaced blunt AppData/ProgramData regex with path/signing heuristics; COM actions resolve CLSID → server path (SoftLanding-style handlers no longer “unknown action”). **Review Reason** column in output. Tests: `Test-ScheduledTasksAuditSuspicion.ps1`.
- **Windows Update stack** — `wuauserv` **Manual** is **Pass** on Win10/11 (on-demand default); **Warn** only when `UsoSvc` is not Automatic or `wuauserv` has an unexpected start type. **Fail** when any service is **Disabled**. Tests: `Test-WindowsUpdateStackStatus.ps1`.
- **Startup Manager** — Drivers tab normalizes `\??\` and relative `system32\...` ImagePath values before signature lookup (same class of fix as User logon).
- **Uninstall Manager** — Quiet/MSI uninstall preference, post-uninstall leftover detection, optional install-folder cleanup on Force Remove. User guide `07_Maintenance_Utilities.md`.
- **Hyper-V infect lab** — Canonical toolkit push: `D:\Hyper-V\w11-infect-lab\Push-CDE-Toolkit.ps1` → guest `C:\CDE` (+ Desktop `CDE.lnk`). BenchLab C06 safe inject: `Inject-C06.ps1`. Cursor rule: `.cursor\rules\push-cde-w11-infect-lab.mdc`.
- **Full notes** — `Toolkit\session_handoff.md`; lab `D:\Hyper-V\w11-infect-lab\README.md`.

## 2026-07-15 update — Code review Pass 1–2 shipped; Pass 3 deferred

- **Pass 1 & 2** — Toolkit-wide review fixes shipped (Startup Manager, CST/Malware glue, workflows/elevation, Hijack repair, OS Repair, File Manager, Diag & Repair/hardware, work orders). CST Scan Results dialog layout refined (Findings/Suppressed focal grids; footer coverage text removed from UI).
- **Pass 3** — Publish / launcher / packaging reviewed (14 findings); **no code changes** — operator keeping current canonical publish workflow (`Toolkit\App\Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`).
- **BenchLab** — Section 10 of the review plan skipped.
- **Publish** — Canonical publish after Pass 2 ~**2:38 PM** GUI payload; launch `Toolkit\CDE.exe`. Full notes — `Toolkit\session_handoff.md` (top section).

## 2026-07-14 update — Infect lab: Azure off → local Hyper-V

- **Azure** — `rg-w11-infect-lab` deleted (stop lab compute/disk/snapshot/storage charges).
- **Local** — Hyper-V Gen2 lab under `D:\Hyper-V\w11-infect-lab\` (vTPM + Autounattend); install-to-desktop still in progress as of doc update.
- **Also this day** — Startup Manager “delete linked target file” + C03 Azure cleanup verified before tear-down; toolkit publish/push preceded Azure delete.
- **Full notes** — `Toolkit\session_handoff.md`.

## 2026-07-13 update — CST Public roots + remediation UX + complex BenchLab

- **CST scan roots** — Threat/Full/drive Custom now include **Users\Public** (+ Desktop/Documents/Local Startup; Full/Custom also Local\Programs + SysWOW64). Sync from Core Security Tool via publish.
- **CST UI** — Findings horizontal scrollbar restored (DataGrid-native); Quarantine/Remove show **per-item remediation progress**.
- **BenchLab** — Complex pack C01–C08 (`Invoke-CdeBenchComplexPack.ps1` / `CDE_Complex_MultiInfection_Pack.md`).
- **Lab VM** — Full runtime pushed to Azure lab `C:\CDE` (Azure lab later removed 2026-07-14).
- **Full notes** — `Toolkit\session_handoff.md`; CST `CST\session_handoff.md`; user guide `05_Security.md`.

## 2026-07-13 update — SMART / CST reports + pre-scan progress + Hijack layout

- **S.M.A.R.T. Analyzer** — After Scan, PDF is built from the on-screen drive grid (no stuck “Saving…” / greyed **Open Report** from a second Report-mode PS hang).
- **CST Scan Results** — Live results dialog again generates `Logs\CST_Scan_*.pdf` and enables **Open Report** (Malware Cleanup / File Manager / Startup Manager / Process Analyzer / Core Security Tool paths).
- **CST pre-scan UX** — TargetPrep / known-good / path discovery stream progress; GUI heartbeat when updates pause. Engine sync from Core Security Tool.
- **Hijack & Scam Repair** — Findings + **Finding Details** + **Quick Repairs** stacked with splitter (AvalonDock bottom pane no longer covered by Quick Repairs).
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe` (GUI ~9:02 AM; CST runtime synced).
- **Full notes** — `Toolkit\session_handoff.md`; CST `CST\session_handoff.md`; user guide `04_Diagnostics.md`, `05_Security.md`, `09_Understanding_Reports.md`.

## 2026-07-11 update — EFI hash baseline gaps as coverage

- **CST** — Empty EFI hash allowlist no longer creates a Suspicious finding/warning; message is in Coverage. See `Toolkit\session_handoff.md` and CST `CST\session_handoff.md`.
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe` (**7/11/2026 ~4:11 PM**).

## 2026-07-10 update — CST Scan Results + detection/archive remediation

- **UI** — Unified **CST Scan Results** (live progress + findings + Quarantine/Remove/Restore); horizontal scroll fixed; mode/coverage labels; archive parent-file remediation path.
- **CST sync** — ThreatScan DLL/light-archive peek, timeout-as-unknown, narrowed trusted-signer early exit + cheap spot-check, correlation/boot baseline tweaks (source: Core Security Tool).
- **Full notes** — `Toolkit\session_handoff.md`; CST `CST\session_handoff.md`; user guide `Toolkit\Docs\UserGuide\05_Security.md`.
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`.

## 2026-07-10 update — Diag & Repair / CST live-Windows polish

- **CIRCL** — Live-Windows CST ThreatScan/FullScan/CustomScan use CIRCL Hashlookup when not WinPE/`OfflineOnly` (synced from Core Security Tool).
- **Catalog** — `mem_coverage` removed from Diag & Repair tree; Memory stays 10 pattern tests; low coverage still drives `[HW:GUIDANCE]` / CHU banner. Totals: CPU 13 / Memory 10 / Drive 6 (29).
- **Stuck Running** — ASCII-sanitize `[HW:TEST]` details + `FinalizeStuckHardwareTests` so Warn rows (e.g. memory coverage) do not leave the tree on Running.
- **CST PDF** — Expander **Open full CST report (PDF)** opens the workflow PDF, not JSON.
- **Full notes** — `Toolkit\session_handoff.md` (2026-07-10 sections); CST `CST\session_handoff.md`; CHU `session_handoff.md` catalog note.

## 2026-07-09 update — Temp File Cleaner skip locked/unavailable files

- **Temp File Cleaner** — Locked, in-use, and access-denied temp files (e.g. `VBCSCompiler` analyzer DLLs during active builds) are **skipped** instead of reported as workflow warnings. Overall cleanup status is **Pass** when only these expected skips occur; summary still shows `In-use: N`.
- **Script** — `Toolkit\Scripts\Workflows\TempFileCleaner.ps1` (`Test-IsUnavailableForDeletionException`, `Register-RemovalFailure`).
- **Docs** — `Toolkit\session_handoff.md` (2026-07-09 section); `Toolkit\Docs\UserGuide\07_Maintenance_Utilities.md`.

## 2026-07-06 update — canonical publish run + verification pass

- Executed canonical publish script: `Toolkit\App\Publish-ToolkitGUI.ps1` after session changes affecting CST/CDE integration.
- Publish verification completed with overall pass; report written to `Toolkit\CDE\Runtime\Data\publish_verify_20260706_192515.json`.
- Verification included:
  - CST release gates pass (PolicyContract, RuleQuality, BootFixture, PathExclusionPolicy, DependencyTrust, IsolatedScanStability),
  - CHU EFI manifest hash pass,
  - CdeCpuSimdCli payload pass,
  - ToolkitGUI unit tests pass.
- Persistent workflow rule (operator requirement): after relevant CDE/CST/CHU source changes, run a fresh `Publish-ToolkitGUI.ps1` before USB deployment (`SyncUSB.bat`) so runtime payloads include latest changes.

## 2026-07-06 update — CHU display backends, CHUPrep boot chain, scroll fix (field-verified)

- **CHU boot path** — rEFInd menu entry loads **`EFI\CDE\CHUPrep.efi`** (console prep), which chainloads **`EFI\CDE\CoreDiag.efi`**. `refind.conf` updated; `CHUPrep.efi` built and staged by `BUILD_CHU_UEFI.ps1`.
- **Display policy** — Default **PC-Check text UI** on firmware where ConOut composites correctly (HP desktop verified). **GOP framebuffer UI** when Console Control is stuck in graphics, or on **portable chassis** (SMBIOS Type 3) when GOP is available and the glyph probe says text is not visible (Samsung laptop verified). Forcing GOP everywhere regressed HP flicker stability.
- **Early logging** — `LogOpen` + `[BOOT] CoreDiag starting` before `UiInitializeDisplay()`; per-line `LogFlush()` so hard resets do not leave empty log files.
- **Results review scroll** — `UiTestTree.c` scroll bounds now use `ViewportRowCount()` (actual text/GOP viewport) instead of fixed `TREE_VIEW_LINES` (22). **Field-verified on HP** after Run All with multiple drives.
- **Publish / stage** — CHU only: `Core Hardware Utility\UEFI\BUILD_CHU_UEFI.ps1` → `Toolkit\EFI\CDE\`. Then **`SyncUSB.bat`**.
- **CoreDiag.efi** — SHA256 `EBC5D75F8687C3A1F9822B02B7B3877A992054DE5F6DD21250A70E32D732E35A`, 281 600 bytes.
- Full notes: `Toolkit\session_handoff.md` (2026-07-06 CHU section); `Core Hardware Utility\session_handoff.md`.

## 2026-07-03 update — WinPE shell handoff + maximize (field-verified)

- **Boot menu → main GUI** — Options **1** / **2** no longer drop to `startnet.cmd` recovery menu. WinPE uses opaque `MainWindow` chrome (no `AllowsTransparency`), software rendering, deferred dashboard init, and `OnExplicitShutdown` for the full WinPE session.
- **Maximize / restore** — Fixed 0×0 restore bounds that crashed the shell when toggling window size in WinPE.
- **Diagnostics** — `CDE\Runtime\winpe_startup.log` (and `X:\winpe_startup.log`) traces boot-menu → main-window handoff; `toolkit_crash.log` for unhandled errors.
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` → sync `CDE\ToolkitGUI\bin\Release\net8.0-windows\` via **`SyncUSB.bat`** (no `boot.wim` rebuild for GUI-only changes).
- Full notes: `Toolkit\session_handoff.md` (2026-07-03 WinPE shell section).

## 2026-07-03 update — SIMD CLI, CST fixes, GitHub source publish

- **CPU SIMD on PowerShell 5.1** — New `Toolkit\App\CdeCpuSimdCli\` console (full `CpuSimdEngine.cs` intrinsics). `HardwareTestEngine.ps1` prefers `CdeCpuSimdCli.exe` from the published GUI folder on PS 5.1; falls back to Add-Type compat/stub. Canonical publish builds CdeCpuSimdCli **self-contained** into the GUI payload. Test: `Scripts\Tests\Test-CpuSimdEnginePs5.ps1`.
- **CST remediation (USB drive root)** — `CstRemediationService.cs` no longer calls `Directory.GetParent("")` when `TOOLKIT_ROOT` is a drive root (`G:\`); uses `ToolkitPaths.GetToolkitRoot()`.
- **Diag & Repair CST row N/A** — `WorkflowViewModels.cs`: `LooksLikeCstNoTargetResult()` matches `No Eligible Targets: True` only; CST **Warn** maps to **Warn** (not Skipped/N/A).
- **GitHub** — Slim single-repo history for `https://github.com/GenNowGamer/Core-Diagnostic-Engine` (~50 MB source). Large artifacts excluded via root `.gitignore` (`boot.wim`, deploy ISOs, `memtest86-usb.img`, `CDE.exe`, publish staging). After clone: run `Publish-ToolkitGUI.ps1` and acquire binaries per `Toolkit\Tools\PLACEHOLDER_ACQUISITION.md`.
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe` (2026-07-03). Run `SyncUSB.bat` before USB field tests.
- Full notes: `Toolkit\session_handoff.md` (2026-07-03 sections).

## 2026-07-01 update — Removable media excluded from hardware testing

- **Policy** — Diag & Repair storage, S.M.A.R.T. Analyzer, and CHU storage tests exclude removable media (USB flash, memory cards, CDE boot USB). Fixed USB external HDDs may remain testable when Windows reports fixed media.
- **CDE** — `PhysicalDiskCatalog.psm1` (`Get-CdeTestablePhysicalDisks`); `HardwareCommon.ps1`, `HardwareSmartEngine.ps1`, `PhysicalDiskCatalogHelper.cs` (Diag & Repair UI tree). Unit test `Test-PhysicalDiskCatalog.ps1`.
- **CHU** — `StorageDrive.c` filters `RemovableMedia` at enumeration; zero fixed drives → storage discovery **Fail** (`UiTestTree.c`, `HwTestRunner.c`).
- **User guide** — `Toolkit\Docs\UserGuide\04_Diagnostics.md`, `10_Reference.md`.
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe` (2026-07-01 1:26 PM). CHU `CoreDiag.efi` staged: SHA256 `54288CCBCCA263A4A7C08648D0FB296A83B1E38D97A1885C35CF01009E8868A5`, 275 968 bytes.
- Full notes: `Toolkit\session_handoff.md` (2026-07-01 removable media section); `Core Hardware Utility\session_handoff.md`.

## 2026-07-01 update — Report policy + Dashboard suggested path

- **Report policy** — PDF-only operator deliverables in `Logs\`; internal JSON and session logs under `CDE\Runtime\Data\`. GUI **Open Report** only (no Save report / Open HTML).
- **Dashboard** — **Verify case** removed; keyword-based **suggested path** highlight on work order generate from `SymptomFlows.json` `keywords`.
- **Case timeline** — Light-theme cards for readability.
- **User guide** — `Toolkit\Docs\UserGuide\` chapters 02–05, 07–10 updated.
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`.
- Full notes: `Toolkit\session_handoff.md` (2026-07-01 section).

## 2026-06-30 update — Hijack & Scam Repair UI + HTML/PDF reports

- **Hijack & Scam Repair** — Full-width findings grid + bottom detail panel; **Select repairable**; Quick Repairs bottom drawer; scan results persist when navigating away; **Re-Scan** label; Startup Manager-style loading overlay during scans; **Open Report** (PDF) via `TabularScanReportService`.
- **Reports** — System Health, Process Analyzer, Hijack, and workflow windows use **Open Report** for operator PDFs.
- **User guide** — `Toolkit\Docs\UserGuide\` chapters 03, 05, 07, 09, 10 updated.
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`.
- Full notes: `Toolkit\session_handoff.md` (2026-06-30 Hijack section).

## 2026-06-30 update — MSIX startup signing + Process Analyzer Investigation UI

- **Startup Manager — MSIX path resolver** — `MsixStartup.ps1` resolves Store/UWP startup-task executables via `Get-AppxPackageManifest` (`windows.startupTask` `TaskId` → extension or application `Executable` under `InstallLocation`). Replaces install-folder paths that previously showed **Not found** / red analysis warnings for Teams, Copilot, etc.
- **Startup Manager — MSIX package signature display** — When the manifest path is not directly readable (WindowsApps ACL), **Signed** shows `Package (Publisher)` with `SignatureStatus=PackagePublisher` (blue) instead of a false **Not found** warning. Accessible binaries still use normal Authenticode via `Get-FileSignatureInfo`.
- **Process Analyzer** — Investigation mode no longer shows the blue toolbar status line (`Investigation active (3s refresh) | …`); the **Investigation ON** button indicates state so Tree view and Deep scan stay accessible.
- **Tests** — `Test-MsixStartupTasks.ps1` expanded (manifest resolution, package publisher fallback, Teams/Copilot when installed).
- **User guide** — `Toolkit\Docs\UserGuide\07_Maintenance_Utilities.md` (MSIX signing, Process Analyzer Investigation UI).
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`.
- Full notes: `Toolkit\session_handoff.md` (2026-06-30 section).

## 2026-06-26 update — Startup Manager depth + Post-Op expansion

- **Startup Manager** — Scheduled logon/boot tasks (`StartupScheduledTask.ps1`), Task Manager `StartupApproved` parity (`StartupApproved.ps1`), GPO Run keys, MSIX startup tasks, cross-mechanism correlation (`StartupCorrelation.ps1`); `\Microsoft\*` scheduled tasks hidden by default (optional read-only view). GUI: SOURCE/RELATED columns, scheduled-task filter checkbox.
- **Post-Op Cleanup** — Eight tools via `PostOpCleanup.ps1` (icon/thumb cache, DNS flush, proxy reset, hosts restore with confirmation, restart Explorer). Duplicates removed from Fast Fixes and OS Repair network reset. Hosts **audit** remains in System Health Check only.
- **Fast Fixes** — Trimmed to 14 verified fixes (DNS/icon/thumb cache in Post-Op only).
- **Tests** — `Test-StartupManagerCoverage.ps1`, `Test-MsixStartupTasks.ps1`, `Test-PostOpCleanup.ps1` in `Invoke-CdeRegressionSuite.ps1`.
- **User guide** — `Toolkit\Docs\UserGuide\` chapters 05, 06, 07, 10 updated.
- Full notes: `Toolkit\session_handoff.md` (2026-06-26 Startup Manager + Post-Op section).

## 2026-06-26 update — Phase 3 diagnostic depth + work-order recording fix

- **Phase 3** — CHU catalog parity tests + CHU Results rollup/Diag & Repair links; tiered CST findings expander (workflow window); Dashboard **suggested path** + **Case timeline**; broad work-order events (`ChuPreBoot`, `CstScan`, workflows with PDF reports). See `Toolkit\session_handoff.md` (2026-06-26 Phase 3 section).
- **Regression** — `Test-HardwareTestCatalogSync.ps1`, `Test-WorkOrderCaseEvents.ps1`, `Test-CstStructuredResults.ps1` added to `Invoke-CdeRegressionSuite.ps1`.
- **Bugfix** — `Add-WorkOrderRun` in `WorkOrder.ps1`: PowerShell operator-precedence bug caused **ReportJson property not found** when recording workflow runs (e.g. Temp File Cleaner completed clean but exited code 1). Fixed dedupe logic; test extended.
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`; user guide chapters updated under `Toolkit\Docs\UserGuide\`.
- Full notes: `Toolkit\session_handoff.md` (2026-06-26 sections).

## 2026-06-25 update — Process Analyzer overhaul

- **Process Analyzer** — Live process triage: CPU/RAM, risk flags, filters, tree view, investigation mode (3s refresh + NEW highlighting), detail pane (command line, session, parent chain, modules, SHA256), export, CST single-file scan with structured results dialog. Cross-links to Startup Manager and Malware Cleanup; System Health Check can open with high CPU/RAM presets.
- **WMI enrichment** — `ProcessWmiEnricher.cs` supplies command line / session / parent PID in C# (`Win32_Process`); detail pane clones `ProcessDetail` on each update for reliable WPF refresh.
- **Publish trim fix** — `PublishTrimmed=false` on ToolkitGUI Release publish; partial trim was stripping JSON model properties in the deployed GUI.
- **CST** — Single-file path enumeration fix in `CoreSecurityTool.psm1` (Process Analyzer CST scan).
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`; fully exit CDE before retesting.
- Full notes: `Toolkit\session_handoff.md` (2026-06-25 section).

## 2026-06-22 update — WinPE boot menu trim, CHU test UI, diagnostic log cleanup, user guide

- **WinPE boot menu** — Removed options **8** (CST Malware Scan Offline - Auto) and **9** (CST Malware Scan Offline - Manual) from `WinPEBootMenuWindow`. Menu is now **1–7** only. CST still runs from **Diag & Repair** and **Malware Cleanup** after CDE launch.
- **CHU test UI** (Core Hardware Utility) — Graphics test tree when GOP+HII available; per-row progress and Detail column; `UiTestTreeWaitForDismiss()` holds results on screen until ENTER after Run Category / Run All. Text ConOut fallback retained. Staged `CoreDiag.efi`: SHA256 `95BECCF4ED33452B1508B9120A6FBA134AEC44161E1A6100399FAC8771ED43C1`, 275 968 bytes.
- **Settings — Clear Test & Scan Logs** — Clears `EFI\CoreDiag\Logs`, `EFI\CoreDiag\Results` (all ready drives), `{TOOLKIT_ROOT}\Logs` (PDFs), and `CDE\Runtime\Data\`. Work order case JSON: **Dashboard → Clear Recent**. See `ResultLogCleanupService.cs`, `WorkOrderService.ClearRecentInternalWorkOrderRecords()`.
- **PDF User Guide** — `Docs\UserGuide\` Markdown → `HALP\CDE_User_Guide.pdf` at publish (`App\UserGuideGenerator`); **Settings → Open User Guide**. Table renderer fix in `UserGuidePdfService` (QuestPDF header/body cells + inline text).
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`. CHU: `BUILD_CHU_UEFI.ps1` → `Toolkit\EFI\CDE\CoreDiag.efi`; sync USB as needed.
- Full notes: `Toolkit\session_handoff.md` (2026-06-22); `Core Hardware Utility\session_handoff.md` (2026-06-22).

## 2026-06-19 update — System Health Check grouped output, deduplicated Maintenance

- **Grouped review output** — All System Health Check catalog steps render grouped property cards in GUI/PDF. Fixed Skip regression (`Format-GroupedBlockHeader` length compare; `Format-CriticalEventsDetail` export; scheduled-task `Actions` array handling).
- **System Audit sidebar removed** — Deleted `SystemAudit.ps1` and Maintenance **System Audit** UI. Audit checks (`audit_*`) run only from **System Health Check** via `SystemAuditChecks.ps1`.
- **Malware Cleanup trimmed** — Removed Autoruns, Hosts File Check, Browser Extensions, and Scheduled Tasks from Malware Cleanup. `MalwareSweep.ps1` = Defender + CST + Update Hash IOCs only. Security audits (`sec_*`) run only from **System Health Check** via `SecurityAuditChecks.ps1`.
- **Regression / publish** — `Test-SkippedHealthChecks.ps1`; `ValidateTools.ps1` uses `SystemHealthCheck.ps1` for audit/security validation. Publish: `Toolkit\App\Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`.
- Full notes: `Toolkit\session_handoff.md` (2026-06-19 section).

## 2026-06-18 update — System Health Check trim, CST UX, scan artifacts

- **System Health Check** — Removed from catalog: Disk SMART (WMI), CPU Temperature, Memory Diagnostic History, S.M.A.R.T. Attribute Analysis, Diag & Repair hardware tests (CPU/Memory/Storage), Windows Defender Scan, Core Security Tool (scan only). Recommended preset → CPU Load, RAM, Disk Free Space, Startup Entry Audit. HW profile toolbar removed from System Health picker. Full Windows: use **Diag & Repair** and **Malware Cleanup** for those capabilities.
- **Update Hash IOCs** — Moved from Malware Cleanup list into **Core Security Tool** config dialog (**Threat Signature Database**). Still `MalwareSweep.ps1 -ToolName UpdateHashIOCs`.
- **CST artifacts** — ~3 files per run (`.log`, `CST_Result_*.json`, `MalwareSweep_*.json`); no HTML; PDF on demand; unified session timestamp.
- **Structured Results** — Malware Cleanup CST rows from final `CST_Result_*.json` only (Malware/Virus/PUP/PUM).
- **Cursor sandbox FP** — Tier1 path exclusion + weak PathHeuristic suppressed-audit filter in CST rules.
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`.
- Full notes: `Toolkit\session_handoff.md` (2026-06-18 section).

## 2026-06-16 update — Diag & Repair (HW + CST) + Windows Update stack

- **Diag & Repair** — Renamed from Hardware Diagnostics. **Run All** = CPU + Memory + Storage + CST (`ScanOnly`; Quick = ThreatScan, Extended = FullScan). Nav `DiagAndRepair` (alias `HardwareDiagnostics`). Static **Security Scan** row; CST file path streams in one line via `[CST:PROGRESS]`. `CstRemediationService` shared with Malware Cleanup. Workflow script: `Toolkit\Scripts\Workflows\HardwareDiagnostics.ps1`.
- **Windows Update** — `windows_update_service` health check reports full update stack; Post-Op keeps `wuauserv` **Automatic**.
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` → canonical `Toolkit\CDE.exe`; relaunch after publish.
- Full notes: `Toolkit\session_handoff.md` (2026-06-16 sections).

## 2026-06-16 update — Windows Update stack diagnostics

> **Merged into section above** — retained for searchability.

- **Investigation** — `wuauserv` was not reverting to **Disabled** on reboot; **Stopped** + **Automatic** is expected idle behavior. Windows Update scans/downloads were succeeding in operational logs.
- **Health check** — `windows_update_service` now reports `wuauserv`, `UsoSvc`, `bits`, and `WaaSMedicSvc` with Status + Start Type; false Warn on idle **Stopped** removed.
- **Post-Op** — `RestoreDefaultServices` keeps `wuauserv` at **Automatic** (fixed from **Manual**).
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` → canonical `Toolkit\CDE.exe`; script changes effective after relaunch.
- Full notes: `Toolkit\session_handoff.md` (2026-06-16 section).

## 2026-06-15 update — PDF reports, readable results, health-check PDF labels

- **PDF deliverables** — QuestPDF-based workflow PDFs in `Logs\`; **Open PDF Report** in workflow execution and System Health results (replaces operator Open JSON/HTML). JSON/HTML still generated internally.
- **Open PDF fix** — `ShellFileOpenHelper` launches PDFs through `explorer.exe` so Acrobat/default viewer shows a window when CDE runs elevated.
- **Readable results** — `WorkflowResultFormatter` drives card-style structured results in the GUI and PDF (plain-English overviews, sections, location/path/notes; hides `[POSTOP:STARTUP]` JSON from display).
- **System Health Check PDF** — `WorkflowStepLabelHelper` maps each step’s `CheckId` to catalog labels (e.g. **Startup Entry Audit**); item cards repeat the test name on long multi-page steps.
- **Startup review UX** — `[REVIEW]` labeling, review panel fields, **DETAILED RESULTS** for passing checks in System Health review.
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` after GUI changes; relaunch `Toolkit\CDE.exe`.
- Full notes: `Toolkit\session_handoff.md` (2026-06-15 section).

## 2026-06-12 update — File Manager, System Audit, uptime, bootloader

- **File Manager** — Directories pane empty on open; Computer auto-expands; populate right pane from **drive** or **shadow copy** tree selection only (`FileManagerView.xaml.cs`).
- **Startup Entry Audit** — moved from Post-Op Cleanup to **System Audit** (`SystemAudit.ps1`, `WorkflowViewModels.cs`); `[POSTOP:STARTUP]` structured results unchanged; Post-Op is three tools.
- **SystemAudit fix** — `Invoke-StartupAudit` uses `$r.Steps.Add` (not `Add-ToolkitWorkflowStep`).
- **Shadow copy browse** — all snapshots per VSS set; newest-first sort (`ShadowCopyBrowse.ps1`).
- **Bootloader Repair** — EFI volumes, `bootsect /nt60` targeting, BCD backup pickers, scan without drive picker (`Bootloader.Common.ps1` + scripts).
- **Startup Manager Extensions** — CLSID→DLL; multi-browser Chromium/Firefox discovery (`ExtensionDiscovery.ps1`).
- **Banner uptime** — `Uptime: Xd Xh Xm` (`BootUptimeHelper.cs`); System Audit still uses `Get-CdeBootUptimeInfo` for detail.
- Full notes: `Toolkit\session_handoff.md` (2026-06-12 section).

## 2026-06-10 update — CHU diagnostics improvement (Weeks 1–3)

Cross-repo work in **Core Hardware Utility** (`CoreDiag.efi`). Plan: `Core Hardware Utility\UEFI\DIAGNOSTICS_IMPROVEMENT_PLAN.md`.

- **Memory** — 9 extended passes; `FirstFail` physical address in FAIL details; modulo-20 (MemTest86 stride 20).
- **Storage** — ATA SMART RETURN STATUS; NVMe MediaErrors; removable-media skip; extended linear + random LBA scan.
- **CPU** — Eratosthenes sieve (50 000 → 5133 primes); multi-core via MP Services; WARN if BSP-only.
- **Integration** — `ResultExportJson` after each CHU test and each Run All step (incremental JSON on `CDEDATA`).

**Build artifact:** SHA256 `3C9A0DD03691E59A67FC37292C79B937C7A8B520AF81ED8819FF5F8135B1788F`, 65 024 bytes, PE checksum `0x00019195`.

**CDE actions:** Rebuild/stage CHU → `Toolkit\Tools\Boot\CoreHardwareUtility\CoreDiag.efi` + `tools_manifest.json` → `SyncUSB.bat` → Week 4 hardware matrix.

**Note:** WinPE **Diag & Repair** (`HardwareDiagnostics.ps1`) is complementary to CHU, not a replacement. *(2026-06-16: includes CST security scan phase.)*

## 2026-06-10 update — Fast Fixes verification, uptime, Enable Offline Administrator

- **Fast Fixes** — `Toolkit\Scripts\Workflows\FastFixes.ps1` rewritten: `Write-FixLog` / `Invoke-FixCommand` / `New-FixResult`, post-action verification for all 17 fixes, workflow **Fail** when verification fails. **PS 5.1 fix:** `Invoke-FixCommand` uses `System.Diagnostics.ProcessStartInfo` (avoids `Start-Process -RedirectStandardOutput $true` coercing to path `"True"`). **RenewIp** reports primary adapter via default route (`Get-NetRoute 0.0.0.0/0`). **ClearEventLogs** uses quiet `wevtutil gli`; `Test-EventLogCleared` tolerates ≤10 residual records when count dropped (distinguishes access denied vs partial clear). User-verified Pass: Flush DNS, Renew IP, Clear Icon/Thumb Cache, Clear Event Logs.
- **Uptime** — Banner `Uptime: …` via `BootUptimeHelper.cs` (Event 12 / 6005 / WMI). System Audit `Get-CdeBootUptimeInfo` shows session + cold-boot + source. *(Banner was `Boot | Session` until 2026-06-12.)*
- **Account recovery (Tools Library)** — **ACCOUNT RECOVERY → Enable Offline Administrator**: `OfflineSamAccount.psm1`, `EnableOfflineAdministrator.ps1`, `executionMode="cde_workflow"` + `workflowScript` in `ToolCatalog.xml`, `OfflineAdministratorDialog`, SAM backup under `%ProgramData%\CDE\AccountRecovery\Backups\`. WinPE + `OFFLINE_REGISTRY_LOADED=1` only; enables `.\Administrator` on offline SAM — does **not** reset Microsoft account / PIN / Entra ID.
- **Publish / deploy** — `Toolkit\App\Publish-ToolkitGUI.ps1` run 2026-06-10 after GUI changes. **`SyncUSB.bat` not run** — sync before USB/WinPE field tests. **No `Customize-WinPE.ps1`** required (script + GUI only; `boot.wim` unchanged).
- Full notes: `Toolkit\session_handoff.md` (2026-06-10 section).

## 2026-06-09 update — Script encoding fix + startup audit hardening

- **Root cause (Malware Cleanup / Fast Fixes parse errors):** Several `Toolkit\Scripts\` files were saved as **UTF-16 LE**. `powershell.exe -File` misread them as ANSI/UTF-8, producing cascading bogus parse errors (missing `)`, `}`, illegal `&`).
- **Encoding normalization:** Converted to **UTF-8 with BOM** (PS 5.1-safe): `MalwareSweep.ps1`, `FastFixes.ps1`, `OSRepair.ps1`, `SmartAnalyzer.ps1`, `Toolkit.Core.psm1`, `Customize-WinPE.ps1`. All scripts under `Toolkit\Scripts\` are now UTF-8. **Convention:** save new/edited `.ps1`/`.psm1` as UTF-8 BOM — never UTF-16.
- **Startup audit (items 1–8):** Winlogon reset/undo verification expanded; User logon Delete routes through `*Entry` paths; `Get-PostOpStartupEntries` includes Winlogon + offline hives; `MalwareSweep` Autoruns Audit uses shared entries; offline Winlogon read from `Offline_SOFTWARE`; `FixBrowserAssoc` clears `.htm`/`.html`/`.url` UserChoice keys; driver re-enable restores `CDE_PriorStart`; CST run-key disable uses `AutorunsDisabled` with rollback restore.
- **Publish:** `Toolkit\App\Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe` (script-only changes do not require GUI rebuild; relaunch CDE to pick up scripts).
- Full notes: `Toolkit\session_handoff.md` (2026-06-09 section).

## 2026-06-05 update — Startup Manager Winlogon reset + CST hash/CIRCL fixes

- **Startup Manager** — User logon tab: Winlogon `Userinit` and `Shell` show deviation styling; **Reset** restores Windows defaults; **Undo** restores pre-reset backup from `%ProgramData%\CDE\WinlogonBackups\`. Enable/Disable/Delete hidden on those two rows. User-verified Userinit reset after `test.dll` append test.
- **CST** — Empty/unreadable SHA-256 paths no longer cause `PerFileAnalysis` errors; CIRCL bulk reputation body fixed (`{"hashes":[...]}` → was 404 on every batch). Synced to `Toolkit\Security\CST\`.
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` required after GUI changes; relaunch `Toolkit\CDE.exe` elevated.
- Full notes: `Toolkit\session_handoff.md` (2026-06-05 section), `Toolkit\README.md` (Startup Manager — Winlogon Reset / Undo).

## 2026-06-04 update — CST false-positive reduction (publish sync)

- **Source:** `Core Security Tool\CST\` — known-good skip engine (`Cst.KnownGood.ps1`), `knownGoodPolicy`, baseline JSON under `rules\baselines\`.
- **CDE runtime:** `Toolkit\App\Publish-ToolkitGUI.ps1` now syncs `CoreSecurityTool.ps1`, `CoreSecurityTool.psm1`, `Cst.KnownGood.ps1`, `rules\rules.json`, `rules\baselines\**`, and `rules\goodware.db` (when present) → `Toolkit\Security\CST\`.
- **Operators:** Build full baseline on a clean reference VM (`Build-CstBaselineHashes.ps1`); run publish before WinPE/USB CST tests. See `Core Security Tool\CST\session_handoff.md` and `perf_reports\false_positive_reduction_roadmap_20260604.md`.

## 2026-06-03 update — Structured Results, Event Logs, CST UI

- **Quick Health / Deep Diagnostics** — Structured Results at workflow end: **Warn/Fail only**, friendly labels (`WorkflowViewModelBase.PopulateDiagnosticStructuredResults`).
- **System Audit → Event Logs** — Unique **errors** (24h) in Structured Results via `[AUDIT:EVENT]` JSON (`SystemAudit.ps1` dedup + GUI parser).
- **CST config dialog** — Removed sidebar build notes / scan summary / scope preview panels (`CoreSecurityToolConfigDialog`).
- Full notes: `Toolkit\session_handoff.md` (2026-06-03 Structured Results section).

## 2026-06-03 update — Post-Op Cleanup

- **Post-Op Cleanup** tools remediated in `Toolkit\Scripts\Workflows\PostOp.ps1`: safe browser cache paths, elevated service restore, critical file-association repair (`assoc`/`ftype`), startup audit with suspicious flagging.
- **Startup Entry Audit** feeds **Structured Results** (`[POSTOP:STARTUP]` markers; UI-thread-safe). *(Relocated to System Audit 2026-06-12.)*
- Shared helpers: `Toolkit\Scripts\Core\Toolkit.Elevation.psm1`, `Toolkit\Scripts\Core\StartupRisk.ps1`.
- Full notes: `Toolkit\session_handoff.md` (2026-06-03 Post-Op section).

## 2026-06-02 update — Hardware Diagnostics

> **Superseded (2026-06-16):** Now **Diag & Repair** with CST. See 2026-06-16 update above.

- PC-Doctor-style **Hardware Diagnostics** in ToolkitGUI (WinPE + Windows): `Toolkit\Scripts\Workflows\HardwareDiagnostics.ps1`, sidebar nav (now **Diag & Repair**), Quick/Extended profiles, 28 HW line-item tests, live `[HW:TEST]` / `[HW:PROGRESS]`.
- UEFI **CHU** (`CoreDiag.efi`) — pre-boot only (see 2026-06-10 CHU diagnostics update for Weeks 1–3 improvements).
- Publish: `Toolkit\App\Publish-ToolkitGUI.ps1`; launch `Toolkit\CDE.exe`. Run elevated for physical disk read tests.
- Full notes: `Toolkit\session_handoff.md` (2026-06-02 Hardware Diagnostics section).

## 2026-06-11 update

- **WinPE session state** — `CDE\Runtime\offline_env.txt` / `offline_progress.log`; `OfflineRuntime.ps1` + `OfflineRuntimePaths.cs`; `SyncUSB.bat` clears runtime after sync. Fixes Startup Manager missing Userinit/Shell when stale root `offline_env.txt` set `OFFLINE_REGISTRY_LOADED` without loaded hives.
- **File Manager** — read-only Shadow Copies browse (`ShadowCopyBrowse.ps1`) on full Windows. *(2026-06-12: empty Directories on open; tree-driven drive/shadow browse.)*
- **Backup & Imaging** — VSS Shadow Copy tool removed; Robocopy path quoting fixed (`PowerShellArgumentHelper`, `Format-RobocopyPathArgument`). User-verified `E:\` → spaced destination folder.
- Details: `Toolkit\session_handoff.md` (2026-06-11 section).

## 2026-05-11 update

- Added dedicated workflow execution UX in ToolkitGUI:
  - new `WorkflowExecutionWindow` with live stream, progress, structured result cards, and **Open PDF Report** artifact action (2026-06-15; JSON/HTML internal only).
  - workflow view models now pass operation title/description for clearer execution context.
- Added Robocopy configuration dialog before execution (VSS dialog removed 2026-06-11).
- Removed low-value `DiskInventory` and `ImagingToolsCheck` from Backup & Imaging tool list.
- Fixed execution-window crash loop by binding result `Output` as one-way in step output TextBox.
- Enforced `BCD Repair` as **WinPE only** in OS Repair:
  - explicit tool label (`BCD Repair (WinPE Only)`)
  - disabled action outside WinPE (`WinPE Only` button text)
  - status text: `Unavailable outside of WinPE`
- Hardened WinPE detection for gating (MiniNT registry check with SystemRoot fallback).
- Fixed publish-path drift for ToolkitGUI with deterministic staging + mirror publish script behavior so runtime folder receives the latest DLL/exe pair.

## 2026-05-12 update

- CST now launches from Malware Cleanup as its own operator flow instead of a generic Run action.
- CST scan selection, detection-scope filtering, quarantine/remove, and rollback are wired through the GUI and PowerShell contract.
- Remaining CST work is in the detection engine layers and richer finding metadata, not in the application wiring.

## 2026-05-13 update

- Documentation refreshed to capture current closeout state before pausing work.
- Publish script guard now treats unchanged output as a warning instead of a hard failure, while still failing if the expected executable is missing.
- No additional workflow behavior changes were introduced in this closeout pass.

## 2026-05-13 batch-4 update

- Workflow contract normalization completed for remaining scripts, including explicit failure propagation and consistent report emission.
- Workflow UI parsing was updated to honor both Output and Detail payloads and to treat failed workflow status as an error condition.
- Batch 4 smoke validation passed across all targeted workflows after TempFileCleaner parser correction.

## 2026-05-14 update

- Startup Manager Services tab fixes were completed and published:
  - false ServiceNotFound paths were removed from pre-check flow.
  - service action failures now classify consistently (AccessDenied, ServiceNotFound, AlreadyInDesiredState, ProtectedOrUnsupported, ExecutionError).
  - TeamViewer restart now reports access-context denial correctly instead of not-found.
  - startup type changes now apply immediately when selecting from the Services dropdown; Set Type button was removed.
- ToolkitGUI elevation at launch is now manifest-driven (`requireAdministrator`) via `ToolkitGUI\app.manifest` and csproj manifest wiring.
- Standardized publish output for ToolkitGUI was revalidated after each service/elevation update.
- CST offline correlation validation is complete — `Validate-CstOfflineCorrelation.ps1` created and all CST validation matrix items are now checked. Hardware CDE WinPE boot validation remains a primary open item.

## 2026-05-14 update (CST WinPE triage)

- Added CST runtime diagnostics to make WinPE root/target discovery explicit in workflow output.
- Added explicit no-target semantics in CST result data (`NoTargets`, no-eligible-target indicator, and detailed coverage reason) to prevent ambiguous zero-scan completion.
- Updated WinPE Custom Scan target UX to use a shell-independent target prompt path for environments where FolderBrowserDialog tree rendering is blank.
- Current blocker remains target-machine runtime discovery behavior; latest changes are diagnostic-first to capture decisive evidence from the affected hardware session.

## Current status

- CDE WinPE and USB workflow is owned by toolkit scripts under `Toolkit\Scripts\`:
  - `Customize-WinPE.ps1` — customize `boot.wim`, drivers, `startnet.cmd`
  - `Prepare-BootableUSB.ps1` — stage rEFInd, boot payloads, and toolkit tree onto USB
  - `SyncUSB.bat` — mirror published `CDE\` runtime to removable media
- `startnet.cmd` in the WIM has CDEDATA volume detection with full-drive scan fallback.
- `ToolkitGUI` launches from the standardized self-contained path `Toolkit\App\ToolkitGUI\bin\Release\net8.0-windows\ToolkitGUI.exe` (publish before USB sync).
- Repository cleanup removed stale debug/intermediate output and removed the obsolete `WinPE-Publish` folder.
- The old VM automation scripts were intentionally removed from `Toolkit\WinPE`; manual hardware validation is the current loop.

## Hardware boot snapshot

- rEFInd pre-boot menu loads cleanly on hardware when USB is prepared with `Prepare-BootableUSB.ps1`.
- CHU boots from rEFInd via **`CHUPrep.efi`** → **`CoreDiag.efi`**; PC-Check text on HP desktop, GOP fallback on Samsung portable (2026-07-06 field-verified).
- CDE WinPE: re-run publish + USB sync after source changes, then confirm on hardware.

## Important integration notes

- Run `Toolkit\App\Publish-ToolkitGUI.ps1` after GUI or CST runtime changes before WinPE/USB testing.
- `WinPE_OfflineStartup.ps1` still resolves `TOOLKIT_ROOT` correctly and writes `CDE\Runtime\offline_env.txt` under the toolkit root (e.g. `X:\` on WinPE USB).
- The staged `boot.wim` under `Toolkit\Mount\WinPEWork\media\sources\boot.wim` (or your active WinPE working tree) is the source used by `Customize-WinPE.ps1` / USB prep scripts.
- `Toolkit\Tools\tools_manifest.json` and staged `CoreDiag.efi` are the source of truth for CHU + memtest payload staging.
- Ensure the target USB has sufficient free space before `SyncUSB.bat` or `Prepare-BootableUSB.ps1`.

## Quick validation points after USB sync

Check staged artifacts in the repo (optional):

```powershell
Test-Path ".\Toolkit\EFI\boot\refind.conf"
Test-Path ".\Toolkit\EFI\CDE\CHUPrep.efi"
Test-Path ".\Toolkit\EFI\CDE\CoreDiag.efi"
```

Check the live USB (replace `H:` with your drive letter):

```powershell
Test-Path "H:\EFI\boot\bootx64.efi"
Test-Path "H:\EFI\boot\refind.conf"
Test-Path "H:\EFI\CDE\CHUPrep.efi"
Test-Path "H:\EFI\CDE\CoreDiag.efi"
Test-Path "H:\EFI\CDE\memtest.efi"
Test-Path "H:\sources\boot.wim"
Test-Path "H:\Toolkit\App\ToolkitGUI\bin\Release\net8.0-windows\ToolkitGUI.exe"
Test-Path "H:\Toolkit\Scripts"
Test-Path "H:\Toolkit\Config"
Test-Path "H:\Toolkit\Tools"
```

## Next steps

1. Publish toolkit (`Publish-ToolkitGUI.ps1`), run `SyncUSB.bat` or `Prepare-BootableUSB.ps1`, and re-test CDE WinPE from the rEFInd menu.
2. If CDE WinPE fails, compare `EFI\boot\refind.conf` loader targets on USB against the repo copy and confirm `boot.wim` + toolkit paths exist.
3. Run CHU Week 4 hardware validation matrix after USB sync (see `Core Hardware Utility\UEFI\DIAGNOSTICS_IMPROVEMENT_PLAN.md` §9).
