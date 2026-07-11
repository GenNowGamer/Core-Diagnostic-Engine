# CDE Toolkit — Session Handoff

**Last updated:** 2026-07-11

## 2026-07-11 — EFI hash baseline gaps as coverage (not findings)

- **CST** — Empty/unresolved EFI hash allowlist no longer emits a Suspicious `BootHashPolicy` finding or warning count; message is in **Coverage** (`coverageReason`). Signer-only boot checks still run.
- **Effect** — Clean FullScans should not show “Review — 1 warning” solely for unconfigured EFI hash baselines.
- **Publish** — `App\Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe` (CST runtime sync). Canonical publish **7/11/2026 ~4:11 PM** (`CDE.exe`).

## 2026-07-10 — CST Scan Results UX + detection hardening + archive remediation

- **Results UI** — File Manager / Startup Manager / Malware Cleanup / Process Analyzer share **CST Scan Results** (live progress → findings). Remediation (**Quarantine / Remove / Restore**) is in that window; separate post-scan operator dialog is no longer auto-opened after Malware Cleanup CST.
- **Horizontal scroll** — Findings grid uses an outer horizontal `ScrollViewer` with fixed column widths. App-wide `ScrollBar` style clears forced `Width=12` for **horizontal** bars (was collapsing to a tiny button).
- **Verdict / coverage** — Mode labels in verdict/action text (ThreatScan vs FullScan vs CustomScan); coverage notes surface Partial / known-good skips / trusted-signer exits.
- **Archive findings** — Inner `zip::entry` rows stay review-only; CST also emits an actionable **parent archive** `File` finding so techs can Quarantine/Remove the `.zip`/`.jar`. UI notes explain the path.
- **CST engine (synced)** — ThreatScan includes DLLs + light archive peek; Authenticode timeouts emit Low/Unknown (not silence); trusted-signer early exit narrowed to Microsoft-family + cheap spot-check on known-good/trusted skips; stronger correlation promote; empty EFI hash baselines → signer-only + coverage note (see 2026-07-11). See CST `CST\session_handoff.md`.
- **Publish** — `App\Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe` (GUI + CST runtime sync). Latest GUI payload this session ~**2:54 PM**; 2026-07-11 coverage-note publish ~**4:11 PM**.

## 2026-07-10 — Startup Manager CST StartupEntryScan

- **Scan with CST** (context menu) now runs `StartupEntryCstScan`: multi-target file CustomScan, command-line LOLBin analysis, synthetic persistence artifact correlation, and Startup Manager risk context.
- **UI** — CST result dialog shows **File / Command line / Persistence** verdicts for startup-entry scans.
- **CST** — `Cst.StartupEntryScan.ps1` / `Invoke-CstStartupEntryScan`; synced by publish.
- **Publish** — `App\Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe` (GUI payload).

## 2026-07-10 — Diag & Repair: stuck Running rows + CST PDF button

- **Stuck Running** — Non-ASCII detail text (e.g. em-dash in Memory Coverage Warn) could corrupt live `[HW:TEST]` JSON under console capture so the GUI never saw completion. `Write-HwTestResult` in `HardwareCommon.ps1` now ASCII-sanitizes detail; end-of-run `FinalizeStuckHardwareTests` in `DiagAndRepairViewModel` reconciles any remaining Queued/Running rows from the workflow JSON.
- **CST PDF** — Malware Cleanup / Diag & Repair expander button is **Open full CST report (PDF)** → `OpenPdfReportAsync()` (not the JSON artifact).
- **Publish** — GUI + script changes need `App\Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`.

## 2026-07-10 — CST CIRCL online reputation (live Windows)

- **Behavior** — CST CIRCL Hashlookup is on for **ThreatScan / FullScan / CustomScan** when not WinPE and not `OfflineOnly` (Malware Cleanup + Diag & Repair Quick/Extended on live Windows with network).
- **WinPE** — `Invoke-CoreSecurityTool` still sets `OfflineOnly`; CIRCL stays inactive offline.
- **FP reduction** — CIRCL known-good suppresses weak content findings only; Hash IOC matches are unchanged.
- **Source** — Core Security Tool `CoreSecurityTool.psm1` + `rules/rules.json`; synced by canonical publish (no `goodware.db` on USB).

## 2026-07-10 — Memory Coverage Check removed from Diag & Repair tree

- **Tree** — `mem_coverage` removed from CHU/CDE hardware catalog (Memory now 10 pattern tests).
- **Guidance** — `Set-HwMemoryCoverageGuidance` still sets `HwMemoryCoverageIncomplete` when Windows sample is below 15%/20%, so `[HW:GUIDANCE]` / CHU banner still fires.
- **Catalog** — 29 tests total (CPU 13 / Memory 10 / Drive 6).

## 2026-07-10 — Diag & Repair hardware detection hardening

- **Warn plumbing** — `Invoke-SingleTest` now maps `Warn:` results to step/GUI **Warn** (previously stripped prefix and showed Pass). Live HW:TEST refresh includes Warn.
- **SMART** — Attribute/overall Warn returns `Warn:` instead of soft-pass `Passed: … warning…` (`HardwareSmartEngine.ps1`).
- **Storage elevation** — `HardwareDiagnostics.ps1` elevates for Storage/All (UAC cancel continues with Warn). Access-denied / missing physical path → **Warn**, not Skipped.
- **CPU timed stress** — Catalog `cpu_stress` + `HardwareTestEngine.RunCpuStressTest()` using profile `cpuStressSeconds` (Quick 20s / Extended 120s).
- **NVMe short DST** — `CdeSmartReader.RunNvmeShortSelfTest` via `IOCTL_STORAGE_PROTOCOL_COMMAND` + log page 0x06 poll (MS NVMe pass-through); unsupported → Skipped/Warn, not false Pass.
- **Extended depth** — Higher Extended memory/storage knobs; mid-disk linear sample on Extended; low Windows memory coverage sets CHU guidance (`memory_coverage`) without a separate tree row.
- **CHU guidance** — `[HW:GUIDANCE]` + Diag & Repair banner / Open CHU Results when coverage/stress/elevation incomplete.
- **Catalog** — Source updated in CHU `Core_Hardware_Utility.json` (29 tests: CPU 13 / Memory 10 / Drive 6); synced to CDE. Memory coverage is CHU-guidance only (no tree row).
- **Publish** — `App\Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`.

## 2026-07-09 — Temp File Cleaner: locked/unavailable files no longer warn

