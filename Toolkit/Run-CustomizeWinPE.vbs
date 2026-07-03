Dim scriptDir, ps1Path, args

scriptDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
ps1Path   = scriptDir & "\Scripts\Customize-WinPE.ps1"

args = "-NoProfile -ExecutionPolicy Bypass -File """ & ps1Path & """"

' ShellExecute with "runas" triggers the UAC elevation prompt
CreateObject("Shell.Application").ShellExecute _
    "powershell.exe", args, scriptDir, "runas", 1
