# AAA_Quality_Checklist

**Product:** CDE Diagnostic Suite (+ CST + CHU)  
**Location:** `Toolkit\AAA_Quality_Checklist.md` (canonical tracker)  
**Purpose:** Ongoing upgrade checklist toward AAA / trusted professional diag & repair quality.  
**How to use:** Mark `- [ ]` → `- [x]` when done. Add date + short note under the item. Any chat can resume from unchecked items.

**Status legend**
- `[ ]` Not started
- `[x]` Done (include `YYYY-MM-DD` note)
- `(blocked)` Waiting on decision, cert, hardware, or external dependency

**Last reviewed:** 2026-07-20  
**Product channel today:** beta (`Toolkit\VERSION.json`)

---

## 0. How agents should use this file

- [ ] Read this file at the start of any AAA / quality / trust / polish task
- [ ] Prefer highest unchecked item in **§1 Priority backlog**, then the matching section
- [ ] After completing work: mark items `[x]`, note date, rebuild/publish per workspace rules when code changed
- [ ] Do not invent a parallel tracker — update this file only

---

## 1. Priority backlog (do first)

- [ ] **P1 — Code signing:** Authenticode-sign `CDE.exe`, ToolkitGUI payload, CLIs (`CdeCpuSimdCli`, `CdeGpuDiagCli`, etc.)
- [ ] **P2 — Pass 3 packaging fixes:** Implement deferred PL/LA tickets (esp. WinPE `TOOLKIT_ROOT` normalization, CST partial-sync fail-closed)
- [ ] **P3 — CHU Week-4 hardware matrix:** Finish multi-OEM validation (clean + known-bad RAM/HDD/NVMe)
- [ ] **P4 — CHU Secure Boot plan:** Sign EFI apps **or** document Secure Boot–off as permanent product limit
- [ ] **P5 — CST USB baselines:** Ship curated known-good set that fits FAT32 USB; keep release gates green after every rules bump
- [ ] **P6 — CI + BenchLab gates:** Hosted CI (build + PS regression + CST gates); automate BenchLab on Hyper-V infect lab
- [ ] **P7 — Backup & Imaging honesty/upgrade:** Real imaging (WIM/VHD/partner) **or** rename UX to file-copy backup only
- [ ] **P8 — Tools Library strategy:** Grow curated monetization-safe tools **or** brand as lean first-party suite
- [ ] **P9 — Version / UX consistency:** Single version source (`1.0.1` everywhere); leave beta only after gates pass
- [ ] **P10 — Formal stable release:** CHANGELOG, known limitations, support path, channel → `stable`

---

## 2. Product position & release process

- [ ] Define one-sentence product position (technician USB suite — not consumer AV / not PassMark clone)
- [ ] Separate customer-facing `CHANGELOG.md` from session handoffs
- [ ] Pin SemVer + release cadence (e.g. quarterly stable)
- [ ] Legal pack: commercial shop use, third-party redistribution, warranty disclaimer
- [ ] “Known limitations” chapter in user guide (Secure Boot, WinPE Wi-Fi, Defender %, imaging scope, etc.)
- [ ] Flip `VERSION.json` channel from `beta` → `stable` only after §1 P1–P6 minimum gates
- [ ] Tag releases in git with publish-verify artifact notes

---

## 3. Trust & supply chain

- [ ] Purchase/configure Authenticode code-signing certificate
- [ ] Sign `Toolkit\CDE.exe` and published GUI/CLI payloads in publish pipeline
- [ ] SmartScreen reputation plan (consistent publisher + distribution URL)
- [ ] SBOM / pinned hashes for all third-party Tools payloads
- [ ] Reproducible “clone → acquire binaries → publish → USB” runbook for a second builder machine
- [ ] Secret scan: never sync CST/dev auth keys (e.g. abuse.ch) to USB
- [ ] Document provenance of ADK/WinPE/memtest/Firefox/MemTest86 artifacts

---

## 4. Packaging, publish, launcher (Pass 3)

- [ ] Inventory Pass 3 tickets PL-01…PL-08 and LA-01…LA-06 into this section as they are closed
- [ ] LA-01: Normalize WinPE `TOOLKIT_ROOT` (no bare `D:` assumption)
- [ ] PL-03: CST sync fail-closed on partial copy
- [ ] Enforce single canonical publish: `Toolkit\App\Publish-ToolkitGUI.ps1` only
- [ ] Publish-Verify required for every release (`Publish-ToolkitGUI-FullVerify.ps1`)
- [ ] USB sync (`SyncUSB.bat` / Prepare USB) verified after packaging fixes
- [ ] Launcher/WinPE entry points smoke-tested on real USB boot

