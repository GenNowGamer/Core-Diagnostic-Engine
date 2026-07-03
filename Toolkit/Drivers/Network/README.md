# WinPE Network (NIC) Drivers

Drop **extracted** vendor Ethernet/NIC driver packages into this folder
(any subfolder layout is fine). When `Scripts\Customize-WinPE.ps1` runs, every
`.inf` found here is injected into `boot.wim` via:

```
Dism /Image:<mount> /Add-Driver /Driver:"Drivers\Network" /Recurse
```

## Why this matters
WinPE only ships a minimal set of inbox NIC drivers. On many modern systems the
Ethernet controller (newer Intel/Realtek 2.5GbE, Killer, or recent laptop NICs)
has **no inbox driver**, so WinPE gets no link and no DHCP address. Adding the
driver here lets WinPE obtain an IP and lets bundled tools — such as the
**Firefox** browser (`Tools\Firefox`) — reach the network.

## Wi-Fi is NOT supported
WinPE has no WLAN stack, so wireless adapters will not work regardless of
drivers. This is **wired Ethernet / USB-Ethernet only**.

## What to add (most common)
- **Intel** Gigabit / 2.5GbE Ethernet driver package (`e1d*.inf`, `e2f*.inf`).
- **Realtek** PCIe GbE / 2.5GbE Family Controller package.
- The Ethernet driver for your specific laptop/desktop OEM, or a known-good
  **USB-to-Ethernet** adapter driver (handy universal fallback).

## How to get the .inf packages
Download the driver from the vendor (Intel, Realtek) or your motherboard/laptop
OEM and extract it. The extracted folder contains the `.inf`, `.sys`, and `.cat`
files. Copy that folder in here.

## Notes
- Drivers must be **64-bit (amd64)** to match the WinPE image.
- Leaving this folder empty is fine — the build simply skips driver injection.
- Properly signed drivers are preferred; unsigned ones are still injected
  (`/ForceUnsigned`) but may warn.
