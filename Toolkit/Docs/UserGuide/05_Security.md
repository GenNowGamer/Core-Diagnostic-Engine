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
2. Click **Open** on **Core Security Tool**
3. In the config dialog, set scan type (**ThreatScan** / **FullScan** / **CustomScan**), detection scope (**All** recommended), and optional custom paths
4. The **CST Scan Results** window opens immediately with live progress (same layout as File Manager / Startup Manager / Process Analyzer). Pre-scan steps (targets, known-good baselines, path discovery) and file analysis both update the progress panel — the window should not sit idle with no status
5. When finished, the same window shows the verdict, metrics, and primary findings. If review-only rows exist, a single collapsed **Suppressed audit Findings** line appears at the bottom of the Findings card; expand it to inspect those rows
6. Use **Copy summary** or **Open Report** for coverage notes and full scan narrative (coverage/action summary is not shown in the dialog footer)
7. Use **Open Report** to open the operator PDF (`Logs\CST_Scan_*.pdf`) generated when results appear
8. Select **actionable** findings and use **Quarantine Selected**, **Remove Selected**, or **Restore from Manifest...** — remediation runs with a **per-item progress** window, then a summary. No separate post-scan operator dialog is required after Malware Cleanup CST
9. **Archive hits:** inner `zip::entry` rows are review-only; select the **parent .zip/.jar** row to quarantine or remove the container

> **ThreatScan** is a high-risk-path triage (not full-disk AV). It walks ProgramData, Temp, Tasks, Startup, Downloads, **Users\Public**, per-user **Desktop** / **Documents** / Roaming / INetCache (and more). Prefer **FullScan** or a folder **CustomScan** when hunting outside those roots. Authenticode timeout alone is a coverage event and does not create a security finding. An unsigned DLL in a risky path is only a weak signal unless another detector corroborates it; unsigned executables retain stronger handling. Empty EFI hash baselines are noted in **Copy summary** / PDF **Coverage**, not as a findings row.

> **WinPE + offline OS:** Boot menu **option 2** so CST can scan the customer's Windows folder. Without offline load, CST may show "no Windows volume found."

### Update Hash IOCs

Threat signature updates are in the CST config dialog under **Threat Signature Database** (not a separate Malware Cleanup button).

---

## Security audits vs malware scans

CDE separates **active scanning** from **configuration audits**:

| Activity | Where to run it |
|----------|-----------------|
| Defender scan, CST malware scan | **Malware Cleanup** |
| Autoruns, hosts file, browser extensions, scheduled tasks, browser/network hijack, Defender exclusions/security tampering, ransomware recovery, driver/filter inventory, remote access | **System Health Check** → Security Audits or Deep System category |

**Scheduled Tasks Audit** flags non-Microsoft tasks with suspicious execute paths or unsigned COM handlers. Microsoft-signed software under AppData (e.g. OneDrive) is not flagged for path alone. COM-only actions show the resolved handler (`COM {guid} -> path`) and a **Review Reason** when flagged.

**Security Tampering Audit** inventories risky Microsoft Defender exclusions when Defender is available. If Defender is disabled or another antivirus owns protection, an unavailable Defender service is treated as N/A rather than a malicious exclusion.

**Ransomware Recovery Audit** reviews VSS/backup-service and Windows Recovery Environment state for recovery impairment. **Driver Signature Audit** also inventories file-system minifilters and disk/volume UpperFilters/LowerFilters; known Microsoft and installed security-product filters are not suspicious merely because they are present.

> **Important:** Do not look for Autoruns or Hosts File checks under Malware Cleanup — they were moved to System Health Check only.

---

## Hijack & Scam Repair

**What this does:** Scans for hijacked browser settings, network redirects, suspicious startup entries, tampered security settings, and remote-access tooling — then lets you repair selected items or review startup rows in Startup Manager.

### Scan workflow

1. Sidebar → **Hijack & Scam Repair**
2. Click **Scan** (becomes **Re-Scan** after the first completed scan)
3. While scanning, the findings grid shows a centered **Scanning...** overlay (same pattern as Startup Manager loading)
4. Review flagged rows in the grid; select a row for **Finding Details** below the grid (location, current value, repair action, guidance). Drag the splitter between Findings and Finding Details to resize
5. Check **FIX** on repairable rows, or click **Select repairable** to check all flagged items that can be fixed here
6. Click **Repair Selected** for bulk fixes, or **Repair this item** in Finding Details for one row

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
- Startup Manager **Suspicious only** uses hijack-scanner heuristics for startup entries and service-specific risk heuristics on the Services tab

### Quick Repairs drawer

Expand **Quick Repairs** at the bottom of the view for bulk scripts (browser, network, security settings, repair-all). These run full repair workflows and may require elevation. Quick Repairs sits in its own bottom row so it does **not** cover **Finding Details**.

> **Tip:** Scan results stay in memory when you switch to another sidebar tool and return — you do not need to re-scan to review findings. Run **Re-Scan** after making system changes.

> **Note:** Some startup and extension findings are **review-only** in this scanner; disable or delete them in **Startup Manager** rather than **Repair Selected**.

---

## After malware removal

1. Re-run **System Health Check** security audits
2. Run **Post-Op Cleanup** (browser cache, services, file associations, DNS/proxy reset, icon cache, optional hosts restore)
3. Check **Startup Manager** for suspicious startup entries
4. Deliver a **PDF report** from Malware Cleanup or Health Check to document what was found
