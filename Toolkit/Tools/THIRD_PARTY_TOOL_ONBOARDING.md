# Third-Party Tool Onboarding

Legacy bundled tools (ClamWin, CrystalDiskInfo, TestDisk/PhotoRec, SystemRescue, OfflineNT, ShredOS) were removed. Add new tools under `Toolkit\Tools\...`, register them in `ToolCatalog.xml`, then run `update_tools_manifest.ps1`.

## Execution modes (`ToolCatalog.xml`)

| `executionMode` | Use when | Required catalog fields |
|-----------------|----------|-------------------------|
| `native` | Portable `.exe` launched with working directory set to the tool folder | `relativePath`, optional `arguments` (supports `{TOOLDIR}` / `{TOOLSROOT}`) |
| `boot_efi` | UEFI boot assets (guidance + Open folder; no process launch) | `relativePath` to `.efi` or boot image |
| `cde_workflow` | First-party CDE PowerShell workflow run in-process with the workflow execution window | `workflowScript` (path under toolkit root, e.g. `Scripts\Workflows\EnableOfflineAdministrator.ps1`); `relativePath` may point to a `.launch.cmd` fallback |

**`cde_workflow` examples (ACCOUNT RECOVERY):** **Enable Offline Administrator** / **Disable Offline Administrator** — `workflowScript` under `Scripts\Workflows\`, `winpeSupport="yes"`, `windowsBcdSupport="no"`. Enable-only and disable-only (no password prompt); GUI runs via `CdeWorkflowRunnerViewModel` when offline hives are loaded. Catalog-only changes need `SyncUSB.bat`; GUI code changes need `Publish-ToolkitGUI.ps1` too.

## Argument path tokens
The Tools launcher expands these tokens in a tool's `arguments` before launch, so a tool can use absolute paths that do not depend on the working directory:
- `{TOOLDIR}` → the folder containing the tool's executable.
- `{TOOLSROOT}` → the resolved `Tools` root.

Example (portable Firefox browser, registered native): `arguments="-profile &quot;{TOOLDIR}\Data\Profile&quot; -no-remote"` keeps the profile alongside the binary (on the USB) rather than the volatile WinPE RAM disk.

## Current catalog boot asset (until replaced)
- `Boot/MemTest86/memtest86-usb.img`

Use `tools_manifest.json` as the single source of expected payload paths/status.
