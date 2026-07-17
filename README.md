# Core Diagnostic Engine

A Windows repair and diagnostics toolkit: **ToolkitGUI** (C# WPF), **PowerShell** workflows under `Toolkit\Scripts`, optional files in `Toolkit\Tools`, and support for running from full Windows or from **WinPE** (bootable USB/ISO). Bootable media is built and maintained with scripts under `Toolkit\Scripts` (for example `Customize-WinPE.ps1`, `Prepare-BootableUSB.ps1`, `SyncUSB.bat`) and the **rEFInd** pre-boot menu documented in `Toolkit\PHASE_3_BOOT_ARCHITECTURE.md`.

Current preboot policy: **rEFInd** on the USB toolkit provides the primary UEFI menu. The repo `EFI\boot\refind.conf` currently lists **CDE WinPE** and **CHU**; Windows Memory Diagnostic (`memtest.efi`) is onboarded via `Ensure-BootArtifacts.ps1` and launchable from WinPE (`Invoke-PreBootTool.ps1 -Tool MemDiag`) or `CDEBoot.efi` when staged to `EFI\CDE\memtest.efi`.

**Code review (2026-07-15):** Pass 1–2 toolkit fixes shipped; Pass 3 (publish/launcher/packaging) reviewed and **deferred** — canonical publish unchanged. See `Toolkit\session_handoff.md`.

**2026-07-17:** System Health Check now combines persisted structured findings (impact, severity, confidence, evidence, recommendations/actions) with the original detailed technical output. Event-log clustering and a separate GPU functional check (`CdeGpuDiagCli`) were added; selected result cards now have a clear **VIEWING** indicator. See `session_handoff.md` and `Toolkit\session_handoff.md`.

**2026-07-16:** Startup Manager service risk/filter/guarded delete, reliable Post-Op hosts restore, System Health Check findings order, scheduled-tasks audit tuning, Windows Update stack Pass for Manual `wuauserv`, Uninstall Manager cleanup, and Hyper-V lab verification/deployment. See `session_handoff.md` and `Toolkit\session_handoff.md`.

Current field status:

- rEFInd menu loads cleanly on hardware when USB is prepared with `Prepare-BootableUSB.ps1`.
- CHU boots from the rEFInd menu and hardware tests run.
- WinPE customization and toolkit sync are owned by CDE scripts; publish with `Toolkit\App\Publish-ToolkitGUI.ps1` before USB sync or WinPE validation.
- WinPE boot menu options **1** / **2** hand off to the main CDE GUI in-process (2026-07-03); if launch fails, check `CDE\Runtime\winpe_startup.log` on the USB.
- CST is exposed from **Malware Cleanup** as its own operator flow (Windows Defender Scan, scan selection, detection scope, quarantine/remove, rollback, post-scan findings review). **Update Hash IOCs** runs from the CST config dialog (**Threat Signature Database**), not as a separate Malware Cleanup row. Autoruns, hosts file, browser extensions, and scheduled-task audits run from **System Health Check** only (2026-06-19). Remaining work: layered detection engine and richer detector metadata.
- **Diag & Repair** (2026-06-16): PC-Doctor-style CPU/Memory/Storage + CST scan-only suite in ToolkitGUI (Quick/Extended). Nav `DiagAndRepair` (alias `HardwareDiagnostics`). UEFI CHU (`CoreDiag.efi`) remains the pre-boot path.
- **Post-Op Cleanup** (2026-06-03; expanded 2026-06-26): Eight remediation tools — browser cache, service defaults, file associations, DNS/proxy reset, shell caches, optional hosts restore, restart Explorer. **Startup Entry Audit** runs from **System Health Check** (`audit_startup`). See `Toolkit\session_handoff.md`.
- **PDF workflow reports** (2026-06-15): QuestPDF PDFs in `Logs\`; **Open PDF** in workflow execution and System Health (replaces operator Open JSON/HTML). De-elevated open via `explorer.exe` for elevated CDE. See `Toolkit\session_handoff.md`.
- **Readable structured results** (2026-06-15): `WorkflowResultFormatter` — plain-English cards in GUI and PDF; System Health PDF labels each check via `HealthCheckCatalog.json` `CheckId`.
- **Structured Results** (2026-06-03): Quick Health / Deep Diagnostics show Warn/Fail at scan end; System Audit Event Logs lists deduplicated 24h errors; CST pre-scan dialog simplified (no sidebar info panels).
- **CST false-positive reduction** (2026-06-04): Known-good hash gating and trusted-signer content-scan skip in CST source; publish sync copies `Cst.KnownGood.ps1` and `rules/baselines/**` into `Toolkit\Security\CST\`. Details in `Core Security Tool\CST\README.md` and `Toolkit\session_handoff.md`.
- **Startup Manager Winlogon reset** (2026-06-05): Userinit/Shell deviation detection, Reset/Undo, backups under `%ProgramData%\CDE\WinlogonBackups\`. **CST hash/CIRCL** fixes synced to `Toolkit\Security\CST\`.
- **Script encoding + startup audit** (2026-06-09): UTF-16 PowerShell scripts caused Malware Cleanup and Fast Fixes parse failures; all `Toolkit\Scripts\` files normalized to **UTF-8 BOM**. Startup audit items 1–8 (Winlogon/offline hives, shared `Get-PostOpStartupEntries`, browser assoc fix, driver `CDE_PriorStart`, CST `AutorunsDisabled`). See `Toolkit\session_handoff.md`.
- **Fast Fixes verification + uptime + account recovery** (2026-06-10; trimmed 2026-06-26): 14 Fast Fixes log via `Write-FixLog` and **Pass/Fail** from post-action checks (DNS flush and icon/thumb cache moved to Post-Op); **Tools Library → ACCOUNT RECOVERY → Enable Offline Administrator** (`cde_workflow`, WinPE + offline OS only). Banner uptime simplified to `Uptime: Xd Xh Xm` (2026-06-12). See `Toolkit\session_handoff.md`.
- **CHU diagnostics Weeks 1–3** (2026-06-10): Cross-repo improvements to `CoreDiag.efi` — deeper memory/storage/CPU tests, incremental JSON on `CDEDATA`. Stage via `BUILD_CHU_UEFI.ps1 -CdeManifestPath` + `SyncUSB.bat`. See `Core Hardware Utility\UEFI\DIAGNOSTICS_IMPROVEMENT_PLAN.md`.
- **Offline runtime + Robocopy + File Manager VSS browse** (2026-06-11): WinPE session state under `CDE\Runtime\`; Startup Manager Userinit/Shell fix for stale `offline_env.txt`; VSS Shadow Copy removed from Backup & Imaging; Robocopy path quoting for `E:\` and spaced paths; File Manager read-only shadow copy tree. See `Toolkit\session_handoff.md`.
- **File Manager, System Audit, uptime, bootloader** (2026-06-12): Empty Directories on open; drive/shadow-copy tree browse only; Startup Entry Audit under System Audit; shadow snapshot list/sort fix; bootloader EFI/backup picker hardening; banner `Uptime: …` single line. See `Toolkit\session_handoff.md`.
- **Windows Update stack diagnostics** (2026-06-16): System Health Check `windows_update_service` reports `wuauserv`, `UsoSvc`, `bits`, and `WaaSMedicSvc` with **Status** and **Start Type**; idle **Stopped** + **Automatic** is **Pass** (not a false Warn). Post-Op **Restore Default Services** keeps `wuauserv` at **Automatic**. See `Toolkit\session_handoff.md`.
- **Diag & Repair (HW + CST)** (2026-06-16): Renamed from Hardware Diagnostics; Run All includes CST ThreatScan/FullScan (scan-only); static Security Scan row with streaming `[CST:PROGRESS]` path; `CstRemediationService` + post-scan dialog. See `Toolkit\session_handoff.md`.
- **System Health Check catalog trim** (2026-06-18): Picker no longer lists SMART/WMI vitals, CPU temperature, memory diag history, S.M.A.R.T. analyzer, Diag & Repair hardware tests, Defender, or CST scan-only — use dedicated sidebar workflows instead. *(2026-06-19: System Audit and Security Audits catalog categories remain in System Health Check only; redundant Maintenance System Audit and Malware Cleanup audit tools removed.)* See `Toolkit\session_handoff.md`.
- **WinPE boot menu trim** (2026-06-22): Removed CST Malware Scan shortcuts (former options 8–9) from `WinPEBootMenuWindow`; menu is keys **1–7**. CST remains in **Diag & Repair** and **Malware Cleanup**.
- **CHU test session UI** (2026-06-22): Graphics test tree with per-row progress and post-run review (`ENTER` to return to menu). See `Core Hardware Utility\session_handoff.md`.
- **Settings diagnostic log cleanup** (2026-06-22): **Settings → Clear Test & Scan Logs** removes CHU `EFI\CoreDiag\Logs` and `Results`, operator PDFs in `{TOOLKIT_ROOT}\Logs`, and internal data under `CDE\Runtime\Data\` (2026-07-01). Work order case JSON cleared separately via **Dashboard → Clear Recent** (2026-07-01).
- **PDF User Guide** (2026-06-22): operator manual at `HALP\CDE_User_Guide.pdf` built from `Docs\UserGuide\` via `App\UserGuideGenerator` on publish; **Settings → Open User Guide**.
- **Phase 3 diagnostic depth** (2026-06-26): Dashboard **suggested path** + case timeline; CHU Results rollup and Diag & Repair highlight links; tiered CST findings expander; work-order `EventKind` / `GuidanceContext`. See `Toolkit\session_handoff.md`.
- **Report policy + symptom inference** (2026-07-01): PDF-only `Logs\`; internal JSON in `CDE\Runtime\Data\`; Dashboard keyword-based symptom highlight on work order generate; **Clear Recent** for work order JSON cleanup. See `Toolkit\session_handoff.md`.
- **Removable media hardware policy** (2026-07-01): Diag & Repair storage, S.M.A.R.T. Analyzer, and CHU storage tests exclude USB flash, memory cards, and boot USB via `PhysicalDiskCatalog.psm1` (CDE) and `StorageDrive.c` (CHU). See `Toolkit\Docs\UserGuide\04_Diagnostics.md`.
- **WinPE shell handoff** (2026-07-03): Boot menu options 1–2 open main `MainWindow` in-process (opaque WinPE chrome, no DWM transparency). Maximize/restore fixed. Trace: `CDE\Runtime\winpe_startup.log`. Publish GUI + `SyncUSB.bat` only. See `Toolkit\session_handoff.md`.
- **Startup Manager + Post-Op expansion** (2026-06-26): Scheduled tasks, StartupApproved parity, GPO Run, MSIX, correlation; `\Microsoft\*` tasks hidden by default. Post-Op eight tools via `PostOpCleanup.ps1`; Fast Fixes deduped to 14. See `Toolkit\session_handoff.md`.
- **MSIX startup signing + Process Analyzer Investigation UI** (2026-06-30): Startup Manager resolves MSIX startup-task executables from Appx manifest and shows `Package (Publisher)` when WindowsApps blocks file access; Process Analyzer hides investigation status banner so Tree view / Deep scan stay usable. See `Toolkit\session_handoff.md`.
- **Hijack & Scam Repair + reports** (2026-06-30): HiJackThis-style scanner under sidebar **REPAIR** with selective repair, Startup Manager integration, persistent scan results, and **Open Report** (PDF) via `TabularScanReportService`. See `Toolkit\session_handoff.md`.
- **Work-order recording fix** (2026-06-26): `Add-WorkOrderRun` dedupe bug fixed — workflows like Temp File Cleaner no longer fail after successful completion when a work order is active.
- **CPU SIMD on PowerShell 5.1** (2026-07-03): `CdeCpuSimdCli.exe` (published with ToolkitGUI) runs real MMX/SSE tests on Win10/11 inbox PS 5.1; Diag & Repair CPU rows show Pass/Fail instead of stub **Warn**. See `Toolkit\session_handoff.md`.
- **CST remediation USB root** (2026-07-03): Malware Cleanup remediation works when the toolkit runs from a drive-letter USB root (`G:\`).
- **Diag & Repair CST status** (2026-07-03): CST scans with warnings show **Warn** in the results table (not **N/A**).
- **GitHub source** (2026-07-03): `https://github.com/GenNowGamer/Core-Diagnostic-Engine` — source-only clone. Rebuild with `Toolkit\App\Publish-ToolkitGUI.ps1`; Microsoft ADK/WinPE and PassMark MemTest86 binaries are **not** in git — see `LICENSE`, `THIRD_PARTY_NOTICES.md`, and `Toolkit\Tools\PLACEHOLDER_ACQUISITION.md`.
- **Temp File Cleaner skip policy** (2026-07-09): Locked, in-use, and access-denied temp files are skipped without workflow warnings; cleanup reports success when only expected skips remain. See `Toolkit\session_handoff.md`.

## Session status (2026-07-03)

- **WinPE shell** — Options 1–2 → `MainWindow`; maximize/restore fixed (`MainWindow.xaml.cs`, `BorderlessWindowHelper`, `WinPeStartupLog.cs`). Field-verified.
- **CdeCpuSimdCli** — `Toolkit\App\CdeCpuSimdCli\`; self-contained publish into GUI payload; `Test-CpuSimdEnginePs5.ps1`.
- **CST** — `CstRemediationService` drive-root fix; `WorkflowViewModels` CST Warn/N/A fix.
- **Git** — Slim orphan history; nested `Toolkit/.git` removed; expanded root `.gitignore`.
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` → canonical `Toolkit\CDE.exe`; `SyncUSB.bat` before USB tests.

## Session status (2026-06-30)

- **Hijack & Scam Repair** — Scan/repair workflow (`HijackRepair.ps1`); GUI view with detail panel, Quick Repairs drawer, **Select repairable**, scan persistence, loading overlay. Startup **Suspicious only** filter shared with scanner.
- **Reports** — `TabularScanReportService` for tabular HTML/PDF/JSON/CSV; System Health **Open HTML**; Process Analyzer and workflow window HTML/PDF buttons.
- **User guide** — `Toolkit\Docs\UserGuide\` chapters 03, 05, 07, 09, 10 updated; regenerate via canonical publish.
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe` + `HALP\CDE_User_Guide.pdf`.

## Session status (2026-06-26)

- **Phase 3** — CHU catalog sync test; case timeline on Dashboard and work order detail; CST expandable full findings; Dashboard verify loop tied to last symptom preset.
- **Startup Manager** — Scheduled logon/boot tasks, StartupApproved sync, GPO Run keys, MSIX startup tasks (manifest executable resolution + package publisher signature when file inaccessible), cross-mechanism correlation; optional `\Microsoft\*` scheduled-task view (read-only).
- **Post-Op Cleanup** — Eight tools (`PostOpCleanup.ps1`); DNS/icon/thumb cache and hosts restore consolidated here; duplicates removed from Fast Fixes and OS Repair network reset.
- **Fast Fixes** — 14 verified fixes (was 17).
- **Regression** — `Invoke-CdeRegressionSuite.ps1` includes `Test-StartupManagerCoverage.ps1`, `Test-PostOpCleanup.ps1`, hardware catalog sync, work-order case events, and CST structured-results tiers.
- **Bugfix** — `WorkOrder.ps1` `Add-WorkOrderRun` ReportJson dedupe (Temp File Cleaner exit code 1 after success).
- **User guide** — `Docs\UserGuide\` chapters 05, 06, 07, 09, 10 updated; regenerate via canonical publish.
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe` + `HALP\CDE_User_Guide.pdf`.

## Session status (2026-06-22)

- **WinPE boot menu** — Seven options only; CST offline scan no longer on boot menu.
- **CHU** — Staged `CoreDiag.efi` with upgraded test-session UI; sync USB to pick up on boot media.
- **Diagnostic logs** — Settings button clears CHU UEFI logs/results and CDE workflow logs from toolkit media.
- **User guide** — `HALP\CDE_User_Guide.pdf`; edit `Toolkit\Docs\UserGuide\` (`manifest.json` + chapter `.md` files) and re-run canonical publish to regenerate.
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` → canonical `Toolkit\CDE.exe` + `HALP\CDE_User_Guide.pdf`.

## Session status (2026-06-19)

- **System Health Check** — Grouped property-card output for all catalog checks; fixed Skip regression on short grouped titles and scheduled-task action parsing. `Format-CriticalEventsDetail` exported from `Toolkit.Core.psm1`.
- **Maintenance deduplication** — Removed sidebar **System Audit** and `SystemAudit.ps1`. Audit checks (`audit_*`) run only via `SystemHealthCheck.ps1` + `SystemAuditChecks.ps1`.
- **Malware Cleanup** — Tool list is **Windows Defender Scan** and **Core Security Tool** only. Removed Autoruns, Hosts File Check, Browser Extensions, and Scheduled Tasks audits from Malware Cleanup; `MalwareSweep.ps1` no longer dispatches those tools. Security audits (`sec_*`) run only via System Health Check + `SecurityAuditChecks.ps1`.
- **Regression** — `Test-SkippedHealthChecks.ps1`; `ValidateTools.ps1` routes audit/security validation through `SystemHealthCheck.ps1`.
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` → canonical `Toolkit\CDE.exe`.

## Session status (2026-06-18)

- **System Health Check** — `HealthCheckCatalog.json` trimmed; recommended preset and recommendation rules updated; HW profile toolbar removed from picker.
- **CST / Malware Cleanup** — Update Hash IOCs in CST config dialog; Structured Results from `CST_Result_*.json` (Malware/Virus/PUP/PUM); ~3 artifacts per CST run; cursor-sandbox Tier1 exclusion.
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` → canonical `Toolkit\CDE.exe`.

## Session status (2026-06-16)

- **Diag & Repair** — HW + CST suite shipped: `HardwareDiagnostics.ps1` (`CstScan`, Run All includes CST), `DiagAndRepairView` / `DiagAndRepairViewModel`, `CstRemediationService`, catalog targets `DiagAndRepair`. Publish via `Publish-ToolkitGUI.ps1`.
- **Windows Update** — Field investigation found no evidence of `wuauserv` reverting to **Disabled** on reboot; idle **Stopped** is normal on modern Windows. Health check and PDF now show the full update stack table via `Get-WindowsUpdateStackSnapshot` / `Format-WindowsUpdateStack` in `Toolkit.Core.psm1`.
- **Post-Op Cleanup** — `RestoreDefaultServices` default for `wuauserv` corrected from `Manual` to `Automatic`.
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` run after changes; canonical launcher `Toolkit\CDE.exe`. Relaunch after publish for GUI/script updates.

## Session status (2026-06-12)

- **File Manager** — Directories pane empty on load; Computer tree auto-expands; right pane from drive or shadow-copy selection only.
- **System Audit** — **Startup Entry Audit** (from Post-Op); `[POSTOP:STARTUP]` structured results; `SystemAudit.ps1` step recording fix.
- **Shadow Copies** — All snapshots per VSS set; newest-first sort.
- **Bootloader Repair** — EFI volume targeting, backup pickers, scan without drive picker.
- **Banner** — `Uptime: Xd Xh Xm` (System Audit still shows boot source detail).
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` after GUI changes.

## Session status (2026-06-11)

- **Offline session** — `CDE\Runtime\offline_env.txt` (not USB root); `SyncUSB.bat` clears runtime after sync. Startup Manager Winlogon rows user-verified after WinPE USB round-trip.
- **Backup & Imaging** — Robocopy Backup only; quoting fixes for PowerShell and `robocopy.exe` when destination paths contain spaces.
- **File Manager** — Shadow Copies browse on full Windows (separate from removed Backup VSS workflow).
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` after GUI changes.

## Session status (2026-06-10)

- **Fast Fixes** — `FastFixes.ps1` rewritten with per-fix verification, `Write-FixLog` → GUI-visible output, and `Invoke-FixCommand` using `ProcessStartInfo` (fixes PS 5.1 `Start-Process -RedirectStandardOutput $true` failure). User-verified: Flush DNS, Renew IP, Clear Icon/Thumb Cache, Clear Event Logs (after verification tolerance fix).
- **Uptime** — Banner `Uptime: …` via `BootUptimeHelper.cs`; System Audit uses `Get-CdeBootUptimeInfo` for session + cold-boot detail and event source.
- **Account recovery** — `OfflineSamAccount.psm1`, `EnableOfflineAdministrator.ps1`, Tools Library `executionMode="cde_workflow"`, `OfflineAdministratorDialog`. Enables built-in `.\Administrator` on offline SAM; does not reset Microsoft account / PIN / Entra ID.
- **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` run after GUI changes (2026-06-10). Run `SyncUSB.bat` before USB/WinPE field validation.

## Session status (2026-06-09)

- Fixed UTF-16 script encoding for `MalwareSweep.ps1`, `FastFixes.ps1`, `OSRepair.ps1`, `SmartAnalyzer.ps1`, `Toolkit.Core.psm1`, `Customize-WinPE.ps1`. Malware Cleanup and Fast Fixes verified in CDE. Startup audit hardening (items 1–8) documented in handoff. Relaunch `Toolkit\CDE.exe` after script updates; publish only when GUI/CST source changes.

## Session status (2026-06-05)

- Startup Manager Winlogon UI shipped and user-verified (Userinit reset). CST empty-SHA256 and CIRCL bulk API fixes documented and synced. Run `Toolkit\App\Publish-ToolkitGUI.ps1` after GUI changes.

## Session status (2026-06-04)

- CST FP reduction roadmap landed in **Core Security Tool** workspace: `knownGoodPolicy`, baseline sidecars, optional SQLite goodware, `Validate-CstRuleQuality.ps1`, extended `Publish-ToolkitGUI.ps1` CST mirror. Run publish after CST changes before USB/WinPE validation.

## Session status (2026-06-03)

- Quick Health / Deep Diagnostics: end-of-run Structured Results (Warn/Fail only). Event Logs: `[AUDIT:EVENT]` dedup in System Audit. CST config dialog: removed build-notes/summary/scope-preview column.
- Post-Op Cleanup remediated: `PostOp.ps1`, `Toolkit.Elevation.psm1`, `StartupRisk.ps1` (Startup Entry Audit relocated to System Audit 2026-06-12).

## Session status (2026-06-02)

- Diag & Repair workflow shipped (2026-06-16; originally Hardware Diagnostics 2026-06-02): `HardwareDiagnostics.ps1`, `DiagAndRepairView`, inline execution (no workflow popup). Quick vs Extended profiles; 29 sub-tests (28 HW + CST). Publish via `Publish-ToolkitGUI.ps1`; run elevated for physical disk reads.

## Session status (2026-05-11)

- ToolkitGUI workflow execution now uses a dedicated execution window with live stream + structured completion results.
- `BCD Repair` is intentionally WinPE-only in OS Repair and is disabled outside WinPE.
- ToolkitGUI publish flow was hardened to prevent stale runtime DLL mismatches by publishing to staging and mirroring into the launcher folder.

## Session status (2026-05-13)

- Documentation-only closeout update for app-level handoff consistency.
- Publish guard behavior was refined to avoid false failure when output is unchanged while still validating expected executable presence.
- Runtime guidance is unchanged: publish to the same standardized ToolkitGUI output folder before WinPE validation.

## Session status (2026-05-13 batch-4)

- Batch 4 contract normalization pass completed for remaining workflow scripts and UI result handling.
- Workflow smoke matrix executed for QuickHealth, DeepDiagnostics, SystemAudit, MalwareSweep, BackupAndImage, PostOp, and TempFileCleaner.
- ToolkitGUI release build and standardized publish output were revalidated.

## Session status (2026-05-14)

- Startup Manager Services tab behavior was stabilized end-to-end:
  - Service action error handling now emits explicit categories (for example AccessDenied, ServiceNotFound, AlreadyInDesiredState).
  - TeamViewer restart failures now classify correctly as access-context/permission failures instead of false not-found results.
  - Services startup type UI was updated to use an always-visible selector and immediate apply-on-change behavior (Set Type button removed).
- ToolkitGUI now uses an application manifest with `requireAdministrator` so launch requires UAC consent and gains high-integrity token authority after approval.
- Startup item folder-toggle logic and service list resilience improvements from this session remain in place.
- CST offline correlation validation is complete — `Validate-CstOfflineCorrelation.ps1` was created and all CST validation matrix items are now checked.

## Session status (2026-05-14 CST WinPE triage)

- CST WinPE scan-root diagnostics were expanded so runtime output now includes:
  - resolved scan root
  - discovered Windows roots
  - target counts before and after existence filtering
  - explicit no-target indicator and coverage reason
- CST scan behavior now surfaces `NoTargets` coverage with warning status instead of presenting silent zero-target completion as a normal pass.
- Custom Scan target selection in WinPE was hardened to a shell-independent path prompt flow to avoid blank FolderBrowserDialog trees on affected WinPE systems.
- Field status: target hardware still reproduces zero-coverage scans; current effort is focused on on-device runtime evidence capture (drive visibility, offline root binding, and no-target reasons) rather than additional packaging changes.

**Handoff / integration notes:** see [`session_handoff.md`](session_handoff.md) and [`Toolkit\session_handoff.md`](Toolkit/session_handoff.md) (WinPE, offline registry, DISM packages, USB workflow).

**Repository layout:** application and scripts live under `Toolkit\` (e.g. `Toolkit\App\ToolkitGUI`, `Toolkit\Scripts`).

Set **`TOOLKIT_ROOT`** to the folder that contains `Scripts`, `Config`, and `App` (e.g. `X:\Toolkit` in WinPE).

---

## Components

- **ToolkitGUI** — Single-window UI with dashboard, workflow views, and managers (file manager, startup, processes, temp cleaner, uninstall, fast fixes, tools library, etc.).
- **PowerShell** — `Toolkit.Core.psm1` plus workflow scripts in `Scripts\Workflows\`.
- **WinPE** — Bootable USB/ISO via `Toolkit\Scripts\Customize-WinPE.ps1`, `Prepare-BootableUSB.ps1`, and `SyncUSB.bat` (see `Toolkit\README.md`). At boot, `startnet.cmd` can run `WinPE_OfflineStartup.ps1` to load an offline Windows registry and write **`CDE\Runtime\offline_env.txt`**. `SyncUSB.bat` clears runtime session files after sync. Local-only helpers also exist under `Toolkit\WinPE\`.

---

## Features (in scope of this project)

### Diagnostics

**System Health Check** is the single health diagnostic hub. Use catalog presets **Recommended**, **Quick Vitals**, **Deep System**, or **Full Audit** in the GUI picker, or run from PowerShell with `-Preset`. Completed workflows offer **Open Report** (QuestPDF deliverable under `Logs\`). Raw step text is formatted into readable cards via `WorkflowResultFormatter` in both the GUI and PDF.

| | System Health Check | Diag & Repair |
|---|:--:|:--:|
| CPU / RAM snapshot | Yes (vitals) | Yes (line-item CPU + memory tests) |
| Disk free space | Yes | — |
| Disk SMART / S.M.A.R.T. analyzer | — *(use S.M.A.R.T. Analyzer or Diag & Repair)* | Yes (SMART + read stress) |
| PC-Doctor-style line tests | — | Yes (Quick / Extended) |
| CST security scan | — *(use Malware Cleanup or Diag & Repair)* | Yes (ThreatScan / FullScan, scan-only) |
| Driver audit, GPU, network | Yes (Deep System preset) | — |
| Event logs | 24h + 7d catalog checks | — |
| System audit bundle | Yes (Full Audit preset) | — |
| Security audits (autoruns, hosts, etc.) | Yes (catalog; no Defender/CST) | — |

**Diag & Repair** runs in ToolkitGUI on Windows and WinPE (`HardwareDiagnostics.ps1`). **CHU** (`CoreDiag.efi`) remains the UEFI pre-boot suite on the rEFInd menu.

### OS repair
- SFC and DISM (online; offline where supported in WinPE)
- BCD / bootrec-style repair flows where scripted
- Network stack reset, Windows Update service repair (full Windows)

### Malware cleanup
- **Malware Cleanup** (ToolkitGUI): Windows Defender quick scan and **Core Security Tool** (pre-scan config dialog with **Update Hash IOCs**). Autoruns, hosts file, browser extensions, and scheduled tasks are audited via **System Health Check → Security Audits** (not Malware Cleanup tools).

### Post-op / cleanup
- **Post-Op Cleanup** (ToolkitGUI): browser disk cache; restore critical service start types including `wuauserv` = **Automatic**; repair broken `.exe`/`.lnk`/`.bat`/`.cmd`/`.com` handlers; DNS flush and proxy reset; icon/thumbnail cache clear; optional hosts file restore (backup + confirmation); restart Explorer

### Utilities (GUI)
- File Manager (empty **Directories** on open; browse via drive/shadow-copy tree; read-only **Shadow Copies** on full Windows), **Startup Manager** (Run/GPO/MSIX/scheduled tasks, StartupApproved parity, correlation; Winlogon `Userinit`/`Shell` reset; `\Microsoft\*` tasks hidden by default), **Process Analyzer** (live CPU/RAM triage, risk flags, investigation mode, detail pane with command line/session/parent chain, CST single-file scan, export), Temp File Cleaner, Uninstall Manager, **Fast Fixes** (14 verified one-click fixes with Pass/Fail workflow steps), **Tools Library** (native/boot tools plus **CDE workflows** such as **Enable Offline Administrator** in WinPE), **Dashboard** (**Clear Recent** for work order JSON), **Settings** (Unmount OS, Reboot Windows, **Open User Guide** (`HALP\CDE_User_Guide.pdf`), **Clear Test & Scan Logs** for CHU + CDE scan artifacts)

### Diag & Repair (GUI + script)
- **Diag & Repair** — PC-Doctor-style table: CPU (12), Memory (10), Storage (6), Security Scan / CST (1); Quick/Extended; live `[HW:TEST]` / `[CST:PROGRESS]` in-view; post-scan CST remediation dialog
- **CHU (UEFI)** — `CoreDiag.efi` from rEFInd; separate from WinPE GUI workflow

### Backup and imaging (workflow)
- **Robocopy Backup** — mirror/copy folders via `BackupAndImage.ps1` and `RobocopyConfigDialog` (path quoting hardened 2026-06-11 for drive roots and spaced paths). The former VSS Shadow Copy workflow was removed from this section; browse existing snapshots via File Manager on full Windows.

### System audit and security audits

- **System Health Check** — catalog-driven multi-check orchestrator (`SystemHealthCheck.ps1`, `Config/HealthCheckCatalog.json`); categories **Quick Vitals**, **Deep System**, **System Audit**, **Security Audits** (installed software, drivers, startup, event logs, partitions, autoruns, hosts file, browser extensions, scheduled tasks — not Defender or CST). Unified results view with grouped per-check review and PDF labeled by `CheckId`. Hardware line tests, SMART analyzer, Defender, and CST scan-only are **not** in the catalog — use **Diag & Repair** or **Malware Cleanup**.
- **Startup Entry Audit** — auto-start registry/folder review (`audit_startup`); review/OK cards in Structured Results and PDF (`[REVIEW]` / `[OK]` lines; `[POSTOP:STARTUP]` for live structured parsing)
- **Event Logs** — deduplicated System/Application **errors** (last 24h) via `audit_event_logs` (`[AUDIT:EVENT]` protocol)
- Session + cold-boot uptime detail and event source in **System Information** (`system_info` / `Get-CdeBootUptimeInfo`)

> **2026-06-19:** Standalone Maintenance **System Audit** (`SystemAudit.ps1`) and Malware Cleanup audit tools were removed; all checks above run from **System Health Check** only.

---

## Project structure

```
Toolkit/
├── App/
│   ├── ToolkitGUI/           # WPF app (sln, csproj, Views, ViewModels, Services/)
│   ├── CdeCpuSimdCli/        # PS 5.1 SIMD probe helper (published self-contained with GUI)
│   └── UserGuideGenerator/   # Markdig + QuestPDF → HALP/CDE_User_Guide.pdf (publish step)
├── Docs/UserGuide/           # User guide Markdown source + manifest.json
├── HALP/                     # CDE_User_Guide.pdf, oscdimg.exe, help links
├── Scripts/
│   ├── Core/                 # Toolkit.Core.psm1, HealthCheckOrchestrator.ps1, WinPE_OfflineStartup.ps1
│   └── Workflows/            # SystemHealthCheck, HardwareDiagnostics, OSRepair, MalwareSweep, etc.
├── Config/settings.json
├── Config/HealthCheckCatalog.json
├── Tools/                    # Optional: your portable tools (subfolders by category)
├── WinPE/                    # build_winpe.ps1 and related helpers
└── Logs/                     # Operator PDF reports (internal JSON under CDE/Runtime/Data/)
```

---

## Source repository

**GitHub (private):** [GenNowGamer/Core-Diagnostic-Engine](https://github.com/GenNowGamer/Core-Diagnostic-Engine)

The clone is **source only** (~50 MB). It does not include WinPE images, deploy ISOs, the 1 GB MemTest USB image, or published `CDE.exe` / GUI binaries.

```powershell
git clone https://github.com/GenNowGamer/Core-Diagnostic-Engine.git
cd Core-Diagnostic-Engine
powershell -NoProfile -ExecutionPolicy Bypass -File "Toolkit\App\Publish-ToolkitGUI.ps1"
```

After clone:

1. **Publish** — `Toolkit\App\Publish-ToolkitGUI.ps1` → canonical `Toolkit\CDE.exe` and self-contained GUI + `CdeCpuSimdCli.exe`.
2. **Large binaries** — Place vendor payloads per `Toolkit\Tools\PLACEHOLDER_ACQUISITION.md` and run `Toolkit\Tools\update_tools_manifest.ps1` (notably `sources\boot.wim`, optional `Diagnostics\Memory\MemTest86\memtest86-usb.img`).
3. **USB media** — `Customize-WinPE.ps1` (admin) → `SyncUSB.bat`.

Excluded paths are listed in the repo root `.gitignore` (`Toolkit/Deploy/`, `Toolkit/Mount/`, `*.iso`, `Toolkit/CDE/Runtime/`, etc.).

---

## Build and run

### Prerequisites
- Visual Studio 2022 or .NET 8 SDK
- Windows ADK + WinPE add-on (for building PE media)
- PowerShell 5.1+ (Windows)

### Build the GUI (Windows)

```powershell
cd Toolkit\App
dotnet restore ToolkitGUI.sln
dotnet build ToolkitGUI.sln -c Release
```

Output: `Toolkit\App\ToolkitGUI\bin\Release\net8.0-windows\ToolkitGUI.exe`

### WinPE: publish to standardized path (self-contained)

Publish `ToolkitGUI` self-contained to the single standardized path used by WinPE `startnet.cmd`:

```powershell
cd Toolkit\App\ToolkitGUI
dotnet publish ToolkitGUI.csproj -c Release -r win-x64 --self-contained true -o "bin\Release\net8.0-windows"
```

The helper script below already cleans nested `win-x64` output automatically.

WinPE `startnet.cmd` launches only `bin\Release\net8.0-windows\ToolkitGUI.exe`. Keep this folder populated via `dotnet publish` (not `dotnet build`) so Windows/WinPE machines without preinstalled .NET runtime still launch correctly.

Optional helper script:

```powershell
.\Toolkit\App\ToolkitGUI\publish_standardized.ps1
```

### Run from Windows

Launch `ToolkitGUI.exe` from the build output. Scripts are resolved via `TOOLKIT_ROOT` or by walking up to `Scripts\Core\Toolkit.Core.psm1` (`ToolkitPaths`).

### WinPE media (CDE toolkit scripts)

Use **`Toolkit\Scripts\Customize-WinPE.ps1`** to customize `boot.wim`, then **`Prepare-BootableUSB.ps1`** and **`SyncUSB.bat`** to stage the toolkit, rEFInd, and boot payloads onto USB. See `Toolkit\README.md` for the full flow. Keep WinPE optional components enabled so `powershell.exe` exists for offline setup.

**Offline Windows:** `Scripts\Core\WinPE_OfflineStartup.ps1` can load offline registry hives and write **`%TOOLKIT_ROOT%\CDE\Runtime\offline_env.txt`**. The GUI applies that file after offline load (and clears stale session state on WinPE Normal CDE). When an offline Windows installation is found, the script **always prompts Y/N** (with a 30-second timeout defaulting to N) before loading hives — it never auto-confirms, even for a single detected installation.

### WinPE media (local WinPE helpers only)

```powershell
# As Administrator
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
cd Toolkit\WinPE
.\build_winpe.ps1
```

Optional: `-WorkingDir`, `-OutputISO`, etc. (see script parameters).

### Using the toolkit

**Windows:** Open the app, use the left nav, run workflows from each view. Operator PDFs go under `Logs\`; internal JSON and session logs under `CDE\Runtime\Data\`.

**WinPE:** Boot the **Core Diagnostic** WinPE image (USB/ISO you built). After `wpeinit`, `startnet` runs offline detection (if PowerShell is present) and starts `ToolkitGUI`. Some features are limited in PE (e.g. Windows Update, client VSS snapshot creation). File Manager **Directories** pane starts empty; use the tree to open a drive or shadow copy (full Windows for shadow copies).

For current rEFInd USB builds, validate before rebooting target hardware (replace `H:` with your USB drive letter):

```powershell
Test-Path "H:\EFI\boot\bootx64.efi"
Test-Path "H:\EFI\boot\refind.conf"
Test-Path "H:\EFI\CDE\CoreDiag.efi"
Test-Path "H:\EFI\CDE\memtest.efi"
Test-Path "H:\sources\boot.wim"
Test-Path "H:\Toolkit\App\ToolkitGUI\bin\Release\net8.0-windows\ToolkitGUI.exe"
```

Expected: rEFInd is the UEFI fallback loader, CHU and memtest EFI payloads are under `EFI\CDE\`, WinPE `boot.wim` is present, and the published toolkit GUI exists on the USB tree.

---

## Optional files in `Tools\`

You may place **your own** portable executables under `Tools\` (e.g. `Hardware\`, `Disk\`, `Malware\`, `Imaging\`, `Network\`, `OS\`). The **Tools Library** view lists what is present. Nothing in `Tools\` is required for the engine itself.

Current onboarded catalog entries are defined in `Toolkit\Tools\ToolCatalog.xml` and tracked by `Toolkit\Tools\tools_manifest.json`. Legacy third-party and proprietary tools (ClamWin Portable, CrystalDiskInfo, TestDisk/PhotoRec, SystemRescue, OfflineNT, and ShredOS) were removed from the catalog and tree. The current boot-class payloads are **Core Hardware Utility (UEFI)** (`CoreDiag.efi` under `Tools\Boot\CoreHardwareUtility\`) and **Microsoft Windows Memory Diagnostic** (`memtest.efi` under `Tools\Boot\WinMemoryDiag\`). The **Tools Library** supports `executionMode` values such as `native`, `boot_efi`, and **`cde_workflow`** (in-process PowerShell workflows with the workflow execution window; requires `workflowScript` in the catalog). First-party **`cde_workflow`** tool: **Enable Offline Administrator** under **ACCOUNT RECOVERY** (WinPE + `OFFLINE_REGISTRY_LOADED=1` only).

For CHU onboarding in this repo:

- Build `CoreDiag.efi` in the CHU repo (`Core Hardware Utility\UEFI`).
- Stage it to `Toolkit\Tools\Boot\CoreHardwareUtility\CoreDiag.efi`.
- Regenerate the tools manifest with `update_tools_manifest.ps1` before syncing USB media.

**Helper scripts** in `Toolkit\Tools\` (run from that folder in PowerShell):

| Script | Purpose |
|--------|--------|
| `update_tools_manifest.ps1` | Regenerate `tools_manifest.json` after you add or change files under `Tools\` |
| `Ensure-BootArtifacts.ps1` | Copy `%SystemRoot%\Boot\EFI\memtest.efi` into `Boot\WinMemoryDiag\` and refresh the manifest (Admin not required; DISM-free) |

Quick CHU staging example (adjust EDK2 build output path for your machine):

```powershell
Copy-Item -Force `
  "<edk2>\Build\CoreDiagPkg\RELEASE_VS2022\X64\CoreDiag.efi" `
  ".\Toolkit\Tools\Boot\CoreHardwareUtility\CoreDiag.efi"

Set-Location .\Toolkit\Tools
.\update_tools_manifest.ps1
```

> **Note:** After staging CHU, run `update_tools_manifest.ps1` so `tools_manifest.json` records the new SHA256 hash for boot-class payloads.

### MRI compatibility mode (current state)

- `Toolkit\App\ToolkitGUI\Views\ToolsLibraryView` now supports both:
  - CDE-native tool entries (`relativePath`)
  - MRI-style metadata (`discFolder` + `executeFile`, `dlUrl`, `dlFile`, `autoCleanup`)
- Placeholder entries/functions are intentionally visible right now for product review:
  - `Acquire` buttons are shown; direct download URLs now run a controlled flow (stage -> hash verify -> promote).
  - Entries without direct download metadata remain visible as inactive/planned acquire items.
  - File and folder payload acquisitions are supported (`.zip` extraction for folder targets).
  - `autoCleanup` currently removes CDE staging folders when enabled.
- Runtime profile file: `Toolkit\Config\global.ini`
  - `Language`, `Skin`, `ShowSplash`, `LogLevel`

---

## PowerShell (direct)

Toolkit workflow scripts must be **UTF-8 with BOM** (not UTF-16). See `Toolkit\README.md` — *PowerShell script encoding*.

```powershell
Import-Module .\Toolkit\Scripts\Core\Toolkit.Core.psm1
.\Toolkit\Scripts\Workflows\SystemHealthCheck.ps1 -Preset quick_vitals
.\Toolkit\Scripts\Workflows\SystemHealthCheck.ps1 -Preset deep_system
# etc.
```

---

## Architecture (high level)

```
Bootable WinPE (USB/ISO)  →  X:\  →  startnet.cmd
                                        →  WinPE_OfflineStartup.ps1 (optional)
                                        →  CDE.exe → ToolkitGUI.exe
                                              →  PowerShellService / workflows
                                              →  Toolkit.Core.psm1 + Scripts\Workflows\*.ps1
                                              →  HardwareDiagnostics.ps1 ([HW:TEST] / [CST:PROGRESS] live lines)
```

---

## Logs

Operator PDF deliverables are written to `Logs\`. Structured workflow/scan JSON and PowerShell session logs are stored under `CDE\Runtime\Data\` (not in `Logs\`).

---

## License

Scripts in this repository are provided as-is. **Tools** you add under `Toolkit\Tools\` must follow their own licenses.

---

## Extending the app

New features are typically: add a workflow script, wire a view model, add a view, register navigation in `MainViewModel`. Example: **Diag & Repair** (`HardwareDiagnostics.ps1`, `DiagAndRepairViewModel`, `DiagAndRepairView`, nav key `DiagAndRepair`, alias `HardwareDiagnostics`).
