# Third-party notices

This repository’s own source is licensed under `LICENSE` (MIT). The components
below are separate works with their own terms.

## Bundled / tracked (OK for public source)

| Component | Location | Notes |
|-----------|----------|--------|
| **rEFInd** | `Toolkit/EFI/refind/`, `Toolkit/EFI/boot/` | GPL-licensed boot manager; icons include CC/GPL license texts under `EFI/boot/icons/licenses/` |
| **7-Zip** | `Toolkit/Windows Tools/Utilities/7Zip/` | LGPL / BSD-style (see vendor package) |
| **CIRCL Hashlookup** | CST online reputation | Public API at `https://hashlookup.circl.lu/` — no API key; subject to CIRCL’s usage policy |

## Not in Git (must obtain locally)

These are required for a full bootable USB toolkit but **must not** be committed
or redistributed via this public repository. See
`Toolkit/Tools/PLACEHOLDER_ACQUISITION.md`.

| Component | Typical path | Source |
|-----------|--------------|--------|
| Windows PE `boot.wim` / mount work | `Toolkit/sources/`, `Toolkit/Mount/` | Windows ADK + `Customize-WinPE.ps1` |
| Microsoft boot stack | `Toolkit/EFI/microsoft/`, `Toolkit/bootmgr.efi`, `Toolkit/boot/*` | Windows ADK / copype |
| Microsoft Memory Diagnostic | `Toolkit/EFI/CDE/memtest.efi`, `WinMemoryDiag/memtest.efi` | Windows kits / `Ensure-BootArtifacts.ps1` |
| `oscdimg.exe` | `Toolkit/HALP/oscdimg.exe` | Windows ADK Deployment Tools |
| PassMark MemTest86 Free package | `Toolkit/Diagnostics/Memory/MemTest86/` | [memtest86.com](https://www.memtest86.com) (vendor EULA) |
| PCDoctor legacy payload | `Toolkit/Tools/Boot/PCDoctor/` | Proprietary — local only |
| Published GUI payload | `Toolkit/CDE.exe`, `Toolkit/CDE/ToolkitGUI/` | Build with `Publish-ToolkitGUI.ps1` |

## Your code vs vendor code

- **Core Diagnostic Engine** GUI, scripts, CST integration, docs: MIT (`LICENSE`).
- **CoreDiag.efi / CHUPrep.efi / CDEBoot.efi**: built from the Core Hardware Utility / EDK2 tree; treat as project artifacts (rebuild from source rather than relying on committed binaries alone when possible).
