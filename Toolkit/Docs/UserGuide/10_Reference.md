# Reference

## Sidebar map

| Section | Items |
|---------|-------|
| **MAIN** | Dashboard, System Health Check, S.M.A.R.T. Analyzer, Diag & Repair, CHU Pre-Boot Results |
| **REPAIR** | OS Repair, Malware Cleanup, **Hijack & Scam Repair**, Disk & Boot Repair |
| **MAINTENANCE** | Backup & Imaging, Post-Op Cleanup |
| **UTILITIES** | Tools Library, File Manager, Startup Manager, Process Analyzer, Temp File Cleaner, Uninstall Manager, Fast Fixes, Settings |

## WinPE capability matrix

| Feature | WinPE (no offline) | WinPE + offline OS | Full Windows |
|---------|-------------------|-------------------|--------------|
| System Health Check | Partial | Most audits | Full |
| Malware Cleanup (CST) | Limited | Full offline scan | Full live scan |
| Defender scan | N/A | N/A | Yes |
| OS Repair SFC | DISM path | Offline DISM | Online SFC |
| Disk & Boot Repair | Yes | Yes | Gated off |
| Fast Fixes | Mostly N/A | Mostly N/A | Full |
| File Manager shadow copies | No | Drive browse | Yes |
| Account recovery tools | No | Yes | N/A |

## Glossary

| Term | Meaning |
|------|---------|
| **BCD** | Boot Configuration Data — Windows boot settings database |
| **CHU** | Core Hardware Utility — UEFI pre-boot hardware diagnostics (`CHUPrep.efi` → `CoreDiag.efi` from rEFInd) |
| **CdeCpuSimdCli** | Small .NET helper beside published `ToolkitGUI.exe`; runs real CPU SIMD tests when CDE uses PowerShell 5.1 |
| **CST** | Core Security Tool — CDE malware scan engine |
| **DISM** | Deployment Image Servicing and Management — repairs Windows component store |
| **Hive** | A registry database file loaded offline in WinPE (e.g. customer's SOFTWARE) |
| **Offline OS** | Customer's Windows installation accessed from WinPE without booting it normally |
| **rEFInd** | UEFI boot menu on the CDE USB |
| **SFC** | System File Checker — verifies and repairs protected Windows files |
| **SMART** | Self-Monitoring Analysis and Reporting Technology — disk health data |
| **Testable drive** | Fixed non-removable physical disk eligible for Diag & Repair storage tests, S.M.A.R.T. Analyzer, and CHU storage catalog runs (USB flash and memory cards excluded) |
| **WinPE** | Windows Preinstallation Environment — minimal Windows for recovery |
| **WinPE startup log** | `CDE\Runtime\winpe_startup.log` — boot menu → main window handoff trace (also `X:\winpe_startup.log` in PE) |
| **Work order** | Case record on Dashboard tying jobs to a client; internal JSON under `CDE\Runtime\WorkOrders\`; closed-case PDF under `Toolkit\WorkOrders\` |
| **Clear Recent** | Dashboard control that deletes saved work order JSON in `CDE\Runtime\WorkOrders\` (not operator PDFs) |
| **EventKind** | Work-order run label: `Workflow`, `ChuPreBoot`, `CstScan`, or `FastFix` |
| **GuidanceContext** | Work-order field storing last symptom id and health preset (`Config\SymptomFlows.json`) |
| **Suggested path** | Dashboard highlight under **What are you seeing?** — inferred from notes or set by symptom click |

## Troubleshooting CDE

| Problem | Try |
|---------|-----|
| Boot menu closes but no main CDE window (text recovery menu) | Sync latest `CDE\ToolkitGUI\bin\Release\net8.0-windows\` via `Publish-ToolkitGUI.ps1` + `SyncUSB.bat`; read `CDE\Runtime\winpe_startup.log` on USB |
| WinPE window maximize crashes to recovery menu | Fixed 2026-07-03 — update GUI payload on USB; same publish/sync path |
| Offline OS not detected | Boot menu option 2; check disk cables; load storage drivers if needed |
| CST finds no targets | Confirm offline Windows loaded; pick correct drive letter |
| PDF won't open | Install a PDF viewer; check `Logs` folder for the `.pdf` file |
| CHU results empty | Run CHU from rEFInd first; click Refresh in CHU Pre-Boot Results |
| Boot USB not in storage tests | Expected — removable media (including CDE USB) is excluded from Diag & Repair, S.M.A.R.T., and CHU storage enumeration |
| Storage tests fail with no drives | Machine may have only removable media visible; attach or select a fixed internal/external HDD |
| Boot repair greyed out | Boot from USB (WinPE) — not available on live Windows desktop |
| DISM Warn 0x800f081f | Mount matching Windows ISO; rerun DISM and browse to `sources\install.wim`, or run Windows Update Repair first |
| User guide missing | Re-run toolkit publish; confirm `HALP\CDE_User_Guide.pdf` on USB |
| Workflow failed after success (exit code 1) | If clean/report looked OK but GUI shows errors, check `CDE\Runtime\Data\workflows\` for internal JSON or `Logs\` for the PDF; update toolkit scripts (`WorkOrder.ps1` fix 2026-06-26). Re-run the workflow |
| Temp cleaner many "access denied" warns | Normal for files locked by running apps (IDEs, compilers); review freed space in the summary |
| DNS flush / proxy reset / icon cache | Use **Post-Op Cleanup** (removed from Fast Fixes and OS Repair network reset) |

## Document information

- **Product:** Core Diagnostic Engine (CDE)
- **Launcher:** `Toolkit\CDE.exe`
- **User guide path:** `Toolkit\HALP\CDE_User_Guide.pdf`
- **Regenerate guide:** run `Toolkit\App\Publish-ToolkitGUI.ps1` (canonical publish)
