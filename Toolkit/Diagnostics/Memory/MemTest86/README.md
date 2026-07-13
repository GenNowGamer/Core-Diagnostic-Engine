# PassMark MemTest86 (vendor package — not in Git)

Download the official **MemTest86 Free** USB package from PassMark and place files here as needed for your USB toolkit:

- `imageUSB.exe` — USB image writer from the vendor zip  
- `MemTest86_User_Guide_UEFI.pdf` — optional documentation  
- `memtest86-usb.img` — large boot image (always gitignored)

Primary in-tree memory diagnostic path for CDE is Microsoft `memtest.efi` via `Ensure-BootArtifacts.ps1` → `EFI/CDE/memtest.efi` (also local-only).

Redistribution of PassMark binaries is governed by the PassMark EULA; keep them on your build machine / USB media, not in this public repository.
