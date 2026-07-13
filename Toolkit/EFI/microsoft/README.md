# Microsoft EFI boot files (not in Git)

This folder is **gitignored**. Populate it from the **Windows ADK** (Assessment and Deployment Kit) / WinPE files used by your USB build pipeline.

Typical contents (from ADK Deployment Tools / WinPE media):

- `boot/bootmgfw.efi`
- `boot/memtest.efi` (+ optional `.mui` language packs)
- `boot/Fonts/*.ttf`
- `boot/Resources/bootres.dll`
- `boot/BCD`, `BCDTemplate`, `efisys*.bin`, etc.

Do **not** commit these files — Microsoft does not allow redistributing ADK/WinPE binaries through a public GitHub repository.

Related local-only paths: `Toolkit/bootmgr.efi`, `Toolkit/boot/bootsect.exe`, `Toolkit/HALP/oscdimg.exe`.