- **Behavior** — Files that cannot be deleted because they are **in use**, **locked**, or return **access denied** (common for `VBCSCompiler` / Roslyn analyzer DLLs while Cursor or `dotnet build` is active) are counted as **skipped**, not failures. Cleanup reports **Pass** / **Workflow completed successfully** when only these expected skips occur.
- **Still warns** — Genuine delete failures (other I/O errors, unexpected exceptions) continue to surface as **Warn** with `[WARN]` log lines.
- **Reporting** — Summary output includes `In-use: N` and per-folder `N skipped (in use).` for transparency without downgrading overall health.
- **Implementation** — `Scripts\Workflows\TempFileCleaner.ps1`: `Test-IsUnavailableForDeletionException`, `Register-RemovalFailure` (classifies sharing violation, lock violation, access denied, `UnauthorizedAccessException`).
- **User guide** — `Docs\UserGuide\07_Maintenance_Utilities.md` (Temp File Cleaner section).
- **Publish** — PowerShell-only change; no GUI rebuild required for dev toolkit (`Toolkit\Scripts\`). Run `App\Publish-ToolkitGUI.ps1` before USB sync if deploying to removable media.

## 2026-07-07 — BenchLab safe-only scenario pack + SSE3 SIMD fix

- **BenchLab automation** — Added `Scripts\BenchLab\Invoke-CdeBenchScenarioPack.ps1` for safe-only inject/cleanup across 24 scenarios plus docs under `Docs\BenchLab\` (`CDE_Malware_Simulation_Matrix.md`, `CDE_Safe_Injection_Recipes.md`, `CDE_Scenario_Automation_QuickStart.md`, `CDE_Release_Gate_Metrics.md`, `CDE_Bench_TestCase_Sheet.csv`). The built-in pack is intentionally AV-safe: inert markers, config drift, persistence artifacts, offline hive/task cases, and boot fixtures only.
- **Bench gate** — Added `Scripts\Tests\Invoke-CdeBenchGate.ps1` to score completed CSV runs and return PASS/FAIL for workflow/remediation/stability gating.
- **SIMD fix** — `Scripts\Core\CpuSimdEngine.cs` `RunSse3Test()` corrected to use deterministic inputs and valid `Sse3.AddSubtract` expectations; isolated single-row SSE3 failures in pre-fix builds were likely false fails rather than hardware defects.
- **Regression** — `Scripts\Tests\Test-CpuSimdEnginePs5.ps1` now validates both SSE2 and SSE3 when `CdeCpuSimdCli.exe` is active.

Operator notes:
1. Use `Scripts\BenchLab\Invoke-CdeBenchScenarioPack.ps1 -Action List` to view the shipped scenario pack.
2. Treat the built-in BenchLab pack as workflow/remediation/offline/fixture validation, not as a standalone malware-recall corpus.
3. Use `App\Publish-ToolkitGUI.ps1` after SIMD or BenchLab changes; use `App\Publish-ToolkitGUI-FullVerify.ps1` for full validation sign-off.

## 2026-07-07 — publish flow split + CST post-scan dialog scroll fix

- **Publish workflow split:** `App\Publish-ToolkitGUI.ps1` is now compile/sync publish only (no automatic full verification gate).
- **Full validation wrapper:** `App\Publish-ToolkitGUI-FullVerify.ps1` now runs publish plus the full verification pipeline (`Publish-Verify-Toolkit.ps1`).
- **Build orchestrator alignment:** `App\Build-CDE-Toolkit.ps1` now calls compile-only publish and keeps verification control in its own `-SkipVerify` gate logic.
- **CST operator UI:** `App\ToolkitGUI\Views\CstFindingsOperatorDialog.xaml` updated to ensure the post-scan findings grid supports horizontal scrolling for long `Location`/`Evidence` rows.

Operational guidance:
1. Use `App\Publish-ToolkitGUI.ps1` for normal iteration.
2. Use `App\Publish-ToolkitGUI-FullVerify.ps1` before release/regression sign-off.
3. Keep `SyncUSB.bat` as the final deployment step for USB media.

## 2026-07-06 — canonical publish verification completed

- Canonical publish executed: `App\Publish-ToolkitGUI.ps1`.
- Verification outcome: PASS.
- Verification report: `CDE\Runtime\Data\publish_verify_20260706_192515.json`.
- Included checks passed:
  - `ValidateTools` summary pass,
  - CST release gates pass (all gates),
  - CHU EFI manifest hash pass,
  - `CdeCpuSimdCli` payload pass,
  - `ToolkitGUI.Tests` unit tests pass.
- Persistent workflow rule: for relevant CDE/CST/CHU code changes, run `App\Publish-ToolkitGUI.ps1` before `SyncUSB.bat` to ensure USB payload includes latest runtime artifacts.

---

## 2026-07-06 — CHU display backends, CHUPrep, logging, results scroll (field-verified)

Cross-repo work in **Core Hardware Utility** (`CoreDiag.efi`, `CHUPrep.efi`). CDE integration: `EFI\boot\refind.conf`, `EFI\CDE\` staging via `BUILD_CHU_UEFI.ps1`.

| Area | Change |
|------|--------|
| **Boot chain** | rEFInd **CHU** entry → `EFI\CDE\CHUPrep.efi` → `\EFI\CDE\CoreDiag.efi`. `CHUPrep.c`: graphics mode, GOP refresh, ConOut reset before chainload. |
| **Display policy** | `UiConsole.c` — default **PC-Check text** (`UiPcCheck.c`). **GOP fallback** when Console Control stuck in graphics, or portable chassis + GOP + `UiProbeFramebufferReflectsConOut` says text invisible (fail-closed on portable). |
| **Field status** | HP desktop: PC-Check menu/tests, full results scroll after Run All. Samsung laptop: GOP menu/tests (blank blue fixed). |
| **Logging** | `CoreDiag.c` opens log before UI init; `Logging.c` flushes after each write. |
| **Scroll fix** | `UiTestTree.c` — `ViewportRowCount()`, `ClampScrollTop()`, `TextFooterSepLine()` aligned to real viewport (~12 text rows on 80×25). |
| **Deploy** | `BUILD_CHU_UEFI.ps1 -CdeManifestPath …\tools_manifest.json` → **`SyncUSB.bat`**. No `Publish-ToolkitGUI.ps1` unless CDE GUI changed. |

**Staged artifact:** `EFI\CDE\CoreDiag.efi` — SHA256 `EBC5D75F8687C3A1F9822B02B7B3877A992054DE5F6DD21250A70E32D732E35A`, 281 600 bytes. Also staged: `CHUPrep.efi`, `CDEBoot.efi`.

**Key files (CHU source):** `UiConsole.c`, `Ui.c`, `UiPcCheck.c`, `UiTestTree.c`, `CHUPrep.c`, `CoreDiag.c`, `Logging.c`, `BUILD_CHU_UEFI.ps1`.

**User guide:** `Docs/UserGuide/04_Diagnostics.md` (CHU boot path, display modes, scroll).

---

## 2026-07-03 — WinPE shell handoff + maximize stability (field-verified)

| Symptom | Cause | Fix |
|---------|--------|-----|
| Boot menu options **1** / **2** exit to `startnet.cmd` recovery text menu (no main CDE GUI) | `MainWindow` used `AllowsTransparency` / layered chrome; WinPE has no DWM — shell failed or exited after boot menu closed | WinPE-only opaque shell: configure chrome **before** `InitializeComponent()`; software render; `SingleBorderWindow`; defer `MainViewModel` until `ContentRendered` |
| Maximize / restore crashes back to recovery menu | Startup set `_isPseudoMaximized` without saving `_restoreBounds`; restore applied **0×0** | Save default restore rect before fill-work-area; validate sizes; intercept `WindowState.Maximized` in WinPE |

| File | Change |
|------|--------|
| `App/ToolkitGUI/MainWindow.xaml` | Removed XAML `AllowsTransparency` / transparent background (set in code per environment) |
| `App/ToolkitGUI/MainWindow.xaml.cs` | `ConfigureShellChromeForEnvironment()`, `ApplyWinPeShellDecorations()`, deferred shell init, safe `ToggleMaximize` / restore bounds, `OnWinPeWindowStateChanged` |
| `App/ToolkitGUI/App.xaml.cs` | WinPE stays on `OnExplicitShutdown`; `RenderMode.SoftwareOnly`; startup breadcrumb logging; `MainWindow.Closed` → explicit shutdown |
| `App/ToolkitGUI/Services/BorderlessWindowHelper.cs` | `GetSafeWorkAreaDips()`, guarded `FillWorkArea()` (no zero/NaN sizes) |
| `App/ToolkitGUI/Services/WinPeStartupLog.cs` | **New** — `CDE\Runtime\winpe_startup.log` (+ `X:\winpe_startup.log`) boot handoff trace |
| `App/ToolkitGUI/ViewModels/PowerShellService.cs` | WinPE banner: skip `PerformanceCounter` CPU + in-process SMART query |
| `App/ToolkitGUI/ViewModels/MainViewModel.cs` | Dashboard / work-order init wrapped so shell construction cannot fail silently |
| `App/ToolkitGUI/Services/WorkOrderService.cs` | WinPE-safe `GetActiveWorkOrder` / `ApplyActiveCaseToProcess` |

**Operator notes**

- Options **1** and **2** stay in-process: boot menu closes → offline splash (option 2 only) → `MainWindow`. No second `ToolkitGUI.exe` launch.
- GUI-only fix: **`App/Publish-ToolkitGUI.ps1`** then **`SyncUSB.bat`** (or copy `CDE\ToolkitGUI\bin\Release\net8.0-windows\`). No `Customize-WinPE.ps1` / `boot.wim` rebuild required unless `startnet.cmd` itself changed.
- If WinPE shell fails again, read **`CDE\Runtime\winpe_startup.log`** on the USB (last line = last successful step). **`toolkit_crash.log`** on Desktop or under `CDE\Runtime\` for unhandled exceptions.
- **Field status (2026-07-03):** Options 1–2 launch main GUI; maximize/restore stable on WinPE.
- **User guide** — `Docs/UserGuide/02_Getting_Started.md`, `10_Reference.md` updated (regenerate PDF on next canonical publish).

---

| Change | Detail |
|--------|--------|
| Project | `App/CdeCpuSimdCli/` — .NET 8 console; `probe` → `{"isStubEngine":false}`; `run Sse2` etc. exit 0/1 |
| Loader | `Scripts/Core/HardwareTestEngine.ps1` — on PS 5.1, prefers `CdeCpuSimdCli.exe` beside published `ToolkitGUI.exe`; Add-Type compat/stub fallback |
| Workflows | `Scripts/Workflows/HardwareCpuTests.ps1` via `Invoke-CpuSimdEngineTest` |
| Publish | `Publish-ToolkitGUI.ps1` copies **self-contained** `CdeCpuSimdCli.exe` into GUI payload (framework-dependent failed on USB without shared runtime) |
| Regression | `Scripts/Tests/Test-CpuSimdEnginePs5.ps1` in suite |
| Child env | `PowerShellService.cs` always sets `TOOLKIT_ROOT` on workflow child processes |
| User guide | `Docs/UserGuide/04_Diagnostics.md`, `10_Reference.md` |

---

## 2026-07-03 — CST remediation + Diag & Repair CST status

| Change | Detail |
|--------|--------|
| Remediation path | `Services/CstRemediationService.cs` — `ResolveCoreSecurityToolPath()` safe when `TOOLKIT_ROOT` is USB drive root (`G:\`) |
| CST row N/A | `ViewModels/WorkflowViewModels.cs` — `FinalizeCstTestFromReport` / `LooksLikeCstNoTargetResult()`; Warn → **Warn** label/brush (not Skipped → N/A) |
| Field note | Defender `UpdatePlatform.exe` access denied during remediation is expected OS protection, not a CDE bug |

---

## 2026-07-03 — GitHub source repository (slim history)

| Change | Detail |
|--------|--------|
| Remote | `https://github.com/GenNowGamer/Core-Diagnostic-Engine` (private) |
| Layout | Single repo — removed nested `Toolkit/.git`; all toolkit source under `Toolkit/` |
| Excluded | Root `.gitignore`: `sources/boot.wim`, `Deploy/`, `Mount/`, `*.iso`, `memtest86-usb.img`, `CDE.exe`, `CDE/Runtime/`, `bin/`/`obj/`, Firefox payload, etc. |
| Clone workflow | `git clone` → `App/Publish-ToolkitGUI.ps1` → acquire large tools per `Tools/PLACEHOLDER_ACQUISITION.md` → `Customize-WinPE.ps1` + `SyncUSB.bat` for USB |
| Push size | ~50 MB (was ~2.9 GB before history rewrite) |
| Docs | `README.md` (Source repository), `Tools/PLACEHOLDER_ACQUISITION.md`, `Docs/DEVELOPER_QUALITY.md` |

---

## 2026-07-01 — Removable media excluded from hardware testing

| Change | Detail |
|--------|--------|
| Policy | USB flash, memory cards, and toolkit boot USB are not hardware-tested in Diag & Repair, S.M.A.R.T. Analyzer, or CHU storage runs |
| CDE module | `Scripts/Core/PhysicalDiskCatalog.psm1` — `Test-CdeIsRemovableMediaDisk`, `Get-CdeTestablePhysicalDisks` (WMI `MediaType` + `Get-Disk.IsRemovable`) |
| Workflows | `Get-HwPhysicalDisks` delegates to catalog; `Get-CdeSmartDrives` filters SMART probe indices |
| GUI | `Services/PhysicalDiskCatalogHelper.cs` — `GetTestableDriveSlots()` for Diag & Repair tree/progress |
| Zero drives | Unchanged **Fail** semantics when no fixed testable disks remain |
| CHU | `StorageDrive.c` skips `RemovableMedia` at slot enumeration; `RunStorageDiscoveryFailure` when count is 0 |
| Tests | `Test-PhysicalDiskCatalog.ps1` in `Invoke-CdeRegressionSuite.ps1` |
| User guide | `Docs/UserGuide/04_Diagnostics.md`, `10_Reference.md` |
| Publish | `App/Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`; CHU `EFI\CDE\CoreDiag.efi` rebuilt and staged |

**Out of scope:** Disk & Boot Repair (`Get-CdeDiskLayout`), System Health disk inventory, CST boot-sector checks.

---

## 2026-07-01 — Dashboard Clear Recent (work order cleanup split)

| Change | Detail |
|--------|--------|
| Settings clear | **Clear Test & Scan Logs** no longer deletes `CDE\Runtime\WorkOrders\` |
| Dashboard | **Recent work orders → Clear Recent** deletes canonical case JSON in `CDE\Runtime\WorkOrders\` (confirmation); closed-case PDFs in `WorkOrders\` preserved |
| Active pointer | If the open case file is removed, `active_work_order.json` is cleared and Dashboard refreshes |
| Service | `WorkOrderService.ClearRecentInternalWorkOrderRecords()` |
| UI | `DashboardView.xaml` — **Clear Recent** button; `SettingsView.xaml` helper text updated |
| User guide | Chapters 02, 03, 08, 09, 10 |

---

## 2026-07-01 — Work order path split (Runtime JSON / WorkOrders PDF)

| Change | Detail |
|--------|--------|
| Internal JSON | Open and closed case records: `CDE\Runtime\WorkOrders\{CaseId}.json` |
| Operator PDF | Close export: `WorkOrders\{CaseId}.pdf` only (no `_Final_` HTML/JSON in `WorkOrders`) |
| Legacy | Existing `WorkOrders\{CaseId}.json` still read for open/closed cases until migrated |
| PDF service | `WorkOrderReportPdfService` (QuestPDF); PS `Close-WorkOrder` loads `ToolkitGUI.dll` via reflection |
| Clear case JSON | **Dashboard → Clear Recent** (not Settings clear logs) |

---

## 2026-07-01 — Report policy, Dashboard suggested path, symptom keyword inference

| Change | Detail |
|--------|--------|
| Report paths | `ReportPathHelper.cs` — operator PDFs in `Logs\` only; internal JSON under `CDE\Runtime\Data\workflows`, `scans`, `cst`; session `.log` under `CDE\Runtime\Data\sessions` (`Initialize-SessionLog` in `Toolkit.Core.psm1`) |
| GUI reports | Unified **Open Report** (PDF); removed Open HTML, Open PDF, Save report across System Health, Hijack, Process Analyzer, workflow window, case timeline, work order detail |
| Clear logs | `ResultLogCleanupService` clears `Logs\`, `CDE\Runtime\Data\`, and CHU `EFI\CoreDiag\` folders |
| Dashboard | **Verify case** removed; **What are you seeing?** highlights **suggested path** on **Generate Work Order** via `DashboardGuidanceHelper.InferSymptomFlowFromNotes` (keyword + summary scoring) |
| Symptom config | `Config/SymptomFlows.json` — optional `keywords` array per flow (`slow_pc`, `suspected_malware`, `tech_support_scam`, `network_issues`, `wont_boot`) |
| Work orders | `GuidanceContext` (`LastSymptomId`, `LastHealthPreset`) written on generate; re-inferred on **Save** unless tech explicitly clicked a symptom chip (`_symptomExplicitlyChosen`) |
| Case timeline | Light-theme cards (`BackgroundMidBrush` / `TextPrimaryBrush`) for readability |
| Hijack detail panel | Removed redundant **Toggle FIX** and **Copy** (grid + **Select repairable** unchanged) |
| User guide | `Docs/UserGuide/` chapters 02–05, 07–10 updated |
| Publish | `App/Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe` |

---

## 2026-06-30 — Hijack & Scam Repair UI + HTML/PDF reports

### Hijack & Scam Repair — scanner UX (HiJackThis-inspired)

| Change | Detail |
|--------|--------|
| Detail panel | Process Analyzer-style bottom pane (location, value, repair action, guidance); grid slimmed to FIX / ACTION / CATEGORY / RISK / NAME |
| Actions | **Fix here** (auto-repair), **Startup Manager** (review-only startup rows), **Info only**; **Select repairable** checks all flagged + repairable (includes Suspicious Defender RTP) |
| Quick Repairs | Left sidebar removed; bottom **Quick Repairs** drawer expands upward (browser / network / security / repair-all bulk scripts) |
| Scan persistence | `MainViewModel` caches `HijackRepairView` (same session VM); navigate to Startup Manager and back without losing results |
| Re-Scan label | Scan button becomes **Re-Scan** after first completed scan |
| Loading UX | Top-right progress bar removed; findings grid shows Startup Manager-style centered **Scanning...** overlay + blue status text in toolbar |
| Reports | **Open Report** (PDF) via `TabularScanReportService`; PDF written to `Logs\` on scan complete (internal JSON under `CDE\Runtime\Data\scans\`) |
| Startup integration | **Manage** + **Startup Manager** toolbar; Startup Manager **Suspicious only** filter + `IsHijackSuspicious` heuristics shared with scan |

### HTML/PDF reports (cross-tool)

> **Superseded 2026-07-01:** All tools now use **Open Report** (PDF in `Logs\` only). Internal JSON under `CDE\Runtime\Data\`. See 2026-07-01 section.

| Tool | Report buttons (2026-06-30) |
|------|----------------|
| **Hijack & Scam Repair** | Open HTML / Open PDF / Save report (findings table) |
| **System Health Check** | Open HTML + Open PDF on results screen |
| **Process Analyzer** | Open HTML / Open PDF / Save report (filtered process snapshot) |
| **Workflow execution window** | Open HTML Report + Open PDF Report in Artifacts |

`WorkflowViewModelBase.OpenHtmlReportAsync()` added; workflow scripts continue emitting `HTML report saved:` / `Report saved:` lines (`HijackRepair.ps1` now uses `-IncludeHtml`).

### Key files

| Area | Path |
|------|------|
| GUI view | `App/ToolkitGUI/Views/HijackRepairView.xaml` |
| ViewModel | `App/ToolkitGUI/ViewModels/WorkflowViewModels.cs` (`HijackRepairViewModel`) |
| Report service | `App/ToolkitGUI/Services/TabularScanReportService.cs` |
| Scan/findings PS | `Scripts/Core/HijackRepairFindings.ps1`, `HijackRepairHelpers.ps1`, `HijackRepairChecks.ps1` |
| Workflow | `Scripts/Workflows/HijackRepair.ps1` |
| Startup shared | `Scripts/Core/StartupRisk.ps1`, `Scripts/Workflows/StartupManager.ps1` |
| Navigation cache | `App/ToolkitGUI/ViewModels/MainViewModel.cs` (`_hijackRepairView`) |
| User guide | `Docs/UserGuide/05_Security.md`, `07_Maintenance_Utilities.md`, `09_Understanding_Reports.md`, `03_Recommended_Workflow.md`, `10_Reference.md` |

### Publish

- `App/Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe` (GUI payload 2026-06-30).

---

## 2026-06-30 — MSIX startup executable resolution + Process Analyzer Investigation UI

### Startup Manager — MSIX path resolver (#1) + package signature display (#2)

| Change | Detail |
|--------|--------|
| Manifest resolver | `MsixStartup.ps1` — `Get-MsixManifestStartupTaskBindings`, `Resolve-MsixStartupExecutablePath` match registry task folder names to `windows.startupTask` `TaskId` in `Get-AppxPackageManifest`; desktop bridge uses extension `Executable`, UWP falls back to `Application` executable |
| Row paths | `Get-MsixStartupTaskRows` sets `FilePath` / `AnalysisFilePath` to resolved `.exe` (not bare `InstallLocation` folder); passes `MsixTaskId` for signing |
| Signature / analysis | `Get-MsixStartupSignatureInfo`, `Get-MsixStartupAnalysisInfo` — Authenticode when file is accessible; else `Package (Publisher)` with `SignatureStatus=PackagePublisher` and OK analysis (no false “file not found” on MSIX rows) |
| Startup Manager wiring | `StartupManager.ps1` `New-StartupRow` — dedicated `MsixStartupTask` branch (not generic `Get-FileSignatureInfo` on folder path) |
| Post-Op audit | `StartupRisk.ps1` `Get-PostOpStartupEntries` MSIX loop uses MSIX resolver + signature helpers |
| GUI | `StartupManagerView.xaml` — blue **Signed** styling for `PackagePublisher` |
| Tests | `Test-MsixStartupTasks.ps1` — 23 tests (Join path, package fallback, Teams `TeamsTfwStartupTask` → `msteams_autostarter.exe`, Copilot manifest fallback when installed) |
| User guide | `Docs/UserGuide/07_Maintenance_Utilities.md` — MSIX signing column behavior; Process Analyzer Investigation toolbar |

**Reference:** [Get-AppxPackageManifest](https://learn.microsoft.com/en-us/powershell/module/appx/get-appxpackagemanifest), [uap5:StartupTask](https://learn.microsoft.com/en-us/uwp/schemas/appxpackage/uapmanifestschema/element-uap5-startuptask).

### Process Analyzer — Investigation toolbar

| Change | Detail |
|--------|--------|
| Status line | Blue toolbar status text hidden while **Investigation ON** (`ProcessAnalyzerView.xaml` + `InverseBooleanToVisibilityConverter`) |
| Status messages | `ProcessAnalyzerViewModel.UpdateStatusText` no longer prefixes `Investigation active (3s refresh)`; loading always `Loading processes...` |
| Rationale | Long status string overlapped Tree view / Deep scan checkboxes; button label already shows investigation state |

### Key files

| Area | Path |
|------|------|
| MSIX core | `Scripts/Core/MsixStartup.ps1` |
| Startup workflow | `Scripts/Workflows/StartupManager.ps1` |
| Post-Op MSIX audit | `Scripts/Core/StartupRisk.ps1` |
| Process Analyzer | `App/ToolkitGUI/ViewModels/ProcessAnalyzerViewModel.cs`, `Views/ProcessAnalyzerView.xaml` |
| Tests | `Scripts/Tests/Test-MsixStartupTasks.ps1` |

### Publish

- `App/Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe` (GUI payload 2026-06-30).

---

## 2026-06-26 — Startup Manager depth + Post-Op expansion

### Startup Manager — Task Manager parity + persistence coverage

| Change | Detail |
|--------|--------|
| Scheduled tasks | `StartupScheduledTask.ps1` — logon/boot/registration/session triggers; enable/disable via Task Scheduler; **SOURCE** / **RELATED** columns in GUI |
| StartupApproved | `StartupApproved.ps1` — Run keys + startup folder enable/disable synced with Task Manager hive |
| GPO Run keys | `Policies\Explorer\Run` listed and managed like standard Run keys |
| Correlation | `StartupCorrelation.ps1` — duplicate persistence across mechanisms (`CorrelationGroupId`, tooltip) |
| MSIX + audit | `StartupRisk.ps1` — MSIX startup tasks in `Get-PostOpStartupEntries`; `audit_startup` includes MSIX |
| Microsoft task filter | `\Microsoft\*` scheduled tasks **hidden by default**; checkbox *Include Windows scheduled tasks*; when shown, read-only (no enable/disable) |
| GUI | `StartupManagerView.xaml` — SOURCE, RELATED columns; scheduled-task filter checkbox |
| Tests | `Test-StartupManagerCoverage.ps1`, `Test-MsixStartupTasks.ps1` in `Invoke-CdeRegressionSuite.ps1` |

### Post-Op Cleanup — five new tools (deduped elsewhere)

| Tool | Script | Notes |
|------|--------|-------|
| Icon + Thumbnail Cache Clear | `PostOpCleanup.ps1` | Shared helpers; was in Fast Fixes |
| DNS Cache Flush | `PostOpCleanup.ps1` | Was in Fast Fixes |
| Reset Proxy Settings | `PostOpCleanup.ps1` | User Internet proxy + WinHTTP |
| Restore Hosts File | `PostOpCleanup.ps1` | Backup + confirmation (`-ConfirmHostsRestore`); audit remains in System Health Check `sec_hosts` |
| Restart Explorer | `PostOpCleanup.ps1` | Apply shell/cache fixes without reboot |

- **`Scripts/Workflows/PostOp.ps1`** — eight GUI tools; **Run All** runs all except hosts restore (confirmation required).
- **Removed duplicates:** `FastFixes.ps1` — `FlushDns`, `ClearIconCache`, `ClearThumbCache`; `OSRepair.ps1` — `ipconfig /flushdns` removed from Network Reset bundle.
- **GUI:** `PostOpViewModel` — five new tools; hosts restore uses Yes/No `MessageBox` before `-ConfirmHostsRestore`.
- **Tests:** `Test-PostOpCleanup.ps1` (13/13) in regression suite.
- **Publish:** `App/Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`.

### Key files

| Area | Path |
|------|------|
| Startup core | `Scripts/Core/StartupApproved.ps1`, `StartupScheduledTask.ps1`, `StartupCorrelation.ps1`, `StartupRisk.ps1` |
| Post-Op core | `Scripts/Core/PostOpCleanup.ps1` |
| Workflows | `Scripts/Workflows/StartupManager.ps1`, `PostOp.ps1` |
| User guide | `Docs/UserGuide/07_Maintenance_Utilities.md`, `05_Security.md`, `10_Reference.md` |

---

## 2026-06-26 — Phase 3 diagnostic depth

| Change | Detail |
|--------|--------|
| CHU parity | Extended `Test-HardwareTestCatalogSync.ps1` (per-id/profile/UEFI/order); CHU Results rollup + Diag & Repair highlight links |
| CST transparency | Tiered findings: actionable default unchanged; expandable all-findings + scan metadata in workflow execution window |
| Verification | Dashboard **suggested path** highlights symptom from notes or `GuidanceContext`; click card to open matching health preset (replaces **Verify case**) |
| Case timeline | Broad event recording (workflows, CHU pre-boot, Process Analyzer CST); Dashboard timeline card + work order detail labels |
| Work order schema | Optional `EventKind`, `DisplayLabel`, `SourceArtifact`, `GuidanceContext`; `ReportHtml` populated from workflow runs |
| Regression | New tiers: `Test-HardwareTestCatalogSync.ps1`, `Test-WorkOrderCaseEvents.ps1`, `Test-CstStructuredResults.ps1` in `Invoke-CdeRegressionSuite.ps1` |
| Publish | `App/Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe` (2026-06-26) |

### Work-order recording fix (same day)

| Issue | Fix |
|-------|-----|
| Temp File Cleaner (and any workflow with active work order) exited **code 1** after successful clean | `Add-WorkOrderRun` dedupe used broken PowerShell precedence (`$ReportJsonPath -and @($Runs) \| Where-Object …`), causing **ReportJson property not found** on `$true`. Fixed with explicit loop + safe property read (same class of bug as `Add-WorkOrderCaseEvent` dedupe). |
| Test | `Test-WorkOrderCaseEvents.ps1` now covers `Add-WorkOrderRun -ReportJsonPath` dedupe |

---

## 2026-06-26 — Phase 2 presentation (Dashboard guidance + reports + splash)

| Change | Detail |
|--------|--------|
| Dashboard | Recommended workflow strip, environment tip, four symptom cards (`slow_pc`, `suspected_malware`, `network_issues`, `wont_boot`) with follow-up navigation; symptom presets are **Dashboard-only** |
| Symptom config | `Config/SymptomFlows.json` + `Test-SymptomFlowsCatalog.ps1`; optional `keywords` per flow for note inference (2026-07-01); catalog presets for symptom health bundles |
| System Health nav | `NavigationService.Request("SystemHealth", "preset:{name}")` applies catalog preset without auto-run |
| Case deliverable | Close work order on Dashboard to generate the case PDF from attached workflow runs |
| Startup splash | Branded 2s splash on **Windows** launch (`StartupSplashWindow`); WinPE boot menu / offline splash unchanged |

---

## 2026-06-26 — Phase 1 consistency (single health hub)

| Change | Detail |
|--------|--------|
| Health hub | **System Health Check** is the only health diagnostic path; `QuickHealth.ps1` and `DeepDiagnostics.ps1` removed |
| Catalog presets | Added `quick_vitals` and `deep_system` presets; GUI picker buttons **Quick Vitals**, **Deep System**, **Full Audit** |
| Legacy checks dropped | `environment`, `disk_smart_wmi`, `cpu_temperature`, `memory_diag_history` removed from `HealthChecks.ps1` |
| Validation | `Test-HealthCheckCatalog.ps1` enforces dispatch↔catalog bijection and category-preset parity; `Test-SystemHealthCheckPresets.ps1` added |
| Repo layout | `CDE/ToolkitGUI/` is published payload only (`bin/Release/net8.0-windows/`); edit `App/ToolkitGUI/` |

---

## 2026-06-25 — Process Analyzer overhaul + publish trim fix

### Process Analyzer (GUI + PowerShell)

| Change | Detail |
|--------|--------|
| Live triage UI | CPU/RAM sampling, risk heuristics, filters (high CPU/RAM, unsigned, suspicious path, in startup, investigation), tree view, freeze snapshot, export JSON/CSV |
| Detail pane | Command line, session, parent PID, start time, parent chain, loaded modules, SHA256, signature status; action buttons (open location, copy path, **CST scan file**, Startup Manager, Malware Cleanup) |
| Investigation mode | **Investigation ON** — 3s refresh, highlights **NEW** processes since mode enabled, **New since investigation** filter |
| CST single-file scan | **CST scan file** on selected process image; structured `ProcessAnalyzerCstResultDialog` (verdict, metrics, findings grid). Fixed leaf-file enumeration in `CoreSecurityTool.psm1` (was “0 items scanned” for single paths) |
| WMI enrichment (C#) | `ProcessWmiEnricher.cs` — `Win32_Process` fills command line, session, parent PID, start time in GUI after list/detail JSON (bypasses unreliable in-app JSON binding for those fields) |
| Detail UI refresh | `PublishSelectedDetail` clones `ProcessDetail` on each update so WPF rebinds (in-place mutation on same reference did not refresh the pane) |
| USER column | Removed from grid (WMI owner lookup was unreliable); detail still collects owner when available from PowerShell detail action |

### PowerShell

| File | Role |
|------|------|
| `Scripts/Workflows/ProcessAnalyzer.ps1` | `List`, `Detail`, `Kill`, `CstScan`, `Export` |
| `Scripts/Core/ProcessAnalyzer.Core.ps1` | Risk heuristics, CPU sample map, parent chain, CST invoke, `Format-ProcessCreationTime` |

### GUI source (edit under `App/ToolkitGUI/` only)

| Area | Files |
|------|--------|
| ViewModel | `ViewModels/ProcessAnalyzerViewModel.cs` |
| View | `Views/ProcessAnalyzerView.xaml`, `.xaml.cs` |
| Models | `Models/ProcessEntry.cs`, `ProcessDetail.cs` |
| CST results | `Services/ProcessAnalyzerCstResultService.cs`, `Views/ProcessAnalyzerCstResultDialog.xaml` |
| WMI | `Services/ProcessWmiEnricher.cs` |

### Build / publish

| Change | Detail |
|--------|--------|
| `PublishTrimmed=false` | Release publish no longer uses partial trim — Newtonsoft.Json deserialization of `ProcessEntry` / `ProcessDetail` was dropping `SessionId`, `CommandLine`, `ParentPid` in the published GUI |
| `ILLink.Descriptors.xml` | Preserves process model types if trimming is re-enabled later |
| Health catalog links | `HealthCheckCatalog.json` recommendations open Process Analyzer with `HighCpu` / `HighRam` filter presets |

**Deploy:** `App/Publish-ToolkitGUI.ps1` after GUI or User Guide changes → `Toolkit\CDE.exe`. Fully exit and relaunch CDE (end any stale `ToolkitGUI` process) before testing.

**Note:** Session **0** and empty command line remain normal for many system/service processes (`svchost`, driver containers, etc.). Interactive user apps (e.g. `explorer`, browsers) should show session **1+** and a populated command line.

---

## 2026-06-23 — File Manager, USB prep, DISM repair source

### File Manager (`FileManagerView.xaml` / `.xaml.cs`, `FolderSizeCalculator.cs`)

| Change | Detail |
|--------|--------|
| Junction/reparse skip | Always skip `FileAttributes.ReparsePoint` in listing, tree, and folder-size recursion; visited-path cycle detection. Fixes infinite `C:\ProgramData\Application Data` navigation and runaway sizes. |
| Context menus | Custom WPF menus (Open, Cut/Copy/Paste, Rename, Delete, Properties, Show in Explorer, New folder). Native shell `IContextMenu` approach removed (second right-click crash). |
| Multi-select | Checkbox column + tri-state header select-all; pane footer shows selected count. |

### Prepare-BootableUSB.ps1

| Change | Detail |
|--------|--------|
| Drive letter reuse | `Test-UsbDriveLetterAllowed` — allow letter if free or owned by target USB disk; suggest current USB letter. |
| Partition path | **diskpart primary**; Windows Storage module fallback. Fixed `Set-Disk -IsReadOnly -IsOffline` parameter-set error that prevented diskpart from running. |
| diskpart script | No `online disk`; skip `convert gpt/mbr` when already correct; format before assign. |
| USB copy exclusions | Aligned with `SyncUSB.bat`: `Run-CustomizeWinPE.vbs`, `.venv`, `.vscode` (plus existing `Deploy`, `Mount`, `App`, etc.). |

### OS Repair — DISM (`OSRepair.ps1`, `WorkflowViewModels.cs`)

| Change | Detail |
|--------|--------|
| Error 0x800f081f | Detect missing CBS source files; log actionable guidance in workflow output. |
| Repair source | `-DismSource` / `-DismSourceIndex` (0 = auto WIM index). Runs `/Source:wim:...\install.wim:N /LimitAccess` when provided. |
| GUI | DISM Image Repair prompts: browse `install.wim`/`install.esd`, Windows Update only, or cancel. |

**Deploy:** `App/Publish-ToolkitGUI.ps1` after GUI changes; `SyncUSB.bat` for script-only updates on USB. User guide PDF regenerated (`HALP\CDE_User_Guide.pdf`, 2026-06-23).

---

## 2026-06-22 — PDF User Guide (HALP)

### What changed

Professional operator manual shipped as **`HALP\CDE_User_Guide.pdf`**, generated at publish from Markdown chapters under `Docs\UserGuide\`. Plain-language coverage of sidebar workflows, boot media, CHU, CST, reports, and Settings (including **Open User Guide** and **Clear Test & Scan Logs**).

| Item | Detail |
|------|--------|
| Source | `Docs\UserGuide\*.md` + `manifest.json` (11 files: cover + 10 TOC chapters) |
| Generator | `App\UserGuideGenerator` — separate console project (Markdig + QuestPDF; not in ToolkitGUI — avoids Markdig.Signed conflict with PowerShell SDK) |
| Renderer | `Services\UserGuidePdfService.cs` — CDE-branded layout (reuses WorkflowReportPdfService styling); Markdown tables via QuestPDF `Header()` + body `Cell()` with per-row column count |
| Output | `Toolkit\HALP\CDE_User_Guide.pdf` (~274 KB); copied to USB with `HALP\` via `SyncUSB.bat` |
| GUI access | **Settings → HELP → Open User Guide** (`ToolkitPaths.GetUserGuidePath()` + `ShellFileOpenHelper`) |

**Chapters (manifest order):** Introduction, Getting Started, Recommended Repair Workflow, Diagnostics, Security, Repair, Maintenance and Utilities, Tools Library and Settings, Understanding Reports, Reference.

Publish integration: `App\Publish-ToolkitGUI.ps1` runs `dotnet run --project App\UserGuideGenerator` after catalog sync.

### Table rendering fix (same session)

Initial PDF tables showed scrambled column alignment (header/body `Cell()` mix + wrong column count). Fixed in `UserGuidePdfService.RenderTable`: derive columns from each row’s pipe-delimited cells, skip delimiter rows, render header row in `table.Header()`, and resolve `CodeInline` / `EmphasisInline` in `GetInlineText`. Regenerate the PDF after editing chapters.

### Regenerate only the guide

```powershell
dotnet run --project Toolkit\App\UserGuideGenerator -c Release -- `
  "D:\Robert\Desktop\App Project Builds\Core Diagnostic Engine\Toolkit" `
  "D:\Robert\Desktop\App Project Builds\Core Diagnostic Engine\Toolkit\Docs\UserGuide" `
  "D:\Robert\Desktop\App Project Builds\Core Diagnostic Engine\Toolkit\HALP\CDE_User_Guide.pdf"
```

---

## 2026-06-22 — Settings: clear diagnostic log folders

### What changed

Added **Settings → Clear Test & Scan Logs** to delete saved CHU and CDE result artifacts in one step (with confirmation).

| Folder | Contents cleared |
|--------|------------------|
| `{drive}\EFI\CoreDiag\Logs` | CHU UEFI session `.log` files (CDEDATA volume) |
| `{drive}\EFI\CoreDiag\Results` | CHU exported JSON result files |
| `{TOOLKIT_ROOT}\Logs` | Operator PDF deliverables only |
| `{TOOLKIT_ROOT}\CDE\Runtime\Data` | Internal workflow/scan/CST JSON and PowerShell session logs |

Work order case JSON under `CDE\Runtime\WorkOrders\` is **not** cleared here — use **Dashboard → Clear Recent**.

`ResultLogCleanupService` discovers CHU folders on every ready drive that has `EFI\CoreDiag\Logs` or `Results` (same drive-scan approach as the CHU Results viewer). CDE logs use `ToolkitPaths.GetLogsRoot()`. Deletes all files and subfolders inside each target directory; reports partial failures if files are locked (e.g. active workflow).

### Key files

| Area | Path |
|------|------|
| Cleanup logic | `App/ToolkitGUI/Services/ResultLogCleanupService.cs` |
| Settings UI | `App/ToolkitGUI/Views/SettingsView.xaml`, `SettingsView.xaml.cs` |

### Publish

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File Toolkit\App\Publish-ToolkitGUI.ps1
```

---

## 2026-06-22 — WinPE boot menu trim (remove CST shortcuts)

### What changed

Removed boot menu options **8** and **9** from the CDE Diagnostic Suite Boot Menu (`WinPEBootMenuWindow`):

| Removed | Was |
|---------|-----|
| `[8] CST Malware Scan (Offline - Auto)` | Launched `CoreSecurityTool.ps1` with auto-detected offline Windows |
| `[9] CST Malware Scan (Offline - Manual)` | Prompted for drive letter, then launched CST |

The WinPE boot menu now has **7 options** (keys **1–7**). Footer text updated from “Press 1-9” to “Press 1-7”.

CST remains available inside CDE after launch via **Diag & Repair** and **Malware Cleanup**.

### Key files

| Area | Path |
|------|------|
| Boot menu UI | `App/ToolkitGUI/Views/WinPEBootMenuWindow.xaml` |
| Boot menu logic | `App/ToolkitGUI/Views/WinPEBootMenuWindow.xaml.cs` |

### Publish

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File Toolkit\App\Publish-ToolkitGUI.ps1
```

Canonical deliverable: `Toolkit\CDE.exe`.

---

## 2026-06-19 — System Health Check grouped output, Maintenance deduplication

### Grouped health-check review + bug fixes

- **Uniform grouped output** — System Health Check review/PDF uses `KIND N : Title` blocks with label/value property rows for all catalog checks (network adapters, software, drivers, events, security audits, etc.).
- **Skip regression fixed** — `Format-GroupedBlockHeader` compared `[string]$Title.Length` as strings (so lengths 8–9 falsely truncated and threw). Fixed to integer `$Title.Length -gt 72`. Exported `Format-CriticalEventsDetail`; scheduled-task actions use safe `Execute`/`Arguments` access when `Actions` is an array.
- **Tests** — `Scripts/Tests/Test-SkippedHealthChecks.ps1` (wired into `Invoke-CdeRegressionSuite.ps1`).

### System Audit removed from Maintenance (checks stay in System Health Check)

| Removed from GUI | Kept for System Health Check |
|------------------|------------------------------|
| Sidebar **System Audit** button / `SystemAuditView` / `SystemAuditViewModel` | `Scripts/Core/SystemAuditChecks.ps1` |
| `Scripts/Workflows/SystemAudit.ps1` | `SystemHealthCheck.ps1` dispatches `audit_*` via `Get-SystemAuditCheckDispatchMap` |

Recommendation actions in `HealthCheckCatalog.json` that targeted `SystemAudit` now target **SystemHealth** (legacy `SystemAudit` nav alias still opens System Health Check).

### Malware Cleanup audit tools removed (checks stay in System Health Check)

| Removed from Malware Cleanup | Kept for System Health Check |
|------------------------------|------------------------------|
| Autoruns Audit, Hosts File Check, Browser Extensions Scan, Scheduled Tasks Audit | `Scripts/Core/SecurityAuditChecks.ps1` |
| `MalwareSweep.ps1` dispatch for those four tools | `SystemHealthCheck.ps1` dispatches `sec_*` via `Get-SecurityAuditCheckDispatchMap` |

**Malware Cleanup** tool list is now: **Windows Defender Scan**, **Core Security Tool** (+ Update Hash IOCs in CST config dialog). `MalwareSweep.ps1` still required for Defender/CST/IOC update.

### Validation

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File Toolkit\Scripts\Tests\Test-SkippedHealthChecks.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File Toolkit\App\Publish-ToolkitGUI.ps1
```

### Key files

| Area | Path |
|------|------|
| Grouped formatters | `Scripts/Core/Toolkit.Core.psm1` |
| GUI grouped parser | `App/ToolkitGUI/Services/WorkflowResultFormatter.cs` |
| System audit checks | `Scripts/Core/SystemAuditChecks.ps1` |
| Security audit checks | `Scripts/Core/SecurityAuditChecks.ps1` |
| Health orchestrator | `Scripts/Workflows/SystemHealthCheck.ps1` |
| Malware dispatcher | `Scripts/Workflows/MalwareSweep.ps1` (Defender + CST + IOC update only) |
| Health catalog | `Config/HealthCheckCatalog.json` |

---

## 2026-06-18 — System Health Check catalog trim, CST UX, fewer scan artifacts

### System Health Check — removed from catalog

The picker is driven by `Config/HealthCheckCatalog.json`. Removed from **System Health Check** (still available in their own sidebar workflows where applicable):

| Removed | Former section |
|---------|----------------|
| Disk SMART (WMI) | Quick Vitals |
| CPU Temperature, Memory Diagnostic History | Deep System |
| S.M.A.R.T. Attribute Analysis | Storage (entire category removed) |
| CPU Tests, Memory Tests, Storage Tests | Diag & Repair (entire category removed) |
| Windows Defender Scan, Core Security Tool (scan only) | Security Audits |

**Recommended preset** is now: CPU Load, RAM, Disk Free Space, Startup Entry Audit. Related recommendation rules for removed checks were dropped. **HW profile** Quick/Extended toolbar removed from System Health (it only applied to the former hardware catalog checks). Use **Diag & Repair** for CPU/Memory/Storage/CST line tests; **Malware Cleanup** for Defender and CST operator flow.

### CST — Update Hash IOCs relocated

- **Removed** standalone **Update Hash IOCs** row from Malware Cleanup.
- **Added** **Threat Signature Database → Update Hash IOCs** in `CoreSecurityToolConfigDialog` (primary blue button, same as **Open and Run**).
- Backend unchanged: `MalwareSweep.ps1 -ToolName UpdateHashIOCs` → `Invoke-CstRulesUpdate`.

### CST — fewer artifacts + Structured Results alignment

- Unified session timestamp (`Get-SessionReportTimestamp` in `Toolkit.Core.psm1`).
- Typical CST run artifacts (~3): workflow `.log`, `CST_Result_<ts>.json`, `MalwareSweep_<ts>.json` — no HTML report, no `_skiplog.json` sidecar by default, PDF generated on demand only.
- Malware Cleanup **Structured Results** populated from final `CST_Result_*.json` only; types **Malware / Virus / PUP / PUM** (not live stream “maybe” hits).
- **Cursor sandbox** false positives: Tier1 path exclusion for `*\\appdata\\local\\temp\\cursor-sandbox-cache\\*` in CST `rules.json`; weak PathHeuristic suppressed-audit filter (confidence &lt; 0.55).

### Key files

| Area | Path |
|------|------|
| Health catalog | `Config/HealthCheckCatalog.json` |
| System Health UI | `App/ToolkitGUI/Views/SystemHealthView.xaml`, `ViewModels/SystemHealthViewModel.cs` |
| CST config dialog | `App/ToolkitGUI/Views/CoreSecurityToolConfigDialog.xaml(.cs)` |
| Malware VM | `App/ToolkitGUI/ViewModels/WorkflowViewModels.cs` (`MalwareCleanupViewModel`) |
| Structured Results | `App/ToolkitGUI/Services/CstStructuredResultsService.cs` |
| Session timestamps | `Scripts/Core/Toolkit.Core.psm1` |
| CST rules | `Core Security Tool/CST/rules/rules.json` (synced to `Toolkit/Security/CST/` on publish) |

### Validation

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File Scripts\Tests\Test-HealthCheckCatalog.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File App\Publish-ToolkitGUI.ps1
```

Relaunch `Toolkit\CDE.exe` after publish; run `SyncUSB.bat` before USB deployment.

---

## 2026-06-16 — Diag & Repair (HW + CST suite)

### What changed

- **Rename (user-facing):** Sidebar **Hardware Diagnostics** → **Diag & Repair** (distinct from **Disk & Boot Repair** under REPAIR). Nav tag `DiagAndRepair`; `HardwareDiagnostics` kept as deep-link alias.
- **Workflow:** `Scripts/Workflows/HardwareDiagnostics.ps1` — filename unchanged for System Health child merges and tests. **Run All** now ends with CST (`Invoke-CoreSecurityTool`, `ScanOnly`). New `-ToolName CstScan`. Quick profile → CST `ThreatScan`; Extended → `FullScan`.
- **ToolkitGUI:** `DiagAndRepairView` / `DiagAndRepairViewModel`; toolbar **CST Scan**; static **Security Scan → Core Security Tool** row in the white results table (29 line items for Run All). CST progress: single in-place streaming path from `[CST:PROGRESS]` on the CST row (not Malware Cleanup’s per-file log lines). Status bar shows phase, percent, and file counts during CST.
- **Remediation:** `App/ToolkitGUI/Services/CstRemediationService.cs` — shared post-scan findings dialog + remediate/rollback (Malware Cleanup refactored to use it).
- **Catalog / System Health:** *(Superseded 2026-06-18)* `HealthCheckCatalog.json` no longer lists Diag & Repair hardware checks, Defender, or CST scan-only — use sidebar **Diag & Repair** and **Malware Cleanup** instead. Historical note: hardware category previously linked recommendations to `DiagAndRepair`.
- **Tests:** `Scripts/Tests/Test-HardwareDiagnosticsCst.ps1`; registered in `Invoke-CdeRegressionSuite.ps1`.

### Key files

| Area | Path |
|------|------|
| Workflow | `Scripts/Workflows/HardwareDiagnostics.ps1` |
| CST bridge | `Scripts/Core/SecurityAuditChecks.ps1` |
| ViewModel | `App/ToolkitGUI/ViewModels/WorkflowViewModels.cs` (`DiagAndRepairViewModel`, `HwTestItemViewModel`) |
| View | `App/ToolkitGUI/Views/DiagAndRepairView.xaml` |
| Remediation | `App/ToolkitGUI/Services/CstRemediationService.cs` |
| Nav | `MainWindow.xaml`, `MainViewModel.cs` (`DiagAndRepair` + `HardwareDiagnostics` alias) |

### Live protocol (stdout)

```text
[HW:TEST] / [HW:PROGRESS]  — hardware sub-tests (unchanged)
[CST:PROGRESS]             — phase, currentPath, scanned/progressTotal, percent (Diag & Repair uses PROGRESS only in-table)
```

`[CST:FINDING]` is ignored in Diag & Repair live UI; findings appear in the post-scan operator dialog only.

### Operator notes

- **Malware Cleanup** still offers CST (autoruns, hosts, etc.); overlap with Diag & Repair is intentional — Diag & Repair is the combined HW + security suite.
- WinPE offline client CST still requires boot-menu **Offline CDE** / `OFFLINE_LOAD_REQUESTED` path; UI shows a WinPE note when applicable.
- Weak **PathHeuristic** hits under `%LocalAppData%\Temp\` (including `cursor-sandbox-cache`) are Tier1-excluded in CST `rules.json` (2026-06-18). Residual low-confidence PathHeuristic may still appear in suppressed audit at confidence &lt; 0.55 — typically safe to ignore for dev-tooling artifacts.

### Validation

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File Scripts\Tests\Invoke-CdeRegressionSuite.ps1
powershell -ExecutionPolicy Bypass -File App\Publish-ToolkitGUI.ps1
```

---

## 2026-06-16 — Windows Update stack diagnostics + Post-Op service default

### Problem investigated

Operators reported Windows Update appearing **disabled** after reboot/cold start. Field checks on `DESKTOP-D18TVI3` showed `wuauserv` **StartType = Automatic** (registry `Start = 0x2`), not **Disabled**. The service was **Stopped** while idle — normal on modern Windows because update orchestration starts `wuauserv` on demand. Windows Update operational logs showed successful scans/downloads on 2026-06-15 and 2026-06-16.

### What changed

- **`Scripts/Core/HealthChecks.ps1`** — `Invoke-HealthCheck_windows_update_service` now collects the full update stack via `Get-WindowsUpdateStackSnapshot`, evaluates with `Get-WindowsUpdateStackStatus`, and writes a formatted table to step `Output` (`Format-WindowsUpdateStack`). **Pass** when startup types are healthy even if core services are idle **Stopped**; **Fail** only when a service **StartType** is **Disabled**; **Warn** if `wuauserv` is **Manual**.
- **`Scripts/Core/Toolkit.Core.psm1`** — New helpers: `Get-WindowsUpdateStackSnapshot`, `Get-WindowsUpdateStackNote`, `Get-WindowsUpdateStackStatus`, `Format-WindowsUpdateStack` (exported from module).
- **`Scripts/Workflows/PostOp.ps1`** — `RestoreDefaultServices` sets `wuauserv` to **Automatic** (was **Manual**, which could demote the service after running Post-Op cleanup).
- **`Config/HealthCheckCatalog.json`** — `windows_update_service` description lists all four services; recommendation title/actions include **Windows Update Repair**.

### Example report output

```text
WINDOWS UPDATE STACK
====================

Service        Status     Start Type   Notes
wuauserv       Stopped    Automatic    Stopped while idle is normal; starts on-demand for scans/installs
UsoSvc         Running    Automatic    Running
bits           Stopped    Manual       Manual trigger-start; idle while no transfer is active
WaaSMedicSvc   Stopped    Manual       Manual repair service; starts only when remediation is needed

Stopped does not mean Disabled. Check the Start Type column for the real configuration.
```

### Key files

| Area | Path |
|------|------|
| Health check | `Scripts/Core/HealthChecks.ps1` |
| Formatters / snapshot | `Scripts/Core/Toolkit.Core.psm1` |
| Post-Op services | `Scripts/Workflows/PostOp.ps1` |
| Catalog | `Config/HealthCheckCatalog.json` |
| Fast fix (enable WU) | `Scripts/Workflows/FastFixes.ps1` (`EnableWuauserv`) |

### Operator notes

- In **services.msc**, distinguish **Status** (Stopped/Running) from **Startup type** (Automatic/Manual/Disabled).
- **Fast Fixes → Enable Windows Update Svc** sets `wuauserv` to Automatic and starts it; idle **Stopped** after reboot is still normal.
- Script-only session: relaunch `Toolkit\CDE.exe` after `App/Publish-ToolkitGUI.ps1`; GUI binary rebuild not required for PowerShell-only changes.

### Validation

```powershell
Import-Module Scripts\Core\Toolkit.Core.psm1 -Force
$services = @(Get-WindowsUpdateStackSnapshot)
Get-WindowsUpdateStackStatus -Services $services
Format-WindowsUpdateStack -Services $services -Summary 'test'

powershell -File Scripts\Tests\Test-HealthCheckCatalog.ps1
.\App\Publish-ToolkitGUI.ps1
```

---

## 2026-06-15 — PDF deliverables, readable results, System Health Check labeling

### Professional PDF reports (QuestPDF)

- **`App/ToolkitGUI/Services/WorkflowReportPdfService.cs`** — Generates branded PDF deliverables (summary cards, status bar chart, per-step detail) via **QuestPDF** (community license). Output: `Logs\<WorkflowName>_<timestamp>.pdf` beside existing JSON/HTML.
- **`WorkflowReportExportHelper.cs`** — Robust JSON extraction from mixed workflow stdout; path parsing for `Report saved:` log lines.
- **`WorkflowViewModelBase.cs`** — `OpenPdfReportAsync`, `EnsurePdfReportAsync`, `CanOpenReport`; PDF generated after workflow completion when structured JSON is available.
- **GUI** — **Open PDF Report** replaces operator-facing **Open JSON** / **Open HTML** in `WorkflowExecutionWindow.xaml` and **Open PDF** in `SystemHealthView.xaml`. JSON/HTML still written by `Generate-Report` for internal/technician merge use.

### De-elevated PDF open (elevated CDE)

- **`ShellFileOpenHelper.cs`** — Opens PDFs via `explorer.exe "<path>"` so the default viewer (e.g. Adobe Acrobat) runs at normal integrity and can foreground its window. Direct `Process.Start` from elevated `ToolkitGUI` (`requireAdministrator` in `app.manifest`) often started Acrobat without a visible window.
- **`WorkflowViewModelBase.OpenPdfReportAsync`** — Uses `ShellFileOpenHelper.OpenWithDefaultApplication`.

### Readable structured results (GUI + PDF)

- **`WorkflowResultFormatter.cs`** + **`FormattedResultModels.cs`** — Central parser turns raw step `Output` into plain-English overviews, sections, and per-item cards (startup `[OK]`/`[REVIEW]` lines, key-value blocks, fixed-width tables, `[AUDIT:EVENT]` JSON, etc.). Hides internal protocol lines (`[POSTOP:STARTUP]`, `[HEALTH:PHASE]`, …).
- **`FormattedResultSectionViewModel.cs`** — Maps formatted sections for WPF binding.
- **`StructuredResultItemViewModel`** — Rich entry fields (`EntryLocation`, `EntryPath`, `StatusLabelText`, …) and `FromFormattedItem`.
- **`WorkflowViewModelBase.ExtractStructuredResultItems`** — Prefers formatter output; CST line protocol remains as fallback.
- **`SystemHealthViewModel`** — Findings include `DetailOverview`, `FormattedItems`, `FormattedSections`; review panel **DETAILED RESULTS** section for all checks (including Pass).
- **`App.xaml`** — Shared `FormattedResultItemTemplate` for workflow structured results and health review cards.
- **`WorkflowReportPdfService`** — Step detail uses formatted sections/cards instead of monospace raw dumps.

### System Health Check — PDF step identification

- **`WorkflowStepLabelHelper.cs`** — Resolves friendly step titles from `Config/HealthCheckCatalog.json` via each step’s `CheckId` (e.g. `audit_startup` → **Startup Entry Audit**). Standalone workflows still use workflow/step naming.
- **PDF** — Large per-step header with catalog label; section titles like `Startup Entry Audit · Verified entries`; blue test label repeated on each item card in **SystemHealthCheck** PDFs so multi-page steps remain identifiable (workflow banner stays **System Health Check**).

### Startup Entry Audit review UX (health check + audit)

- **`SystemAuditChecks.ps1`** — `[SUSPICIOUS]` → `[REVIEW]`; summary `Review: N` instead of `Suspicious: N`.
- **`StructuredResultItemViewModel.FromStartupAudit`** — Review reason, location, risk band fields for structured/review panels.
- **`SystemHealthReviewHelper.cs`** — Parses `[REVIEW]` and legacy `[SUSPICIOUS]`; headline uses formatter overview when available.

### Validation

```powershell
dotnet build App\ToolkitGUI\ToolkitGUI.csproj -c Release
.\App\Publish-ToolkitGUI.ps1
# Relaunch Toolkit\CDE.exe after publish
powershell -File Scripts\Workflows\SystemHealthCheck.ps1 -SelectedChecks "audit_startup,ram"
powershell -File Scripts\Workflows\SystemAudit.ps1 -ToolName StartupAudit
```

---

## 2026-06-12 — Phase 1 trust & polish

- **`Toolkit.Core.psm1`** — `Get-WorkflowStepCounts`, `Get-WorkflowOverallHealth`, `Set-WorkflowOverallHealth`, `Group-WorkflowEvents`, `Format-WorkflowEventSummaryText`. `Generate-Report` exports `OverallHealth` when set.
- **Health fix** — `QuickHealth.ps1` / `DeepDiagnostics.ps1` / `OSRepair.ps1` use shared helpers (fixes single-Warn → `Healthy` bug from scalar `.Count`).
- **Deep Diagnostics** — `CriticalEvents` step includes `EventSummary`, `EventCount`, grouped `Output`; exports `DeepDiagnostics_Events_*.json` when count > 20.
- **Temp File Cleaner** — per-folder `FailedItems`, actual `FreedBytes`, `CleanedWithWarnings` → Warn steps. *(2026-07-09: in-use / locked / access-denied skips no longer increment `FailedItems` or warn — see 2026-07-09 handoff section.)*
- **Regression** — `Scripts\Tests\Invoke-CdeRegressionSuite.ps1` (unit + syntax; `-IncludeWorkflowSmoke` optional).
- **Dashboard** — OS Repair / Backup card copy corrected.

### File Manager — empty Directories + tree-driven browse

- **`FileManagerView.xaml.cs`** — Directories pane starts empty (`ClearPane`); no auto-load of `TOOLKIT_ROOT` / USB path on open. **Computer** auto-expands on load. Right pane fills only for **drive** and **shadow copy** tree nodes (`OpensPaneOnSelect`); Users / Toolkit / Offline OS are expand-only shortcuts. Clicking **Computer** clears the pane. Split-view bottom pane starts empty.

### Startup Entry Audit → System Audit

- **`WorkflowViewModels.cs`** — tool moved from `PostOpViewModel` to `SystemAuditViewModel`; live `[POSTOP:STARTUP]` parsing on `SystemAuditViewModel`.
- **`SystemAudit.ps1`** — `Invoke-StartupAudit` + `StartupRisk.ps1` dot-source; dispatch `StartupAudit` / `SystemAudit_All`.
- **`PostOp.ps1`** — startup audit removed; Post-Op is three GUI tools.
- **Fix** — `Invoke-StartupAudit` uses `$r.Steps.Add` (not `Add-ToolkitWorkflowStep`, which Post-Op imports but System Audit does not).

### Shadow copy browse — list + sort

- **`ShadowCopyBrowse.ps1`** — `Parse-VssAdminShadowCopiesFromBlock` enumerates every shadow in each VSS set (was first-only / wrong drive label). `Get-ShadowCopySortDate` for newest-first ordering. `Test-ShadowCopyBrowse.ps1`.

### Bootloader Repair — execution audit fixes

- **`Bootloader.Common.ps1`** — `Get-EfiSystemVolumes`, `Invoke-BootsectOnBootloaderTarget` (`bootsect /nt60 D: /force`), backup file pickers, scan lists all Windows + EFI volumes without drive picker.
- Workflow scripts + **`BootloaderRepairViewModel`** updated. `Test-BootloaderCommon.ps1`.

### Startup Manager — Extensions tab

- **`ExtensionDiscovery.ps1`** — CLSID→DLL for legacy IE extensions; Chromium + Firefox profiles/browsers.
- **`StartupManager.ps1`** / GUI — `AnalysisFilePath`, `BrowserExtension` row type; path resolution excludes `.lnk` from space-splitting.

### Banner uptime — single line

- **`BootUptimeHelper.cs`** — banner `Uptime: Xd Xh Xm` (one kernel uptime; Event 12 → 6005 → WMI). System Audit unchanged (`Get-CdeBootUptimeInfo` still shows session + cold-boot + source).

### Validation

```powershell
dotnet build App\ToolkitGUI\ToolkitGUI.csproj -c Release
.\App\Publish-ToolkitGUI.ps1
powershell -File Scripts\Workflows\SystemAudit.ps1 -ToolName StartupAudit
```

---

## 2026-06-11 — Offline runtime, File Manager VSS browse, Backup Robocopy hardening

### WinPE offline session state (`CDE\Runtime\`)

- Session files moved from toolkit root to **`%TOOLKIT_ROOT%\CDE\Runtime\`**:
  - `offline_env.txt` — `OFFLINE_WINDOWS_ROOT`, `OFFLINE_REGISTRY_LOADED`, `OFFLINE_DRIVERS_LOADED`
  - `offline_progress.log` — WinPE offline load splash progress
- **`Scripts/Core/OfflineRuntime.ps1`** — path helpers, `Test-OfflineRegistrySessionActive` (requires loaded `HKLM\Offline_SOFTWARE\...\Winlogon`), `Sync-OfflineRegistryLoadedEnv`, session cleanup.
- **`App/ToolkitGUI/OfflineRuntimePaths.cs`** — C# mirror; GUI clears stale session on WinPE boot / Normal CDE; applies env only after offline load (not before boot menu).
- **`SyncUSB.bat`** — post-sync deletes `CDE\Runtime` and legacy root `offline_env.txt` / `offline_progress.log`.
- **Fix:** Stale root `offline_env.txt` with `OFFLINE_REGISTRY_LOADED=1` but no loaded hive caused Startup Manager to miss **Userinit** / **Shell** (Winlogon lookup pointed at missing `Offline_SOFTWARE`). User-verified on USB WinPE round-trip + live Windows.

### File Manager — shadow copy browse (read-only)

- **`Scripts/Core/ShadowCopyBrowse.ps1`** + **`ShadowCopyBrowseService.cs`** — list/mount VSS snapshots for technician browse (full Windows; not WinPE).
- File Manager tree **Shadow Copies** node; mounted paths under `%TEMP%\CDE_ShadowBrowse\` are read-only in the UI.
- Separate from Backup & Imaging (below).

### Backup & Imaging — Robocopy only; VSS workflow removed

- Removed **VSS Shadow Copy** tool and **`VssConfigDialog`** from Backup & Imaging (client `vssadmin create` / browse-via-workflow-log was unreliable).
- **Robocopy Backup** remains via `BackupAndImage.ps1` + `RobocopyConfigDialog`.

**Robocopy quoting fixes (2026-06-11):**

| Layer | Issue | Fix |
|-------|--------|-----|
| GUI → `powershell.exe` | `'E:\'` and spaces in paths broke argv parsing | `PowerShellArgumentHelper.QuotePathParameterForProcess` (double quotes; drive roots as `E:`) |
| Script → `robocopy.exe` | Unquoted spaced dest split into folder + file filter (`test`) | `Format-RobocopyPathArgument` wraps spaced paths in `"..."` for `Start-Process -ArgumentList` |
| UX | Dry run skipped robocopy; exit 0 with 0 files reported success | Dry run uses `/L`; warn/fail when source has files but none copied; log file counts |

- User-verified: `E:\` → `D:\Robert\Desktop\robocopy test` — 3804 files, ~3.5 GB.

### Publish

- `App/Publish-ToolkitGUI.ps1` after GUI changes. Script-only updates (`BackupAndImage.ps1`, `OfflineRuntime.ps1`, `ShadowCopyBrowse.ps1`) — relaunch `Toolkit\CDE.exe` or re-run `SyncUSB.bat`.

---

## 2026-06-10 — CHU diagnostics improvement (Weeks 1–3, cross-repo)

Implemented in **Core Hardware Utility**; staged artifact targets `Tools\Boot\CoreHardwareUtility\CoreDiag.efi` and `EFI\CDE\CoreDiag.efi` on USB.

| Area | Change |
|------|--------|
| Memory | 9 passes, error addresses, moving inversions, modulo-20 |
| Storage | SMART RETURN STATUS, NVMe MediaErrors, extended scan |
| CPU | Prime sieve + MP Services; WARN if no MP Services |
| Results | Incremental `ResultExportJson` on `CDEDATA:\EFI\CoreDiag\Results\` |

**Artifact:** SHA256 `3C9A0DD03691E59A67FC37292C79B937C7A8B520AF81ED8819FF5F8135B1788F`, 65 024 bytes.

**Deploy:** `Core Hardware Utility\UEFI\BUILD_CHU_UEFI.ps1 -CdeManifestPath "…\Toolkit\Tools\tools_manifest.json"` → **`SyncUSB.bat`**.

**Unchanged:** WinPE ToolkitGUI **Diag & Repair** (`HardwareDiagnostics.ps1` workflow script); Microsoft `memtest.efi` boot payload (separate catalog entry; run `Ensure-BootArtifacts.ps1` if missing).

Plan: `Core Hardware Utility\UEFI\DIAGNOSTICS_IMPROVEMENT_PLAN.md`.

---

## 2026-06-10 (Latest) — Offline Administrator enable/disable (WinPE verified)

### What changed

**ACCOUNT RECOVERY — enable-only + disable-only workflows (chntpw `user_F` / RID 500)**

- `Scripts/Core/OfflineSamAccount.psm1` — SAM `F` key edits via `ushort ACB_bits@0x38` per [chntpw `sam.h`](https://github.com/mechinn/chntpw/blob/main/sam.h).
  - **Enable:** chntpw mode-2 semantics (`ACB_PWNOEXP`, clear `ACB_DISABLED` / `ACB_AUTOLOCK`, `failedcnt = 0`).
  - **Disable:** set `ACB_DISABLED` (inverse of enable; offline equivalent of `net user administrator /active:no`).
- **Enable Offline Administrator** — strict **enable-only**; no offline password writes (blank built-in admin has no SAM hash storage per chntpw; password set in Windows after logon).
- **Disable Offline Administrator** — new `cde_workflow` + `DisableOfflineAdministrator.ps1` + launch.cmd.
- **GUI:** removed `OfflineAdministratorDialog`; Tools Library runs both workflows directly (no password prompt).
- **WinPE gates:** `Resolve-OfflineWindowsRoot`, offline env checks in `ToolsLibraryView.xaml.cs` / `App.xaml.cs`; `WinPE_OfflineStartup.ps1` path normalization retained.
- **Crypto module** (MD4 + DES-RID) and `Test-OfflineSamCrypto.ps1` retained for SAM layout validation; not used by enable/disable workflows.

**Scope:** offline local `.\Administrator` (RID 500) only — not Microsoft account, Entra ID, PIN/Hello, or domain cached creds.

### Files changed

- `Scripts/Core/OfflineSamAccount.psm1` — enable/disable SAM helpers, backup
- `Scripts/Workflows/EnableOfflineAdministrator.ps1` — enable-only workflow
- `Scripts/Workflows/DisableOfflineAdministrator.ps1` — **new** disable-only workflow
- `Scripts/Workflows/Test-OfflineSamCrypto.ps1` — **new** crypto vectors (optional)
- `Tools/ToolCatalog.xml` — Enable + Disable entries under ACCOUNT RECOVERY
- `Tools/AccountRecovery/DisableOfflineAdministrator.launch.cmd` — **new**
- `App/ToolkitGUI/Views/ToolsLibraryView.xaml.cs` — drop password dialog path
- `App/ToolkitGUI/Views/OfflineAdministratorDialog.xaml(.cs)` — **removed**
- `Tools/TOOLS_VALIDATION_CHECKLIST.md`, `Tools/THIRD_PARTY_TOOL_ONBOARDING.md`

### Validation

- **User-verified on USB WinPE (2026-06-10):**
  - **Enable:** option 2 → Tools Library → Enable Offline Administrator → reboot → `.\Administrator` sign-in **success**.
  - **Disable:** option 2 → Disable Offline Administrator → reboot → Administrator sign-in **blocked** as intended.
- Crypto self-test (`Test-OfflineSamCrypto.ps1`): **PASS** on host (`MD4` NT OWF + DES RID 500 round-trip).

### Operator notes

- Boot WinPE → option **2** (Load Offline OS) → Tools Library → Enable or Disable Offline Administrator.
- After **enable:** sign in as `.\Administrator` (blank password on typical clean installs, or existing password); set password in Windows after logon.
- After **disable:** `.\Administrator` unavailable until enabled again (offline enable workflow or online `net user administrator /active:yes`).
- Hive pattern: edit `HKLM\Offline_SAM` → **`reg unload Offline_SAM`** → reboot to installed Windows.
- Deploy: `Publish-ToolkitGUI.ps1` (if GUI changed) + **`SyncUSB.bat`** before field use.

### References

- Microsoft: [Local accounts](https://learn.microsoft.com/en-us/windows/security/identity-protection/access-control/local-accounts), [Enable/disable built-in Administrator](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/enable-and-disable-the-built-in-administrator-account), [WinRE registry persistence](https://learn.microsoft.com/en-us/answers/questions/3861489/registry-issues)
- SAM layout: [chntpw `sam.h` / `libsam.c`](https://github.com/mechinn/chntpw)

---

## 2026-06-09 — Enable Offline Administrator (research-backed SAM rewrite, superseded by enable-only above)

## 2026-06-10 — Fast Fixes verification, uptime, Enable Offline Administrator (initial)

### What changed

**Fast Fixes — verification + logging (all 17 fixes)**

- Each fix logs through `Write-FixLog` (visible in workflow execution window) and returns `New-FixResult` with **Pass** / **Fail** from post-action checks; workflow marks step **Fail** when verification fails.
- `Invoke-FixCommand` runs external commands via `System.Diagnostics.ProcessStartInfo` with in-memory stdout/stderr capture — fixes PS 5.1 bug where `Start-Process -RedirectStandardOutput $true` coerced `$true` to path `"True"` and crashed (e.g. Flush DNS).
- **RenewIp** — reports adapter tied to default route (`Get-NetRoute -DestinationPrefix 0.0.0.0/0`), not arbitrary first IPv4 adapter.
- **ClearEventLogs** — `Get-EventLogRecordCount` uses quiet `wevtutil gli`; `Test-EventLogCleared` accepts ≤10 residual records when count dropped materially; distinguishes access denied (Security) vs partial clear.

**Uptime — session vs cold boot**

- Banner shows single-line **`Uptime: Xd Xh Xm`** (`BootUptimeHelper.cs`; Event 12 → 6005 → WMI). System Audit still distinguishes session vs cold-boot via `Get-CdeBootUptimeInfo` + event source.
- `Scripts/Core/Toolkit.Core.psm1`: `Get-CdeBootUptimeInfo`, `Format-CdeUptimeSpan`; `Format-SystemDetail` shows both spans + event source.
- *(2026-06-10–11 banner was `Boot: X | Session: Y`; simplified 2026-06-12.)*
- `ToolkitGUI.csproj` — `System.Management` package for WMI fallback.

**Tools Library — Enable Offline Administrator (`cde_workflow`)**

- New **ACCOUNT RECOVERY** category in `Tools/ToolCatalog.xml`; `executionMode="cde_workflow"`, `workflowScript="Scripts\Workflows\EnableOfflineAdministrator.ps1"`.
- `Scripts/Core/OfflineSamAccount.psm1` — enable RID 500, set NT hash (initial; superseded by 2026-06-09 chntpw rewrite above).
- `Scripts/Workflows/EnableOfflineAdministrator.ps1` — WinPE + `OFFLINE_REGISTRY_LOADED=1` gates; loads workflow window; unloads `HKLM\Offline_SAM` on exit.
- GUI: `OfflineAdministratorDialog` (password + confirm), `CdeWorkflowRunnerViewModel`, `ToolsLibraryView.xaml.cs` (`cde_workflow` path, ephemeral password file).
- Fallback launcher: `Tools/AccountRecovery/EnableOfflineAdministrator.launch.cmd`.
- **Scope:** offline local `.\Administrator` only — not MSA / PIN / Entra ID recovery.

### Files changed

- `Scripts/Workflows/FastFixes.ps1` — verification rewrite + `Invoke-FixCommand` fix
- `Scripts/Core/Toolkit.Core.psm1` — boot/session uptime helpers
- `Scripts/Core/OfflineSamAccount.psm1` — **new**
- `Scripts/Workflows/EnableOfflineAdministrator.ps1` — **new**
- `Tools/ToolCatalog.xml` — ACCOUNT RECOVERY + `cde_workflow`
- `Tools/AccountRecovery/EnableOfflineAdministrator.launch.cmd` — **new**
- `App/ToolkitGUI/BootUptimeHelper.cs` — **new**
- `App/ToolkitGUI/ViewModels/PowerShellService.cs` — banner uptime
- `App/ToolkitGUI/Views/OfflineAdministratorDialog.xaml(.cs)` — **new**
- `App/ToolkitGUI/ViewModels/CdeWorkflowRunnerViewModel.cs` — workflow runner
- `App/ToolkitGUI/Views/ToolsLibraryView.xaml.cs` — `cde_workflow` execution
- `App/ToolkitGUI/ToolkitGUI.csproj` — `System.Management`

### Validation

```powershell
# Fast Fixes catalog (0 parse errors)
$e = $null
[void][Management.Automation.Language.Parser]::ParseFile('Scripts\Workflows\FastFixes.ps1', [ref]$null, [ref]$e)
$e.Count

# GUI publish
.\App\Publish-ToolkitGUI.ps1
dotnet build App\ToolkitGUI\ToolkitGUI.csproj -c Release
```

- User-verified Pass (2026-06-10): Flush DNS, Renew IP, Clear Icon Cache, Clear Thumbnail Cache, Clear Event Logs.
- User-verified cold-boot uptime in banner + System Audit.
- Enable Offline Administrator — **not yet hardware-validated** on USB WinPE (publish done; `SyncUSB.bat` pending).

### Operator notes

- **Fast Fixes** — script-only; relaunch `Toolkit\CDE.exe` (no publish required for script-only Fast Fixes changes).
- **Uptime + Offline Administrator** — require `Publish-ToolkitGUI.ps1` (done 2026-06-10). Run **`SyncUSB.bat`** before testing on physical USB WinPE.
- **Offline Administrator** — boot WinPE → option **2** (Load Offline OS) → Tools Library → Enable Offline Administrator. After reboot to installed Windows, sign in as `.\Administrator` with the password set in the dialog.
- **No `Customize-WinPE.ps1`** for this session — changes are toolkit scripts + published GUI, not `boot.wim` / `startnet.cmd`.

---

## 2026-06-09 — PowerShell UTF-8 encoding fix + startup audit hardening (items 1–8)

### What changed

**Script encoding (critical runtime fix)**

- **Symptom:** Malware Cleanup tools and Fast Fixes failed at launch with PowerShell parse errors (`Missing closing ')'`, `Unexpected token ')'`, illegal `&`) even though the scripts were logically valid.
- **Root cause:** Files were stored as **UTF-16 LE** in git/workspace. `powershell.exe -File` does not decode UTF-16 correctly in this path → byte-pair misread → parser errors.
- **Fix:** Read as Unicode, write as **UTF-8 with BOM** (matches `PostOp.ps1` and other healthy workflows). Verify with `[System.Management.Automation.Language.Parser]::ParseFile` → 0 errors before closing.
- **Files converted:** `Scripts/Workflows/MalwareSweep.ps1`, `FastFixes.ps1`, `OSRepair.ps1`, `SmartAnalyzer.ps1`, `Scripts/Core/Toolkit.Core.psm1`, `Scripts/Customize-WinPE.ps1`.
- **Repo rule:** All `Toolkit/Scripts/**/*.ps1` and `*.psm1` must be **UTF-8 BOM**. Do not commit UTF-16 scripts.

**Startup / Winlogon audit hardening (audit items 1–8)**

| # | Area | Change |
|---|------|--------|
| 1 | Startup Manager | Missing/empty `Userinit`/`Shell` listed with Reset; reset works when property absent |
| 2 | Startup Manager | Reset/Undo verification uses expanded normalized compare (`Test-WinlogonValueMatchesDefault`, `Test-WinlogonRegistryValuesEqual`) |
| 3 | Startup Manager | User logon registry Delete routes through `*Entry` paths (cleans `AutorunsDisabled` subkeys) |
| 4 | PostOp + MalwareSweep | `Get-PostOpStartupEntries` includes Winlogon; PostOp Startup Audit and MalwareSweep **Autoruns Audit** use shared entries and flag deviated Winlogon |
| 5 | StartupRisk | `Get-WinlogonRegistryContext` reads `Offline_SOFTWARE\...\Winlogon` when `OFFLINE_REGISTRY_LOADED=1`; StartupManager uses shared context |
| 6 | Fast Fixes | `FixBrowserAssoc` removes `.htm`/`.html`/`.url` UserChoice keys under `HKCU\...\FileExts\` |
| 7 | Startup Manager | Driver disable saves `CDE_PriorStart`; re-enable restores prior Start (fallback via `OriginalData` / `-ActionStatePayload`) |
| 8 | CST | `Invoke-CstDisableRunKeyEntry` moves values to `AutorunsDisabled`; `Invoke-CstRestoreRunKeyEntry` on rollback; synced to `Toolkit/Security/CST/` and `Core Security Tool/CST/` |

**MalwareSweep Autoruns Audit**

- Dots `Scripts/Core/StartupRisk.ps1` after `Toolkit.Core.psm1` import.
- WinPE without offline hives → N/A with guidance to load offline Windows.
- Otherwise uses `Get-PostOpStartupEntries` (run keys, startup folders, Winlogon deviation flags).

### Files changed

- `Scripts/Core/StartupRisk.ps1` — `Get-PostOpStartupEntries`, offline Winlogon context, deviation helpers
- `Scripts/Workflows/StartupManager.ps1` — Winlogon/entry paths, driver `CDE_PriorStart`, `AutorunsDisabled` cleanup
- `Scripts/Workflows/SystemAudit.ps1` — Startup Entry Audit (relocated from Post-Op 2026-06-12); `PostOp.ps1` retains browser cache / services / file associations only
- `Scripts/Workflows/MalwareSweep.ps1` — UTF-8 BOM + Autoruns Audit rewrite
- `Scripts/Workflows/FastFixes.ps1` — UTF-8 BOM + `FixBrowserAssoc` UserChoice cleanup
- `Scripts/Workflows/OSRepair.ps1`, `SmartAnalyzer.ps1` — UTF-8 BOM
- `Scripts/Core/Toolkit.Core.psm1`, `Scripts/Customize-WinPE.ps1` — UTF-8 BOM
- `App/ToolkitGUI/ViewModels/ManagerViewModels.cs` — User logon Delete via entry paths
- `Security/CST/CoreSecurityTool.psm1` — run-key disable/restore via `AutorunsDisabled`

### Validation

```powershell
# Parse check (0 errors each)
$f = "Toolkit\Scripts\Workflows\MalwareSweep.ps1"
$e = $null
[void][Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f), [ref]$null, [ref]$e)
$e.Count

