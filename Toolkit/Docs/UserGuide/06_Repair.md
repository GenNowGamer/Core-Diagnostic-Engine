# Repair

## OS Repair

**What this does:** Repairs Windows system files, the component store, network stack, and Windows Update when the OS is damaged or misconfigured.

### Tools

| Tool | Full Windows | WinPE (offline OS loaded) |
|------|--------------|---------------------------|
| **System File Checker (SFC)** | Online scan | Runs **DISM** instead (SFC needs a running component store) |
| **DISM** | Online repair (optional `install.wim` source) | Offline repair against selected Windows folder |
| **Network Stack Reset** | Yes | **Not available** in WinPE |
| **Windows Update Repair** | Yes | **Not available** in WinPE |
| **Offline Update Uninstall** | No | **WinPE only** — remove bad updates from offline image |

### Steps — SFC / DISM (typical)

1. Sidebar → **OS Repair**
2. In WinPE, confirm the correct **offline Windows installation** is selected
3. Click **SFC** or **DISM** and wait for completion (may take 30+ minutes)
4. For **DISM** on full Windows, choose whether to browse for a matching **`install.wim`** / **`install.esd`** (recommended when Windows Update cannot supply repair files)
5. Review Pass/Fail/Warn in the workflow window; open PDF if needed
6. Reboot and test Windows normally

### DISM error 0x800f081f (source files not found)

If DISM completes with **Warn** and reports **0x800f081f**, Windows Update could not download the files needed to repair the component store.

1. Mount a **Windows ISO** that matches the PC's edition and build (e.g. Windows 10 22H2 for build 19045.x)
2. Run **DISM Image Repair** again → **Yes** → select `sources\install.wim` from the mounted ISO
3. After DISM reports **Pass**, run **SFC** on full Windows
4. If online repair still fails, try **Windows Update Repair** in OS Repair, then rerun DISM

Manual elevated command (replace drive letter and index):

```text
DISM /Online /Cleanup-Image /RestoreHealth /Source:wim:D:\sources\install.wim:6 /LimitAccess
```

Use `DISM /Get-WimInfo /WimFile:D:\sources\install.wim` to find the correct index.

> **Important:** Never assume `C:\` is the customer drive in WinPE — always verify the offline Windows path.

---

## Disk & Boot Repair

**What this does:** Fixes boot configuration (BCD), EFI boot files, and master boot record issues when Windows will not start.

> **WinPE only:** This entire section is disabled when running CDE on a normal Windows desktop. Boot from USB to use it.

### Steps

1. Boot USB → WinPE menu option **1** or **2**
2. Sidebar → **Disk & Boot Repair**
3. Review the **read-only disk map**
4. Common actions:
   - **Backup BCD** before changes
   - **Scan OS** to find Windows installations
   - **BCD Repair** / **Rebuild BCD** / **Rebuild EFI** as appropriate
   - **Fix MBR** / **Fix Boot** on legacy BIOS systems if applicable

Always back up BCD stores before destructive boot repairs.

---

## Fast Fixes

**What this does:** Fourteen one-click repairs with automatic Pass/Fail verification — ideal for quick bench fixes on a working Windows session.

### Categories

| Category | Examples |
|----------|----------|
| Networking | Reset Winsock, renew IP, disable IPv6 |
| OS | Clear event logs |
| Services | Enable Windows Update, BITS, Defender |
| Browsers | Reset Edge/Chrome, fix browser file associations |
| Performance | Disable UI animations, clean Start Menu cache, high performance power plan |

> **Note:** DNS flush and icon/thumbnail cache clear live in **Post-Op Cleanup** only (removed from Fast Fixes 2026-06-26).

### Steps

1. Sidebar → **Fast Fixes**
2. Filter by category if needed
3. Click a fix → confirm → wait for **Pass** or **Fail**
4. Read the log line if verification fails

> **Tip:** Fast Fixes are for **live Windows**. Most show **N/A** in WinPE.
