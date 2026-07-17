# Recommended Repair Workflow

## Start here: a practical bench order

Use this order for a typical "computer won't behave" job. Adjust based on the customer's symptoms.

On the **Dashboard**, the **What are you seeing?** symptom cards mirror this workflow. Enter client notes and **Generate Work Order** — CDE infers the best path from keywords in your notes (or click a symptom chip to choose explicitly). The suggested card highlights immediately and shows follow-up tools.

```
Symptoms → Health Check → Targeted tests → Repair → Verify → Cleanup
```

### Step 1 — Understand the problem

Ask what changed: updates, new software, malware pop-ups, no boot, slow performance, network loss. Note whether Windows starts normally.

### Step 2 — Boot CDE correctly

| Situation | Boot choice |
|-----------|-------------|
| Windows starts; run CDE on the live system | Launch `CDE.exe` as administrator |
| Windows won't start; repair from USB | USB boot → WinPE menu **option 2** (Offline OS) |
| Hardware suspicion before OS loads | rEFInd → **Core Hardware Utility (CHU)** first |

### Step 3 — Run System Health Check

Open **System Health Check** → choose a preset (**Recommended**, **Quick Vitals**, **Deep System**, or **Full Audit**) or pick checks manually → **Run Health Check**.

Review the scored findings and the full technical detail beneath them. Yellow (Warn) and red (Fail) items tell you where to focus next; Severity, Confidence, Evidence, and Recommendations explain why. The selected card is marked **VIEWING** in the left list.

### Step 4 — Deepen diagnostics as needed

| If health check suggests… | Go to… |
|---------------------------|--------|
| Disk problems | **S.M.A.R.T. Analyzer** and/or **Diag & Repair → Storage** |
| CPU/RAM stress | **Diag & Repair → CPU / Memory** |
| Malware concern | **Malware Cleanup** (Defender + Core Security Tool) |
| Browser/search hijacks, proxy/DNS tampering, security settings | **Hijack & Scam Repair** |
| Boot/startup issues | **Startup Manager**; security audits in Health Check |
| OS file corruption | **OS Repair** (SFC/DISM) |

### Step 5 — Apply repairs

Use the smallest fix that addresses the finding:

- **Fast Fixes** for quick network/cache/service issues on live Windows
- **OS Repair** for system file and component store problems
- **Disk & Boot Repair** (WinPE only) for boot manager and BCD issues
- **Post-Op Cleanup** after malware removal or major changes
- **Hijack & Scam Repair** when health checks or symptoms point to browser, network, or security-setting hijacks

### Step 6 — Verify and document

Re-run critical checks. On the **Dashboard**, follow the highlighted **suggested path** under **What are you seeing?** — click the symptom card to open System Health with the matching preset (or use the follow-up buttons). The **Case timeline** card lists workflows, CHU pre-boot loads, and standalone CST scans for the active case.

Use **Open Report** from System Health Check, Hijack & Scam Repair, Process Analyzer, S.M.A.R.T. Analyzer, the workflow execution window (when shown), or the case timeline when you need a customer-facing PDF (`Logs\`). For **Diag & Repair** and **Disk & Boot Repair**, use the case timeline or browse `Logs\` directly. When starting a fresh case on a shared USB, clear scan artifacts from **Settings → Clear Test & Scan Logs**, then remove old case records from **Dashboard → Clear Recent** if the recent list is cluttered.

> **WinPE only:** Disk & Boot Repair, offline DISM/SFC, and offline Windows Update package removal require WinPE with the customer's OS loaded (menu option 2).
