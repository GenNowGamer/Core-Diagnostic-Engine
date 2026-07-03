' Run-PrepareUSB.vbs
' Double-click this file to launch Prepare-BootableUSB.ps1 as Administrator.
' Triggers a UAC prompt, then opens an elevated PowerShell window running the script.
' Media launch behavior after preparation:
'   Default Windows launcher: CDE.exe at media root
'   Fallback launcher: Scripts\Launch\CDE_Portable.bat

Dim fso, scriptDir, ps1Path, psArgs

Set fso   = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1Path   = scriptDir & "\Scripts\Prepare-BootableUSB.ps1"

psArgs = "-NoProfile -ExecutionPolicy Bypass -NoExit -File """ & ps1Path & """"

CreateObject("Shell.Application").ShellExecute _
    "powershell.exe", psArgs, scriptDir, "runas", 1
