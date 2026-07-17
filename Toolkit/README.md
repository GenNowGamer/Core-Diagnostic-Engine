# CDE — Core Diagnostic Environment

**Version:** 1.0.0 (Beta)  
**Build Date:** 2026-05-22  
**Platform:** UEFI USB / WinPE (Windows 10 ADK)

---

## Overview

CDE is a bootable USB diagnostic suite built on Windows PE. It boots via UEFI from a FAT32 USB drive into a **rEFInd** graphical menu (see `EFI\boot\refind.conf` — currently **CDE WinPE** and **CHU**; Microsoft `memtest.efi` is a separate boot payload via `Ensure-BootArtifacts.ps1`, WinPE `Invoke-PreBootTool.ps1`, or `CDEBoot.efi`). Once WinPE loads, `startnet.cmd` auto-launches `ToolkitGUI.exe` (Windows portable entry: `CDE.exe`), which presents a full-screen branded WPF boot menu — replacing the legacy text-based CMD menu. After entering the toolkit, use sidebar **System Health Check** for catalog-driven vitals, deep system, system audit, and security audit checks (not hardware line tests, SMART analyzer, Defender, or CST — those live under **Diag & Repair** and **Malware Cleanup**), **Diag & Repair** for PC-Doctor-style CPU/Memory/Storage line tests plus CST security scan (Quick/Extended), and per-tool workflows from **Malware Cleanup**, **Post-Op Cleanup**, and other sidebar views. **CHU** pre-boot hardware runs via rEFInd → **`CHUPrep.efi`** → **`CoreDiag.efi`** (PC-Check text or GOP UI depending on firmware) — see `Core Hardware Utility\UEFI\DIAGNOSTICS_IMPROVEMENT_PLAN.md` and `session_handoff.md` (2026-07-06).

The project mirrors the architecture of the proven MRI diagnostic platform while integrating CDE-specific tooling including the Core Hardware Utility (CHU) UEFI application and the Core Security Tool (CST) PowerShell module.

