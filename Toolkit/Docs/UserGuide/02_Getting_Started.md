# Getting Started

## Booting from the CDE USB

1. Insert the CDE USB drive into the computer.
2. Power on and open the **UEFI/BIOS boot menu** (often F12, F11, Esc, or F8 — varies by manufacturer).
3. Choose the USB drive as the boot device.
4. When the **rEFInd** graphical menu appears, select **CDE WinPE** to start the toolkit.

> **Tip:** If Secure Boot blocks CHU or custom boot files, disable Secure Boot in firmware settings for diagnostic sessions.

## WinPE boot menu (keys 1–7)

After WinPE loads, CDE shows a full-screen boot menu. Press a number key or click an option:

| Key | Option | Use when |
|-----|--------|----------|
| **1** | Launch CDE Toolkit GUI | You want CDE tools in WinPE without loading the customer's Windows registry |
| **2** | Launch CDE + Load Offline OS | You need to scan or repair the customer's installed Windows (malware scan, offline DISM, startup audit, account recovery) |
| **3** | WinPE Command Prompt | You need a raw command line |
| **4** | PowerShell (WinPE) | You need PowerShell scripts in WinPE |
| **5** | Network Setup | You need network in WinPE (`wpeinit`) |
| **6** | Reboot | Restart the computer |
| **7** | Shutdown | Power off the computer |

> **Important:** For most repair jobs on a customer's drive, choose **option 2** so CDE can load their offline Windows installation. You will be asked to confirm before registry hives are loaded.

> **Tip:** Options **1** and **2** continue in the same `ToolkitGUI.exe` process — the boot menu closes and the main CDE window opens. If you return to a text recovery menu instead, sync the latest GUI from `Publish-ToolkitGUI.ps1` and check `CDE\Runtime\winpe_startup.log` on the USB.

## Administrator access (UAC)

CDE runs with administrator rights. Windows will show a **User Account Control** prompt — choose **Yes**. Many repair tools need elevated access to system files, the registry, and disk volumes.

## The CDE main window

After the boot menu (or when launching `CDE.exe` on a full Windows system):

- **Left sidebar** — tools grouped as Main, Repair, Maintenance, and Utilities
- **Top header** — computer name, environment badge (WinPE or Windows), CPU/RAM/SMART summary, uptime
- **Work order strip** — optional case tracking from the Dashboard

## Work orders (Dashboard)

**What this does:** Keeps client name, phone, notes, and case ID with your session so diagnostics, repairs, and standalone scans are logged together.

1. Open **Dashboard** in the sidebar.
2. Enter client details and notes.
3. Click **Generate** or **Save** to start or update a work order.
4. Run diagnostics and repairs from other sidebar tools — results are tied to the active case.

**Case timeline** (active work order only) — newest-first list of workflow runs, CHU pre-boot result loads, and Process Analyzer CST scans. Timestamps show as local friendly times (for example `Jul 20, 2026 9:48 AM`). Use **Open Report** (PDF) or **Open artifact** on each row when paths are available.

**Suggested path** — under **What are you seeing?**, CDE highlights the best-matching symptom when you **Generate Work Order** (from notes keywords) or when you click a symptom chip. The hint text and accent highlight show the recommended path; the detail panel lists follow-up tools and health-check presets. Click a symptom to confirm or change the path.

**Recent work orders** — lists saved cases from `CDE\Runtime\WorkOrders\`. Click a case for run history in the detail window (Opened/Closed times use local friendly dates such as `Jul 20, 2026 9:48 AM`). Use **Clear Recent** to remove all case JSON files (closed-case PDFs in `WorkOrders\` are kept).

**Symptom cards** — five paths: Slow PC, Suspected Malware, Tech Support Scam, Network Issues, Won't Boot. Selecting one saves `GuidanceContext` on the work order and can jump you to the matching health preset or repair tool.

> **Tip:** On a USB toolkit, work orders are stored on the USB media so you can review past jobs later. Internal case JSON lives under `CDE\Runtime\WorkOrders\`; the printable PDF for a closed case is saved to `WorkOrders\{CaseId}.pdf`. Open a closed case from **Recent work orders** for run history, or use **Open Final Report** for the PDF.
