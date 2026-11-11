# Core Diagnostic Engine (CDE)

[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%7C%20Windows%2011%20%7C%20WinPE%20(x64)-0078D6.svg?logo=windows&logoColor=white)](#core-operating-environments)
[![Version](https://img.shields.io/badge/Version-1.0.1%20(Beta)-green.svg)](https://github.com/GenNowGamer/Core-Diagnostic-Engine/releases/latest)
[![Latest Release](https://img.shields.io/badge/Release-v1.0.1-orange.svg)](https://github.com/GenNowGamer/Core-Diagnostic-Engine/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/GenNowGamer/Core-Diagnostic-Engine/total?color=2ea44f&logo=github&label=Downloads)](https://github.com/GenNowGamer/Core-Diagnostic-Engine/releases)
[![Framework](https://img.shields.io/badge/Framework-.NET%208%20WPF%20%7C%20PowerShell%205.1%2B-512BD4.svg?logo=dotnet&logoColor=white)](#system-architecture)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](#license--disclaimers)
[![Execution](https://img.shields.io/badge/Telemetry-Zero%20%7C%20100%25%20Local-success.svg)](#security-privacy--safety-standards)

**Core Diagnostic Engine (CDE)** is a professional, modular diagnostic, repair, malware remediation, and bench-testing toolkit for Windows PCs. Engineered for computer repair technicians, IT administrators, and service bench specialists, CDE combines bare-metal UEFI hardware diagnostics, offline recovery inside a custom Windows Preinstallation Environment (WinPE), and live operating system triage into a single, cohesive WPF platform.

Whether diagnosing failing storage on an unbootable machine, neutralizing sophisticated persistence mechanisms, repairing corrupted Windows servicing stacks, or producing polished, client-ready PDF reports, CDE delivers deterministic, evidence-based results without external cloud dependencies.

---

### 📥 Downloads

| Asset | Format | Description | Direct Download |
| :--- | :--- | :--- | :--- |
| **CDE Portable Package** | Standalone Archive (`.zip`) | Full CDE diagnostic toolkit for 64-bit Windows 10/11 & WinPE | [**Download CDE v1.0.1 (.zip)**](https://github.com/GenNowGamer/Core-Diagnostic-Engine/releases/latest/download/CDE-v1.0.1-Portable.zip) |
| **CDE User Guide** | PDF Manual (`.pdf`) | Comprehensive technician bench manual & reference | [**Download User Guide (.pdf)**](https://github.com/GenNowGamer/Core-Diagnostic-Engine/releases/latest/download/CDE_User_Guide.pdf) |

---

---

## Table of Contents

- [Core Operating Environments](#core-operating-environments)
- [Recommended Technician Workflow](#recommended-technician-workflow)
- [Comprehensive Features & Capabilities](#comprehensive-features--capabilities)
  - [1. Diagnostics & System Health](#1-diagnostics--system-health)
  - [2. Hardware Diagnostics & Stress Testing](#2-hardware-diagnostics--stress-testing)
  - [3. Security & Anti-Malware Suite](#3-security--anti-malware-suite)
  - [4. Hijack, Scam & Persistence Remediation](#4-hijack-scam--persistence-remediation)
  - [5. System Repair & OS Restoration](#5-system-repair--os-restoration)
  - [6. Maintenance & Bench Utilities](#6-maintenance--bench-utilities)
  - [7. Case Management & Professional Deliverables](#7-case-management--professional-deliverables)
- [System Architecture](#system-architecture)
- [Repository Layout](#repository-layout)
- [Building & Deployment](#building--deployment)
  - [Prerequisites](#prerequisites)
  - [Compiling ToolkitGUI](#compiling-toolkitgui)
  - [Building Bootable WinPE Media](#building-bootable-winpe-media)
  - [Running on Live Windows](#running-on-live-windows)
  - [Vendor Binaries & Tool Acquisition](#vendor-binaries--tool-acquisition)
- [Security, Privacy & Safety Standards](#security-privacy--safety-standards)
- [License & Disclaimers](#license--disclaimers)

---

## Core Operating Environments

CDE is architected to operate across three distinct operational tiers, ensuring technicians have full diagnostic visibility regardless of system health:

```
┌────────────────────────────────────────────────────────────────────────┐
│                        CORE DIAGNOSTIC ENGINE                          │
├─────────────────────┬──────────────────────────┬───────────────────────┤
│   Bare-Metal UEFI   │   Offline WinPE Media    │     Live Windows      │
│  (rEFInd + CHU EFI) │  (USB / ISO Environment) │  (Windows 10 & 11 OS) │
├─────────────────────┼──────────────────────────┼───────────────────────┤
│ • Pre-boot test     │ • Unbootable OS repair   │ • Live OS triage      │
│ • CPU / RAM verify  │ • Offline registry hives │ • Real-time vitals    │
│ • SMART controller  │ • Offline DISM servicing │ • Process analysis    │
│ • Zero OS overhead  │ • Bootloader & BCD fixes │ • Post-op remediation │
│ • Hardware isolates │ • Offline SAM recovery   │ • Client deliverables │
└─────────────────────┴──────────────────────────┴───────────────────────┘
```

1. **Live Windows Mode (`CDE.exe`):**  
   Runs with elevated privileges on active Windows 10 and Windows 11 desktop and server systems. Enables real-time process monitoring, live system health checks, driver/service triage, online system file repairs, and post-malware cleanup.
2. **Offline WinPE Mode (Bootable USB / ISO):**  
   Boots into a customized Windows Preinstallation Environment via UEFI or legacy BIOS. Automatically searches for and mounts offline Windows installations into the offline registry namespace, enabling offline DISM repairs, bootloader reconstruction, offline malware sweeps, and offline administrator account recovery without booting the compromised OS.
3. **Pre-Boot UEFI Diagnostics (Core Hardware Utility - CHU):**  
   Integrated with the onboard rEFInd UEFI boot manager. Boots directly into `CoreDiag.efi` before any operating system loads, performing bare-metal CPU instruction verification, multi-pass memory sweeps, and low-level SMART controller diagnostics isolated from driver interference.

---

## Recommended Technician Workflow

CDE aligns with professional bench service lifecycle standards, moving logically from symptom intake to verified resolution:

```
[ Intake & Symptoms ] ──► [ System Health Check ] ──► [ Targeted Diagnostics ]
                                                              │
                                                              ▼
[ Client Deliverable ] ◄── [ Post-Op Cleanup ] ◄── [ Surgical Repair ]
```

1. **Intake & Symptom Mapping:**  
   Launch CDE on the target machine or boot into WinPE. On the **Dashboard**, record client notes and generate a work order. CDE's symptom engine analyzes keywords in the complaint and highlights the recommended diagnostic path.
2. **System Health Check (Automated Sweep):**  
   Execute a baseline health sweep (**Recommended**, **Quick Vitals**, **Deep System**, or **Full Audit**). Review scored findings categorized by Severity, Impact, deterministic Confidence (0–100), and evidence-quality Classification.
3. **Targeted Deep Testing:**  
   Drill down into specialized diagnostic engines based on initial findings:
   - *Storage issues:* Launch **S.M.A.R.T. Analyzer** or **Diag & Repair → Storage**.
   - *Memory/CPU stability:* Run **Diag & Repair** line tests or reboot into pre-boot **CHU**.
   - *Suspected infection:* Run **Malware Cleanup** (Core Security Tool) and **Hijack & Scam Repair**.
   - *Startup/freeze problems:* Inspect **Startup Manager** and **Process Analyzer**.
4. **Surgical Repair & Remediation:**  
   Apply targeted fixes using the least intrusive method:
   - System file and servicing corruption: **OS Repair** (SFC / DISM with external WIM support).
   - Boot failures and BCD errors: **Disk & Boot Repair** (WinPE).
   - Hijacked settings, browser redirects, or tampered services: **Hijack & Scam Repair** and **Startup Manager**.
   - Account lockouts on offline machines: **Tools Library → Account Recovery**.
5. **Post-Op Cleanup & Verification:**  
   Run **Post-Op Cleanup** to restore default critical service start types, rebuild broken shell file associations, reset hijacked DNS/proxies, and flush damaged caches. Re-run baseline checks to verify resolution.
6. **Documentation & Deliverable:**  
   Click **Open Report** in any workflow to generate a professional, print-ready PDF work order or diagnostic audit under `Logs\` for client handoff and billing records.

---

## Comprehensive Features & Capabilities

### 1. Diagnostics & System Health

The **System Health Check** view is CDE's central automated diagnostic clearinghouse. Built on a modular catalog (`HealthCheckCatalog.json`), it evaluates system state against battle-tested operational rules:

* **Catalog Presets:**
  - **Quick Vitals:** Rapid CPU/RAM sustained utilization snapshots, system disk free space, OS version/build compatibility, activation state, battery wear/health, and recent system crash telemetry.
  - **Deep System:** Driver signature validation, file system minifilter audits, full Windows Update servicing stack inspection, network interface configurations, GPU hardware telemetry, thermal event tracking (7-day window), and Windows Reliability Monitor scores.
  - **System Audit:** Installed software inventory, Windows service configurations, persistent startup entries, partition table layouts, and event log error clustering.
  - **Security Audits:** Publisher-aware autorun analysis, hosts file integrity checks, browser extension inventories, non-Microsoft scheduled task audits, security tampering inspections, and ransomware recovery environment verification.
* **Deterministic Scored Findings:**  
  Findings are structured into actionable cards featuring:
  - **Classification:** Categorized as *Confirmed fault*, *Corroborated suspect*, *Single signal*, *Inventory*, or *Expected limitation*.
  - **Deterministic Confidence:** Calculated match score (0–100) reflecting explicit rule criteria rather than speculative heuristics.
  - **Actionable Evidence & Recommendations:** Explicit registry keys, file paths, event IDs, and clear remediation guidance.
* **Correlated Event Clustering:**  
  Analyzes Windows System and Application event logs over 24-hour and 7-day intervals. Automatically groups cascade failures into correlated clusters (e.g., unexpected shutdowns, BSOD bugchecks, storage/NTFS timeouts, display driver recoveries, and discrete WHEA hardware error splits).
* **GPU Functional Diagnostics (`CdeGpuDiagCli`):**  
  Active functional testing utility evaluating display driver integrity, DirectX 11/12 compatibility, OpenGL, Vulkan, and a capped VRAM write/readback verification with real-time temperature reporting. Environment-aware reporting safely tags virtualized or headless sessions as **N/A** without throwing false failures.

---

### 2. Hardware Diagnostics & Stress Testing

* **Diag & Repair (PC-Doctor Style Line Tests):**  
  An integrated hardware stress-test suite available in both full Windows and WinPE, structured into **Quick** and **Extended** profiles:
  - **CPU Tests (12 Sub-tests):** Instruction execution, arithmetic, cache stability, and SIMD instruction set verification (MMX, SSE, SSE2, AVX) powered by the standalone `CdeCpuSimdCli` engine.
  - **Memory Tests (10 Sub-tests):** Multi-pass pattern verification, address bus walk, bit-fade testing, and allocation stress.
  - **Storage Tests (6 Sub-tests):** Sequential read stress, random seek verification, buffer integrity, and controller handshake tests.
  - **Security Pass:** Integrated scan-only pass powered by the Core Security Tool.
* **S.M.A.R.T. Analyzer:**  
  Low-level drive telemetry for internal and external fixed drives. Displays raw and normalized attributes, reallocated sector counts, wear level indicators, temperature history, and overall drive health badges. Excludes USB flash drives and WinPE boot media from storage tests to prevent false alarms.
* **Core Hardware Utility (CHU Pre-Boot Integration):**  
  For hardware issues that prevent Windows from loading or require bare-metal isolation, CDE pairs with CHU (`CoreDiag.efi`). Pre-boot results saved to the toolkit drive are automatically ingested and rendered inside the CDE GUI (**CHU Pre-Boot Results**), providing unified case tracking across pre-boot and in-OS testing.

---

### 3. Security & Anti-Malware Suite

* **Core Security Tool (CST):**  
  CDE's purpose-built threat detection and remediation engine, engineered for both live Windows environments and offline WinPE drive mounts:
  - **Scan Modes:** *ThreatScan* (high-speed triage targeting critical autorun paths, AppData, temp locations, browser directories, and scheduled tasks), *FullScan* (comprehensive volume analysis), and *CustomScan* (targeted folder/file analysis).
  - **Noise Suppression & Known-Good Gating:** Features hash-based known-good allowlisting, trusted publisher signature validation, and baseline sidecars to prevent false alarms on developer binaries or system tools.
  - **Integrated Remediation:** Supports selective quarantine, safe deletion, manifest-backed restoration, and detailed remediation tracking with live step progress.
  - **Threat Signature Updates:** One-click offline and online IOC signature database synchronization directly within the tool.
* **Windows Defender Integration:**  
  Trigger built-in Windows Defender quick scans and offline remediation passes directly from the CDE interface on supported Windows systems.
* **Security Tampering & Ransomware Recovery Audits:**  
  - Inventories dangerous Microsoft Defender folder and extension exclusions.
  - Audits Volume Shadow Copy (VSS) status, backup service configurations, and Windows Recovery Environment (WinRE) health to detect ransomware destruction tactics.
  - Detects weakened UAC settings, disabled Windows Firewall profiles, and bypassed SmartScreen configurations.
* **Antivirus Coexistence Intelligence:**  
  Queries Windows Security Center to identify active third-party security suites (e.g., Malwarebytes, CrowdStrike, SentinelOne). Automatically suppresses false warnings when Microsoft Defender is operating in passive or disabled coexistence mode.

---

### 4. Hijack, Scam & Persistence Remediation

* **Hijack & Scam Repair:**  
  A modern, technician-oriented scanner inspired by HiJackThis, designed to uncover tech support scam artifacts and browser takeovers:
  - Identifies hijacked browser homepages, default search engines, rogue extensions, and malicious shortcut parameters (`.lnk` target tampering).
  - Flags rogue proxy servers, malicious DNS overrides, and tampered Internet settings.
  - Scans for unauthorized remote support software (AnyDesk, TeamViewer, UltraViewer, ScreenConnect) and malicious helper objects.
  - Provides selective repair controls with automatic configuration backups.
* **Startup Manager:**  
  Full inspection and management of all Windows persistence mechanisms:
  - **User Logon Persistence:** Standard Run and RunOnce keys (`HKLM` and `HKCU`), Group Policy Run keys (`Policies\Explorer\Run`), and Startup folder items.
  - **MSIX / Store App Startup Tasks:** Identifies and manages modern AppModel packaged startup tasks (e.g., Microsoft Teams, OneDrive) with package publisher resolution.
  - **Scheduled Tasks:** Audits logon, boot, and idle tasks. Automatically isolates core Windows system tasks (`\Microsoft\*`) from third-party persistence, allowing safe disabling or removal of suspicious tasks.
  - **Services & Drivers:** Analyzes service binary paths, execution launchers, and driver signatures. Supports in-line service startup reconfiguration, service termination, and guarded unregistration.
  - **Task Manager Parity:** Synchronizes state changes with the Windows `StartupApproved` registry keys, ensuring changes are cleanly reflected in native Windows management tools.
* **Winlogon Shield:**  
  Specifically targets boot-level persistence hooks by monitoring `Userinit` and `Shell` registry entries. Automatically detects unauthorized replacements (e.g., ransomware locker hooks or spyware shells) and provides one-click restoration to Windows factory defaults with automatic backup.

---

### 5. System Repair & OS Restoration

* **OS Repair (SFC & DISM Servicing):**  
  Comprehensive system file integrity and component store servicing:
  - **System File Checker (SFC):** Verifies and replaces corrupted protected system files on running Windows installations.
  - **DISM Component Store Repair:** Repairs damaged WinSxS component stores online or offline.
  - **External `install.wim` Source Mounting:** Seamlessly solves DISM error `0x800f081f` (source files not found). Allows technicians to mount matching Windows ISO install media (`install.wim` / `install.esd`) as a local repair payload without internet access.
  - **Network Stack Reset:** Resets Winsock catalogs, TCP/IP stacks, IPv4/IPv6 configurations, and Windows firewall profiles in a single operation.
  - **Windows Update Stack Repair:** Resets corrupted Windows Update cache folders (`SoftwareDistribution`, `Catroot2`) and restores core servicing components.
* **Disk & Boot Repair (WinPE Exclusive):**  
  Dedicated bootloader recovery environment for unbootable UEFI and BIOS systems:
  - Visual disk and partition mapping showing volume layouts, filesystem types, and active boot flags.
  - **BCD Backup & Restore:** Safeguards existing boot configuration data prior to repair operations.
  - **EFI Bootloader Rebuild:** Reconstructs corrupted EFI system partitions (`bootx64.efi`, Microsoft BCD structures) using `bcdboot` targeting detected offline Windows installations.
  - **MBR & Boot Sector Repair:** Restores master boot records and volume boot codes (`bootrec /fixmbr`, `bootrec /fixboot`).
* **Offline Update Removal:**  
  Uninstall problematic Windows cumulative updates directly from offline Windows images inside WinPE, resolving blue-screen boot loops caused by faulty updates.

---

### 6. Maintenance & Bench Utilities

* **Post-Op Cleanup:**  
  A dedicated 8-tool cleanup and restoration suite designed for execution following malware removal or heavy repair operations:
  1. *Browser Cache Clear:* Cleans disk cache for Edge, Chrome, and Firefox without wiping user passwords or bookmarks.
  2. *Restore Default Services:* Realigns essential Windows services (including `wuauserv`, `bits`, `DcomLaunch`, and `RpcSs`) to factory startup types.
  3. *File Association Fix:* Restores hijacked core shell execution handlers (`.exe`, `.lnk`, `.bat`, `.cmd`, `.com`).
  4. *Icon & Thumbnail Cache Reset:* Rebuilds corrupted desktop icons and shell thumbnail databases.
  5. *DNS Cache Flush:* Flushes local resolver caches following network hijack remediation.
  6. *Reset Proxy Settings:* Disables rogue user-level and WinHTTP system proxies.
  7. *Restore Hosts File:* Replaces tampered `hosts` files with clean Windows defaults (requires operator confirmation).
  8. *Restart Explorer:* Restarts the Windows shell in-place to apply visual and association fixes without a reboot.
* **Fast Fixes:**  
  Fourteen rapid, one-click automated technician fixes covering common bench issues (network renewals, printer spooler resets, Windows search indexing rebuilds, Windows Store cache resets, and event log clears). Every fix executes with post-action verification and displays an explicit **Pass/Fail** status.
* **File Manager & Shadow Copy Explorer:**  
  Dual-pane navigation interface optimized for technician recovery workflows:
  - Browse offline volumes and copy critical customer data.
  - **Read-Only VSS Shadow Copy Browser:** Mounts and navigates Volume Shadow Copy snapshots on live Windows, enabling direct retrieval of uncorrupted prior versions of user files.
  - **Integrated CST Scanner:** Right-click any file, folder, or drive to launch an immediate Core Security Tool custom threat analysis.
* **Process Analyzer:**  
  Real-time process triage utility featuring live CPU/RAM load sorting, parent-child process tree inspection, Authenticode signature verification, loaded module tracking, network connection enumeration, and behavioral anomaly heuristics. Includes one-click process termination and direct CST file analysis.
* **Offline Account Recovery (WinPE):**  
  Direct offline SAM database manipulation tool. Safely enables the built-in local `Administrator` account on locked-out Windows installations without requiring password cracking or third-party registry hacks.
* **Backup & Imaging (Robocopy):**  
  Hardened graphical frontend for `robocopy.exe`, supporting folder mirroring, user profile data extraction, and backup staging with path-quoting resilience for drive roots and spaced directory paths.
* **Temp File Cleaner & Uninstall Manager:**  
  Intelligently sweeps system and user temp directories while gracefully skipping locked application files, accompanied by an application manager for removing bloatware.

---

### 7. Case Management & Professional Deliverables

* **Intake & Symptom Inference:**  
  Technicians enter customer complaint notes into the **Dashboard**. CDE's symptom matcher analyzes the notes, links the case to matching diagnostic presets, and suggests the most effective repair path.
* **Case Tracking & Timelines:**  
  Work orders track every action taken during a bench session—including automated health checks, pre-boot CHU results, malware sweeps, and repair scripts—into structured JSON records stored under `CDE\Runtime\WorkOrders\`.
* **Professional PDF Deliverables (`Logs\`):**  
  Powered by QuestPDF, CDE automatically compiles clean, beautifully formatted PDF deliverables for completed workflows. Reports include work order metadata, executive overall health statuses (`Healthy`, `Healthy with notes`, `Warning`, `Critical`), line-item test results, and plain-English findings with clear remediation notes, ready for presentation to customers or integration into shop ticketing systems.

---

## System Architecture

CDE is designed with clean architectural boundaries separating the user interface, workflow orchestration, and hardware execution layers:

```
┌────────────────────────────────────────────────────────────────────────┐
│                      WPF USER INTERFACE (ToolkitGUI)                   │
│   Dashboard  │  Health Check  │  Diag & Repair  │  Security  │  Repair │
├────────────────────────────────────────────────────────────────────────┤
│                          INTEROP & DISPATCH                            │
│           Process Runners  │  PowerShell Runspaces  │  WPF Services    │
├────────────────────────────────────────────────────────────────────────┤
│                     CORE POWERSHELL WORKFLOW LAYER                     │
│  Toolkit.Core.psm1  │  SystemHealthCheck.ps1   │  HardwareDiagnostics  │
│  HealthFindings     │  EventFindingClusters    │  OSRepair.ps1         │
│  StartupManager     │  HijackRepair.ps1        │  PostOpCleanup.ps1    │
├────────────────────────────────────────────────────────────────────────┤
│                      STANDALONE DIAGNOSTIC HELPERS                     │
│    CdeCpuSimdCli.exe (SIMD)    │    CdeGpuDiagCli.exe (DirectX/Vulkan) │
├────────────────────────────────────────────────────────────────────────┤
│                         BARE-METAL UEFI ENGINE                         │
│       rEFInd Boot Manager      │      Core Hardware Utility (CHU)      │
│     EFI\boot\bootx64.efi       │      EFI\CDE\CoreDiag.efi             │
└────────────────────────────────────────────────────────────────────────┘
```

* **WPF Frontend (`ToolkitGUI`):**  
  Built on .NET 8 (C#) using standard Windows Presentation Foundation controls. Features full-screen responsive layouts, dark theme styling, live script progress streaming, and high-DPI scaling. Runs with `requireAdministrator` manifest elevation.
* **PowerShell Orchestration Core (`Toolkit.Core.psm1`):**  
  Encapsulates common hardware detection, offline registry mounting, file system safety, and logging utilities. All scripts are strictly standardized to **UTF-8 with BOM** for flawless execution across Windows PowerShell 5.1 and modern PowerShell runtimes.
* **Diagnostic CLI Companions:**  
  Lightweight, self-contained .NET executables (`CdeCpuSimdCli.exe`, `CdeGpuDiagCli.exe`) companion-published alongside the GUI to execute low-level instruction sweeps and graphics driver API handshakes that cannot be performed reliably via standard scripting APIs.
* **Pre-Boot UEFI Subsystem:**  
  Composed of rEFInd as the primary UEFI boot selector, chainloading into custom EDK2-built diagnostic payloads (`CoreDiag.efi`) or standard WinPE loaders.

---

## Repository Layout

```text
Core-Diagnostic-Engine/
├── Toolkit/
│   ├── App/
│   │   ├── ToolkitGUI/             # Main C# WPF desktop application
│   │   ├── CdeCpuSimdCli/          # SIMD instruction diagnostic CLI helper
│   │   ├── CdeGpuDiagCli/          # GPU functional diagnostic CLI helper
│   │   ├── UserGuideGenerator/     # Markdown-to-PDF documentation generator
│   │   └── Publish-ToolkitGUI.ps1  # Canonical build and staging script
│   ├── Config/
│   │   ├── HealthCheckCatalog.json # Diagnostic checks, categories & presets
│   │   ├── EventFindingClusters.json# Event log correlation definitions
│   │   └── settings.json           # Toolkit operational defaults
│   ├── Docs/
│   │   └── UserGuide/              # Full operator manual source chapters
│   ├── HALP/                       # Help assets & compiled CDE_User_Guide.pdf
│   ├── Scripts/
│   │   ├── Core/                   # Modular diagnostic libraries & orchestrators
│   │   │   ├── Toolkit.Core.psm1   # Primary engine module
│   │   │   ├── HealthChecks.ps1    # Health check implementations
│   │   │   ├── HealthFindings.ps1  # Finding classification & scoring
│   │   │   └── WinPE_OfflineStartup.ps1# WinPE offline registry detection
│   │   └── Workflows/              # Standalone workflow scripts (OSRepair, PostOp, etc.)
│   ├── Security/                   # Core Security Tool (CST) engine & rulesets
│   ├── Tools/                      # Portable technician utilities catalog
│   ├── WinPE/                      # WinPE configuration & customization scripts
│   ├── EFI/                        # rEFInd configuration and UEFI boot assets
│   ├── Logs/                       # Generated client-ready PDF deliverables
│   └── CDE.exe                     # Published entry launcher
├── session_handoff.md              # Engineering notes & historical session logs
├── THIRD_PARTY_NOTICES.md          # Open-source and third-party notices
├── LICENSE                         # MIT License
└── README.md                       # Repository overview & documentation
```

---

## Building & Deployment

### Prerequisites

To compile and package CDE from source, ensure your development environment includes:

- **Windows 10 or Windows 11 (64-bit)**
- **.NET 8 SDK** (or Visual Studio 2022 with .NET desktop development workload)
- **PowerShell 5.1** or **PowerShell 7+**
- **Windows ADK & WinPE Add-on** (required only when building bootable WinPE media)

---

### Compiling ToolkitGUI

Clone the repository and run the canonical publish script from an elevated PowerShell session:

```powershell
# Clone the repository
git clone https://github.com/GenNowGamer/Core-Diagnostic-Engine.git
cd Core-Diagnostic-Engine

# Compile and publish ToolkitGUI and companion CLI utilities
powershell -NoProfile -ExecutionPolicy Bypass -File "Toolkit\App\Publish-ToolkitGUI.ps1"
```

The build pipeline will:
1. Restore dependencies and compile `ToolkitGUI.sln` in Release configuration.
2. Publish `ToolkitGUI.exe` as a self-contained 64-bit binary into `Toolkit\App\ToolkitGUI\bin\Release\net8.0-windows\`.
3. Compile and publish `CdeCpuSimdCli` and `CdeGpuDiagCli` into the deployment directory.
4. Generate the canonical operator manual `HALP\CDE_User_Guide.pdf` from source markdown files using QuestPDF.
5. Stage the primary launcher executable as `Toolkit\CDE.exe`.

---

### Creating Bootable Media

CDE supports both bare-metal UEFI hardware diagnostics and full offline Windows PE recovery.

#### Option A: 1-Click Bootable USB (Recommended)
1. Insert a USB flash drive (16 GB or 32 GB recommended).
2. Double-click **`Prepare-USB.bat`** in the root directory (click **Yes** on the UAC Administrator prompt).
3. Select your USB drive's disk number from the interactive table and confirm.

> **Note on Out-of-the-Box Booting:**  
> The USB boots immediately via **rEFInd** into bare-metal UEFI hardware diagnostics (**Core Hardware Utility / CHU** and **MemTest86**) without any additional configuration.

#### Option B: Building Full Offline WinPE Recovery Media
To enable the full offline Windows PE environment (for offline DISM, registry repair, and offline malware remediation):
1. Install the official Microsoft [Windows ADK and Windows PE Add-on](https://learn.microsoft.com/windows-hardware/get-started/adk-install).
2. Double-click **`Build-WinPE.bat`** in the root directory.  
   *This automatically stages the base Windows PE image and boot scaffolding from your ADK, injects PowerShell components, storage/network drivers, and `startnet.cmd`, and commits `sources\boot.wim`.*
3. When prompted, select **Y** to automatically prepare your bootable USB, or run **`Create-ISO.bat`** to generate a hybrid BIOS/UEFI `.iso` for Ventoy, Rufus, or virtual machines.

---

### Running on Live Windows

To run CDE directly on a live Windows machine without booting into WinPE:

1. Navigate to the `Toolkit` directory.
2. Right-click **`CDE.exe`** and select **Run as Administrator** (elevated token required for physical drive reads and system registry inspections).
3. The CDE dashboard will load, ready for live diagnostics and repair workflows.

---

### Vendor Binaries & Tool Acquisition

In accordance with redistribution licenses, third-party vendor binaries (such as Microsoft Windows ADK boot components and PassMark MemTest86 images) are **not** committed to the Git repository. 

Refer to [`Toolkit\Tools\PLACEHOLDER_ACQUISITION.md`](Toolkit/Tools/PLACEHOLDER_ACQUISITION.md) for step-by-step instructions on acquiring and staging these optional external assets. Once placed, execute `Toolkit\Tools\update_tools_manifest.ps1` to update cryptographic SHA256 integrity hashes in the catalog manifest.

---

## Security, Privacy & Safety Standards

* **100% Local Execution:** All diagnostic sweeps, telemetry collection, malware analysis, and reporting engines execute entirely on the target machine. Zero diagnostic data, hardware profiles, or customer telemetry are ever transmitted to cloud endpoints.
* **Deterministic Findings over Speculative Scoring:** Findings are grounded in verifiable technical evidence (registry states, Authenticode signatures, event log IDs, hardware timeouts) to minimize noise and eliminate false alarms on technician benches.
* **Guarded Remediation & Automatic Backups:** Risky operations—including hosts file resets, Winlogon resets, service deletions, BCD updates, and scheduled task removals—create automated backups before execution and provide clear rollback mechanisms.
* **Clean Repository Hygiene:** Sensitive developer configurations, transient build artifacts, local scratch files, and proprietary vendor images are strictly isolated via `.gitignore`.
* **Changelog & Historical Release Notes:** Complete historical development logs and release summaries are cataloged separately in [`Toolkit/CHANGELOG.md`](Toolkit/CHANGELOG.md), keeping this documentation focused on application features and operator usage.

---

## License & Disclaimers

- **License:** Core Diagnostic Engine source code is open source under the [MIT License](LICENSE).
- **Third-Party Components:** Bundled utilities, open-source libraries, and boot components are governed by their respective licenses as detailed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- **Disclaimer:** Core Diagnostic Engine is an independent software toolkit developed for technician use. Windows, WinPE, DISM, and Windows Defender are registered trademarks of Microsoft Corporation. Other trademarks, product names, and company brands are the property of their respective owners.