---

## 5. GUI modules

### 5.1 Dashboard / Work orders
- [ ] Case templates / tech ID fields (if shops need them)
- [ ] Keep symptom → suggested path accurate vs user guide workflow

### 5.2 System Health Check
- [ ] Calibrate FP rates on clean Windows fleets
- [ ] Publish internal FP/noise notes after major catalog changes
- [ ] Keep confidence/corroboration tests green

### 5.3 S.M.A.R.T. Analyzer
- [ ] Expand drive matrix (NVMe / SATA SSD / HDD OEMs)
- [ ] Golden log samples for known-good and known-fail drives

### 5.4 Diag & Repair
- [ ] Always ship `CdeCpuSimdCli` (no permanent stub Warn on stock USB)
- [ ] Catalog wording parity with CHU / `HardwareTestCatalog.json`
- [ ] Cancel ≠ success regression covered

### 5.5 CHU Results
- [ ] Harden empty-log / missing-results UX
- [ ] Auto-import / discover results when USB returns from pre-boot

### 5.6 OS Repair
- [ ] Expand offline DISM/SFC regression scenarios
- [ ] Non-zero exit → Fail (keep Pass 2 semantics)

### 5.7 Malware Cleanup
- [ ] Document Defender estimated % honestly in UI/help
- [ ] CST results UX remains usable without maximize

### 5.8 Hijack & Scam Repair
- [ ] Continuous BenchLab scam/hijack scenarios
- [ ] Destructive confirms remain mandatory

### 5.9 Disk & Boot Repair
- [ ] Mandatory BCD backup UX before mutating repairs
- [ ] Dry-run / preview where feasible
- [ ] Golden disk images in lab for boot repair verification

### 5.10 Backup & Imaging
- [ ] Decide: upgrade to real imaging **or** rename to file backup
- [ ] If upgrade: WIM/VHD and/or licensed imaging partner integration
- [ ] Dry-run + mirror safety remains clear

### 5.11 Post-Op Cleanup
- [ ] Optional safe preset / Run All (safe subset only)
- [ ] Hosts restore confirm + clear failure messages

### 5.12 Tools Library
- [ ] Execute chosen strategy (grow curated tools **or** lean branding)
- [ ] No placeholder-only tools in stable channel
- [ ] Manifest hash mismatch blocks ship

### 5.13 File Manager
- [ ] Keep DestructiveActionDialog on delete/move/mirror
- [ ] VSS browse regression on full Windows

### 5.14 Startup Manager
- [ ] Coverage tests green after every autorun change
- [ ] Publisher-aware scoring / MSIX signature display maintained

### 5.15 Process Analyzer
- [ ] Optional Sysmon pack docs for deeper shops
- [ ] CST scan-file path remains reliable

### 5.16 Temp / Uninstall / Fast Fixes
- [ ] Per–Fast Fix regression for verified set
- [ ] Non-safe fixes always confirm

### 5.17 Settings / Help / UX polish
- [ ] Single version string everywhere (nav, About, VERSION.json, README)
- [ ] In-app What’s New for stable releases
- [ ] Accessibility: `AutomationProperties`, keyboard model, Narrator pass
- [ ] Document en-US-only (or add localization later)

---

## 6. PowerShell workflows & core

- [ ] Output contract markers treated as API (`OUTPUT_CONTRACT.md`) — version bump on break
- [ ] Empty `catch { }` lint/grep gate in CI for operator paths
- [ ] Elevation relay cancel/kill tests remain in regression
- [ ] Bootloader suite: never mark Fail as Done; lab golden images
- [ ] Offline SAM tools: always show “no password reset / no MSA” limits in UI
- [ ] `ValidateTools.ps1` + `tools_manifest.json` gate on every USB ship
- [ ] `DEVELOPER_QUALITY.md` followed on every mutating change

**Workflow inventory (track major regressions as you touch them)**
- [ ] SystemHealthCheck
- [ ] SmartAnalyzer
- [ ] HardwareDiagnostics / Cpu / Memory / Storage
- [ ] ProcessAnalyzer
- [ ] StartupManager
- [ ] PostOp
- [ ] UninstallManager
- [ ] FastFixes
- [ ] OSRepair
- [ ] MalwareSweep
- [ ] HijackRepair
- [ ] TempFileCleaner
- [ ] BackupAndImage
- [ ] Enable/Disable OfflineAdministrator
- [ ] Bootloader* family (BCD/MBR/EFI/scan/backup/restore)

