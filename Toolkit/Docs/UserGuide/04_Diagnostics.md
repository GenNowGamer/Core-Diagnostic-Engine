# Diagnostics

This chapter covers the main **find problems** tools in the MAIN sidebar section.

## System Health Check

**What this does:** Runs a catalog of automated checks (vitals, deep system info, audits, security reviews) and presents scored findings together with detailed technical inventories and a PDF report.

### When to use it

- First pass on any machine (quick overview)
- Before and after major repairs (before/after comparison)
- When you need one report covering many areas

### Steps

1. Sidebar → **System Health Check**
2. Use a preset (**Recommended**, **Quick Vitals**, **Deep System**, **Full Audit**) or tick individual checks in the category list (**Select All** / **Clear All** as needed)
3. Click **Run Health Check**
4. Review the left-side cards — green Pass, yellow Warn, red Fail. The currently open card has a blue highlight, left accent, and **VIEWING** badge
5. In the right panel, review:
   - **Actionable / verified findings** — Finding, Impact, Severity, deterministic Confidence (0–100 match score), Evidence, and Recommendations
   - **Detailed results** — the full adapter, device, service, event, or inventory information collected by the check
6. The **Findings** list follows the catalog order in `Config/HealthCheckCatalog.json` (`findingsDisplayOrder`: Activation through Remote Access)
7. Click **Open Report** for a printable PDF summary (`Logs\`)

> **Confidence:** This is a deterministic rule/evidence match score from 0–100, not a probability that hardware or software is faulty.

### What is included

| Category | Examples |
|----------|----------|
| Quick Vitals | OS version, CPU load, RAM, disk space, activation, recent errors |
| Deep System | Drivers, Windows Update stack (idle **Stopped** + **Manual** `wuauserv` is normal on Win10/11), network adapters, GPU information, GPU functional tests, critical events |
| System Audit | Installed software, services, startup entries, event logs, partitions |
| Security Audits | Autoruns, hosts file, browser extensions, scheduled tasks, browser hijack, network hijack, security tampering, remote access |

> **Important:** Heavy scans (SMART deep tests, Defender, line-item hardware tests) are **not** in Health Check — use **S.M.A.R.T. Analyzer**, **Diag & Repair**, and **Malware Cleanup** instead.

### Event and GPU findings

- Event-log checks correlate related records into findings such as unexpected shutdown, BSOD, application crash, storage/NTFS, WHEA hardware, service, update, and display-driver failures. Raw/deduplicated event evidence remains available in the detailed output.
- **GPU Information** is inventory-only. **GPU Functional Tests** is a separate active check covering driver state, DirectX, OpenGL, Vulkan, a capped VRAM write/readback test, and best-effort temperature reporting.
- WinPE, Remote Desktop, Microsoft Basic Display, missing graphics runtimes, or unavailable vendor temperature tools can produce **N/A**. That means the test could not run in that environment; it is not automatically a failure.

---

## S.M.A.R.T. Analyzer

**What this does:** Reads disk self-monitoring data (SMART) for fixed internal and external drives and shows health attributes.

> **Removable media:** USB flash drives, memory cards, and other removable media are **not** listed or scanned (including the CDE boot USB in WinPE). USB external hard drives that report as fixed media may still appear.

### Steps

1. Sidebar → **S.M.A.R.T. Analyzer**
2. Select a drive from the list
3. Click **Scan** (or refresh)
4. Review overall health badge and attribute table
5. When the scan finishes, **Open Report** enables and opens the PDF under `Logs\` (built from the scan results — status should not stay on “Saving…” forever)

### Next steps

- Failing SMART → recommend drive replacement; run **Diag & Repair → Storage** for read tests
- Healthy SMART but slow disk → check free space (Health Check) and temp files (**Temp File Cleaner**)

---

## Diag & Repair

**What this does:** Runs detailed line-by-line hardware tests (CPU, memory, storage) plus an optional **Core Security Tool** scan-only pass — similar to commercial PC diagnostic suites.

### Profiles

| Profile | Use when |
|---------|----------|
| **Quick** | Bench triage; shorter run times |
| **Extended** | Deeper stress; more thorough disk and CPU work |

### Steps

1. Sidebar → **Diag & Repair**
2. Choose **Quick** or **Extended**
3. Click **Run All Tests** or run **CPU Tests**, **Memory Tests**, **Storage Tests**, or **CST Scan** individually
4. Watch the live results table as each sub-test completes
5. After CST scan, review the post-scan dialog for detections (remediation optional)
6. A PDF report is saved under `Logs\` when the run finishes. With an active work order, use **Dashboard → Case timeline → Open Report**; there is no **Open Report** button on the Diag & Repair screen itself

> **Tip:** Run CDE as Administrator for full storage physical-read tests. In WinPE with offline Windows loaded, CST can scan the customer's volume.

> **Removable media:** Storage tests run only on **fixed testable** drives. USB flash sticks, SD/microSD cards, and the toolkit boot USB are excluded automatically. If no fixed drives are present, storage discovery **fails** with no physical drives detected.

### CPU tests (PowerShell 5.1)

On Windows 10/11, CDE runs under **PowerShell 5.1**. CPU SIMD line tests (MMX, SSE, SSE2, …) use **`CdeCpuSimdCli.exe`**, published self-contained next to `ToolkitGUI.exe`. You should see **Pass** or **Fail** per row — not a permanent **Warn** with “stub engine.” If every SIMD row warns about a stub, republish with `Publish-ToolkitGUI.ps1` and run `SyncUSB.bat`.

---

## Testable drive policy (Diag & Repair, S.M.A.R.T., CHU)

CDE and CHU use the same intent: **do not hardware-test removable media.**

| Surface | What is excluded | What may still be tested |
|---------|------------------|---------------------------|
| **Diag & Repair → Storage** | Removable media (`Win32_DiskDrive.MediaType` / `Get-Disk.IsRemovable`) | Internal SATA/NVMe; many USB external HDDs (fixed media) |
| **S.M.A.R.T. Analyzer** | Same filter via `PhysicalDiskCatalog.psm1` | Same |
| **CHU (UEFI)** | `EFI_BLOCK_IO_MEDIA.RemovableMedia` at drive enumeration | Fixed disks only in the storage test tree |

**Not affected:** Disk & Boot Repair still lists all disks (including removable) for layout and repair work. System Health disk inventory is unchanged.

---

## CHU Pre-Boot Results

**What this does:** Shows JSON results from **Core Hardware Utility** (`CoreDiag.efi`) after you run pre-boot hardware tests from the rEFInd menu.

### Steps

1. Boot USB → rEFInd → **Core Hardware Utility** (loads `CHUPrep.efi`, then `CoreDiag.efi`)
2. Run memory, storage, or CPU tests (or Run All) — storage tests target **fixed** drives only (boot USB and other removable media are not listed)
3. After tests, use **UP/DOWN** in the results review screen to scroll the full list; press **ENTER** to return to the CHU menu
4. Boot back into CDE WinPE or Windows
5. Sidebar → **CHU Pre-Boot Results** → **Refresh**

Results are stored on the toolkit volume under `EFI\CoreDiag\Results`. Session logs are under `EFI\CoreDiag\Logs` (written from early boot when the `CDEDATA` volume is available).

> **Display modes:** On many desktops CHU uses a **PC-Check-style text** interface. On some laptops the firmware shows only a GOP framebuffer — CHU switches to a graphics menu automatically. Both paths support the same tests and review scroll.

The status bar shows a **rollup** (pass / warn / fail counts). When a test maps to the hardware catalog, the row shows the catalog display name. For warned or failed tests, use **Open matching Diag & Repair test** to jump to the same test in Diag & Repair (highlighted, no auto-run). With an active work order, loading results also adds a **CHU pre-boot** entry to the Dashboard case timeline.

---

## CHU vs Diag & Repair

| Tool | When it runs | Best for |
|------|--------------|----------|
| **CHU (UEFI)** | Before Windows starts | Raw hardware validation, no OS interference |
| **Diag & Repair (WinPE/Windows)** | Inside CDE GUI | Technician workflow, combined with CST, live progress in CDE |

Use both when a machine has intermittent hardware faults — CHU for pre-boot proof, Diag & Repair for documented in-session runs with PDF workflow output.

When Diag & Repair reports **partial memory coverage**, **CPU stress warnings**, or **storage elevation warnings**, the view shows a CHU guidance banner with a link to **CHU Pre-Boot Results**. That means Windows-side coverage is incomplete for clearing intermittent hardware risk — run CHU from the USB pre-boot menu for physical validation.
