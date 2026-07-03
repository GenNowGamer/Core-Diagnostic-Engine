# WinPE Storage Controller Drivers

Drop **extracted** vendor storage-controller driver packages into this folder
(any subfolder layout is fine). When `Scripts\Customize-WinPE.ps1` runs, every
`.inf` found here is injected into `boot.wim` via:

```
Dism /Image:<mount> /Add-Driver /Driver:"Drivers\Storage" /Recurse
```

## Why this matters
WinPE only ships a minimal set of inbox storage drivers. On many modern systems
the SATA/NVMe controller is in **RAID / Intel VMD** mode, which WinPE cannot see
without the vendor driver. Adding the driver here lets WinPE (and the CDE
**S.M.A.R.T. Analyzer**) enumerate those drives.

## What to add (most common)
- **Intel Rapid Storage Technology (RST) / VMD** F6 driver package
  (`iaStorVD.inf`, `iaStorAC.inf`).
- **AMD RAID** F6 driver package, if applicable.
- Any vendor NVMe controller driver for non-standard controllers.

## How to get the .inf packages
Download the **F6 / "floppy" install** package from the vendor (Intel, AMD, or
your motherboard/laptop OEM) and extract it. The extracted folder contains the
`.inf`, `.sys`, and `.cat` files. Copy that folder in here.

## Notes
- Drivers must be **64-bit (amd64)** to match the WinPE image.
- Leaving this folder empty is fine — the build simply skips driver injection.
- Properly signed drivers are preferred; unsigned ones are still injected
  (`/ForceUnsigned`) but may warn.
