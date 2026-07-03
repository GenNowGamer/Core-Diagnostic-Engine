# Tools Validation Checklist

Use this checklist after updating any third-party tool payload.

## Windows validation
- Launch CDE and open `Tools Library`.
- Verify only `monetizationApproved=true` tools are visible.
- Verify native tools appear with `Mode: Native`.
- Run `update_tools_manifest.ps1` and confirm `tools_manifest.json` reflects current payload statuses.
- Launch at least one **native** tool you still ship under `Toolkit\Tools` (after onboarding replacements).
- Confirm unresolved entries (`manual_required`) show manifest remediation guidance.
- Confirm acquired entries pass SHA256 validation and launch.

## WinPE validation
- Boot WinPE from current CDE USB media (after `Publish-ToolkitGUI.ps1` and USB sync) and launch CDE.
- Verify catalog loads and categories render (including **ACCOUNT RECOVERY** when `monetizationApproved=true`).
- Launch a native WinPE-safe tool and confirm process starts.
- Open a boot-only entry and confirm guidance dialog + folder open action.
- Launch **Firefox** (RECOVERY & NETWORK TOOLS): confirm it opens with its portable profile and no "profile cannot be loaded" error. Network access requires a wired NIC driver injected via `Drivers\Network` (Wi-Fi unsupported in WinPE).
- **Enable Offline Administrator** (`cde_workflow`, enable-only):
  - **WinPE:** boot menu option **2** (Load Offline OS) → confirm `OFFLINE_REGISTRY_LOADED=1` and `HKLM:\Offline_SAM` exists → Tools Library → run workflow (no password dialog).
  - **During workflow:** log shows pre-flight `000001F4`, SAM backup, post-verify `ACB_bits` (disabled bit cleared).
  - **After:** SAM backup under `%ProgramData%\CDE\AccountRecovery\Backups\` on the offline volume; `Offline_SAM` unloaded; reboot to **installed Windows** (not WinPE).
  - **Login:** sign in as `.\Administrator` (blank password on typical clean Win10/11 built-in admin, or existing password if previously set). Set or change password in Windows after logon.
  - Scope is local SAM only — not MSA / Entra ID / PIN.
  - **Negative:** workflow blocked without offline hives or invalid `OFFLINE_WINDOWS_ROOT`.
- **Disable Offline Administrator** (`cde_workflow`, disable-only):
  - **WinPE:** same offline gates as enable → Tools Library → run workflow (no dialog).
  - **During workflow:** SAM backup, pre/post `ACB_bits` with `ACB_DISABLED` set.
  - **After:** `Offline_SAM` unloaded; reboot to installed Windows; `.\Administrator` sign-in blocked.
  - **Pair test:** enable → reboot → sign in → boot WinPE option 2 again → disable → reboot → confirm Administrator cannot sign in.

## Deployment validation (USB / WinPE)
- Run `Prepare-BootableUSB.ps1` or `SyncUSB.bat` and confirm the toolkit tree copied without errors.
- On FAT32 targets, confirm no single bundled file exceeds 4 GB.
- Confirm USB payload includes `Toolkit/Tools/ToolCatalog.xml` and `Toolkit/Tools/tools_manifest.json`.
- Confirm `Toolkit/Tools/update_tools_manifest.ps1` is included for on-target audit/regeneration workflows.
- Confirm existing WinPE startup, offline hive, and CDE launch flow are unchanged.
