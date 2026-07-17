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

- `[HEALTH:FINDING] {json}` — one persisted System Health finding. Fields: `findingId`, `checkId`, `subject`, `finding`, `impact`, `severity`, `confidence` (deterministic 0–100 match score), `status`, `evidence[]`, `recommendations[]`, and trusted `actions[]`
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
