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

- Isolated lab VM only (current host lab: local **Hyper-V** `w11-infect-lab` under `D:\Hyper-V\w11-infect-lab\` — Azure `rg-w11-infect-lab` retired 2026-07-14)
- On the Hyper-V host, **`Inject-C06.ps1`** (same folder as `Push-CDE-Toolkit.ps1`) runs C06 inject on the guest via PowerShell Direct; toolkit must already be at `C:\CDE`
- Inject requires `-SafeOnly`
- Prefer admin PowerShell for hosts/service scenarios (C01, C05, C06, C08)
- Revert snapshot / Hyper-V **checkpoint** after each campaign

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

**C03 remediation notes:** **Support Assist Pro (Remote)** is a registry **uninstall mask** (DisplayName/Publisher only — no `UninstallString`). Uninstall Manager **Uninstall** is disabled / will refuse it; use **Force Remove** to clear the key. Persistence: delete **SupportAssistUpdater** (broken Run) and **SupportAssistCore** (points at `ProgramData\VendorCache\Runtime\core_agent.cmd`) in Startup Manager — after Delete, accept **also remove target file** when offered so `core_agent.cmd` does not remain orphaned.

## Suggested operator flow

1. Snapshot restore (`baseline-pre-infect`)
2. Inject one campaign (start with **C03** or **C04**)
3. Run CDE → Malware Cleanup / CST **ThreatScan** or **FullScan** (both now walk **Users\Public**, Desktop, Documents — see CST high-risk roots)
4. Remediate **content** findings in CST; clear **persistence** (Run/Startup/tasks **and** eligible rogue services) via Startup Manager / System Health; clear **proxy / browser policy / hosts** via Hijack & Scam Repair (CST Custom file scans do not replace those)
5. Cleanup pack action and/or restore snapshot

## Detection expectations (important)

| Artifact type | Typical detector |
|---|---|
| Inert script markers under Temp / Public / Downloads / Desktop / Startup (path-gated YaraLike) | **CST** ThreatScan / FullScan |
| Run / Startup / scheduled task / optional rogue service (C06, C08) | **Startup Manager** (User logon + Services) / System Health (CST Custom defaults persistence collectors **off**) |
| Proxy / PAC / Edge homepage policy / hosts | **Hijack & Scam Repair** / System Health (CST config findings are mainly **hosts**) |
| Decoy folders (e.g. AdobeCache) | Not intended as malware; remove with BenchLab **Cleanup** |

**C02 example:** After inject, expect CST to see Public + Temp script IOCs. The logon task, proxy/PAC, and Edge policy need Startup Manager / Hijack even if CST file scan is clean.

## State / artifacts

- State: `%ProgramData%\CDE\BenchLab\state\complex\`
- Artifacts: `%ProgramData%\CDE\BenchLab\artifacts\complex\`
- A scenario state JSON (for example `state\complex\C06.json`) is BenchLab bookkeeping, not infection persistence. CDE remediation may remove every injected artifact while leaving this inert record. Use `Invoke-CdeBenchComplexPack.ps1 -Action Clean -ScenarioId C06` (or the matching scenario id) to reset both scenario artifacts and state before another injection.
