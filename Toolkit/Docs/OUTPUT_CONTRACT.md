# CDE Structured Output Contract

Workflow scripts and health checks may emit machine-readable progress lines on stdout.

## Version 1 (`[CDE:EVENT:v1]`)

Prefix every JSON payload with the tag `[CDE:EVENT:v1]` (no space). One event per line.

```text
[CDE:EVENT:v1]{"type":"progress","tool":"OSRepair","step":"SFC","pct":42}
```

### Common fields

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | `progress`, `status`, `finding`, `complete` |
| `tool` | string | Workflow or subsystem name |
| `step` | string | Optional step or phase id |
| `pct` | number | 0–100 progress when applicable |
| `message` | string | Human-readable detail |

### Legacy aliases

Existing tags remain valid for parsers that already handle them:

- `[HEALTH:FINDING] {json}` — one persisted System Health finding. Fields: `findingId`, `checkId`, `subject`, `finding`, `impact`, `severity`, `confidence` (deterministic 0–100 match score), `status`, `classification` (evidence quality), `evidence[]`, `recommendations[]`, and trusted `actions[]`

### Finding `classification` (evidence quality)

Separate from `severity` / `status`. Used to decide whether a finding belongs in **Actionable** vs inventory/limitation lists.

| Value | Meaning | Attention list |
|-------|---------|----------------|
| `ConfirmedFault` | Validated fault / fail outcome | Yes |
| `CorroboratedSuspect` | Strong multi-weight or high-confidence suspect | Yes |
| `SingleSignal` | One heuristic or isolated Warn signal | Yes (only if status is Warn/Fail) |
| `Inventory` | Informational inventory / residual unclassified noise | No |
| `ExpectedLimitation` | Known environmental limitation (e.g. USB SMART bridge) | No |
| `Incomplete` | Check could not complete (N/A / Skip) | No |

When `classification` is omitted on older payloads, ToolkitGUI derives it from `status` / `severity` / `confidence` using the same rules as `Scripts/Core/HealthFindings.ps1`.
- `[AUDIT:EVENT]` — raw/deduplicated event evidence retained alongside correlated health findings
- `[HIJACK:FINDING]` — hijack scan findings
- `[POSTOP:STARTUP]` — startup-entry review evidence
- `SFC_PROGRESS:` — OS Repair SFC percentage
- `Write-HealthPhaseLine` output — system health live tags

New workflows should prefer `[CDE:EVENT:v1]` for progress and status.

System Health report JSON also stores the same objects on each workflow step as
`StructuredFindings`. Human-readable `Output` remains populated with the check's
full technical detail; finding markers are additive and must not replace that
detail.

## OverallHealth (soft / hard rollup)

`Get-WorkflowOverallHealth` / `Set-WorkflowOverallHealth` (Toolkit.Core.psm1) set
`OverallHealth` on the workflow result. Prefer evidence quality over raw Warn count
(NIST SP 800-61: prioritize confirmed / high-impact signals).

| Value | Meaning |
|-------|---------|
| `Critical` | ConfirmedFault and/or Fail outcomes |
| `Warning` | Attention findings (CorroboratedSuspect / SingleSignal Warn\|Fail) |
| `HealthyWithNotes` | Only ExpectedLimitation / Incomplete / soft Inventory notes |
| `Healthy` | Clean Pass (Skip alone does not demote) |

Legacy steps without `StructuredFindings` still roll up Fail→Critical, Warn→Warning.

## Confidence calibration

`confidence` remains a deterministic 0–100 match score (not P(fault)). After
corroboration, `Invoke-HealthFindingConfidenceCalibration` applies floors/caps:

| Classification | Rule |
|----------------|------|
| `ConfirmedFault` | floor ≥ 90 |
| `CorroboratedSuspect` | floor ≥ 75 (bonus applied earlier in corroboration) |
| `SingleSignal` | unchanged |
| `Inventory` (Info) | cap ≤ 40 (residual noise demotion) |
| `Inventory` (Warn) | cap ≤ 55 |
| `ExpectedLimitation` | clamp to 85–95 |
| `Incomplete` | floor ≥ 90 |

Formula summary: `calibrated = clamp(0, 100, base + corroboration_bonus − noise_penalty)`.

## Per-machine baselines

`Scripts/Core/MachineBaseline.ps1` stores the last Health/SMART snapshot under
`CDE/Runtime/Data/baselines/{machineId}.json` (BIOS serial or computer name).
System Health Check compares the prior snapshot before saving a new one and may
emit SMART growth / new-ConfirmedFault delta findings.

## Event suppressor packs

Optional lab packs in `Config/EventSuppressorPacks/*.json` merge extra
`suppressors` into `EventFindingClusters` at load time. Auto-detect: WinPE,
Hyper-V/VM guest, USB storage. Override: `CDE_EVENT_SUPPRESSOR_PACKS=pack1,pack2`.

## PowerShell helper

```powershell
Write-CdeEvent -Payload @{
    type = 'progress'
    tool = 'OSRepair'
    step = 'DISM'
    pct  = 10
}
```

Exported from `Toolkit.Core.psm1`.