**Source repository:** [GenNowGamer/Core-Diagnostic-Engine](https://github.com/GenNowGamer/Core-Diagnostic-Engine) (private). Clone is source-only; run `App/Publish-ToolkitGUI.ps1` after clone and acquire large binaries per `Tools/PLACEHOLDER_ACQUISITION.md`.

## Session Update (2026-07-17)

- **Structured System Health findings** — Workflow steps persist Finding, Impact, Severity, deterministic Confidence (0–100), Evidence, Recommendations, and actions. Event-log checks correlate known failure clusters while retaining unmatched significant events.
- **Hybrid review UI/PDF** — Structured findings are additive to the previous grouped technical output, so adapter/device/service/event details remain available. The selected result card is blue-highlighted with a left accent and **VIEWING** badge; duplicate **DETAILED RESULTS** label removed.
- **GPU functional tests** — New Deep System `gpu_functional_tests` check uses self-contained `CdeGpuDiagCli.exe` for driver, D3D11, OpenGL, Vulkan, capped VRAM, and best-effort thermal checks. Unsupported environments report **N/A**.
- **Reliability** — Fixed PowerShell 5.1 generic-list conversion that caused `Argument types do not match` in Hijack/GPU finding paths. Regression coverage added in `Test-HealthFindingsAndEventClusters.ps1`.
- **Publish** — `App/Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`; latest GUI payload **2026-07-17 10:35:34 AM**.

## Session Update (2026-07-16)

- **System Health Check** — Findings list sorts by `findingsDisplayOrder` in `Config/HealthCheckCatalog.json`. Removed duplicate `audit_system_info` (use `system_info`). Startup Entry Audit review panel shows each entry once (Needs review cards + compact Verified).
- **Scheduled Tasks Audit** — Smarter suspicion heuristics (Microsoft-signed AppData paths OK); COM handler resolution for ClassId actions; **Review Reason** column. `Test-ScheduledTasksAuditSuspicion.ps1`.
- **Windows Update stack** — **Pass** when `wuauserv` is **Manual** or **Automatic** and `UsoSvc` is **Automatic**; idle **Stopped** is normal. `Test-WindowsUpdateStackStatus.ps1`.
- **Startup Manager — Services** — Service-specific risk/suspicion analysis with **RISK** display; **Suspicious only** filters Services; eligible suspicious or unprotected third-party services support confirmed **Delete** (`sc.exe delete`, binary retained). Protected Windows service hosts/services, drivers, Windows-folder services, and offline sessions remain blocked. Registry metadata fallback avoids an embedded-runspace `CimCmdlets` dependency; the blank WPF new-item row is disabled. `Test-StartupManagerCoverage.ps1` (**64/64**).
- **Startup Manager — Drivers** — ImagePath normalization for `\??\` and relative system32 paths before signature lookup.
- **Post-Op Restore Hosts File** — Uses live `%SystemRoot%`, clears read-only, writes defaults directly, carries toolkit/offline context through elevation, and records failed-step output. `Test-PostOpCleanup.ps1` (**15/15**).
- **Uninstall Manager** — Quiet/MSI uninstall preference, leftover detection, optional folder cleanup. `Test-UninstallManager.ps1`.
- **Hyper-V lab** — Push via `D:\Hyper-V\w11-infect-lab\Push-CDE-Toolkit.ps1`; C06 inject via `Inject-C06.ps1`. Details — `Toolkit\session_handoff.md`.
- **C06 verification** — All injected infection artifacts removed on `w11-infect-lab`; only inert BenchLab scenario-state JSON remained. Latest GUI/service build pushed successfully (`HV_CDE_PUSH_OK`).
- **Publish** — `App/Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe` after GUI/script changes; latest GUI payload from this update: **2026-07-16 1:38 PM**.

## Session Update (2026-07-15)

- **Code review Pass 1 & 2 — shipped** — Correctness/security/UX fixes across Startup Manager, CST/Malware glue, workflow elevation, Hijack repair, OS Repair/Fast Fixes, File Manager/Robocopy, Diag & Repair/hardware tests, and work orders/logging. Regression helpers: `Test-StartupManagerCoverage.ps1`, `Test-ToolkitElevation.ps1`, `Test-HijackRepairHelpers.ps1` (also in `Invoke-CdeRegressionSuite.ps1` where wired).
- **CST Scan Results UI** — Findings and Suppressed grids are the focal layout (shared height 2:1); footer coverage/action-summary text removed from the dialog (still in Copy summary / PDF).
- **Code review Pass 3 — deferred** — Publish/launcher/packaging reviewed (14 documented findings); operator keeping current workflow. No changes to `Publish-ToolkitGUI.ps1`, `CDE.exe`, or `SyncUSB.bat` from that review.
- **Publish** — `App/Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`; full validation `App/Publish-ToolkitGUI-FullVerify.ps1`. Details — `session_handoff.md`.

## Session Update (2026-07-10)

- **CST CIRCL (live Windows)** — ThreatScan/FullScan/CustomScan use CIRCL Hashlookup when not WinPE/`OfflineOnly`; content scans defer until batch known-good map is ready. Synced via `Publish-ToolkitGUI.ps1`.
- **Diag & Repair catalog** — CPU 13 / Memory 10 / Storage 6 (29 total); `mem_coverage` removed from tree (CHU guidance banner only); `cpu_stress` added.
- **Stuck Running fix** — ASCII-safe `[HW:TEST]` details + `FinalizeStuckHardwareTests` after Diag & Repair runs.
- **CST PDF** — Findings expander **Open full CST report (PDF)** opens the workflow PDF.
- **Details** — `session_handoff.md` (repo root + `Toolkit/`).

## Session Update (2026-07-09)

- **Temp File Cleaner** — Locked, in-use, and access-denied deletes (sharing violation, `UnauthorizedAccessException`, Win32 `0x0005`) count as **skipped**, not **Warn**. Typical when `VBCSCompiler` / Roslyn holds analyzer DLLs during Cursor or `dotnet build`. Genuine I/O failures still warn. `Scripts/Workflows/TempFileCleaner.ps1`.
- **User guide** — `Docs/UserGuide/07_Maintenance_Utilities.md` (Temp File Cleaner completion behavior).

## Session Update (2026-07-06)

- **CHU boot chain** — rEFInd CHU entry loads `EFI\CDE\CHUPrep.efi` (console prep), which chainloads `CoreDiag.efi`. Staged by `Core Hardware Utility\UEFI\BUILD_CHU_UEFI.ps1`.
- **CHU display** — PC-Check text default (HP desktop verified); GOP fallback on portable hardware when ConOut text is not visible (Samsung laptop verified).
- **CHU results scroll** — Post-test review uses real viewport height; Run All scroll reaches last HDD row on HP (field-verified).
- **CHU logging** — Early `LogOpen` + per-line flush before UI init.
- **Deploy** — CHU rebuild → `SyncUSB.bat` (no GUI publish unless CDE app changed). `CoreDiag.efi` SHA256 `EBC5D75F8687C3A1F9822B02B7B3877A992054DE5F6DD21250A70E32D732E35A`.
- **User guide** — `Docs/UserGuide/04_Diagnostics.md`, `08_Tools_Library_Settings.md`, `10_Reference.md`.

## Session Update (2026-07-03)

- **WinPE shell handoff** — Boot menu options **1** / **2** open main CDE GUI in-process (opaque WinPE `MainWindow`; no DWM transparency). Maximize/restore stable. Trace: `CDE\Runtime\winpe_startup.log`. GUI-only deploy: `Publish-ToolkitGUI.ps1` + `SyncUSB.bat`.
- **CdeCpuSimdCli** — Real CPU SIMD tests on PowerShell 5.1 (Win10/11 inbox). Published self-contained beside `ToolkitGUI.exe`; `HardwareTestEngine.ps1` invokes CLI on PS 5.1. Regression: `Scripts/Tests/Test-CpuSimdEnginePs5.ps1`.
- **CST remediation** — `CstRemediationService.cs` fixed for USB toolkit at drive root (`TOOLKIT_ROOT=G:\`).
- **Diag & Repair CST row** — Warnings show **Warn** (not **N/A**); `WorkflowViewModels.FinalizeCstTestFromReport`.
- **Git** — Single-repo layout (no nested `Toolkit/.git`); slim GitHub history; large artifacts gitignored — see repo root `.gitignore`.
- **Publish** — `App/Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`; `SyncUSB.bat` before field USB tests.

## Session Update (2026-07-01)

- **Removable media hardware policy** — Diag & Repair storage, S.M.A.R.T. Analyzer, and CHU storage tests exclude USB flash, memory cards, and boot USB. CDE: `Scripts/Core/PhysicalDiskCatalog.psm1` + `PhysicalDiskCatalogHelper.cs`. CHU: `StorageDrive.c` filters `RemovableMedia` at enumeration. Disk & Boot Repair still lists all disks. See `Docs/UserGuide/04_Diagnostics.md`.
- **Report policy** — Operator PDFs only in `Logs\`; internal JSON under `CDE\Runtime\Data\` (`workflows`, `scans`, `cst`, `sessions`); PowerShell session logs no longer written to `Logs\`. GUI unified on **Open Report** (removed Open HTML, Open PDF, Save report). `ReportPathHelper.cs` centralizes paths.
- **Dashboard suggested path** — **Verify case** removed; **What are you seeing?** highlights the inferred symptom on **Generate Work Order** via keyword scoring in `SymptomFlows.json` (`keywords` per flow). `GuidanceContext` persisted on create; re-infers on **Save** unless the tech explicitly clicked a symptom chip.
- **Case timeline** — Light-theme cards for readability on the Dashboard.
- **Hijack & Scam Repair** — Removed redundant **Toggle FIX** and **Copy** from the detail panel (grid + **Select repairable** remain).
- **User guide** — `Docs/UserGuide/` chapters 02, 03, 04, 05, 07, 08, 09, 10 updated.
- **Publish** — `App/Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`.

## Session Update (2026-06-30)

- **Hijack & Scam Repair** — HiJackThis-style scanner under sidebar **REPAIR**: full-width findings grid, bottom detail panel, **Select repairable**, Quick Repairs bottom drawer, scan persistence across navigation, **Re-Scan** label, Startup Manager-style loading overlay. **Open Report** (PDF) via `TabularScanReportService`. Startup rows review-only with **Manage** → Startup Manager (**Suspicious only** filter).
- **Reports** — System Health, Process Analyzer, Hijack, and workflow windows use **Open Report** for operator PDFs.
- **Startup Manager — MSIX executable resolution** — `MsixStartup.ps1` resolves startup-task image paths from `Get-AppxPackageManifest` (`windows.startupTask` `TaskId` matched to registry folder name; extension or application `Executable` under `InstallLocation`). Fixes **Not found** / false analysis warnings on MSIX rows (Teams, Copilot, etc.) that previously used the install folder only.
- **Startup Manager — MSIX package signature display** — When the resolved path is not directly accessible (WindowsApps ACL), **Signed** shows `Package (Publisher)` (`SignatureStatus=PackagePublisher`, blue) instead of **Not found**. Accessible binaries use normal Authenticode. `StartupManager.ps1` routes `MsixStartupTask` rows through `Get-MsixStartupSignatureInfo` / `Get-MsixStartupAnalysisInfo`.
- **Process Analyzer — Investigation UI** — Toolbar status line hidden during **Investigation ON**; removed `Investigation active (3s refresh)` status prefix so Tree view and Deep scan checkboxes are not overlapped.
- **User guide** — `Docs/UserGuide/` chapters 03, 05, 07, 09, 10 updated.
- **Tests** — `Test-MsixStartupTasks.ps1` expanded (23 tests).
- **Publish** — `App/Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`.

## Session Update (2026-06-26)

- **Phase 3 — diagnostic depth** — CHU catalog parity test (`Test-HardwareTestCatalogSync.ps1`); CHU Pre-Boot Results rollup + per-failure **Open matching Diag & Repair test** links; Diag & Repair `highlight:{catalogId}` navigation; tiered CST findings (`CstFindingsExpander` in workflow execution window — actionable default unchanged); Dashboard **suggested path** + **Case timeline**; work-order optional fields `EventKind`, `DisplayLabel`, `SourceArtifact`, `GuidanceContext`; CHU/CST/Process Analyzer recording hooks.
- **Startup Manager — persistence depth** — Scheduled logon/boot tasks, `StartupApproved` parity for Run/folder entries, GPO Run keys, cross-mechanism correlation (SOURCE/RELATED columns), MSIX startup tasks in list + `audit_startup` (manifest executable resolution + package publisher signature). `\Microsoft\*` scheduled tasks hidden by default (optional checkbox; read-only when shown). Non-Microsoft scheduled tasks support **Delete** (unregister). Core: `StartupApproved.ps1`, `StartupScheduledTask.ps1`, `StartupCorrelation.ps1`, `MsixStartup.ps1`; tests `Test-StartupManagerCoverage.ps1`, `Test-MsixStartupTasks.ps1`.
- **Post-Op Cleanup — eight tools** — Added icon/thumbnail cache, DNS flush, proxy reset, hosts restore (confirmation), restart Explorer via `PostOpCleanup.ps1`. Removed duplicate fixes from **Fast Fixes** (Flush DNS, icon/thumb cache) and **OS Repair** network reset (DNS flush). Hosts **audit** remains in System Health Check only.
- **Fast Fixes** — Catalog trimmed to **14** verified one-click fixes (DNS/icon/thumb cache moved to Post-Op).
- **Regression** — `Test-WorkOrderCaseEvents.ps1`, `Test-CstStructuredResults.ps1`, `Test-PostOpCleanup.ps1` wired into `Invoke-CdeRegressionSuite.ps1`.
- **Work-order bugfix** — `Add-WorkOrderRun` ReportJson dedupe used invalid PowerShell precedence; caused exit code 1 after successful workflows (e.g. Temp File Cleaner) when a work order was active. Fixed in `Scripts/Core/WorkOrder.ps1`.
- **User guide** — `Docs/UserGuide/` chapters updated (Post-Op, Startup Manager, Fast Fixes dedup, workflow verify, case timeline, CHU correlation, CST expander). **2026-06-30:** `07_Maintenance_Utilities.md` — MSIX signing, Process Analyzer Investigation UI.
- **Publish** — `App/Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`.

## Session Update (2026-06-19)

- **System Health Check — grouped review output** — All catalog checks use grouped property cards in the GUI and PDF (`Format-GroupedBlockHeader` / `Format-GroupedPropertyLine` in `Toolkit.Core.psm1`; `WorkflowResultFormatter.FormatGroupBlockOutput`). Fixed regression where checks with 8–9 character titles (e.g. driver names) threw on string-length comparison and appeared as **Skip** (Windows Update stack, Drivers, Critical Events, Scheduled Tasks).
- **Maintenance deduplication — System Audit sidebar removed** — The separate **System Audit** Maintenance view and `Scripts/Workflows/SystemAudit.ps1` were removed. Shared implementations remain in `Scripts/Core/SystemAuditChecks.ps1` and run only via **System Health Check** (`SystemHealthCheck.ps1`, catalog category **System Audit**: `audit_*` check ids). Recommendation actions that previously opened System Audit now navigate to **System Health Check**.
- **Malware Cleanup scope reduced** — Removed **Autoruns Audit**, **Hosts File Check**, **Browser Extensions Scan**, and **Scheduled Tasks Audit** from the Malware Cleanup tool list. `MalwareSweep.ps1` now dispatches **Windows Defender Scan**, **Core Security Tool**, and **Update Hash IOCs** only. Shared security audit functions remain in `Scripts/Core/SecurityAuditChecks.ps1` and run via **System Health Check** (catalog category **Security Audits**: `sec_*` check ids).
- **Regression** — `Scripts/Tests/Test-SkippedHealthChecks.ps1` (also in `Invoke-CdeRegressionSuite.ps1`). `ValidateTools.ps1` validates audit/security checks through `SystemHealthCheck.ps1`.
- **Publish** — `App/Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`.

## Session Update (2026-06-18)

- **System Health Check catalog trim** — `Config/HealthCheckCatalog.json` no longer lists: Disk SMART (WMI), CPU Temperature, Memory Diagnostic History, S.M.A.R.T. Attribute Analysis, Diag & Repair hardware tests (CPU/Memory/Storage), Windows Defender Scan, or Core Security Tool (scan only). **Recommended** preset: CPU Load, RAM, Disk Free Space, Startup Entry Audit. HW profile Quick/Extended removed from System Health toolbar. Use sidebar **Diag & Repair** and **Malware Cleanup** for those capabilities.
- **Update Hash IOCs** — Moved from Malware Cleanup tool list to **Core Security Tool** config dialog (**Threat Signature Database** card; primary blue button). Still `MalwareSweep.ps1 -ToolName UpdateHashIOCs`.
- **CST run artifacts** — Unified session timestamp; typical run leaves ~3 files (`.log`, `CST_Result_*.json`, `MalwareSweep_*.json`); no HTML; PDF on demand; skip summary inline (no `_skiplog.json` sidecar by default).
- **Malware Cleanup Structured Results** — Populated from final `CST_Result_*.json` only; actionable types Malware/Virus/PUP/PUM.
- **Cursor sandbox FP** — CST Tier1 path exclusion for `cursor-sandbox-cache`; weak PathHeuristic suppressed-audit filter (&lt; 0.55 confidence).
- **Publish** — `App/Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`.

## Session Update (2026-06-16)

- **Diag & Repair (HW + CST)** — Sidebar **Diag & Repair** (nav `DiagAndRepair`; alias `HardwareDiagnostics`) replaces **Hardware Diagnostics**. **Run All Tests** = CPU → Memory → Storage → CST (`ScanOnly`; Quick = ThreatScan, Extended = FullScan). Separate **CST Scan** toolbar button. Static **Security Scan → Core Security Tool** row in the results table; live CST file path updates in one streaming line via `[CST:PROGRESS]` (no per-file log scroll). Post-scan remediation via shared `CstRemediationService` + `CstFindingsOperatorDialog`. Workflow script filename unchanged: `Scripts/Workflows/HardwareDiagnostics.ps1` (`-ToolName All|CpuTests|MemoryTests|StorageTests|CstScan`). GUI: `DiagAndRepairView`, `DiagAndRepairViewModel`. Regression: `Scripts/Tests/Test-HardwareDiagnosticsCst.ps1`.
- **Windows Update stack diagnostics** — System Health Check `windows_update_service` (`HealthChecks.ps1`) now reports **`wuauserv`**, **`UsoSvc`**, **`bits`**, and **`WaaSMedicSvc`** with **Status** and **Start Type** in a formatted table (`Format-WindowsUpdateStack` in `Toolkit.Core.psm1`). **Stopped** while idle is **Pass** when startup type is healthy; only **Disabled** startup type fails the check. Clarifies the common confusion between **Stopped** (runtime) and **Disabled** (startup type). *(2026-07-16: **Manual** `wuauserv` is **Pass** — normal Win10/11 default; `UsoSvc` must be **Automatic**.)*
- **Post-Op Cleanup** — **Restore Default Services** (`PostOp.ps1`) sets `wuauserv` to **Automatic** (optional operator posture; health check no longer Warns solely because Manual was left in place).
- **Health check catalog** — `Config/HealthCheckCatalog.json`: System Health Check categories (Quick Vitals, Deep System, System Audit, Security Audits), check ids/labels, presets, recommendations. *(2026-06-18: hardware/Diag & Repair, Storage SMART analyzer, Defender, and CST scan-only removed from catalog — use dedicated sidebar workflows.)* `windows_update_service` lists full WU stack.
- **Operator** — GUI + script changes: canonical publish `App/Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`; relaunch after publish.

## Session Update (2026-06-15)

- **PDF workflow reports** — QuestPDF generates professional PDFs under `Logs\` (`WorkflowReportPdfService.cs`). Workflow execution and **System Health Check** expose **Open PDF** (JSON/HTML remain for internal/technician merge via `Generate-Report`).
- **Elevated PDF open** — `ShellFileOpenHelper.cs` opens PDFs via `explorer.exe` so default viewers foreground correctly when CDE runs as administrator.
- **Readable structured results** — `WorkflowResultFormatter.cs` formats raw step output into scannable cards in the GUI (`FormattedResultItemTemplate` in `App.xaml`) and in PDF step sections. System Health review panel adds **DETAILED RESULTS** for all check statuses.
- **System Health Check PDF labeling** — `WorkflowStepLabelHelper.cs` resolves friendly names from `Config/HealthCheckCatalog.json` per step `CheckId`; repeats test name on each item card in health-check PDFs.
- **Startup Entry Audit** — `[REVIEW]` tags and review-panel UX aligned with health check (`SystemAuditChecks.ps1`, `StructuredResultItemViewModel`, `SystemHealthReviewHelper`).
- **Publish** — `App/Publish-ToolkitGUI.ps1` after GUI changes; relaunch `Toolkit\CDE.exe`.

```powershell
dotnet build App\ToolkitGUI\ToolkitGUI.csproj -c Release
.\App\Publish-ToolkitGUI.ps1
```

## Session Update (2026-06-25)

- **Process Analyzer** — Expanded from a simple process list to live triage: CPU/RAM sampling, risk heuristics, filters (high CPU/RAM, unsigned, suspicious path, in startup, **Investigation** mode with NEW highlighting), tree view, freeze snapshot, **Open Report** (PDF). Investigation mode uses the **Investigation ON** button for state (no overlapping toolbar status banner). Detail pane: command line, session, parent PID, parent chain, loaded modules, SHA256, signature; **CST scan file** with structured results dialog; shortcuts to Startup Manager and Malware Cleanup. System Health Check recommendations can open Process Analyzer with high CPU/RAM presets (`HealthCheckCatalog.json`).
- **WMI + UI fix** — `Services/ProcessWmiEnricher.cs` enriches list/detail from `Win32_Process`; detail updates clone `ProcessDetail` so the pane refreshes. Release publish sets **`PublishTrimmed=false`** (partial trim had broken JSON deserialization for session/command line in the field).
- **Scripts** — `Scripts/Workflows/ProcessAnalyzer.ps1`, `Scripts/Core/ProcessAnalyzer.Core.ps1`. CST leaf-file enumeration fix synced on publish.
- **Publish** — `App/Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`; relaunch after publish (kill stale `ToolkitGUI` if needed).

## Session Update (2026-06-23)

- **File Manager** — Skips reparse-point/junction folders (fixes infinite `Application Data` loops and runaway folder sizes under `C:\ProgramData`). Custom right-click menus (Open, Cut/Copy/Paste, Rename, Delete, Properties, Show in Explorer, New folder). Checkbox column + header select-all for multi-select copy/move/delete.
- **Prepare-BootableUSB.ps1** — USB drive letter can be **reused** when it belongs only to the target disk (e.g. keep `E:` on the SanDisk stick). Partition/format uses **diskpart first** (Storage module fallback). Fixed `Set-Disk` parameter-set bug that blocked diskpart fallback. Robocopy exclusions aligned with `SyncUSB.bat`: `Run-CustomizeWinPE.vbs`, `.venv`, `.vscode`.
- **OS Repair — DISM** — Optional `install.wim` / `install.esd` source when Windows Update cannot supply repair files (**error 0x800f081f**). GUI prompts before DISM run; script auto-picks WIM index when possible (`-DismSource`, `-DismSourceIndex`).
- **Publish** — `App/Publish-ToolkitGUI.ps1` after GUI changes; script-only fixes via `SyncUSB.bat` or relaunch `CDE.exe`.

## Session Update (2026-06-22)

- **WinPE boot menu** — Removed CST Malware Scan shortcuts (former options 8–9); menu is keys **1–7** only. CST remains in **Diag & Repair** and **Malware Cleanup**.
- **Settings — Clear Test & Scan Logs** — Clears `EFI\CoreDiag\Logs`, `EFI\CoreDiag\Results` (discovered on ready drives), `{TOOLKIT_ROOT}\Logs` (PDFs), and `CDE\Runtime\Data\` with confirmation. Work order JSON: **Dashboard → Clear Recent**. `App/ToolkitGUI/Services/ResultLogCleanupService.cs`, `WorkOrderService.ClearRecentInternalWorkOrderRecords()`.
- **PDF User Guide** — Operator manual: edit `Docs/UserGuide\` (`manifest.json` + chapter `.md`); publish runs `App/UserGuideGenerator` → `HALP\CDE_User_Guide.pdf`. **Settings → Open User Guide**. Generator is a separate console app (Markdig + QuestPDF) to avoid ToolkitGUI Markdig.Signed conflicts.
- **Publish** — `App/Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe` + user guide PDF; `HALP\` syncs to USB with `SyncUSB.bat`.

## Session Update (2026-06-12)

- **Phase 1 trust & polish** — Centralized workflow health helpers (`Get-WorkflowOverallHealth`, fixes PS 5.1 scalar `.Count` trap). `OverallHealth` persisted in JSON reports. Deep Diagnostics adds grouped `EventSummary` + optional full events export. Temp File Cleaner tracks `FailedItems` and actual `FreedBytes`. **Work orders** capture workflow runs and produce a case PDF on close. Dashboard copy updated (OS Repair / Backup). Local regression suite: `Scripts\Tests\Invoke-CdeRegressionSuite.ps1`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File Toolkit\Scripts\Tests\Invoke-CdeRegressionSuite.ps1
# Optional read-only workflow smoke:
powershell -NoProfile -ExecutionPolicy Bypass -File Toolkit\Scripts\Tests\Invoke-CdeRegressionSuite.ps1 -IncludeWorkflowSmoke
```

- **File Manager** — **Directories** pane starts empty on open; **Computer** tree auto-expands. Right pane populates only when a technician selects a **drive** or **shadow copy** (not Users / Toolkit / Offline OS shortcuts). Split-view bottom pane also starts empty.
- **Startup Entry Audit** — runs from **System Health Check** (`audit_startup`); `[POSTOP:STARTUP]` structured results. **Post-Op Cleanup** is eight remediation tools (browser cache, services, associations, DNS/proxy reset, shell caches, optional hosts restore, restart Explorer) — see Session Update 2026-06-26.
- **System Audit** — `Invoke-StartupAudit` uses `$r.Steps.Add` (not `Add-ToolkitWorkflowStep` from elevation module). `ValidateTools.ps1` includes `StartupAudit`.
- **Shadow Copies** — `ShadowCopyBrowse.ps1` lists every snapshot per VSS set (not only the first drive); sort newest-first by real datetime.
- **Bootloader Repair** — EFI volume discovery, `bootsect /nt60` targeting, BCD restore backup pickers, scan-without-drive-picker; `Test-BootloaderCommon.ps1`.
- **Startup Manager — Extensions** — CLSID→DLL resolution for legacy BHO/toolbars; Chromium + Firefox extension discovery across profiles.
- **Banner uptime** — single line `Uptime: Xd Xh Xm` (`BootUptimeHelper.cs`; Kernel-General Event 12 → Event 6005 → WMI). System Audit still reports session + cold-boot detail and source via `Get-CdeBootUptimeInfo`.
- **Publish** — `App/Publish-ToolkitGUI.ps1` after GUI changes; script-only fixes after relaunch or `SyncUSB.bat`.

## Session Update (2026-06-11)

- **WinPE offline session state** — `offline_env.txt` and `offline_progress.log` live under **`CDE\Runtime\`** (not toolkit root). `OfflineRuntime.ps1` / `OfflineRuntimePaths.cs` validate `OFFLINE_REGISTRY_LOADED` only when `HKLM\Offline_SOFTWARE\...\Winlogon` exists. `SyncUSB.bat` clears runtime artifacts after sync. Fixes missing **Userinit** / **Shell** in Startup Manager when a stale USB session file was present.
- **File Manager** — read-only **Shadow Copies** tree (`ShadowCopyBrowse.ps1`) on full Windows; mount under `%TEMP%\CDE_ShadowBrowse\`.
- **Backup & Imaging** — **VSS Shadow Copy** workflow removed (unreliable on client Windows). **Robocopy Backup** only. Path quoting fixed for drive roots (`E:\`), spaces in paths (GUI → PowerShell and script → `robocopy.exe`), dry-run `/L`, and clearer log summaries (file/byte counts).
- **Publish** — `App/Publish-ToolkitGUI.ps1` after GUI changes; script-only fixes take effect after relaunch or `SyncUSB.bat`.

## Session Update (2026-06-10)

- **Fast Fixes verification** — 14 one-click fixes in `Scripts/Workflows/FastFixes.ps1` log via `Write-FixLog` and set workflow step **Pass/Fail** from post-action checks (DNS flush and icon/thumb cache moved to Post-Op 2026-06-26). `Invoke-FixCommand` uses `ProcessStartInfo` redirect (PS 5.1-safe). Clear Event Logs verification tolerates small residual counts after `wevtutil cl`; Renew IP reports the default-route adapter.
- **Uptime** — Banner shows `Uptime: …` (`BootUptimeHelper.cs`; Event 12 / 6005 / WMI). System Audit lists session + cold-boot uptimes with event source via `Get-CdeBootUptimeInfo` in `Toolkit.Core.psm1`.
- **Account recovery** — Tools Library **ACCOUNT RECOVERY → Enable Offline Administrator** (`executionMode="cde_workflow"`). WinPE + offline OS (boot menu option 2) only; enables built-in `.\Administrator` on offline SAM via `OfflineSamAccount.psm1`. Does not reset Microsoft account, PIN, or Entra ID.
- **Publish** — `App/Publish-ToolkitGUI.ps1` run after GUI changes (2026-06-10). Run `SyncUSB.bat` before USB/WinPE validation. No `Customize-WinPE.ps1` needed for these changes.

## Session Update (2026-06-09)

- **PowerShell script encoding** — Several workflow scripts were UTF-16 LE, which breaks `powershell.exe -File` and surfaces bogus parse errors in CDE (Malware Cleanup, Fast Fixes). All scripts under `Scripts/` are now **UTF-8 with BOM**. **Do not save Toolkit scripts as UTF-16.** Validate with `Parser::ParseFile` after encoding changes.
- **Startup audit hardening (items 1–8)** — Shared `Get-PostOpStartupEntries` in `StartupRisk.ps1` (Winlogon + offline hives); PostOp Startup Audit and MalwareSweep Autoruns Audit use it; Startup Manager Winlogon/Delete/driver/CST paths hardened. Details in `session_handoff.md`.
- **Operator:** Relaunch `Toolkit\CDE.exe` after script-only changes. `App/Publish-ToolkitGUI.ps1` only required for GUI or CST source updates.

## Session Update (2026-06-05)

- **Startup Manager — Winlogon reset/undo** — User logon tab surfaces `Userinit` and `Shell` from `HKLM\...\Winlogon`. Deviations from Windows defaults show red styling; **Reset** restores the default value (with JSON backup under `%ProgramData%\CDE\WinlogonBackups\`); **Undo** restores the pre-reset value. Enable/Disable/Delete are hidden for these two rows (not merely disabled).
- **CST hash + CIRCL fixes (synced to `Security/CST/`)** — Empty/unreadable SHA-256 paths (AppX stubs, reparse points) no longer throw `PerFileAnalysis` binding errors; CIRCL bulk reputation now POSTs `{"hashes":["<sha1>",...]}` to `/bulk/sha1` (fixes prior 404 on every batch). Negative cache for hashes missing from bulk responses.
- **Publish** — `App/Publish-ToolkitGUI.ps1` rebuilt ToolkitGUI after Startup Manager UI changes; launch `Toolkit\CDE.exe` (elevated) to pick up the new payload.

## Session Update (2026-06-04)

- **CST false-positive reduction** — Source in `Core Security Tool\CST\`: known-good hash skip + trusted-signer early exit before YARA/pattern work; scan summary fields `knownGoodSkips`, `trustedSignerSkips`, `contentScansPerformed`.
- **Publish sync** — `App/Publish-ToolkitGUI.ps1` mirrors `Cst.KnownGood.ps1`, `rules/baselines/**`, and optional `rules/goodware.db` to `Security/CST/` (in addition to `.ps1`, `.psm1`, `rules.json`).
- **Validation (CST source):** `Validate-CstPolicyContract`, `Validate-CstRuleQuality`, `Validate-CstReleaseGates` (4 gates) — pass as of 2026-06-04.

## Session Update (2026-06-03)

- **Structured Results** — Quick Health / Deep Diagnostics: Warn/Fail findings at workflow end (`PopulateDiagnosticStructuredResults`). System Audit **Event Logs**: unique 24h errors via `[AUDIT:EVENT]` in `SystemAudit.ps1`. **All workflows** with line-item output use `WorkflowResultFormatter` for card-style rows (location, path, status badges) in the execution window and PDF. System Health review shows **DETAILED RESULTS** for every check status.
- **CST UI** — `CoreSecurityToolConfigDialog`: scan config plus **Update Hash IOCs** (Threat Signature Database, 2026-06-18). Right-column build notes / scan summary / scope preview removed (2026-06-03).
- **Post-Op Cleanup** — Eight tools in `Scripts/Workflows/PostOp.ps1` + `Scripts/Core/PostOpCleanup.ps1` (browser cache, restore default services, file associations, icon/thumb cache, DNS flush, proxy reset, hosts restore, restart Explorer). *(Startup Entry Audit relocated to System Health Check 2026-06-19.)*
- **Startup Entry Audit** *(2026-06-03 in Post-Op; relocated to System Audit 2026-06-12)* — Review/OK cards in **Structured Results** and PDF via `WorkflowResultFormatter`; `[POSTOP:STARTUP]` JSON for live parsing; now runs from `SystemAudit.ps1`.
- Helpers: `Scripts/Core/Toolkit.Elevation.psm1`, `Scripts/Core/StartupRisk.ps1` (shared with Startup Manager).

## Session Update (2026-06-02)

- **Diag & Repair** — PC-Doctor-style workflow in ToolkitGUI (CPU 13 / Memory 10 / Storage 6 line tests — 29 total; no `mem_coverage` tree row, Quick and Extended profiles, CST ThreatScan/FullScan scan-only, inline results table, no workflow popup).
- Script: `Scripts/Workflows/HardwareDiagnostics.ps1` (`-ToolName All|CpuTests|MemoryTests|StorageTests|CstScan`, `-TestProfile Quick|Extended`).
- UEFI CHU: rEFInd loads `EFI\CDE\CHUPrep.efi` → `CoreDiag.efi`. Rebuild with `Core Hardware Utility\UEFI\BUILD_CHU_UEFI.ps1`, then `SyncUSB.bat`. Use rEFInd for pre-boot hardware; ToolkitGUI for WinPE/Windows line-item suite.
- Publish after GUI changes: `App/Publish-ToolkitGUI.ps1` → `CDE.exe`. Administrator recommended for storage physical-read tests.

## Session Update (2026-06-01)

- CST FullScan responsiveness and completion telemetry behavior were stabilized in this workspace session.
- Artifact correlation was updated to a guarded indexed path in CST, with validator parity re-confirmed.
- Canonical publish path (`App/Publish-ToolkitGUI.ps1`) now resolves and syncs CST source files cleanly to runtime without stale-source warnings.
- Current validation snapshot after these changes:
  - `Validate-CstPolicyContract.ps1`: 51 passed, 0 failed
  - `Validate-CstOfflineCorrelation.ps1`: 27 passed, 0 failed, 3 skipped (WinPE-only runtime checks)
  - `Validate-CstBootScanner.ps1`: 6 passed, 0 failed

---

## Boot Flow

### UEFI Graphical Menu (rEFInd)

| # | Entry | Description |
|---|-------|-------------|
| 1 | CDE WinPE | Chainloads `EFI\Microsoft\Boot\bootmgfw.efi` into the CDE WinPE environment |
| 2 | Core Hardware Utility (CHU) | Loads `EFI\CDE\CHUPrep.efi` from rEFInd (prep launcher → `CoreDiag.efi`) |
| 3 | Windows Memory Diagnostic | `EFI\CDE\memtest.efi` (not in current `refind.conf`; use `Ensure-BootArtifacts.ps1`, WinPE MemDiag launch, or add rEFInd menuentry) |

### WinPE Boot Menu (WPF GUI — hosted in ToolkitGUI.exe)

`startnet.cmd` auto-launches `ToolkitGUI.exe` on boot. The app displays a full-screen branded menu.
Keys 1–7 or mouse clicks select options.

| # | Option | Description |
|---|--------|-------------|
| 1 | Launch CDE Toolkit GUI | Normal CDE launch — no offline OS loading |
| 2 | Launch CDE + Load Offline OS | CDE with offline Windows drive detection and hive load |
| 3 | WinPE Command Prompt | Raw CMD shell in WinPE |
| 4 | PowerShell (WinPE) | PowerShell 5.1 in WinPE |
| 5 | Network Setup | Runs `wpeinit` for network initialization |
| 6 | Reboot | System reboot (confirms before acting) |
| 7 | Shutdown | Clean system shutdown (confirms before acting) |

CST offline malware scans are available inside CDE via **Diag & Repair** and **Malware Cleanup** — not from the WinPE boot menu.

After option **1** or **2**, the same `ToolkitGUI.exe` process opens the main CDE shell (`MainWindow`). On WinPE the shell uses an opaque window frame (not transparent chrome). If launch fails, check `CDE\Runtime\winpe_startup.log` on the USB.

If `ToolkitGUI.exe` is missing, `startnet.cmd` falls back to a minimal text menu (options 1–6).

---

## Repository Structure

```
CDE Beta_Test/
├── README.md                       # This file
├── CDE.exe                         # Default Windows launcher (root entrypoint)
├── Run-CustomizeWinPE.vbs          # Root helper that elevates and runs Scripts\Customize-WinPE.ps1
├── autorun.inf                     # ISO auto-execution stub
├── bootmgr / bootmgr.efi           # BIOS and UEFI boot managers (root copies)
│
├── boot/                           # BIOS/MBR boot files
│   ├── BCD                         # Boot Configuration Database (BIOS)
│   ├── BOOT.SDI                    # System Deployment Image signature
│   └── en-us/, resources/          # WBM localization and resource DLLs
│
├── EFI/                            # UEFI boot files
│   ├── boot/
│   │   ├── bootx64.efi             # rEFInd fallback launcher (UEFI removable path)
│   │   ├── refind.conf             # Active deterministic CDE rEFInd menu
│   │   └── icons/                  # Required for graphical rEFInd menu rendering
│   ├── refind/
│   │   └── refind_x64.efi          # rEFInd source binary copied to EFI\boot\bootx64.efi
│   ├── CDE/
│   │   ├── CHUPrep.efi             # rEFInd CHU entry (console prep → CoreDiag)
│   │   ├── CoreDiag.efi            # CHU main UEFI application (EDK2, unsigned)
│   │   ├── CDEBoot.efi             # Windows BCD BOOTAPP chainload (alternate)
│   │   └── memtest.efi             # Windows Memory Diagnostic payload
│   └── microsoft/boot/
│       ├── BCD                     # USB Boot Configuration Database for WinPE
│       ├── bootmgfw.efi            # Windows Boot Manager used to enter WinPE
│       └── memtest.efi             # Microsoft memtest payload retained with boot files
│
├── sources/
│   └── boot.wim                    # WinPE image (rebuilt by Customize-WinPE.ps1)
│
├── Scripts/                        # Build and runtime PowerShell scripts
│   ├── Launch/
│   │   └── CDE_Portable.bat        # Fallback Windows launcher
│   ├── Customize-WinPE.ps1         # Builds boot.wim: adds PS OCs, injects startnet.cmd, injects Drivers\Storage + Drivers\Network
│   ├── Prepare-BootableUSB.ps1     # Formats USB and deploys all CDE files
│   ├── Invoke-PreBootTool.ps1      # Legacy/manual pre-boot launcher helper (not on default WinPE menu)
│   ├── CreateISO.ps1               # Creates bootable ISO from CDE tree
│   ├── Core/                       # Shared PowerShell modules
│   └── Workflows/                  # Automation workflows
│
├── CDE/                            # Main application (ToolkitGUI + supporting files)
│   ├── ToolkitGUI/                 # .NET diagnostic GUI application
│   ├── Data/                       # Application data
│   └── Tools_Management/           # Tool discovery and management
│
├── Config/
│   ├── global.ini                  # Runtime configuration (language, logging, boot)
│   └── settings.json               # Path and environment settings
│
├── Diagnostics/                    # Diagnostic tools
│   ├── Hardware/                   # Hardware diagnostics
│   ├── Memory/                     # Memory test tools
│   ├── Storage/                    # Disk and storage tools
│   ├── Malware/                    # Malware scanners
│   └── Utils/                      # General diagnostic utilities
│
├── Windows Tools/                  # Windows utilities and repair tools
├── Tools/                          # Tools Library payloads (ToolCatalog.xml; Firefox/, AccountRecovery/, etc.)
├── Drivers/                        # Optional .inf packages injected into boot.wim
│   ├── Storage/                    # Storage controller (RAID/VMD) drivers
│   └── Network/                    # Ethernet/NIC drivers (Wi-Fi not supported in WinPE)
├── Deploy/                         # Deployment artifacts (Hyper-V, etc.)
├── Mount/                          # WinPE DISM mount point (transient — not committed)
├── Logs/                           # Operator PDF deliverables (transient — not committed)
│   # Internal JSON/session logs: CDE/Runtime/Data/
└── WinPE/                          # WinPE build scripts and customizations
```

---

## Build & Deployment

### Prerequisites
- Windows 10 ADK + WinPE Add-On installed  
  (`C:\Program Files (x86)\Windows Kits\10\...`)
- PowerShell 5.1, run as Administrator
- Target USB drive (minimum 2 GB). The prepare script repartitions and formats the selected disk as FAT32.

### PowerShell script encoding (required)

All `Scripts/**/*.ps1` and `Scripts/**/*.psm1` must be **UTF-8 with BOM**. UTF-16 (with or without BOM) breaks `powershell.exe -File` in CDE and produces misleading parse errors (missing `)`, illegal `&`, etc.). After editing or bulk-converting scripts, verify:

```powershell
$e = $null
[void][Management.Automation.Language.Parser]::ParseFile('Scripts\Workflows\FastFixes.ps1', [ref]$null, [ref]$e)
$e.Count  # expect 0
```

### 1 — Build WinPE (`boot.wim`)

Run elevated:
```powershell
.\Scripts\Customize-WinPE.ps1
```

Optional helper from the Toolkit root:
```text
Run-CustomizeWinPE.vbs
```

What it does:
1. Copies a fresh `winpe.wim` from the ADK as the base
2. Mounts it and installs four PowerShell optional components:  
   `WinPE-WMI`, `WinPE-NetFx`, `WinPE-Scripting`, `WinPE-PowerShell`
3. Injects `Mount\WinPEWork\startnet.cmd` (the CDE boot menu)
4. Injects `CDECore.psm1` (Toolkit.Core PowerShell module)
5. Injects any `.inf` driver packages found under `Drivers\Storage` (RAID/VMD controllers) and `Drivers\Network` (Ethernet/NIC) — skipped if those folders are empty/absent
6. Commits to `sources\boot.wim` (~476 MB)

**Re-run this script any time `startnet.cmd` is modified.**

> Tip: For network access in WinPE (e.g. the bundled Firefox browser), drop your machine's extracted Ethernet driver `.inf` packages into `Drivers\Network\` before building. Wi-Fi is not supported in WinPE — Ethernet / USB-Ethernet only.

Note: `Run-CustomizeWinPE.vbs` is a local build helper and is excluded from USB copies (`SyncUSB.bat` and `Prepare-BootableUSB.ps1`).

### 2 — Prepare USB Drive

Run elevated (will prompt for target drive — destructive):
```powershell
.\Scripts\Prepare-BootableUSB.ps1
```

What it does:
1. Prompts for a drive letter before wipe (reuses the USB's current letter when it belongs to the target disk).
2. Partitions and formats the selected target disk as FAT32 (GPT or MBR) via **diskpart** (Windows Storage module fallback).
3. Applies `active` only on MBR disks.
4. Copies CDE files from the project root (same dev-folder/file exclusions as `SyncUSB.bat`).
5. Sets UEFI fallback launcher to rEFInd and validates rEFInd loader paths.
6. Applies BIOS boot sector (`bootsect /mbr`) only for MBR disks.

Optional launcher: `PrepareUSB.vbs` (elevates and runs the script interactively).

### 3 — Quick Update (rEFInd config only)

If only `EFI\boot\refind.conf` changed, copy it directly — no `boot.wim` rebuild needed:
```powershell
Copy-Item ".\EFI\boot\refind.conf" "H:\EFI\boot\refind.conf" -Force
```

### 4 - Windows Portable Launch Path

Default Windows launch entrypoint is now:

```text
CDE.exe
```

Behavior summary:
1. `CDE.exe` resolves `TOOLKIT_ROOT` from its own directory.
2. It launches `CDE\ToolkitGUI\bin\Release\net8.0-windows\ToolkitGUI.exe`.
3. If elevation is required, it retries via elevated `CDE.exe` self-relaunch.

Fallback launcher remains available at:

```text
Scripts\Launch\CDE_Portable.bat
```

Publish/deploy workflow remains:
1. Edit source in `App\ToolkitGUI\`.
2. Run `App\Publish-ToolkitGUI.ps1` for compile/sync publish (builds ToolkitGUI and launcher, syncs to `CDE\`, regenerates `HALP\CDE_User_Guide.pdf` from `Docs\UserGuide\`).
3. Run `App\Publish-ToolkitGUI-FullVerify.ps1` when full validation is required (regression, ValidateTools, CST release gates, CHU hash, SIMD payload, GUI unit tests).
4. Run `SyncUSB.bat` to copy to USB (including `PrepareUSB.vbs` and `Scripts\Prepare-BootableUSB.ps1`).

After sync, `SyncUSB.bat` removes **`CDE\Runtime\`** and any legacy root **`offline_env.txt`** / **`offline_progress.log`** (WinPE session state is runtime-only, not part of the payload).

`SyncUSB.bat` and `Prepare-BootableUSB.ps1` exclude development/editor-only paths from USB copy:

**Folders:** `Deploy`, `Mount`, `Logs`, `App`, `.git`, `.venv`, `.vscode`, `Tools\Deploy`, `Tools\.staging`

**Files (examples):** `*.md`, `CreateISO.vbs`, `Run-CustomizeWinPE.vbs`, `PrepareUSB.vbs`, `SyncUSB.bat`, `Customize-WinPE.ps1`, `Prepare-BootableUSB.ps1`, and other build-only scripts.

### USB Prep Troubleshooting

Use this section if `PrepareUSB.vbs` fails while partitioning or formatting a GPT USB.

1. Error: `The ACTIVE command can only be used on fixed MBR disks.`
  - Cause: MBR-only `active` command was used on GPT media.
  - Fixed behavior: `Prepare-BootableUSB.ps1` only runs `active` for MBR disks.

2. Error: `There is no volume selected. Please select a volume and try again.`
  - Cause: DiskPart did not have the new partition selected before `format`/`assign`.
  - Fixed behavior: diskpart script runs `format` before `assign`, with `select partition 1` after `create partition primary`.

3. Error: `Parameter set cannot be resolved using the specified named parameters` (Storage module) or diskpart exits immediately with `This disk is already online`.
  - Cause: invalid combined `Set-Disk -IsReadOnly -IsOffline` call; redundant `online disk` in diskpart.
  - Fixed behavior: diskpart is primary; Storage module uses separate `Set-Disk` calls only when needed.

4. Symptom: wanted to keep the USB's existing drive letter (e.g. `E:`) but script rejected it as "in use."
  - Fixed behavior: letters on the **target USB disk** may be reused; letters on other disks are still rejected.

5. Symptom: `SyncUSB.bat` appears to copy nothing, and USB keeps old prep behavior.
  - Verify `SOURCE:` in sync output is your Toolkit path on local disk, not removable media.
  - Confirm destination drive is the USB letter.
  - Current behavior: `SyncUSB.bat` now copies `PrepareUSB.vbs` and `Scripts\Prepare-BootableUSB.ps1` to USB (they are no longer excluded).

6. On GPT targets, BIOS boot sector is intentionally skipped.
  - Expected output: success message indicating `bootsect.exe` is skipped on GPT and UEFI boot path is used.

---

## UEFI Menu Architecture

The default UEFI boot path is now owned by rEFInd at `EFI\boot\bootx64.efi` with its active configuration at `EFI\boot\refind.conf`.

- `CDE WinPE` chainloads `EFI\Microsoft\Boot\bootmgfw.efi`, which uses the adjacent UEFI BCD to load `sources\boot.wim`.
- `Core Hardware Utility (CHU)` loads `EFI\CDE\CHUPrep.efi` from rEFInd, which chainloads `EFI\CDE\CoreDiag.efi`.
- `Windows Memory Diagnostic` launches `EFI\CDE\memtest.efi` directly from rEFInd.

`EFI\boot\icons\` is required for graphical rendering. If the icons directory is missing, rEFInd falls back to text-only mode.

> **Secure Boot must be DISABLED** for CHU because `CoreDiag.efi` is unsigned.

---

## WinPE Notes

- **PowerShell path in WinPE:** `X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`
- **CDE_ROOT detection:** `startnet.cmd` auto-detects the USB drive letter by searching for `autorun.inf` across all drive letters, then falls back to searching for `ToolkitGUI.exe`, then prompts manually.
- **Live BCD in WinPE:** When booting from USB, `HKLM\BCD00000000` is loaded from the USB BCD. The laptop's internal BCD is **not** the live BCD.
- **Rebooting from WinPE:** Use `wpeutil reboot` (not `shutdown /r /t 0`).
- **Offline-aware workflows:** When an offline Windows install is loaded, CDE binds `OFFLINE_WINDOWS_ROOT`, `HKLM\Offline_SOFTWARE`, `HKLM\Offline_SYSTEM`, `HKLM\Offline_SAM`, and offline user hives for workflows that support offline inspection.
- **Offline driver load fail-safe (2026-05-22):** `Scripts\Core\WinPE_OfflineStartup.ps1` now loads each matching DriverStore package via a timed `drvload` call (8s timeout). If a package hangs, times out, or returns non-zero, startup logs a warning and continues.
- **Known package blocklist:** To prevent a confirmed startup hang on some hardware, package folders matching `^mt7612us_` are skipped during offline driver loading.
- **Attach behavior on driver failures:** Offline OS attachment is not gated on every driver package succeeding. If registry hives load successfully, CDE still writes **`CDE\Runtime\offline_env.txt`** and continues with the attached offline session.
- **Session file location (2026-06-11):** Do not leave `offline_env.txt` at the USB root from older builds — use `CDE\Runtime\` only; `SyncUSB.bat` clears both.
- **Parity contract:** WinPE actions that depend on the live Windows session are now surfaced as `N/A` in the UI instead of presenting misleading runnable actions.
- **System Audit in WinPE:** Installed software, services, and event log audit paths can now read offline registry hives and offline `System.evtx` / `Application.evtx` data when available. *(Run these checks from **System Health Check** → **System Audit** category; standalone Maintenance System Audit removed 2026-06-19.)*

---

## USB BCD Entries

| Entry | Type | Path | Description |
|-------|------|------|-------------|
| `{bootmgr}` | Boot Manager | — | USB Windows Boot Manager; `displayorder` points to WinPE `{default}` |
| `{default}` | OSLOADER | `\sources\boot.wim` (ramdisk) | WinPE — main CDE boot entry |
| `{memdiag}` | WINDOWSMEMORYDIAGNOSTIC | `\efi\microsoft\boot\memtest.efi` | Retained in USB BCD; default UEFI menu uses rEFInd `EFI\CDE\memtest.efi` |

---

## Key Scripts Reference

| Script | Purpose | Requires Elevation |
|--------|---------|-------------------|
| `Customize-WinPE.ps1` | Build `boot.wim` | Yes (DISM) |
| `Prepare-BootableUSB.ps1` | Format and deploy USB | Yes |
| `Invoke-PreBootTool.ps1` | Legacy/manual pre-boot launcher helper | No |
| `CreateISO.ps1` | Generate bootable ISO | No |

---

## Backup & Imaging — Robocopy Backup

Backup & Imaging exposes a single workflow tool: **Robocopy Backup** (`BackupAndImage.ps1` → `RobocopyBackup`). Configure source/destination in `RobocopyConfigDialog` (dry-run preview uses robocopy `/L`).

**Notes:**

- Robocopy exit codes **0–7** are success; **1** commonly means files were copied.
- Paths with **spaces** and drive roots like **`E:\`** are normalized/quoted for both `powershell.exe` and `robocopy.exe` (see `PowerShellArgumentHelper.cs`, `Format-RobocopyPathArgument` in `BackupAndImage.ps1`).
- The former **VSS Shadow Copy** create/browse workflow was removed from this section; use **File Manager → Shadow Copies** to browse existing volume snapshots on full Windows.

---

## Startup Manager — Winlogon Reset / Undo

The **User logon** tab lists Winlogon values `Userinit` and `Shell` alongside Run keys and startup-folder items. Shared deviation logic lives in `Scripts/Core/StartupRisk.ps1`; actions are implemented in `Scripts/Workflows/StartupManager.ps1`.

| Value | Windows default |
|-------|-----------------|
| `Userinit` | `%SystemRoot%\system32\userinit.exe,` (trailing comma is normal) |
| `Shell` | `explorer.exe` |

**Deviation examples:** extra comma-separated components after `userinit.exe` (common malware persistence), or `Shell` not resolving to `explorer.exe`.

**UI behavior (ToolkitGUI):**

- Deviated rows use red text on NAME / RISK / PATH.
- **Userinit** and **Shell** show only **Reset** and **Undo** — Enable, Disable, and Delete are not rendered for these rows.
- **Reset** is available only when a deviation is detected; writes a backup JSON before applying the default.
- **Undo** is available after a reset while the registry still matches the default (restores `previousValue` from backup).

**Backup path:** `%ProgramData%\CDE\WinlogonBackups\Userinit.json` and `Shell.json`

> Run CDE elevated so Reset/Undo can write `HKLM`. Winlogon **reset/undo** in Startup Manager remains live-Windows oriented; **read/audit** paths (System Health Check **Startup Entry Audit**, formerly standalone System Audit / Malware Autoruns) use offline Winlogon when `OFFLINE_REGISTRY_LOADED=1`.

---

## Startup Manager — Disabled Entry Storage

The Startup Manager in ToolkitGUI disables startup folder shortcuts (e.g., from
`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup`) by moving them to an
external holding folder rather than deleting them, so they can be re-enabled later.

**Storage paths for disabled entries:**

| Source | Disabled path |
|--------|--------------|
| User Startup | `%LOCALAPPDATA%\CDE\DisabledStartup` |
| All Users Startup | `%ProgramData%\CDE\DisabledStartup` |
| Offline — per user | `<UserProfile>\AppData\Local\CDE\DisabledStartup` |
| Offline — all users | `<OfflineRoot>\ProgramData\CDE\DisabledStartup` |

> **Why not a subfolder of the Startup folder?**  
> Windows Shell opens any subfolder found inside the Startup folder as an Explorer window
> on every boot. Storing disabled entries inside `<StartupFolder>\CDE_AutorunsDisabled\`
> (the previous approach) caused an Explorer window to appear at every startup.
> The holding folder is intentionally placed outside the Startup folder tree.

**Migration behavior (hardened):** `StartupManager.ps1` now runs legacy migration on
every Startup Manager action (List/Enable/Disable/Delete), not only on first list load.
It moves all legacy items from `<StartupFolder>\CDE_AutorunsDisabled\` to the external
disabled store, resolves filename collisions safely, and then force-removes the legacy
folder recursively to prevent Explorer windows from opening at sign-in.

---

## Current Status (Beta)

- [x] WinPE boots from USB with full PowerShell 5.1 support
- [x] WPF WinPE boot menu hosted in `ToolkitGUI.exe` is operational (7 options; CST boot shortcuts removed 2026-06-22)
- [x] WinPE boot menu options **1** / **2** hand off to main CDE GUI; maximize/restore stable (opaque shell, 2026-07-03)
- [x] Settings **Clear Test & Scan Logs** — one-click cleanup of CHU `EFI\CoreDiag\Logs`/`Results`, CDE `Logs\` (PDFs), and `CDE\Runtime\Data\` (2026-06-22; expanded 2026-07-01)
- [x] Dashboard **Clear Recent** — removes work order case JSON from `CDE\Runtime\WorkOrders\` without deleting closed-case PDFs (2026-07-01)
- [x] PDF **User Guide** in `HALP\CDE_User_Guide.pdf`; **Settings → Open User Guide**; regenerated on canonical publish (2026-06-22)
- [x] System Audit has partial offline-aware parity in WinPE for installed software, services, and offline EVTX logs
- [x] OS Repair, Malware Cleanup, Bootloader Repair, and Fast Fixes now use explicit `N/A` gating for WinPE-inapplicable actions
- [x] Startup Manager disabled-entry storage moved outside Startup folder (2026-05-18)
- [x] Startup Manager legacy folder cleanup hardened to prevent Explorer auto-open at sign-in (2026-05-19)
- [x] Startup Manager now includes top category tabs (Services, Startup Apps, Drivers, User Logon, Extensions) with tab-aware actions (2026-05-29)
- [x] Startup Manager first-open non-maximized layout compression issue stabilized (2026-05-29)
- [x] Startup Manager Winlogon Userinit/Shell reset and undo with deviation styling; standard actions hidden on Winlogon rows (2026-06-05)
- [x] WinPE offline driver loading hardened with per-package timeout + non-blocking continuation (2026-05-22)
- [x] Temp File Cleaner supports dynamic drive-scoped discovery with user/profile-first grouping and cross-drive clean validation (2026-05-29)
- [x] Temp File Cleaner Workflow Execution structured results now include itemized per-folder cleanup details (2026-05-29)
- [x] ToolkitGUI .NET application is the primary WinPE front end
- [x] Diag & Repair — PC-Doctor-style CPU/Memory/Storage + CST ThreatScan/FullScan (scan-only, post-scan dialog); Quick/Extended; static Security Scan row with streaming path (2026-06-16; supersedes 2026-06-02 Hardware Diagnostics)
- [x] Post-Op Cleanup — eight tools incl. DNS/proxy reset, shell caches, hosts restore, restart Explorer; deduped from Fast Fixes/OS Repair (2026-06-26); browser cache, services (`wuauserv` = Automatic), file associations (2026-06-03; WU default fix 2026-06-16)
- [x] Startup Manager — scheduled tasks, StartupApproved parity, GPO Run, MSIX, correlation; `\Microsoft\*` tasks hidden by default (2026-06-26)
- [x] Startup Manager — MSIX manifest executable resolution + `Package (Publisher)` signature fallback; Process Analyzer Investigation toolbar status hidden (2026-06-30)
- [x] Hijack & Scam Repair — scan/repair workflow, detail panel, Quick Repairs drawer, HTML/PDF reports, Startup Manager integration (2026-06-30)
- [x] Fast Fixes — 14 verified fixes (DNS/icon/thumb moved to Post-Op 2026-06-26); per-fix verification, Pass/Fail workflow steps, PS 5.1 `Invoke-FixCommand` redirect fix (2026-06-10)
- [x] Banner uptime — `Uptime: Xd Xh Xm` (Event 12 / 6005 / WMI); System Audit retains boot source detail (2026-06-12)
- [x] Tools Library `cde_workflow` — Enable Offline Administrator (WinPE + offline SAM; publish 2026-06-10; USB sync pending)
- [x] WinPE offline session under `CDE\Runtime\`; Startup Manager Userinit/Shell visible after stale `offline_env.txt` fix (2026-06-11)
- [x] File Manager shadow copy browse (read-only); Backup & Imaging Robocopy path quoting (2026-06-11)
- [x] File Manager — empty Directories on open; drive/shadow-copy tree selection only; Computer auto-expand (2026-06-12)
- [x] System Audit — Startup Entry Audit with `[POSTOP:STARTUP]` structured results (relocated from Post-Op 2026-06-12)
- [x] Shadow copy browse — all snapshots per set, newest-first sort (2026-06-12)
- [x] Bootloader Repair — EFI targeting, backup pickers, shared common helpers hardened (2026-06-12)
- [x] Workflow PDF reports (QuestPDF) + **Open PDF**; de-elevated viewer launch; readable formatted results in GUI/PDF (2026-06-15)
- [x] System Health Check PDF — per-check catalog labels via `CheckId`; multi-page item cards repeat test name (2026-06-15)
- [x] System Health Check catalog trim — hardware/Diag & Repair, SMART analyzer, Defender, CST scan-only removed from picker; Update Hash IOCs in CST config dialog (2026-06-18)
- [x] File Manager — junction/reparse skip, custom context menus, checkbox multi-select (2026-06-23)
- [x] Prepare-BootableUSB — drive letter reuse, diskpart-primary partition, aligned USB copy exclusions (2026-06-23)
- [x] OS Repair DISM — optional install.wim source + 0x800f081f guidance (2026-06-23)
- [ ] ISO generation — pending
