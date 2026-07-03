# Placeholder Acquisition Guide

This toolkit uses an allowlist for monetization-safe tool distribution.

## Required workflow
- Place official vendor/project binaries/ISOs in the exact paths from `tools_manifest.json`.
- Run `update_tools_manifest.ps1` after copying files.
- Only `status: acquired` entries are launchable in CDE.

## Acquisition commands
- Regenerate manifest from current files:
  - `powershell -ExecutionPolicy Bypass -File .\Toolkit\Tools\update_tools_manifest.ps1`

- Optional auto-download pass (only entries with explicit direct URLs in script):
  - `powershell -ExecutionPolicy Bypass -File .\Toolkit\Tools\update_tools_manifest.ps1 -DownloadApprovedNow`

## Notes
- Boot ISOs are pinned (`preferredVersion: PIN_REQUIRED`) and should be manually sourced from official URLs.
- Native tools may use latest stable, but checksum is locked once acquired.
- If a file is missing, entry remains `manual_required`.

## Not in Git (clone / fresh checkout)

The GitHub repository tracks **source only** (~50 MB). These paths stay on your dev machine or USB but are **gitignored** — copy or rebuild them locally:

| Path | How to obtain |
|------|----------------|
| `sources/boot.wim` | `Scripts/Customize-WinPE.ps1` (Administrator) |
| `Deploy/*.iso`, `WinPE/*.iso`, `Mount/` | Local build outputs — do not commit |
| `Diagnostics/Memory/MemTest86/memtest86-usb.img` | Official MemTest86 vendor download (~1 GB USB image) |
| `Tools/Firefox/` | Portable browser payload — deploy via `SyncUSB.bat` / acquire flow |
| `CDE.exe`, `CDE/ToolkitGUI/bin/...` | `App/Publish-ToolkitGUI.ps1` |
| `Tools/Boot/PCDoctor/` | Legacy proprietary payload — not distributed in git |

After placing files, run `update_tools_manifest.ps1` so `tools_manifest.json` reflects `acquired` status.
