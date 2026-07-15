# Maintenance and Utilities

## Post-Op Cleanup

**What this does:** Post-malware and post-repair cleanup — browser caches, service defaults, file associations, DNS/proxy reset, shell caches, and optional hosts restore.

### Tools

| Tool | Use for |
|------|---------|
| **Browser Cache Clear** | Edge/Chrome/Firefox disk cache (not cookies/passwords) |
| **Restore Default Services** | Reset critical Windows services to default start types |
| **File Association Fix** | Repair hijacked `.exe`, `.lnk`, `.bat`, `.cmd`, `.com` handlers |
| **Icon + Thumbnail Cache Clear** | Fix broken or stale desktop icons and thumbnails |
| **DNS Cache Flush** | Clear resolver cache after DNS hijack or VPN issues |
| **Reset Proxy Settings** | Disable user Internet proxy and reset WinHTTP proxy |
| **Restore Hosts File** | Replace `hosts` with Windows defaults (backup first; **confirmation required**) |
| **Restart Explorer** | Apply shell/cache fixes without a full reboot |

> **Note:** The **Hosts File Check** in System Health Check still **audits** the hosts file; remediation lives here only.

### Steps

1. Sidebar → **Post-Op Cleanup**
2. Click **Run** on each tool you need (eight tools; no single **Run All** button)
3. Approve UAC if prompted (services and associations need elevation on live Windows)

---

## Backup & Imaging

**What this does:** Copies files and folders with Robocopy — mirror or backup mode with optional dry run.

### Steps

1. Sidebar → **Backup & Imaging**
2. Click **Robocopy Backup**
3. Set source, destination, mirror mode, and dry-run if testing
4. Run and review the log summary

> **Tip:** Use **File Manager → Shadow Copies** (full Windows) to browse previous versions read-only before backup decisions.

---

## Startup Manager

**What this does:** Lists and controls programs that start with Windows — Run keys (including **GPO** policies), startup folders, **MSIX startup tasks** (Store apps such as Teams), **scheduled logon/boot tasks**, services, drivers, browser extensions, and Winlogon entries. CDE aligns enable/disable behavior with **Task Manager** via the `StartupApproved` registry hive where Windows uses it.

### Tabs

| Tab | Use for |
|-----|---------|
| **User logon** | Run keys, GPO Run keys, startup folders, MSIX tasks, scheduled tasks, **Userinit/Shell** reset when hijacked |
| **Drivers** | Boot-start drivers |
| **Extensions** | Browser extensions and legacy BHO entries |
| **Services** | Change startup type, start/stop/restart |

### Persistence types (User logon)

| Source | Notes |
|--------|--------|
| **Run / RunOnce** | HKLM and HKCU; CDE moves disabled values to `AutorunsDisabled` and syncs `StartupApproved` |
| **GPO Run** | `Policies\Explorer\Run` — listed and managed like standard Run keys |
| **Startup folder** | Active folder vs `CDE\DisabledStartup`; `StartupApproved` synced for Task Manager parity |
| **MSIX startup task** | Per-package tasks under AppModel (e.g. Teams, Copilot); disable via package `State` DWORD. CDE resolves the startup executable from the Appx manifest (`windows.startupTask` `TaskId`) and checks Authenticode when the file is accessible. If WindowsApps blocks direct file access, **Signed** shows `Package (Publisher)` instead of **Not found**. |
| **Scheduled task** | Tasks with logon, boot, registration, or session triggers; enable/disable via Task Scheduler. **Non-Microsoft tasks can be Delete'd** (unregister). **Windows `\Microsoft\` tasks are hidden by default** (checkbox: *Include Windows scheduled tasks*); when shown, they are read-only. |

When the same app appears through more than one mechanism, the **RELATED** column and analysis tooltip warn you (e.g. Teams via MSIX task and a Run key).

### Right-click actions

Right-click a row for technician jump tools (Enable / Disable / Delete stay on the row buttons only):

| Action | Use for |
|--------|---------|
| **Open target folder** | Explorer select on the resolved target (prefers `-File` scripts over `powershell.exe`) |
| **Copy target file path / command line** | Paste into notes or another tool |
| **Delete target file...** | Remove a leftover dropper under ProgramData / AppData / Temp / Public (not OS install paths). Does not remove the autorun itself |
| **Scan with CST** | Startup-entry scan: multi-target file CustomScan + command-line LOLBin analysis + persistence correlation; result dialog shows **File / Command line / Persistence** verdicts |
| **Copy registry path / Open in Registry Editor** | When the entry has a registry location |
| **Show entry details** | Full name, source, risk, analysis, command line, **resolved target**, related |
| **Open Malware Cleanup / Process Analyzer / File Manager** | Jump to related workflows |

