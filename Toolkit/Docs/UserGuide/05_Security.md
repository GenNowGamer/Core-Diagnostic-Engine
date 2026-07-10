# Security

## Malware Cleanup

**What this does:** Runs antivirus and custom malware scanning tools from one screen.

### Tools in this view

| Tool | Purpose |
|------|---------|
| **Windows Defender Scan** | Microsoft's built-in quick scan (live Windows) |
| **Core Security Tool (CST)** | CDE's advanced scan engine with configurable scope and remediation |

### Steps — Core Security Tool

1. Sidebar → **Malware Cleanup**
2. Click **Core Security Tool** (or open **⚙ Config** first)
3. In the config dialog, set scan type (**Threat Scan** or **Full Scan**), targets, and remediation options
4. Run the scan and watch progress in the workflow window
5. Review structured results and the post-scan findings dialog

**Structured results (default)** — Malware Cleanup and Diag & Repair CST rows show actionable findings only (Malware, Virus, PUP, PUM). Expand **Show all findings and scan metadata** in the workflow window for detector details and scan metadata. Use **Open full CST report (PDF)** for the operator PDF under `Logs\` (not the raw JSON artifact). Process Analyzer CST keeps its dedicated results dialog.

> **WinPE + offline OS:** Boot menu **option 2** so CST can scan the customer's Windows folder. Without offline load, CST may show "no Windows volume found."

### Update Hash IOCs

Threat signature updates are in the CST config dialog under **Threat Signature Database** (not a separate Malware Cleanup button).

---

## Security audits vs malware scans

CDE separates **active scanning** from **configuration audits**:

| Activity | Where to run it |
|----------|-----------------|
| Defender scan, CST malware scan | **Malware Cleanup** |
| Autoruns, hosts file, browser extensions, scheduled tasks, browser/network hijack, security tampering, remote access | **System Health Check** → Security Audits category |

> **Important:** Do not look for Autoruns or Hosts File checks under Malware Cleanup — they were moved to System Health Check only.

---

## Hijack & Scam Repair

**What this does:** Scans for hijacked browser settings, network redirects, suspicious startup entries, tampered security settings, and remote-access tooling — then lets you repair selected items or review startup rows in Startup Manager.

### Scan workflow

1. Sidebar → **Hijack & Scam Repair**
2. Click **Scan** (becomes **Re-Scan** after the first completed scan)
3. While scanning, the findings grid shows a centered **Scanning...** overlay (same pattern as Startup Manager loading)
4. Review flagged rows in the grid; select a row for the **detail panel** below (location, current value, repair action, guidance)
5. Check **FIX** on repairable rows, or click **Select repairable** to check all flagged items that can be fixed here
6. Click **Repair Selected** for bulk fixes, or **Repair this item** in the detail pane for one row

### Grid columns

| Column | Meaning |
|--------|---------|
| **FIX** | Include in **Repair Selected** (enabled only when ACTION = Fix here) |
| **ACTION** | **Fix here** (auto-repair), **Startup Manager** (review-only startup row), or **Info only** |
| **CATEGORY** | Browser, Network, Security, Startup, Remote, etc. |
| **RISK** | Severity (e.g. Hijacked, Suspicious) |
| **NAME** | Short description of the finding |

### Reports and export

After a scan completes:

| Button | Use for |
|--------|---------|
| **Open Report** | Open the operator PDF from `Logs\` (generated automatically after the scan) |

Use **Show scan log** in the detail toolbar if you need the raw workflow output.

### Startup Manager integration

- **Startup Manager** toolbar button opens Startup Manager with **Suspicious only** enabled
- **Manage** on a startup finding jumps to Startup Manager filtered to that entry
- Startup Manager **Suspicious only** checkbox uses the same heuristics as the hijack scanner

### Quick Repairs drawer

Expand **Quick Repairs** at the bottom of the view for bulk scripts (browser, network, security settings, repair-all). These run full repair workflows and may require elevation.

> **Tip:** Scan results stay in memory when you switch to another sidebar tool and return — you do not need to re-scan to review findings. Run **Re-Scan** after making system changes.

> **Note:** Some startup and extension findings are **review-only** in this scanner; disable or delete them in **Startup Manager** rather than **Repair Selected**.

---

## After malware removal

1. Re-run **System Health Check** security audits
2. Run **Post-Op Cleanup** (browser cache, services, file associations, DNS/proxy reset, icon cache, optional hosts restore)
3. Check **Startup Manager** for suspicious startup entries
4. Deliver a **PDF report** from Malware Cleanup or Health Check to document what was found
