# Tools Library and Settings

## Tools Library

**What this does:** Launches onboard boot tools, portable apps, and special CDE workflows from a catalog.

### Common entries

| Category | Tool | Notes |
|----------|------|-------|
| Boot Environment | **Core Hardware Utility** | rEFInd loads `CHUPrep.efi`, which chainloads `CoreDiag.efi` |
| Boot Environment | **Windows Memory Diagnostic** | Memory test EFI payload |
| Recovery & Network | **Firefox ESR** | Portable browser (Ethernet in WinPE) |
| Account Recovery | **Enable Offline Administrator** | WinPE + offline OS only |
| Account Recovery | **Disable Offline Administrator** | Reverses offline admin enable |

### Steps — boot tool

1. Sidebar → **Tools Library**
2. Find the tool card
3. Click **Launch** or **Run**

> **WinPE only:** Account recovery tools require boot menu **option 2** and a detected Windows installation.

---

## Settings

**What this does:** Toolkit preferences, power actions, log cleanup, and this user guide.

### About

Shows CDE version information.

### Power (WinPE)

| Button | Action |
|--------|--------|
| **Unmount OS** | Unloads offline registry hives without rebooting |
| **Reboot Windows** | Unloads hives then reboots the PC |

Use **Unmount OS** before removing the USB if you loaded an offline OS and want to return to the boot menu without restarting.

### Diagnostic logs

**Clear Test & Scan Logs** removes:

- `EFI\CoreDiag\Logs` — CHU UEFI logs
- `EFI\CoreDiag\Results` — CHU JSON results
- `Logs\` — operator PDF deliverables
- `CDE\Runtime\Data\` — internal workflow/scan/CST JSON and PowerShell session logs

Work order case JSON under `CDE\Runtime\WorkOrders\` is **not** removed here. Use **Dashboard → Recent work orders → Clear Recent** to delete saved case records (closed-case PDFs in `WorkOrders\` are kept).

Confirm before deleting — this cannot be undone.

### Help

**Open User Guide** opens this PDF from `HALP\CDE_User_Guide.pdf` on the toolkit media.

---

## Launching CDE on full Windows

Outside WinPE, run the canonical launcher:

```
Toolkit\CDE.exe
```

`CDE.exe` sets `TOOLKIT_ROOT` and starts the graphical toolkit. Always approve the administrator prompt.
