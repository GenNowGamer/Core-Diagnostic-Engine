# Understanding Reports

## Where reports are saved

CDE separates **operator deliverables** from **internal app data**:

| Location | Contents |
|----------|----------|
| **`Logs\`** | **PDF only** — printable reports for customers and case files |
| **`CDE\Runtime\Data\workflows\`** | Internal workflow JSON (step details, health summaries) |
| **`CDE\Runtime\Data\scans\`** | Internal JSON for Hijack & Scam Repair and Process Analyzer snapshots |
| **`CDE\Runtime\Data\cst\`** | Internal CST scan JSON from Process Analyzer single-file scans |
| **`CDE\Runtime\Data\sessions\`** | PowerShell session `.log` files (not written to `Logs\`) |

CHU pre-boot tests write separately to **`EFI\CoreDiag\Logs`** and **`EFI\CoreDiag\Results`**. Logs are opened early in boot (before the CHU UI initializes) when the `CDEDATA` volume is writable.

When a workflow or scan finishes, CDE generates the internal JSON first, then builds the matching PDF under `Logs\` with the same base filename.

## Opening reports

After a workflow or scan finishes, use **Open Report** in the tool, workflow window, or case timeline. CDE opens the PDF from `Logs\` through Windows Explorer (works when CDE is elevated).

| Tool | Where to open |
|------|----------------|
| **Workflow execution window** | **Open Report** (Artifacts panel) — shown for OS Repair, Malware Cleanup, Post-Op Cleanup, Fast Fixes, Temp File Cleaner, Backup & Imaging, and similar workflow tools |
| **System Health Check** | **Open Report** on the results screen |
| **Hijack & Scam Repair** | **Open Report** after a scan |
| **Process Analyzer** | **Open Report** after processes are loaded |
| **S.M.A.R.T. Analyzer** | **Open Report** after a scan |
| **CST Scan Results** | **Open Report** when live CST results finish (Malware Cleanup / File Manager / Startup Manager / Process Analyzer / Core Security Tool) |
| **Diag & Repair** | **Dashboard → Case timeline → Open Report** when a work order is active, or open the matching `.pdf` in `Logs\` (no in-view button; live progress stays on the Diag screen) |
| **Disk & Boot Repair** | **Dashboard → Case timeline → Open Report**, or browse `Logs\` |

There is no **Save report** or **Open HTML** button in the GUI — operators use the PDF in `Logs\`. Internal JSON under `CDE\Runtime\Data\` is cleared with **Settings → Clear Test & Scan Logs**; work order case JSON is cleared separately with **Dashboard → Clear Recent**.

## What PDF reports contain

- Workflow name and timestamp
- Overall health summary (Pass / Warn / Fail counts)
- Step-by-step results in plain language
- System Health PDFs label each check using friendly names from the health catalog
- Hijack & Scam Repair and Process Analyzer PDFs use a findings/process table layout (landscape) suitable for bench notes

## Work orders and logging

When a work order is active on the Dashboard, runs are appended to that case:

| Event kind | Typical source |
|------------|----------------|
| **Workflow** | Malware Cleanup, OS Repair, Diag & Repair, Post-Op Cleanup, Temp File Cleaner, Fast Fixes, etc. |
| **ChuPreBoot** | Refresh on **CHU Pre-Boot Results** (once per JSON file) |
| **CstScan** | Process Analyzer **CST scan file** |

Each run may store paths to internal JSON and the operator PDF. The Dashboard **Case timeline** and work order detail window provide **Open Report** when the PDF still exists on disk.

Use consistent case IDs for shop billing and revisit history on the USB.

## Clearing old reports

Before a new customer job on a shared USB:

1. Sidebar → **Settings**
2. **Clear Test & Scan Logs**
3. Confirm deletion

This removes CHU `EFI\CoreDiag\Logs` and `Results`, operator PDFs in `Logs\`, and internal data under `CDE\Runtime\Data\` (workflows, scans, CST, session logs).

To clear saved work order case records (not the closed-case PDFs), use **Dashboard → Recent work orders → Clear Recent**.

Locked files (active scan still running) may fail to delete — wait for the workflow to finish and try again.