---

## 7. Core Security Tool (CST)

- [ ] Keep Validate-CstReleaseGates **9/9** after every rules bump
- [ ] Ship USB-fit curated known-good baselines
- [ ] Optional large goodware DB for HDD kits only (not FAT32-breaking)
- [ ] SHA-256 online reputation (beyond SHA-1 Hashlookup) when available
- [ ] FP triage log process after each rules update
- [ ] Market clearly as technician triage — not real-time AV
- [ ] Publish sync: CST source → `Toolkit\Security\CST\` via canonical publish only
- [ ] No secrets in shipped CST tree

---

## 8. Core Hardware Utility (CHU)

- [ ] Complete Week-4 hardware matrix (§9 in CHU improvement plan)
- [ ] Secure Boot signing **or** permanent limitation docs + UI warning
- [ ] Catalog sync: `cpu_stress` and all JSON deltas in UEFI + CDE catalogs
- [ ] Run `BUILD_CHU_UEFI.ps1` + stage to `Toolkit\EFI\CDE\` on every CHU change
- [ ] Empty boot-log / Samsung early-logging retest
- [ ] Decide BootNext overnight burn-in (implement or defer explicitly)
- [ ] Add CHU smoke validation artifact (QEMU/EDK2 and/or checklist CI upload)
- [ ] Branded splash only if it doesn’t regress PC-Check/GOP stability

---

## 9. WinPE / boot / USB

- [ ] Pin Windows ADK / WinPE version in docs
- [ ] One-button build path verified (`Build-CDE-Toolkit.ps1` or equivalent)
- [ ] Ethernet driver pack library + `Drivers\Network` runbook
- [ ] Bold UI/docs: WinPE Wi-Fi unsupported
- [ ] rEFInd → CHUPrep → CoreDiag chain verified on ≥3 machines
- [ ] Prepare-BootableUSB / SyncUSB destructive confirms and checksum verify
- [ ] Fresh-clone acquire checklist (`PLACEHOLDER_ACQUISITION.md`) exercised on clean machine

---

## 10. Testing & quality system

- [ ] Hosted CI: build ToolkitGUI + run `Invoke-CdeRegressionSuite.ps1`
- [ ] CI: CST release gates
- [ ] CI: Publish-Verify (or subset) on tags
- [ ] Expand C# unit tests beyond thin path/PDF/health cases
- [ ] Automate BenchLab on `w11-infect-lab` Hyper-V as release gate
- [ ] UI display matrix: scheduled lab pass before stable
- [ ] Optional opt-in crash/telemetry backend (decide yes/no)
- [ ] Coverage report for critical ViewModels / contract parsers

---

## 11. Documentation & brand

- [ ] User guide synced to UI after every stable feature
- [ ] Known limitations chapter
- [ ] One-pager: what CDE is / is not
- [ ] Support path (email / Discord / GitHub issues) documented
- [ ] README version/date no longer stale vs `VERSION.json`
- [ ] THIRD_PARTY_NOTICES kept current when tools added

---

## 12. Already strong (preserve — do not regress)

Mark a regression here if something below breaks; otherwise leave unchecked as “monitor.”

- [ ] Symptom → work order → suggested path workflow intact
- [ ] Structured findings (severity, confidence, evidence, recommendations)
- [ ] Destructive confirms + elevation relay
- [ ] CST deep integration (Malware, Startup, Process, Health)
- [ ] CHU pre-boot ↔ GUI results rollup
- [ ] Operator PDF guide + `OUTPUT_CONTRACT.md`
- [ ] Publish-verify + PS regression culture
- [ ] Monetization/allowlist discipline for third-party tools

---

## 13. Completion log

| Date | Item(s) | Notes / publish |
|------|---------|-----------------|
| 2026-07-20 | Checklist created | Initial AAA audit tracker |
|  |  |  |

---

## 14. Session handoff snippet (paste into new chats)

```
Resume AAA work from Toolkit\AAA_Quality_Checklist.md.
Start at §1 Priority backlog — first unchecked item.
Mark completed items [x] with date; publish via App\Publish-ToolkitGUI.ps1 when required.
```
