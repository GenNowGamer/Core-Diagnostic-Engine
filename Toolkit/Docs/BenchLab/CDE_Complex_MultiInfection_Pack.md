# CDE Complex Multi-Infection Bench Pack

Date: 2026-07-13  
Script: `Scripts\BenchLab\Invoke-CdeBenchComplexPack.ps1`

## Purpose

Harder **safe-only** campaigns for lab VMs after the original S01–S24 pack feels too easy.

Each **C0x** scenario plants **multiple infection types at once**:

- Inert script **content markers** that match CST YaraLike needles (comments only — no network, no decode, no payload execution)
- **Persistence** (Run / RunOnce / Startup / Scheduled Task / optional Service)
- **Hijacks** (hosts, proxy/PAC, Edge policy, uninstall mask, browser extension metadata)
- **Decoy noise** so hits are not the only files present

This pack does **not** ship or execute real malware.

## Safety

- Isolated lab VM only
- Inject requires `-SafeOnly`
- Prefer admin PowerShell for hosts/service scenarios (C01, C05, C06, C08)
- Revert snapshot after each campaign

## Commands (from Toolkit / `C:\CDE` root)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\BenchLab\Invoke-CdeBenchComplexPack.ps1 -Action List

powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\BenchLab\Invoke-CdeBenchComplexPack.ps1 -Action Inject -ScenarioId C03 -SafeOnly

powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\BenchLab\Invoke-CdeBenchComplexPack.ps1 -Action Cleanup -ScenarioId C03

powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\BenchLab\Invoke-CdeBenchComplexPack.ps1 -Action Cleanup -ScenarioId ALL
```

## Scenario summary

| Id | What you get |
|----|----------------|
| C01 | Temp IWR/-enc hit + Run + Startup mshta marker + hosts + Downloads decoys |
| C02 | Public + Temp script IOCs + logon task + proxy/PAC + Edge homepage |
| C03 | Certutil/mshta/regsvr markers + real Run + broken Run red herring + uninstall mask |
| C04 | WebClient hit buried in ~180 decoys + Roaming -nop marker + Startup/Task/Run/RunOnce |
| C05 | Nested LocalTemp DownloadString hit + RunOnce/Run/Startup/Task + optional Defender-drift key |
| C06 | Bits/mshta/regsvr/IWR markers + Run + optional service + hosts |
| C07 | Same “family” agent dropped in 6 CST-visible paths + task + Run + uninstall mask |
| C08 | Kitchen-sink: many content markers + noise + persistence + proxy + Edge + Chrome ext + hosts + optional service |

## Suggested operator flow

1. Snapshot restore (`baseline-pre-infect`)
2. Inject one campaign (start with **C03** or **C04**)
3. Run CDE → Malware Cleanup / CST **ThreatScan** or **FullScan** (both now walk **Users\Public**, Desktop, Documents — see CST high-risk roots)
4. Remediate **content** findings in CST; clear **persistence** via Startup Manager / System Health; clear **proxy / browser policy / hosts** via Hijack & Scam Repair (CST Custom file scans do not replace those)
5. Cleanup pack action and/or restore snapshot

## Detection expectations (important)

| Artifact type | Typical detector |
|---|---|
| Inert script markers under Temp / Public / Downloads / Desktop / Startup (path-gated YaraLike) | **CST** ThreatScan / FullScan |
| Run / Startup / scheduled task | **Startup Manager** / System Health (CST Custom defaults persistence collectors **off**) |
| Proxy / PAC / Edge homepage policy / hosts | **Hijack & Scam Repair** / System Health (CST config findings are mainly **hosts**) |
| Decoy folders (e.g. AdobeCache) | Not intended as malware; remove with BenchLab **Cleanup** |

**C02 example:** After inject, expect CST to see Public + Temp script IOCs. The logon task, proxy/PAC, and Edge policy need Startup Manager / Hijack even if CST file scan is clean.

## State / artifacts

- State: `%ProgramData%\CDE\BenchLab\state\complex\`
- Artifacts: `%ProgramData%\CDE\BenchLab\artifacts\complex\`
