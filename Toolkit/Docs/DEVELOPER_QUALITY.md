# CDE Developer Quality Policy

## Error handling

- Do not use empty `catch { }` blocks on operator-visible paths (GUI ViewModels, workflow dispatchers).
- Surface `Exception.Message` in status text or workflow step output when a tool fails.
- Use `$ErrorActionPreference = 'Stop'` for mutating PowerShell actions; use `SilentlyContinue` only for enumeration helpers.

## Destructive operations

- GUI must confirm before delete, force-remove, boot repair, hijack category repair, non-safe fast fixes, and most Post-Op tools.
- PowerShell workflows use elevation relay (`Toolkit.Elevation.psm1`) when admin rights are required on non-elevated hosts.

## Verification

- Run `Toolkit\Scripts\Tests\Invoke-CdeRegressionSuite.ps1` before handoff.
- Run `Toolkit\App\Publish-Verify-Toolkit.ps1` after canonical publish.

## Source control

- **GitHub:** `https://github.com/GenNowGamer/Core-Diagnostic-Engine` (private) — source-only clone; no `boot.wim`, deploy ISOs, or published `CDE.exe` in git.
- **Publish before USB tests:** `powershell -NoProfile -ExecutionPolicy Bypass -File Toolkit\App\Publish-ToolkitGUI.ps1` → `Toolkit\CDE.exe`.
- **Large binaries:** `Toolkit\Tools\PLACEHOLDER_ACQUISITION.md` + `update_tools_manifest.ps1` after copying vendor payloads.
- Do not commit `Toolkit\CDE\Runtime\`, `Logs\`, `Deploy\`, or nested `.git` under `Toolkit/`.
