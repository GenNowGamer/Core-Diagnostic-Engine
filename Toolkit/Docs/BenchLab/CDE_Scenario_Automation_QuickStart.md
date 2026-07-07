# CDE Scenario Automation Quick Start

Date: 2026-07-07
Script: Scripts\BenchLab\Invoke-CdeBenchScenarioPack.ps1

## Purpose

Automates safe-only injection and cleanup for all 24 BenchLab scenarios.
No real malware execution is performed.

The built-in pack validates workflow coverage, persistence/audit handling, remediation plumbing, reboot cleanliness, and boot/offline fixtures. It does not replace a separate approved positive-detection corpus if you need malware-conviction testing.

## Safety Constraints

- Run only in isolated VM labs.
- Injection requires explicit `-SafeOnly` acknowledgement.
- Several scenarios require Administrator rights.
- Offline scenarios require explicit offline paths.

## Commands

List scenarios:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\BenchLab\Invoke-CdeBenchScenarioPack.ps1 -Action List
```

Inject all scenarios (safe-only):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\BenchLab\Invoke-CdeBenchScenarioPack.ps1 -Action Inject -ScenarioId ALL -SafeOnly
```

Cleanup all scenarios:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\BenchLab\Invoke-CdeBenchScenarioPack.ps1 -Action Cleanup -ScenarioId ALL
```

Inject one scenario:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\BenchLab\Invoke-CdeBenchScenarioPack.ps1 -Action Inject -ScenarioId S07 -SafeOnly
```

Offline scenario examples:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\BenchLab\Invoke-CdeBenchScenarioPack.ps1 -Action Inject -ScenarioId S18 -SafeOnly -OfflineSoftwareHivePath D:\Offline\Windows\System32\config\SOFTWARE

powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\BenchLab\Invoke-CdeBenchScenarioPack.ps1 -Action Inject -ScenarioId S19 -SafeOnly -OfflineWindowsRoot D:\Windows
```

## Artifacts and State

- State: `%ProgramData%\CDE\BenchLab\state`
- Generated artifacts: `%ProgramData%\CDE\BenchLab\artifacts`

## Suggested Run Sequence

1. Revert VM snapshot.
2. Inject target scenario(s).
3. Run CDE workflows and validators.
4. Capture CSV/JSON/PDF evidence.
5. Cleanup scenarios.
6. Revert snapshot before next run.