When you **Delete** a Run/Startup/**non-Microsoft scheduled task** entry whose target still exists in a remediable path (e.g. `ProgramData\VendorCache\...`), CDE asks whether to **also delete that target file** (and empty parent folders). Prefer Yes for leftover malware droppers after clearing persistence.

Services tab offers the same file/CST/copy/details jumps (plus **Copy service name**).

> **Tip:** Use **System Health Check → Scheduled Tasks** (security audit) to review non-Microsoft scheduled tasks for persistence risk. The default Startup Manager view focuses on user-facing startup mechanisms like Task Manager.

### Winlogon reset

If `Userinit` or `Shell` values were changed by malware, they appear highlighted. Use **Reset** to restore Windows defaults (backup created automatically). **Undo** restores the previous value if reset was wrong.

### Hijack & Scam Repair integration

- **Suspicious only** filter — shows startup rows that match hijack-scanner heuristics (same logic as **Hijack & Scam Repair**)
- **Manage** from a hijack finding opens Startup Manager with this filter enabled
- Review-only startup findings in Hijack & Scam Repair should be disabled or deleted here rather than via **Repair Selected**

---

## File Manager

**What this does:** Browse drives and folders in a split-pane layout — useful for copying logs, pulling user data, or inspecting offline OS files.

### Steps

1. Sidebar → **File Manager**
2. Expand **Computer** → select a **drive** or **shadow copy**
3. The right pane shows folder contents
4. Use checkboxes to select multiple files or folders for batch copy, move, or delete
5. Right-click for Open, Cut/Copy/Paste, Rename, Delete, Properties, Show in Explorer, **Scan with CST**, or New folder
6. **Scan with CST** — right-click a file or folder (or multi-select) to run a Core Security Tool CustomScan on those paths. Empty area of the pane: **Scan this folder with CST** scans the current folder. Results open in **CST Scan Results** (live progress → findings). Archive threats: select the parent `.zip`/`.jar` row to quarantine/remove; inner entry rows are review-only.

The directories pane starts empty until you select a location.

> **Note:** Junction/reparse-point folders (e.g. `C:\ProgramData\Application Data`) are hidden to prevent infinite navigation loops. Folder size calculations skip the same paths.

---

## Process Analyzer

**What this does:** Live process triage on the running system — CPU and RAM usage, image path, risk heuristics, and a detail pane for command line, session, parent chain, loaded modules, and file hash. Use during malware investigations or when System Health Check flags high CPU or memory.

### Main controls

| Control | Use for |
|---------|---------|
| **Refresh** | Reload the process list |
| **Pause / Resume refresh** | Stop or resume auto-refresh (default ~10s) |
| **Freeze** | Hold the current snapshot while you inspect rows |
| **Investigation ON** | 3-second refresh; highlights processes that **started after** you enabled the mode. The button label shows when investigation is active (no separate status banner in the toolbar). |
| **Open Report** | Open the operator PDF for the current filtered process snapshot (`Logs\`) |
| **Terminate** | End the selected process (use with care) |

### Filters and views

- Search box — filter by name, path, company, PID, or risk flags
- Preset dropdown — e.g. high CPU (≥10%), high RAM (≥500 MB), unsigned (with **Deep scan**), suspicious path, in startup, **New since investigation**
- **Tree view** — parent/child process tree
- **Deep scan (signatures)** — Authenticode check on image paths (slower refresh)

### Detail pane (select a row)

Shows command line, parent PID, **session** (0 = services/system; 1+ = user desktop), start time, signature, RAM, parent chain, top loaded modules, and SHA256. Action buttons:

| Button | Action |
|--------|--------|
| **Open location** | Open the process image folder in Explorer |
| **Copy path** | Copy image path to clipboard |
| **CST scan file** | Run Core Security Tool against the selected executable only; results open in a structured dialog |
| **Startup Manager** | Jump to Startup Manager |
| **Malware Cleanup** | Jump to Malware Cleanup |

> **Note:** Many Windows services legitimately show **Session: 0** and an empty command line. Interactive apps such as `explorer` or your browser should show **Session: 1** (or higher on RDP) and a populated command line.

> **Tip — `svchost` rows:** Use the detail pane **Command line** to see the `-k` service group and `-s` service name (e.g. `-k netsvcs -s wuauserv`). The **Services (svchost)** list names hosted services when available. Session **0** and `C:\Windows\System32\svchost.exe` without `-s` usually indicate a shared service host, not a standalone app.

### From System Health Check

When CPU or RAM checks warn or fail, use the recommendation link **Process Analyzer (high CPU)** or **(high RAM)** to open this view with the matching filter already applied.

---

## Temp File Cleaner

**What this does:** Finds temporary files across user profiles and system temp locations, grouped by folder, for safe cleanup.

1. Choose drive scope
2. **Scan**
3. Review sizes and select folders
4. **Clean** selected items

### Completion status

A successful clean may still leave some files behind when another process has them open — this is normal on a running system. CDE treats these as **skipped (in use)**, not failures:

- Files reported as *being used by another process*
- Files where delete returns *access denied* (common for `VBCSCompiler` / Roslyn analyzer DLLs while an IDE or `dotnet build` is active)

When only these expected skips occur, the workflow reports **Completed** / **Pass** — not a warning. The summary may note how many items were skipped (for example, `In-use: 5`). Genuine delete errors (unexpected I/O problems) still show as warnings.

> **Tip:** Close heavy build tools or reboot before cleaning if you want the temp folder as empty as possible.

## Uninstall Manager

**What this does:** Lists installed programs from registry uninstall keys. Run the vendor uninstaller or force-remove broken entries.

Use force-remove only when the normal uninstaller is missing or corrupted.
