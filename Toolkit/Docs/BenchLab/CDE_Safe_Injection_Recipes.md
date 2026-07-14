# CDE Safe Injection Recipes (Non-Weaponized)

Date: 2026-07-07

This document defines safe simulation recipes that do not execute real malware payloads.

## Safety Rules

- Use isolated VM networks only.
- Do not execute unknown binaries.
- Use inert files, harmless scripts, and configuration drift simulation.
- Revert snapshot after each scenario.

## Recipe Format

- Recipe Id
- Goal
- Setup Steps
- Validation Steps
- Cleanup Steps

## Recipes

### R01 - Single Marker Drop

Goal: Validate basic scan workflow, operator evidence capture, and post-run cleanup around a harmless file drop.

Setup:

1. Place an inert marker file in user Downloads.
2. Do not execute anything.

Validation:

1. Run Malware Cleanup with CST ThreatScan.
2. Confirm the workflow runs, artifacts are generated, and coverage is correct.
3. Do not expect malware conviction from the built-in marker alone.

Cleanup:

1. Remove the marker file or revert snapshot.
2. Reboot and re-run targeted scan if you are validating report consistency.

### R02 - Multi-Path Marker Drop

Goal: Validate multi-path coverage and artifact reporting with harmless marker files.

Setup:

1. Place inert marker copies in Temp, Public, and Desktop.

Validation:

1. Run CST ThreatScan or FullScan (both walk Users\Public, Desktop, and Documents as of 2026-07-13), or CustomScan those folders explicitly.
2. Confirm all injected paths are included in operator review/reporting.
3. Do not expect malware conviction from the built-in markers alone.

Cleanup:

1. Remediate and verify all injected copies gone.

### R03 - Run Key Persistence Simulation

Goal: Validate startup persistence detection and correlation.

Setup:

1. Create benign executable placeholder path in AppData.
2. Add Run key pointing to placeholder.

Validation:

1. Run System Health suspected_malware and Startup Manager.
2. Run CST and confirm correlated persistence signal.

Cleanup:

1. Remove Run key and file.

### R04 - Scheduled Task Persistence Simulation

Goal: Validate sec_scheduled_tasks plus CST correlation.

Setup:

1. Create scheduled task at logon pointing to inert script.

Validation:

1. Run System Health security checks.
2. Run Hijack and Scam Repair and CST.

Cleanup:

1. Delete test task.

### R05 - Service Path Tamper Simulation

Goal: Validate service anomaly detection.

Setup:

1. Create a test service or alter a test service ImagePath to benign placeholder.

Validation:

1. Run System Health audit_services and CST.
2. Confirm warning and remediation path.

Cleanup:

1. Restore original configuration.

### R06 - Hosts Redirect Simulation

Goal: Validate hosts hijack detection and restoration.

Setup:

1. Add non-default hosts entries mapping known domains to localhost.

Validation:

1. Run sec_hosts.
2. Run Post-Op Restore Hosts.

Cleanup:

1. Confirm hosts only has default localhost entries.

### R07 - Proxy and PAC Hijack Simulation

Goal: Validate network hijack detection.

Setup:

1. Set user proxy and PAC URL to inert local/non-routable values.

Validation:

1. Run sec_network_hijack.
2. Run Hijack repair or Post-Op reset.

Cleanup:

1. Confirm proxy and PAC disabled/reset.

### R08 - Browser Policy Hijack Simulation

Goal: Validate browser hijack policy detection.

Setup:

1. Set browser policy registry keys for homepage/search override.

Validation:

1. Run sec_browser_hijack.
2. Run Hijack repair path.

Cleanup:

1. Remove test policy keys.

### R09 - Security Tamper Simulation

Goal: Validate the workflow around a safe configuration-drift harness.

Setup:

1. Apply a safe simulation flag or controlled local drift in the VM.
2. If you need true sec_security_tampering validation, use a separate approved policy-drift case outside the built-in safe-only pack.

Validation:

1. Run sec_security_tampering.
2. Execute recommended repair path.

Cleanup:

1. Restore baseline policies.

### R10 - Offline Startup Hive Simulation

Goal: Validate WinPE offline collector and correlation behavior.

Setup:

1. Boot WinPE offline mode.
2. Mount offline hive and add startup persistence entry.

Validation:

1. Run CST offline scan and sec_autoruns.
2. Confirm offline artifact type appears.

Cleanup:

1. Remove injected hive entries.

### R11 - Boot Fixture Malformed MBR Signature

Goal: Validate boot scanner warning logic safely.

Setup:

1. Use fixture-based validator only; do not alter real boot disk.

Validation:

1. Run CST boot scanner validator.
2. Confirm invalid signature warning scenario passes expected check.

Cleanup:

1. None (fixture only).

### R12 - Repeatability Stress Set

Goal: Validate deterministic behavior.

Setup:

1. Pick R01, R03, R06.
2. Run each scenario five times from clean snapshot.

Validation:

1. Compare finding counts/status variance.

Cleanup:

1. Keep result set for release gate analytics.

## Current pack behavior summary

- The BenchLab script pack is safe-only and AV-safe by design.
- It is best suited for operator flow, persistence/audit coverage, remediation plumbing, reboot cleanliness, offline collector checks, and fixture-based boot validation.
- Use a separate approved positive-detection sample set if you need malware engine recall metrics.
