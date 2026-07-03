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