# Smoke tests
$env:TOOLKIT_ROOT = (Resolve-Path "Toolkit").Path
powershell -File "Toolkit\Scripts\Workflows\MalwareSweep.ps1" -ToolName AutorunsAudit
powershell -File "Toolkit\Scripts\Workflows\FastFixes.ps1"   # emits fix catalog JSON
```

- User-confirmed: Malware Cleanup and Fast Fixes work in CDE after encoding fix (2026-06-09).

### Operator notes

- **No GUI rebuild required** for script-only fixes — CDE loads `Toolkit\Scripts\` at runtime via `TOOLKIT_ROOT`. Relaunch `Toolkit\CDE.exe` after pulling script changes.
- Run `App/Publish-ToolkitGUI.ps1` when **ToolkitGUI** or **CST source** changes; publish output is always `Toolkit\CDE.exe` plus synced `CDE\ToolkitGUI\bin\Release\net8.0-windows\`.

---

## 2026-06-05 — Startup Manager Winlogon Reset + CST Hash/CIRCL Fixes

### What changed

**Startup Manager (CDE / ToolkitGUI)**

- Winlogon `Userinit` and `Shell` entries on the **User logon** tab now expose **Reset** (restore Windows default) and **Undo** (restore pre-reset backup).
- Deviated Winlogon values show red styling (`IsDeviated`); deviation detection and defaults are in `Scripts/Core/StartupRisk.ps1`.
- Enable / Disable / Delete buttons are **hidden** (not grayed) for Userinit and Shell — only Reset/Undo appear.
- Reset backs up the prior value to `%ProgramData%\CDE\WinlogonBackups\{Userinit|Shell}.json` before writing the default.
- User-verified: appending `test.dll` to Userinit flagged Warning + Reset; Reset restored `%SystemRoot%\system32\userinit.exe,`.

**CST (source + `Toolkit/Security/CST/` sync)**

- Empty or unreadable SHA-256 on AppX/reparse paths no longer fails `Test-CstKnownGoodHash` binding (`AllowEmptyString`, hash readability guards, format validation before known-good lookup).
- CIRCL bulk SHA-1 reputation: request body fixed to `{"hashes":[...]}` (bare array caused 404 on every batch); improved bulk response parsing and negative cache for unknown hashes.
- Regression test: `CST/tests/Test-CirclBulkBody.ps1`; `Validate-CstPolicyContract.ps1 -SkipMinuteCapTest` pass.

### Files changed

- `App/ToolkitGUI/Views/StartupManagerView.xaml` — Reset/Undo, deviated styling, hide standard actions when unsupported
- `App/ToolkitGUI/ViewModels/ManagerViewModels.cs` — `ResetWinlogonEntry` / `UndoWinlogonEntry` routing
- `App/ToolkitGUI/Models/StartupEntry.cs` — `SupportsReset`, `SupportsUndo`, `IsDeviated`, Winlogon metadata fields
- `Scripts/Core/StartupRisk.ps1` — Winlogon deviation, defaults, backup helpers
- `Scripts/Workflows/StartupManager.ps1` — `Reset-WinlogonRegistryValue`, `Undo-WinlogonRegistryValue`
- `Core Security Tool/CST/CoreSecurityTool.psm1`, `Cst.KnownGood.ps1` — hash + CIRCL fixes (mirrored to `Toolkit/Security/CST/`)

### Validation

- `App/Publish-ToolkitGUI.ps1` — pass (ToolkitGUI payload synced to `CDE/ToolkitGUI/bin/Release/net8.0-windows/`)
- Startup Manager Userinit reset — user-confirmed on live host
- `Validate-CstPolicyContract.ps1 -SkipMinuteCapTest` — pass
- `CST/tests/Test-CirclBulkBody.ps1` — live CIRCL bulk 200 OK

### Operator notes

- Rebuild GUI after Startup Manager XAML changes: `Toolkit\App\Publish-ToolkitGUI.ps1`; fully exit and relaunch `Toolkit\CDE.exe` (admin).
- Stale `ToolkitGUI.exe` (pre-build) showed Warning but omitted Reset/Undo — always publish before testing Winlogon UI.

---

## 2026-06-04 — CST false-positive reduction + extended publish sync

### What changed

- **CST engine (source repo):** After malware SHA-256 IOC, files matching `knownGoodPolicy` or trusted-signer early exit skip YARA/patterns/heuristics/archives. Helpers in `Core Security Tool\CST\Cst.KnownGood.ps1`.
- **Policy:** `knownGoodPolicy` in `rules.json`; seed baseline `rules/baselines/win11_23h2_amd64.json`; optional `rules/goodware.db` (SQLite, NSRL-scale).
- **Telemetry:** CST scan JSON `summary` includes `knownGoodSkips`, `trustedSignerSkips`, `contentScansPerformed` (GUI may consume later).
- **Publish:** `App/Publish-ToolkitGUI.ps1` CST mirror now includes:

```text
CoreSecurityTool.ps1
CoreSecurityTool.psm1
Cst.KnownGood.ps1
rules/rules.json
rules/baselines/**
rules/goodware.db   (if present in source)
```

→ `Toolkit/Security/CST/`

### Key files (CST source)

| Area | Path |
|------|------|
| Known-good module | `Core Security Tool/CST/Cst.KnownGood.ps1` |
| Baseline builder | `Core Security Tool/CST/scripts/Build-CstBaselineHashes.ps1` |
| Rule quality gate | `Core Security Tool/CST/Validate-CstRuleQuality.ps1` |
| Implementation notes | `Core Security Tool/CST/perf_reports/false_positive_reduction_roadmap_20260604.md` |

### Operator notes

- Replace seed baseline with output from `Build-CstBaselineHashes.ps1` on a **clean reference VM** (VMware / Windows Sandbox / Hyper-V; 64 GB VM disk is usually enough for a minimal image).
- Run `App/Publish-ToolkitGUI.ps1` after CST source changes before WinPE or USB malware scans.
- Leave `onlineReputation.enabledForThreatScan` **false** until ThreatScan load-testing completes.

### Validation (CST source, 2026-06-04)

```powershell
cd "Core Security Tool\CST"
.\Validate-CstPolicyContract.ps1
.\Validate-CstRuleQuality.ps1
.\Validate-CstReleaseGates.ps1 -SkipMinuteCapTest
```

---

## 2026-06-03 — Structured Results expansion + Event Logs dedup + CST config UI trim

### What changed

- **Quick Health / Deep Diagnostics** — Workflow execution **Structured Results** populate **once at end** from saved report JSON (or stdout fallback). Only **Warn** and **Fail** steps appear, with friendly labels via `FromDiagnosticFinding` (e.g. CPU Temperature, Driver Audit). Clean scan shows *"No warnings or failures detected in this scan."*
- **System Audit → Event Logs** — Last **24h errors only** (System + Application); deduplicated by log + source + event ID + normalized message. Step output appends `[AUDIT:EVENT]` JSON lines; GUI parses into Structured Results (severity **Error**, occurrence count when repeated). Empty set: *"No errors in the last 24 hours."* Step status **Warn** when any unique errors exist.
- **Core Security Tool config dialog** — Removed right-column info panels (Current Build Notes, dynamic Quick Scan summary, Safer Scope Preview). Single-column layout; smaller window. Removed `RefreshSummary` / `BuildScopePreview` code-behind.

### Key files

| Area | Path |
|------|------|
| Diagnostic structured results | `App/ToolkitGUI/ViewModels/WorkflowViewModelBase.cs` (`PopulateDiagnosticStructuredResults`, `IsDiagnosticWorkflow`) |
| Finding row model | `App/ToolkitGUI/Models/StructuredResultItemViewModel.cs` (`FromDiagnosticFinding`, `FromEventLogEntry`) |
| Event Logs workflow | `Scripts/Workflows/SystemAudit.ps1` (`Invoke-EventLogsAudit`, dedup helpers) |
| CST pre-scan UI | `App/ToolkitGUI/Views/CoreSecurityToolConfigDialog.xaml` (+ `.xaml.cs`) |

### Live protocols (structured results)

```text
[AUDIT:EVENT] {"log":"Application","source":"...","eventId":1000,"message":"...","count":2}
```

(Quick/Deep use workflow report `Steps[]` with `Status` Warn/Fail — no extra stdout marker.)

### Operator notes

- Event Logs human-readable block remains in the live log / report `Output`; Structured Results use deduped `[AUDIT:EVENT]` rows only.
- Publish before GUI testing: `App/Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`.

### Validation

```powershell
powershell -File "Toolkit\Scripts\Workflows\SystemAudit.ps1" -ToolName EventLogs
powershell -File "Toolkit\Scripts\Workflows\QuickHealth.ps1"
powershell -File "Toolkit\Scripts\Workflows\DeepDiagnostics.ps1"
```

---

## 2026-06-03 — Post-Op Cleanup remediation + Startup Audit structured results

### What changed

- **PostOp.ps1** end-to-end fixes for all four GUI tools (audit + live validation on Windows):
  - **Browser Cache Clear** — per-profile cache dirs only (Edge/Chrome/Firefox `cache2`); no longer deletes Firefox `Profiles` root; WinPE = N/A.
  - **Restore Default Services** — UAC elevation relay via `Toolkit.Elevation.psm1`; honest Pass/Warn/Fail step status; WinPE = N/A. *(2026-06-16: `wuauserv` restore target corrected from Manual to Automatic — see 2026-06-16 section.)*
  - **File Association Fix** — `assoc`/`ftype` + `Registry::HKEY_CLASSES_ROOT` for `.exe`/`.lnk`/`.bat`/`.cmd`/`.com`; elevation relay; does not touch UserChoice keys (Win10+ tamper protection).
  - **Startup Entry Audit** — *(moved to System Audit 2026-06-12)* shared risk helpers; flags suspicious entries; offline hive aware when `OFFLINE_REGISTRY_LOADED=1`.
- **Startup Audit GUI** — suspicious items appear in **Workflow Execution → Structured Results** via `[POSTOP:STARTUP]` JSON; color-coded risk badge + location; UI-thread-safe factory dispatch (fixes cross-thread `SolidColorBrush` crash).
- **`-ToolName All`** now includes `FileAssociationFix` (was missing from default batch).
- **Shared modules:** `Scripts/Core/StartupRisk.ps1` (dot-sourced by `StartupManager.ps1` + PostOp); `Scripts/Core/Toolkit.Elevation.psm1` (elevation relay + step helpers).

### Key files

| Area | Path |
|------|------|
| Workflow | `Scripts/Workflows/PostOp.ps1` |
| Elevation / steps | `Scripts/Core/Toolkit.Elevation.psm1` |
| Startup risk | `Scripts/Core/StartupRisk.ps1` |
| GUI | `ViewModels/WorkflowViewModels.cs` (`SystemAuditViewModel`; was `PostOpViewModel`), `Models/StructuredResultItemViewModel.cs` (`FromStartupAudit`) |
| Execution UX | `ViewModels/WorkflowViewModelBase.cs` (`AddStructuredResultItem` UI-thread factory) |

### Live protocol (Startup Audit structured results)

```text
[POSTOP:STARTUP] {"name":"...","location":"HKLM\\...\\Run","risk":"Caution","reasons":"...","path":"..."}
```

### Operator notes

- **Restore Default Services** and **File Association Fix** prompt for elevation when not already admin (approve UAC).
- Structured Results lists **suspicious** startup items only; full inventory remains in the live log / report JSON. *(Superseded 2026-06-15: `WorkflowResultFormatter` lists all startup entries as OK/Review cards in GUI and PDF; `[POSTOP:STARTUP]` JSON hidden from display.)*
- Publish before testing: `App/Publish-ToolkitGUI.ps1` → launch `Toolkit\CDE.exe`.

### Validation

```powershell
powershell -File "Toolkit\Scripts\Workflows\SystemAudit.ps1" -ToolName StartupAudit
powershell -File "Toolkit\Scripts\Workflows\PostOp.ps1" -ToolName FileAssociationFix
```

---

## 2026-06-02 — Hardware Diagnostics (PC-Doctor-style, WinPE + Windows)

> **Superseded (2026-06-16):** User-facing name is now **Diag & Repair** with CST integration. See **2026-06-16 — Diag & Repair** above. Workflow script filename `HardwareDiagnostics.ps1` is unchanged.

### What changed

- **New workflow:** `Scripts/Workflows/HardwareDiagnostics.ps1` — per-line CPU (12), Memory (10), and Storage (6) sub-tests with live `[HW:TEST]` / `[HW:PROGRESS]` stdout.
- **ToolkitGUI (original):** Sidebar **Hardware Diagnostics** — now **Diag & Repair** (`DiagAndRepairView` / `DiagAndRepairViewModel`).
- **Profiles:** `-TestProfile Quick|Extended` (default Quick). Extended increases register/cache/prime/FPU loops, memory buffer size/passes, and storage read depth.
- **UEFI CHU (2026-06-02):** Pre-boot hardware remains `EFI\CDE\CoreDiag.efi` (rEFInd). WinPE/Windows line tests are ToolkitGUI + PowerShell. *(CHU test depth improved 2026-06-10 — see section above.)*
- **Script hardening:** PS 5.1-safe strings (no UTF-8 em dash in double quotes), no `Stopwatch` in Add-Type blocks, storage physical reads report **Skipped** without elevation (not silent pass).
- **Publish:** `App/Publish-ToolkitGUI.ps1` stages to `Toolkit\CDE\`; launch **`Toolkit\CDE.exe`** (not legacy `ToolkitGUI.exe` at repo root).

### Key files

| Area | Path |
|------|------|
| Workflow | `Scripts/Workflows/HardwareDiagnostics.ps1` |
| ViewModel | `App/ToolkitGUI/ViewModels/WorkflowViewModels.cs` (`DiagAndRepairViewModel`, `HwTestItemViewModel`) |
| View | `App/ToolkitGUI/Views/DiagAndRepairView.xaml` |
| Nav | `MainWindow.xaml`, `MainViewModel.cs` |
| Converter | `App/ToolkitGUI/Models/VisibilityConverters.cs` (`InverseBooleanConverter`) |

### Live protocol (stdout)

```text
[HW:PROFILE] {"profile":"Quick","toolName":"All"}
[HW:TEST] {"category":"CPU","test":"Register Test","status":"Running|Passed|Failed|Skipped","detail":"...","durationSec":1.2}
[HW:PROGRESS] {"percent":42,"scanned":3,"total":28,"currentTest":"...","phase":"CPU Tests"}
```

### Operator notes

- Run CDE **as Administrator** for full storage physical-read tests (`\\.\PHYSICALDRIVEx`); otherwise read lines may **Fail** or **Skip**.
- **Extended** can run many minutes (memory + large linear disk reads). Quick is the default bench profile.
- Some AV products may flag fresh unsigned `ToolkitGUI.dll` after publish; allowlist the publish folder if needed.

### Validation

```powershell
dotnet build "Toolkit\App\ToolkitGUI\ToolkitGUI.csproj" -c Release
powershell -ExecutionPolicy Bypass -File "Toolkit\App\Publish-ToolkitGUI.ps1"
powershell -File "Toolkit\Scripts\Workflows\HardwareDiagnostics.ps1" -ToolName All -TestProfile Quick
```

Then `SyncUSB.bat` or `Prepare-BootableUSB.ps1` before hardware WinPE validation.

---

## 2026-06-02 — CST False Positive Mitigation (v1.4.1)

### What changed

- **CST rules upgraded to v1.4.1** with three targeted false-positive mitigation patches:
  1. **PS_WebClient_IEX path filtering** — Added `pathRegex` constraint requiring risky paths (temp/downloads/startup). Stops Critical malware hits on legitimate toolchain scripts (Playwright, vcpkg, package managers) in Program Files and cache directories.
  2. **Toolbar PUP pattern strengthening** — Replaced broad `toolbar` pattern with context-qualified version requiring installer/addon/extension keywords. Prevents PUP false alarms on UI resources in Eclipse, NVIDIA toolkits, and games.
  3. **EFI boot file mode-aware enforcement** — Modified `Find-CstBootChainFindings` to only check required EFI paths when scanning boot media (WinPE, ThreatScan mode, or mounted EFI partitions). Eliminates spurious "Missing EFI boot file" warnings on C:\ full scans.
- **Validation results:** Test scan with 254 findings reduced to 246 projected (-8, -3.1%). Expected 15-60% noise reduction on typical workstation scans with developer toolchains.
- **Quality assurance:** Detection strength preserved (hash IOC, signer validation, heuristics unchanged). False negative risk minimal (other detectors still catch real threats in whitelisted paths).

### Files changed

- `Security/CST/rules/rules.json` (v1.4.0 → v1.4.1)
- `Security/CST/CoreSecurityTool.psm1` (mode-aware EFI boot checks)
- `Core Security Tool/CST/Validate-CstPatchImpact.ps1` (new validation script)
- `Core Security Tool/CST/perf_reports/false_positive_mitigation_patch_20260602.md` (patch documentation)
- `Core Security Tool/CST/perf_reports/patch_deployment_summary_20260602.md` (deployment guide)
- `Core Security Tool/CST/perf_reports/patch_validation_20260602.json` (validation artifact)

### Validation snapshot

- Replay validation: 8 false positives suppressed (6 malware, 2 EFI warnings)
- Suppressed items: codex runtimes, Playwright installer, vcpkg init, bootx64.efi, bootmgfw.efi
- Rules version confirmed: v1.4.1 in both CST source and Toolkit runtime
- No detection regressions expected; all core detectors operational

### Notes / next steps

- Recommended: run live production scan and compare with projection
- Monitor for any new Critical findings in system paths (investigate thoroughly if present)
- Expected outcome: near-zero malware hits on clean developer workstations
- Deployment QA details in `perf_reports/patch_deployment_summary_20260602.md`

---

## 2026-06-01 — CST FullScan Responsiveness + Correlation Stability + Publish Sync Fix

### What changed

- Completed CST scan-pipeline hardening and validation for FullScan UI responsiveness and completion clarity:
  - source throttling for scan progress emissions
  - UI progress coalescing and finding-batch buffering on Toolkit GUI side
  - bounded log retention and throttled auto-scroll behavior
  - explicit completion-phase telemetry milestones to remove perceived post-scan stalls
- Reinstated and stabilized indexed artifact correlation in CST:
  - exact/leaf token indexes with safe leaf extraction (`try/catch` around `GetFileName`)
  - fallback full scan retained for semantic parity
  - fixed generic-list iteration binder issue that caused offline-correlation validator failures
- Fixed canonical publish script CST source path resolution:
  - CST source discovery now probes valid candidate roots and selects an existing path
  - publish now syncs CST runtime files without missing-source warnings

### Files changed

- `Security/CST/CoreSecurityTool.psm1`
- `App/ToolkitGUI/ViewModels/WorkflowViewModels.cs`
- `App/ToolkitGUI/ViewModels/WorkflowViewModelBase.cs`
- `App/ToolkitGUI/Views/WorkflowExecutionWindow.xaml.cs`
- `App/Publish-ToolkitGUI.ps1`
- `Core Security Tool/CST/Validate-CstPolicyContract.ps1`
- `Core Security Tool/CST/Validate-CstOfflineCorrelation.ps1`
- `Core Security Tool/CST/Validate-CstBootScanner.ps1`

### Validation snapshot

- `Validate-CstPolicyContract.ps1`: 51 passed, 0 failed
- `Validate-CstOfflineCorrelation.ps1`: 27 passed, 0 failed, 3 skipped (WinPE-only runtime checks)
- `Validate-CstBootScanner.ps1`: 6 passed, 0 failed
- Correlation regression smoke marker emitted successfully: `CORRELATION_OPT_SMOKE_OK`
- `App/Publish-ToolkitGUI.ps1` completed with clean CST runtime sync:
  - `CoreSecurityTool.ps1` synced
  - `CoreSecurityTool.psm1` synced
  - `rules\rules.json` synced

### Notes / next steps

- Remaining static diagnostics in CST include pre-existing advisory warnings not introduced in this session.
- Next recommended verification is one live GUI-driven FullScan from deployed Toolkit runtime to capture end-to-end completion telemetry UX in real execution flow.

---

## 2026-05-29 (Latest) — Firefox Portable Browser (Tools Library) + WinPE NIC Driver Injection

### What changed

- Added **Mozilla Firefox ESR 140.x** as a portable, USB-run web browser for research/recovery.
  - Extracted into `Tools/Firefox/` via the official installer's silent `/INI=` mode (no shortcuts, no maintenance service, no default-agent registration).
  - Added `Tools/Firefox/distribution/policies.json` to disable self-update (WinPE has no maintenance service), telemetry, studies, the default-browser check, and the first-run page.
  - Profile is portable and stored on the media at `Tools/Firefox/Data/Profile`.
- Registered Firefox in the existing **Tools Library** via `Tools/ToolCatalog.xml` under a new `RECOVERY & NETWORK TOOLS` category (`executionMode="native"`, `relativePath="Firefox\firefox.exe"`).
- Added a generic **path-token expansion** to the Tools launcher so tools can use absolute paths independent of the working directory:
  - `{TOOLDIR}` → the tool's own folder, `{TOOLSROOT}` → the Tools root.
  - Firefox launch args are `-profile "{TOOLDIR}\Data\Profile" -no-remote`.
  - This fixed a "Your Firefox profile cannot be loaded" error caused by the previous *relative* profile path resolving against the wrong working directory when launched from the elevated GUI.
- Added a **network (NIC) driver injection** step to `Scripts/Customize-WinPE.ps1`, mirroring the existing storage-driver block: every `.inf` under `Drivers/Network` is injected into `boot.wim` via `Dism /Add-Driver /Recurse /ForceUnsigned` (graceful skip if empty/absent).
- Created `Drivers/Network/README.md` explaining where to drop extracted Ethernet/NIC `.inf` packages. Wi-Fi is **not** supported in WinPE (Ethernet / USB-Ethernet only).

### Files changed

- `Tools/ToolCatalog.xml` (new Firefox entry)
- `Tools/Firefox/` (extracted app; `distribution/policies.json`; `Data/Profile/`)
- `App/ToolkitGUI/Views/ToolsLibraryView.xaml.cs` (`{TOOLDIR}`/`{TOOLSROOT}` token expansion in launch)
- `Scripts/Customize-WinPE.ps1` (Drivers\Network injection block)
- `Drivers/Network/README.md` (new)

### Validation

- `App/Publish-ToolkitGUI.ps1` completed with no build errors; CDE sync complete.
- `Customize-WinPE.ps1` re-parsed clean (now UTF-8 BOM per 2026-06-09 encoding standard).
- Firefox verified to create/load its portable profile from any working directory when given the absolute (`{TOOLDIR}`-expanded) profile path.

### Notes / next steps

- `Publish-ToolkitGUI.ps1` does **not** copy `Tools/`; Firefox reaches the USB via `SyncUSB.bat` (~267 MB).
- For Ethernet in WinPE on machines without inbox NIC drivers, drop the extracted driver `.inf` packages into `Drivers/Network/` and rebuild `boot.wim`.

---

## 2026-05-29 (Latest) — Header S.M.A.R.T. Status Fix + Deep Diagnostics Cleanup

### What changed

- Fixed the dashboard header **S.M.A.R.T. status** that always showed `Unknown`.
  - Root cause: `GetSmartSummary()` ran the analyzer script via a bare `PowerShell.Create()`, which is silently blocked by execution policy → empty result → `Unknown` fallback.
  - Fix: route the call through `QueryAsync(...)` (explicit runspace + `Set-ExecutionPolicy -Scope Process Bypass`), the same path the dedicated S.M.A.R.T. Analyzer uses. Added a 60-second result cache.
- Removed the redundant raw-WMI S.M.A.R.T. block from `Deep Diagnostics` (it emitted undecoded `MSStorageDriver_FailurePredictData` `VendorSpecific` byte arrays). S.M.A.R.T. is now covered solely by the dedicated native analyzer.

### Files changed

- `App/ToolkitGUI/ViewModels/PowerShellService.cs` (header S.M.A.R.T. via `QueryAsync` + cache)
- `Scripts/Workflows/DeepDiagnostics.ps1` (removed raw-WMI S.M.A.R.T. block; UTF-8 BOM preserved)

### Validation

- User-confirmed: header S.M.A.R.T. status now reports correctly (no longer `Unknown`).
- `DeepDiagnostics.ps1` re-parsed clean after the block removal; build succeeded.

---

## 2026-05-29 — Startup Manager Category Tabs + First-Open Layout Stabilization

### What changed

- Expanded Startup Manager into category tabs across the top:
  - `Services`
  - `Startup Apps`
  - `Drivers`
  - `User Logon`
  - `Extensions`
- Updated tab-aware action routing so enable/disable/delete operations target the correct backend behavior per category.
- Stabilized first-open rendering in non-maximized window mode so the Startup Manager content no longer appears compressed/squished on initial load.
- Clarified behavior differences by entry type, including why some `Drivers` rows do not expose `Disable` when a safe disable path is not available.

### Files changed

- `App/ToolkitGUI/ViewModels/ManagerViewModels.cs`
- `App/ToolkitGUI/Views/StartupManagerView.xaml`
- `App/ToolkitGUI/Views/StartupManagerView.xaml.cs`
- `App/ToolkitGUI/MainWindow.xaml`
- `App/ToolkitGUI/MainWindow.xaml.cs`
- `Scripts/Workflows/StartupManager.ps1`
- `App/ToolkitGUI/Models/StartupEntry.cs`

### Validation

- `App/Publish-ToolkitGUI.ps1` completed successfully after Startup Manager iterations.
- Runtime checks during this session confirmed:
  - category tabs render and switch correctly,
  - first-open layout no longer compresses,
  - driver action availability reflects supported operation paths.

---

## 2026-05-29 (Latest) — Temp File Cleaner Dynamic Discovery + Structured Results

### What changed

- `Temp File Cleaner` was upgraded from mostly static single-root discovery to dynamic discovery with user-selected drive scope.
- First-open drive selection default is now system drive only (Option B).
- Scan results are grouped user/profile-first, with dynamic path coverage including user temp/cache/history locations and per-drive directories.
- Clean actions now enforce whitelist validation from the latest scan and skip protected/non-whitelisted targets with warnings.
- Workflow execution `Structured Results` now receives itemized per-folder cleanup entries (folder path + bytes/items cleaned) instead of only a single aggregate summary.
- Per-folder cleanup message text was normalized to plain ASCII to avoid mojibake/gibberish rendering in the UI.

### Files changed

- `Scripts/Workflows/TempFileCleaner.ps1`
- `App/ToolkitGUI/ViewModels/ManagerViewModels.cs`
- `App/ToolkitGUI/Models/ToolModels.cs`
- `App/ToolkitGUI/Views/TempFileCleanerView.xaml`

### Validation

- `App/Publish-ToolkitGUI.ps1` completed successfully after implementation and follow-up text-format fix.
- User-verified runtime behavior:
  - Dynamic scan and cleaning workflow behaved as expected.
  - Structured Results now shows folder-level cleanup items.
  - Gibberish character issue in cleanup line resolved.

---

## 2026-05-29 (Latest) — SyncUSB Dev Folder Exclusions

### What changed

- Added development/editor folders to `SyncUSB.bat` robocopy directory exclusions:
  - `.venv`
  - `.vscode`
- Updated the script's displayed exclusion summary to reflect the new excluded folders.

### Why it matters

- Prevents syncing Python virtual environments and editor metadata to bootable USB media.
- Keeps deployment media clean and reduces unnecessary file copy volume.

### Files changed

- `SyncUSB.bat`

---

## 2026-05-28 (Latest) — CST Runtime Mirror and Smoke Validation

### What changed

- Mirrored updated CST runtime files from source CST into Toolkit deployment path:
  - `Security/CST/CoreSecurityTool.ps1`
  - `Security/CST/CoreSecurityTool.psm1`
  - `Security/CST/rules/rules.json`
- Mirrored changes include bounded-analysis safeguards and timeout controls that reduce per-file stall risk:
  - capped YARA text/byte reads
  - capped entropy byte windows
  - signature verification timeout
  - archive analysis time budget
  - slow-file telemetry in scan output

### Validation run

- Executed Toolkit workflow smoke test:
  - `Scripts/Workflows/MalwareSweep.ps1`
  - mode: `CustomScan`
  - detection scope: `MalwareOnly`
  - action mode: `ScanOnly`
  - target: `./Security/CST`
- Workflow completed successfully and generated reports under `Logs/`.

### Notes

- Source CST release gates were re-run post-mirror and all passed (`-SkipMinuteCapTest`).
- Current workflow remains local-only across repos in this workspace; no remote push step is required.

## 2026-07-07 (Latest) — CST behavioral telemetry workflow integration

### What changed

- Added `App\CdeBehaviorCollector\` helper project and published runtime executable `CdeBehaviorCollector.exe`.
- `App\Publish-ToolkitGUI.ps1` now publishes the collector alongside the GUI/runtime payload and mirrors it into `Toolkit\CDE\ToolkitGUI\bin\Release\net8.0-windows\`.
- `Scripts\Core\SecurityAuditChecks.ps1` now hooks behavior telemetry generation into `Invoke-CoreSecurityTool`:
  - generates a behavior bundle in `Toolkit\CDE\Runtime\Data\cst\`
  - passes the bundle into CST automatically
  - surfaces telemetry bundle details in workflow output
- Synced CST runtime mirror now includes behavior-artifact import, telemetry-weighted correlation, graph-edge summaries, and imported-artifact deduplication.

### Validation

- Canonical publish script completed successfully after collector and workflow changes.
- CST validators passed after sync:
  - `Validate-CstBehaviorArtifactImport.ps1`
  - `Validate-CstBehaviorCollector.ps1`
  - `Validate-CstOfflineCorrelation.ps1`
- Runtime smoke tests under `Toolkit\CDE\Runtime\Data\cst\` confirmed:
  - `behaviorArtifactsPath` is present in CST result JSON
  - imported behavior telemetry is consumed
  - deduped imported behavior count now resolves to `2` unique imported artifacts for repeated `System-7045` events

### Operator notes

- Full workflow proof of telemetry-weighted scoring in a runtime artifact still depends on host logging availability.
- Existing runtime smoke tests proved:
  - workflow hook works
  - imported telemetry bundle is handed to CST
  - benign script test triggers file-content detection and live Run-key collection
- Validator runs remain the authoritative proof for telemetry weighting and graph-edge scoring when host event logs do not naturally provide matching imported process/autorun events.

---

## 2026-05-28 (Latest) — PrepareUSB GPT + Sync Propagation Fixes

### What changed

- `Scripts/Prepare-BootableUSB.ps1` now supports GPT-targeted media creation without DiskPart `ACTIVE` failures:
  - Detects disk partition style (MBR vs GPT).
  - Runs `active` only for MBR disks.
  - Explicitly runs `select partition 1` after `create partition primary` before format/assign.
  - Applies `bootsect.exe /mbr` only on MBR disks and skips it on GPT with a success/info message.
- `SyncUSB.bat` no longer excludes USB prep launch scripts from copy:
  - Removed `PrepareUSB.vbs` and `Prepare-BootableUSB.ps1` from `/XF` exclusions so USB media receives updated prep logic.

### Why it matters

- Running `H:\PrepareUSB.vbs` now uses the current patched script after a normal sync from Toolkit root.
- GPT removable disks no longer fail with DiskPart errors caused by MBR-only commands or missing selected partition context.

### Files changed

- `Scripts/Prepare-BootableUSB.ps1`
- `SyncUSB.bat`

---

## 2026-05-22 (Latest) — CDE Hash IOC Update Button

> **UI relocated (2026-06-18):** **Update Hash IOCs** is no longer a Malware Cleanup tool row. It lives in **Core Security Tool** config dialog → **Threat Signature Database** card. Backend below unchanged.

### What changed

- **`Scripts/Workflows/MalwareSweep.ps1`**: Added `Invoke-CstRulesUpdate` function and `UpdateHashIOCs` dispatch case. Calls `Update-CstRulesFromGitHub.ps1` from the CST `updates\` folder resolved via `Resolve-CoreSecurityToolPath`. Output captured with `$?` for correct pass/fail status. Skip path now logs a Warning instead of silently returning.
- **`App/ToolkitGUI/ViewModels/WorkflowViewModels.cs`**: *(Historical)* Added "Update Hash IOCs" `ToolItem` to `MalwareCleanupViewModel`. **As of 2026-06-18** removed from Malware Cleanup list; wired via `OnUpdateHashIocRequested` on `CoreSecurityToolConfigDialog` instead.
- **`Security/CST/updates/Update-CstRulesFromGitHub.ps1`**: Deployed here as the copy `Resolve-CoreSecurityToolPath` resolves to at runtime (deployed CST path takes precedence over the source project path).

### Runtime behavior

- **Update Hash IOCs** in **Core Security Tool** config dialog (Malware Cleanup → Core Security Tool) fetches `rules.json` from `https://raw.githubusercontent.com/GenNowGamer/CDE-threat-rules/main/rules.json`.
- Logs remote version, hash count, and either "Already up to date" or the full update summary on success.
- Threat Level resolves to Clean on success.

---

## 2026-05-27 — Prepare-BootableUSB Interactive Drive Letter Prompt

### What changed

- `Scripts/Prepare-BootableUSB.ps1` now prompts for the USB drive letter instead of assuming a hardcoded target.
- The prompt shows currently mounted drive letters, validates that the selection is a single non-system letter, and confirms before formatting.
- The USB deployment flow remains destructive by design, but the target is now explicit and user-selected at runtime.

### Why it matters

- The bootable USB workflow is no longer tied to a fixed `H:` assumption.
- This makes the format/deploy script portable across machines where the removable drive letter changes.

### Files changed

- `Scripts/Prepare-BootableUSB.ps1`

### Files changed

- `Scripts/Workflows/MalwareSweep.ps1`
- `App/ToolkitGUI/ViewModels/WorkflowViewModels.cs`
- `Security/CST/updates/Update-CstRulesFromGitHub.ps1` (new deployed copy)

---

## 2026-05-22 (Earlier) — WinPE Offline Driver Load Fail-Safe

### What changed

- Hardened `Scripts/Core/WinPE_OfflineStartup.ps1` driver loading path used by WinPE Option 2 (Load Offline OS).
- Replaced direct synchronous `drvload.exe` call with `Start-Process` + `WaitForExit` timeout guard.
- Added per-package timeout of 8 seconds so one problematic INF cannot stall the entire startup sequence.
- Added explicit blocklist for known problematic package folder pattern: `^mt7612us_`.

### Runtime behavior now

- Matching network/storage DriverStore packages are still attempted during offline load.
- If a package is blocked, hangs, times out, or exits non-zero, startup records a warning and continues.
- Offline OS attachment remains tied to successful offline hive loading, not to every driver package succeeding.
- When hives load, `CDE\Runtime\offline_env.txt` is written and CDE continues into the attached offline session (legacy root `offline_env.txt` is migrated/cleared on load).

### Why this was added

- One desktop system consistently stalled at `Loading driver package: mt7612us_rl.inf_amd64_...` while another machine succeeded.
- Root cause was an unbounded per-package `drvload` call in Option 2 startup flow.

### File changed

- `Scripts/Core/WinPE_OfflineStartup.ps1`

---

## 2026-05-22 (Earlier) — WinPE Parity Pass for 5 Categories

### Scope completed this session

The requested parity pass was implemented only for these categories, in order:
1. OS Repair
2. Malware Cleanup
3. Bootloader Repair
4. System Audit
5. Fast Fixes

### What changed

**WinPE N/A contract**
- UI now disables clearly non-applicable WinPE actions with a grey `N/A` button/state instead of exposing them as normal runnable actions.
- Result rendering now treats `N/A` the same way as `Skip` for neutral/grey display.

**OS Repair**
- `Network Stack Reset` and `Windows Update Repair` are now explicitly `N/A` in WinPE.
- Script-side result messages explain that these require live Windows services/network state.

**Malware Cleanup**
- `Autoruns Audit`, `Browser Extension Scan`, and `Scheduled Tasks Audit` now show `N/A` in WinPE where they depend on live Windows/session behavior.

**Bootloader Repair**
- Unavailable-state labeling was normalized to the same `N/A` contract used elsewhere in the app.

**System Audit**
- Added offline-aware paths for WinPE when offline hives are loaded:
  - Installed software from `HKLM\Offline_SOFTWARE` and per-user offline uninstall keys
  - Services from `HKLM\Offline_SYSTEM\ControlSet###\Services`
  - Event logs from offline `Windows\System32\winevt\Logs\System.evtx` and `Application.evtx`
- `PnP Devices` is now treated as `N/A` in WinPE instead of presenting misleading live-session behavior.

**Fast Fixes**
- WinPE applicability metadata was added so clearly live-only fixes can render as `N/A`.
- The redundant `Reset TCP/IP Stack` entry was removed from Fast Fixes entirely because OS Repair already owns that action surface.

**SyncUSB.bat**
- `Run-CustomizeWinPE.vbs` was added to the `/XF` exclusion list, so it will no longer be copied to USB.

### Files changed

- `App/ToolkitGUI/Models/ToolModels.cs`
- `App/ToolkitGUI/Models/WorkflowExecutionResult.cs`
- `App/ToolkitGUI/ViewModels/ManagerViewModels.cs`
- `App/ToolkitGUI/ViewModels/WorkflowViewModels.cs`
- `App/ToolkitGUI/Views/FastFixesView.xaml`
- `Scripts/Workflows/FastFixes.ps1`
- `Scripts/Workflows/MalwareSweep.ps1`
- `Scripts/Workflows/OSRepair.ps1`
- `Scripts/Workflows/SystemAudit.ps1`
- `SyncUSB.bat`

### Validation

- `App\Publish-ToolkitGUI.ps1` completed successfully after the parity edits.
- Publish ended with `CDE sync complete.` for the local deployment mirror.

### Important current state

- The latest parity/doc changes have been published locally.
- USB media still requires `SyncUSB.bat` to receive the latest post-publish updates.
- If `startnet.cmd` or other WinPE image content changes again, rebuild `sources\boot.wim` before syncing USB.

---

## 2026-05-21 (Latest) — Unified WPF Boot Menu (WinPEBootMenuWindow)

### What was built

Replaced the `startnet.cmd` text-based boot menu with a full-screen WPF window hosted inside
`ToolkitGUI.exe`. The boot menu, offline OS selection, and progress splash are now a single in-process
experience — eliminating the CMD→WPF handoff that previously caused process termination in edge cases.

### New files

| File | Purpose |
|------|---------|
| `App/ToolkitGUI/Views/WinPEBootMenuWindow.xaml` | Full-screen branded boot menu: splash background, 7-button left panel (Launch CDE, Launch + Offline, CMD, PS, Net, Reboot, Shutdown). Keys 1-7 trigger corresponding actions. *(CST Auto/Manual options 8–9 removed 2026-06-22.)* |
| `App/ToolkitGUI/Views/WinPEBootMenuWindow.xaml.cs` | Code-behind: `WinPELaunchChoice` enum, `TaskCompletionSource<WinPELaunchChoice>` pattern, action handlers, `LaunchProcess` helper. *(CST launch handlers and `PromptDriveLetter` removed 2026-06-22.)* |
| `Run-CustomizeWinPE.vbs` | Double-click helper at Toolkit root that elevates via UAC and runs `Scripts\Customize-WinPE.ps1`. |

### Modified files

**`App/ToolkitGUI/App.xaml.cs`**
- Added `ShutdownMode = ShutdownMode.OnExplicitShutdown` at startup start; switched to
  `OnMainWindowClose` only after `mainWindow.Show()`. Prevents process termination during the
  splash→MainWindow handoff when no other window is open.
- Inserted WinPE boot menu invocation block before `ShouldRunOfflineLoadFlow()`:
  - Shows `WinPEBootMenuWindow`, awaits `WaitForChoiceAsync()`.
  - NormalCDE: sets `OFFLINE_LOAD_REQUESTED=0`.
  - OfflineCDE: sets `OFFLINE_LOAD_REQUESTED=1`.
  - Cancelled/reboot/shutdown choice: calls `Shutdown(0)` and returns.
- Block is guarded by `IsWinPeRuntime()` — non-WinPE launch path is completely unchanged.

**`Mount/WinPEWork/startnet.cmd`**
- Removed 9-option text BOOT MENU, `:LAUNCH_GUI`, and `:LAUNCH_GUI_OFFLINE` labels.
- Now auto-launches `ToolkitGUI.exe` via `start /wait` immediately after env setup.
- Falls back to `:FALLBACK_MENU` (text menu, 6 options) only if `ToolkitGUI.exe` is missing.
- After CDE exits, shows `:RECOVERY_MENU` (5 options: Relaunch, CMD, PS, Reboot, Shutdown).
- All `goto MENU` → `goto RECOVERY_MENU` throughout utility labels.

**`WinPE/build_winpe.ps1`**
- Removed `CHOICE /C 12`, `OFFLINE_LOAD_REQUESTED`, and two-option launch block from the embedded
  `$startnetContent` heredoc.
- Now uses `START /WAIT "" "%GUI_EXE%"` thin-launcher pattern (mirrors `startnet.cmd`).

**`SyncUSB.bat`** (earlier this session)
- Added stale-WIM timestamp warning: if `Mount/WinPEWork/startnet.cmd` is newer than
  `sources/boot.wim`, prints a warning to run `Scripts/Customize-WinPE.ps1` (admin) first.

### WinPE deploy workflow (reminder)

Whenever `startnet.cmd` is changed, two steps are required before it takes effect:
1. Run `Run-CustomizeWinPE.vbs` (double-click; UAC prompt; injects `startnet.cmd` into
   `sources\boot.wim` via DISM — admin required).
2. Run `SyncUSB.bat` to push the updated `boot.wim` + all other files to USB.

### State at end of session

- ToolkitGUI published successfully: 752 files, 0 errors. Timestamp: `5/21/2026 3:31:23 PM`.
- All compiler errors resolved (removed `CharacterSpacing` — WinUI-only, not valid WPF).
- `startnet.cmd` has been fully refactored; changes require admin WIM rebuild to take effect on USB.

---

## 2026-05-21 — Windows Launcher Migration Complete and Startup Optimized

## 2026-05-21 (Latest) - Windows Launcher Migration Complete and Startup Optimized

### Final state

- Default Windows launcher is now `CDE.exe` at Toolkit root.
- Fallback batch launcher moved to `Scripts\Launch\CDE_Portable.bat` and retained on media.
- WinPE launch flow is unchanged.

### Root cause and fixes during migration

1. Initial launcher crash fixed:
  - Cause: attempted to set process environment variables while using shell execute path.
  - Fix: launch ToolkitGUI with `UseShellExecute=false` for normal path.
2. Elevation fallback path quoting bug fixed:
  - Cause: cmd-based elevated fallback broke on spaced paths (`D:\Robert\Desktop\App ...`).
  - Fix: replaced cmd fallback with elevated self-relaunch of `CDE.exe` using `--elevated-launch` arg.
3. Startup time optimized:
  - Removed WinForms dependency from launcher.
  - Switched error dialog to native `user32!MessageBoxW`.
  - Launcher publish flags tuned in `App\Publish-ToolkitGUI.ps1`:
    - `PublishSingleFile=true`
    - `EnableCompressionInSingleFile=false`
    - `PublishReadyToRun=true`
    - `DebugType=None`
    - `DebugSymbols=false`

### Deployment/script alignment completed

- `App\Publish-ToolkitGUI.ps1` builds ToolkitGUI payload + launcher; **only** `Toolkit\CDE.exe` is the published launcher exe. GUI DLLs sync to `CDE\ToolkitGUI\bin\Release\net8.0-windows\` (no second `CDE\CDE.exe`).
- `SyncUSB.bat` updated to verify launcher artifacts on destination media:
  - `%DRIVE%:\CDE.exe`
  - `%DRIVE%:\Scripts\Launch\CDE_Portable.bat`
- `CreateISO.vbs`, `PrepareUSB.vbs`, `Scripts\CreateISO.ps1`, `Scripts\Prepare-BootableUSB.ps1`, and `autorun.inf` updated for new default launch behavior.

### Verification snapshot

- Local and USB launcher hashes matched after final publish/sync.
- User confirmed both local and USB `CDE.exe` launch successfully and in acceptable startup time.

### Canonical workflow (unchanged order)

1. Edit source under `App\ToolkitGUI\`.
2. Run `App\Publish-ToolkitGUI.ps1`.
3. Run `SyncUSB.bat`.

---

### Publish pipeline hardening

- `App/Publish-ToolkitGUI.ps1` updated:
  - Added `-r win-x64 --self-contained true` to dotnet publish args — produces a portable self-contained
    binary that carries its own .NET runtime, eliminating the "You must install .NET" error in WinPE.
  - Added post-publish robocopy block: auto-copies `App\bin\` → `CDE\bin\` after every successful publish.
  - Added CDE exe timestamp validation at end of script to confirm sync succeeded.
- **Canonical workflow:** Always edit in `App\ToolkitGUI\`, run `App\Publish-ToolkitGUI.ps1`, then
  `SyncUSB.bat`. Never edit `CDE\ToolkitGUI\` directly — it is overwritten on every publish.

### File Manager pane clipping fix

- `App/ToolkitGUI/Views/FileManagerView.xaml`:
  - Both pane containers changed from `StackPanel` to `Grid` with four rows: `Auto/Auto/Auto/*`.
  - Removed hardcoded `Height="580"` from `LeftListView` and `RightListView`; both now `Grid.Row="3"`.
  - Panes now fill all available vertical space correctly in all window sizes.

### OSRepair.ps1 — SFC replaced with DISM in WinPE

- `Scripts/Workflows/OSRepair.ps1`:
  - `Invoke-SFC`: In WinPE mode, `sfc /offbootdir` is replaced with DISM offline
    `/CheckHealth` + `/RestoreHealth`. SFC requires VSS + CBS which are absent in WinPE.
  - `Invoke-DISM`: Fixed hardcoded `/Image:C:\` — now derives the drive from `$WindowsDir` via
    `Split-Path -Qualifier`.

### Unmount OS reliability fix (SettingsView)

- `App/ToolkitGUI/Views/SettingsView.xaml.cs` — `GetOfflineHiveCleanupScript()` rewritten:
  - Root cause: `ExecuteAsync` uses a PS SDK runspace with `InitialSessionState.CreateDefault()` which
    loads the Registry provider, acquiring open HKEY handles on loaded offline hives. Inline `reg.exe
    unload` in the same runspace fails with "Access is denied" because those handles are still held.
  - Fix: Forces GC collection before unload (`[GC]::Collect()` × 2 with finalizers) to release cached
    Registry provider handles.
  - All `reg.exe unload` calls now use `Start-Process` (child process, no inherited HKEY handles).
  - HKU enumeration replaced with `reg.exe query HKU` (avoids PS Registry provider acquiring new
    handles to HKU while we're trying to unload it).
  - Exit code `2` treated as success (hive already unloaded is acceptable).
  - Method changed from `private static` to `internal static` (shared with MainWindow).

### Close-with-unmount prompt (MainWindow)

- `App/ToolkitGUI/Views/UnmountOnCloseDialog.xaml` + `.xaml.cs` — new custom dialog:
  - Dark-themed dialog matching app style with "Cancel" (left) and "Confirm" (right) buttons.
  - Returns `DialogResult = true` on Confirm, `false` on Cancel.

- `App/ToolkitGUI/MainWindow.xaml.cs` — added `OnClosing` override:
  - Condition: only intercepts when both `X:\Windows\System32` exists (WinPE) AND
    `OFFLINE_WINDOWS_ROOT` env var is non-empty (offline OS is loaded).
  - On close attempt: cancels the close, shows `UnmountOnCloseDialog`.
  - **Confirm**: runs `SettingsView.GetOfflineHiveCleanupScript()` async (same logic as Settings
    Unmount button), sets `_closingConfirmed = true`, then calls `Close()` — bypass flag prevents
    re-interception.
  - **Cancel**: dialog closes, CDE window stays open, nothing unmounted.
  - If neither WinPE nor offline OS loaded: close proceeds normally with no prompt.

### State at end of session

- All changes built and deployed to USB (`H:\`). ToolkitGUI.exe on USB: `5/20/2026 2:59:14 PM`.
- Both `.NET install` error and File Manager clipping confirmed resolved by user.
- Unmount OS fix and close-with-unmount are ready for WinPE testing.
---

## 2026-05-20 â€” Bootloader Target Selector & SyncUSB Hardening

### What was built

Replaced auto-selection behavior in bootloader workflows with explicit user-selectable DataGridView UI,
ensuring operators must actively choose which Windows installation to repair. Added robust error handling
to SyncUSB.bat and removed debug artifacts.

### Bootloader.Common.ps1 changes

- Implemented `Assert-BootloaderUiSupportOrThrow` capability gate to hard-fail if WinForms/DataGridView
  types are unavailable in the WinPE image (prevents silent auto-fallback).
- Replaced `Select-BootloaderTargetWithConfirmation` behavior:
  - Was: auto-selected `$Targets[0]` (highest scored) with only confirm/cancel prompt
  - Now: opens a WinForms modal Form with themed DataGridView listing all targets
  - User must select a row (with visual styling matching Toolkit theme) before Continue button activates
  - Rows show: Index, Drive, Windows Directory, EFI BCD presence, BIOS BCD presence, Score
  - Theme colors applied: light backgrounds (#EEF2F7/#FFFFFF), blue primary action (#0078D4),
    neutral borders (#D0D6E0), Segoe UI 9pt typography
  - Existing second-stage confirmation prompt retained (shows selected target details + write action warning)

### BootloaderRebuildEfi.ps1 changes

- Removed silent first-match EFI auto-fallback behavior (`Select-Object -First 1`)
- Was: if selected target lacked EFI BCD, automatically switched to first EFI-capable target without prompting
- Now: if selected target lacks EFI BCD, calls `Select-BootloaderTargetWithConfirmation` again with EFI-only targets
  so operator explicitly chooses which EFI system volume to rebuild

### SyncUSB.bat hardening

1. **Fixed elevation handling** (double-click would close immediately after drive prompt):
   - Replaced PowerShell `Start-Process -Verb RunAs` with direct cmd.exe elevation relaunch
   - Added `/k` flag to keep elevated CMD window open (vs /c which closes on exit)
   - Explicit working directory argument in cmd invocation
   - Elevation marker (`--elevated`) prevents redundant net session check on re-entry

2. **Fixed batch syntax errors**:
   - Removed invalid drive letter substitution lines
   - Fixed escaped parenthesis parser error in same-drive error message
   - Changed robocopy destination from `"%DRIVE%:\"` to `"%DRIVE%:"` (quoted trailing backslash breaks argv parsing with spaces in path)

3. **Improved input validation**:
   - Added drive prompt re-loop when blank entry provided
   - Added confirm prompt re-loop when blank or invalid entry provided
   - Clearer re-prompt messages

4. **Cleanup**:
   - Deleted obsolete `SyncUSB_Debug.bat` file
   - Added `SyncUSB_Debug.bat` to `/XF` exclusion list in SyncUSB.bat

### Verification results

- Parse/load validation: Both `Bootloader.Common.ps1` and `BootloaderRebuildEfi.ps1` parse cleanly in Windows PowerShell 5.1
- Robocopy argument parsing: Confirmed spaced-path handling now works without "Invalid Parameter" errors
- USB sync test: Successfully synced bootloader changes to H:\ (robocopy exit code 0-7 range, files marked Newer)
- Explicit files copied to USB: `Bootloader.Common.ps1`, `BootloaderRebuildEfi.ps1` (verified in robocopy output)


---

## 2026-05-20 (Continued) — Critical Bug Fixes: rEFInd Menu Regression & WinPE UI Fallback

### Issue 1: rEFInd bootloader menu completely missing after SyncUSB.bat

**Symptom:** Booted USB → skipped rEFInd graphical menu → jumped directly to WinPE diagnostic boot menu

**Root cause:** SyncUSB.bat ran robocopy which copied a 2.7MB `EFI\boot\bootx64.efi` from source, overwriting the correct rEFInd binary. 
The source `bootx64.efi` was NOT rEFInd; it was a stale/wrong file. Meanwhile, `Prepare-BootableUSB.ps1` has a post-copy step that
explicitly copies `refind_x64.efi` (278KB) over `bootx64.efi` to fix this, but **SyncUSB.bat was missing this critical post-sync step**.

**Fix applied to SyncUSB.bat:**
- Added post-robocopy verification step that copies `H:\EFI\refind\refind_x64.efi` to `H:\EFI\boot\bootx64.efi` after all files sync
- Outputs verification message: "✓ UEFI fallback launcher (bootx64.efi) verified as rEFInd"
- Errors if rEFInd binary missing or copy fails, preventing silent boot corruption

**USB restored:** Manually copied correct rEFInd file to H:\EFI\boot\bootx64.efi; hashes verified matching.

### Issue 2: WinForms/DataGridView unavailable in WinPE image

**Symptom:** Running bootloader tools in WinPE showed: "Bootloader selector UI requires WinForms/DataGridView support, which is unavailable in this WinPE Image."

**Root cause:** Standard Windows ADK WinPE image does not include desktop GUI support (WinForms/System.Windows.Forms assemblies). 
WinPE minimal image has no WPF, WinForms, or System.Drawing - only core runtime + PowerShell.

**Fix applied to Bootloader.Common.ps1:**
- Replaced hard-fail approach with hybrid GUI/console implementation:
  1. Try loading WinForms at script startup; set $script:HasWinForms = $true only if both Form and DataGridView types load successfully
  2. Implemented `Select-BootloaderTargetWithConfirmation_Console` for WinPE environments
  3. Router function `Select-BootloaderTargetWithConfirmation` dispatches to GUI or console based on $script:HasWinForms
- Console menu shows:
  - Numbered table of available targets (Drive, Windows Directory, EFI BCD, BIOS BCD columns)
  - Prompts for target selection by number (1, 2, 3, etc)
  - Shows selection summary and confirmation prompt
  - Returns same target object structure as GUI version, so all downstream code works identically
- `Confirm-BootloaderWriteAction` also routes GUI (message box) vs console (text prompt) based on availability
- Added `Get-EnvironmentMode` helper to detect WinPE vs normal Windows

**Impact:** All bootloader repair tools now work in both ToolkitGUI (GUI) and WinPE (console), eliminating the WinForms blocker.

**Files changed:**
- `SyncUSB.bat` - Added post-robocopy rEFInd verification step
- `Bootloader.Common.ps1` - Hybrid GUI/console target selector
---

## 2026-05-20 (Continued) — Critical Bug Fixes: rEFInd Menu Regression & WinPE UI Fallback

### Issue 1: rEFInd bootloader menu completely missing after SyncUSB.bat

**Symptom:** Booted USB → skipped rEFInd graphical menu → jumped directly to WinPE diagnostic boot menu

**Root cause:** SyncUSB.bat ran robocopy which copied a 2.7MB `EFI\boot\bootx64.efi` from source, overwriting the correct rEFInd binary. 
The source `bootx64.efi` was NOT rEFInd; it was a stale/wrong file. Meanwhile, `Prepare-BootableUSB.ps1` has a post-copy step that
explicitly copies `refind_x64.efi` (278KB) over `bootx64.efi` to fix this, but **SyncUSB.bat was missing this critical post-sync step**.

**Fix applied to SyncUSB.bat:**
- Added post-robocopy verification step that copies `H:\EFI\refind\refind_x64.efi` to `H:\EFI\boot\bootx64.efi` after all files sync
- Outputs verification message: "✓ UEFI fallback launcher (bootx64.efi) verified as rEFInd"
- Errors if rEFInd binary missing or copy fails, preventing silent boot corruption

**USB restored:** Manually copied correct rEFInd file to H:\EFI\boot\bootx64.efi; hashes verified matching.

### Issue 2: WinForms/DataGridView unavailable in WinPE image

**Symptom:** Running bootloader tools in WinPE showed: "Bootloader selector UI requires WinForms/DataGridView support, which is unavailable in this WinPE Image."

**Root cause:** Standard Windows ADK WinPE image does not include desktop GUI support (WinForms/System.Windows.Forms assemblies). 
WinPE minimal image has no WPF, WinForms, or System.Drawing - only core runtime + PowerShell.

**Fix applied to Bootloader.Common.ps1:**
- Replaced hard-fail approach with hybrid GUI/console implementation:
  1. Try loading WinForms at script startup; set $script:HasWinForms = $true only if both Form and DataGridView types load successfully
  2. Implemented `Select-BootloaderTargetWithConfirmation_Console` for WinPE environments
  3. Router function `Select-BootloaderTargetWithConfirmation` dispatches to GUI or console based on $script:HasWinForms
- Console menu shows:
  - Numbered table of available targets (Drive, Windows Directory, EFI BCD, BIOS BCD columns)
  - Prompts for target selection by number (1, 2, 3, etc)
  - Shows selection summary and confirmation prompt
  - Returns same target object structure as GUI version, so all downstream code works identically
- `Confirm-BootloaderWriteAction` also routes GUI (message box) vs console (text prompt) based on availability
- Added `Get-EnvironmentMode` helper to detect WinPE vs normal Windows

**Impact:** All bootloader repair tools now work in both ToolkitGUI (GUI) and WinPE (console), eliminating the WinForms blocker.

**Files changed:**
- `SyncUSB.bat` - Added post-robocopy rEFInd verification step
- `Bootloader.Common.ps1` - Hybrid GUI/console target selector

---

## 2026-05-19 â€” Bootloader UI and WinPE-native script replacement

### What was built

Added a full Bootloader Repair section to the ToolkitGUI and replaced all
`bootrec.exe` usage with WinPE-native equivalents. `bootrec.exe` is a
WinRE-only tool â€” it does not exist in ADK WinPE (`winpe.wim`) and was
causing `ExitCode -1` errors at runtime.

### ToolkitGUI changes

- `App/ToolkitGUI/Views/BootloaderRepairView.xaml` â€” New view: 7 repair
  action buttons (Scan OS, Fix MBR, Fix Boot, Rebuild BCD, Check Integrity,
  Rebuild EFI, Full BCD Repair).
- `App/ToolkitGUI/Views/BootloaderRepairView.xaml.cs` â€” Code-behind for view.
- `App/ToolkitGUI/ViewModels/WorkflowViewModels.cs` â€” Added
  `BootloaderRepairViewModel` with commands for all 7 actions.
- `App/ToolkitGUI/ViewModels/MainViewModel.cs` â€” Wired Bootloader section
  into navigation.
- `App/ToolkitGUI/Views/OSRepairView.xaml` â€” UI refinements.
- `App/ToolkitGUI/MainWindow.xaml` â€” Layout updates.

### Bootloader workflow scripts

All scripts are in `Scripts/Workflows/`. The common library is
`Bootloader.Common.ps1`, dot-sourced by every script.

| Script | Tool used | Notes |
|---|---|---|
| `Bootloader.Common.ps1` | (library) | `global:` scope modifier on all 6 functions; `${ActionName}` parse fix; path resolution in `Invoke-BootloaderCommandCaptured` |
| `BootloaderScanOs.ps1` | Pure PowerShell | Replaced `bootrec /scanos`; calls `Get-BootloaderTargets` directly |
| `BootloaderFixMbr.ps1` | `bootsect.exe /nt60 SYS /mbr` | Replaced `bootrec /fixmbr` |
| `BootloaderFixBoot.ps1` | `bootsect.exe /nt60 SYS` | Replaced `bootrec /fixboot` |
| `BootloaderRebuildBcd.ps1` | `bcdboot.exe` | Replaced `bootrec /rebuildbcd` |
| `BootloaderBcdRepair.ps1` | `bcdedit` + `bootsect` + `bcdboot` | Replaced 4 `bootrec` calls |
| `BootloaderCheckIntegrity.ps1` | `bcdedit.exe` | Unchanged â€” was already WinPE-native |
| `BootloaderRebuildEfi.ps1` | `bcdboot.exe` | Unchanged â€” was already WinPE-native |
| `BootloaderBcdBackup.ps1` | File copy | BCD backup to date-stamped file |
| `BootloaderBcdRestore.ps1` | File copy | BCD restore from backup |

### WinPE build infrastructure

- `Scripts/Customize-WinPE.ps1` â€” Added `bootsect.exe` injection step.
  Uses `robocopy /B` (SeBackupPrivilege) to bypass DISM-mount ACL restrictions
  that block `Copy-Item`. Also fixed UTF-8 BOM (was UTF-8 no-BOM; PS 5.1
  misread em-dash bytes as CP1252 curly-quote, splitting strings mid-line).
- `Scripts/Core/WinPE_OfflineStartup.ps1` â€” Pre-existing changes from
  earlier session (already synced to USB).

### Bug fixes resolved this session

1. **`Assert-WinPeOrThrow` not recognized** â€” Root cause: `Start-Workflow`
   runs the script block in module scope; dot-sourced functions are invisible
   from there. Fix: `function global:` on all functions in
   `Bootloader.Common.ps1`.
2. **`ParseException: InvalidVariableReferenceWithDrive`** â€” `"...$ActionName:..."` in a double-quoted string; `:` after a variable name signals a scope modifier to the PS parser. Fix: `${ActionName}`.
3. **`bootrec.exe` ExitCode -1** â€” `bootrec.exe` is WinRE-only; not present
   in ADK `winpe.wim`. Even with path resolution it was never found.
   Fix: full architectural replacement with `bcdboot`/`bootsect`.
4. **`Customize-WinPE.ps1` parse errors** â€” File was UTF-8 without BOM.
   PS 5.1 decoded em-dash bytes as CP1252, producing U+201D (right
   curly-quote) which PS treats as a string terminator. Fix: replaced all
   em-dashes with ASCII hyphens, saved with UTF-8 BOM.
5. **`bootsect.exe` injection `Access denied`** â€” DISM-mounted WinPE
   System32 ACLs block `Copy-Item`. Fix: replaced with `robocopy /B`.

### Current deployed state (USB H:)

- `H:\sources\boot.wim` â€” Rebuilt 476 MB; PS OCs + `bootsect.exe` (114 KB
  in System32) + `startnet.cmd` + `CDECore.psm1`
- `H:\Scripts\Workflows\` â€” All 5 modified bootloader scripts synced

### Deploy script fixes (CreateISO, PrepareUSB, SyncUSB)

All three scripts are now consistent with the current toolchain.

**`Scripts/CreateISO.ps1`** â€” ISO staging:
- Added `App\` exclusion (source code; deployed app is in `CDE\`)
- Added `Tools\Deploy\` and `Tools\.staging\` exclusions (gitignored large binaries)
- Removed stale `refind_temp` exclusion
- Added `/XF` list: `*.md`, `.gitignore`, `script_output.txt`, launcher VBSes, and the
  three build-only PS1s (`CreateISO.ps1`, `Customize-WinPE.ps1`, `Prepare-BootableUSB.ps1`)

**`Scripts/Prepare-BootableUSB.ps1`** â€” fresh USB creation:
- Fixed UEFI validation: `CDEBoot.efi` â†’ `CoreDiag.efi` (matches `refind.conf` loader path;
  `CDEBoot.efi` is the compiled source name, `CoreDiag.efi` is what rEFInd actually loads)
- Added `Tools\Deploy\` and `Tools\.staging\` to folder exclusions
- Added `script_output.txt` to file exclusions

**`SyncUSB.bat`** â€” incremental USB sync:
- Replaced `/XF "*.bat"` wildcard with named exclusions â€” wildcard was silently dropping
  `CDE_Portable.bat` from every sync (the Windows-mode launcher needed on the USB)
- Added `.git\`, `Tools\Deploy\`, `Tools\.staging\` to `/XD`

---

## Next session â€” resume point

**Goal: Test all 5 bootloader tools in WinPE from USB.**

Boot from H: and run each tool from `Bootloader â†’ [action]` in the ToolkitGUI:

| Tool | Expected result |
|---|---|
| **Scan OS** | Detects Windows installations on attached drives; no external tool required |
| **Fix MBR** | Confirmation prompt â†’ `bootsect.exe /nt60 SYS /mbr` runs in WinPE |
| **Fix Boot** | Confirmation prompt â†’ `bootsect.exe /nt60 SYS` runs in WinPE |
| **Rebuild BCD** | Target selection â†’ `bcdboot.exe <WindowsDir> /s <DriveRoot> /f ALL` |
| **BCD Repair** | `bcdedit /enum` first; if broken â†’ `bootsect` + `bcdboot` remediation |
| **Check Integrity** | `bcdedit /enum all` output displayed â€” should work regardless of prior session |
| **Rebuild EFI** | `bcdboot.exe` â€” should work regardless of prior session |

**Important:** Fix MBR, Fix Boot, and BCD Repair require `bootsect.exe` in
`X:\Windows\System32`. This is only present after running
`Customize-WinPE.ps1` and booting from the rebuilt `boot.wim`.

If any tool shows `ExitCode -1` or "file not found":
1. Check `X:\Windows\System32\bootsect.exe` exists in WinPE shell
2. If missing, `Customize-WinPE.ps1` needs to be re-run on the dev machine
   and `H:\sources\boot.wim` replaced

---

## Key files

| File | Purpose |
|---|---|
| `Scripts/Customize-WinPE.ps1` | Rebuilds `boot.wim`; run as Administrator on dev machine |
| `Scripts/Workflows/Bootloader.Common.ps1` | Shared library for all bootloader scripts |
| `Scripts/Core/Toolkit.Core.psm1` | Core module (`Start-Workflow`, `Write-Log`, `Generate-Report`) |
| `App/ToolkitGUI/` | .NET 8 WPF frontend |
| `sources/boot.wim` | WinPE image (gitignored; rebuilt by Customize-WinPE.ps1) |
