''##############################################################################
'#                                                                            #
'#                        Create CDE Diagnostic ISO                          #
'#                                                                            #
'##############################################################################
'
' Double-click to build a bootable BIOS + UEFI hybrid ISO of the
' CDE Diagnostic Suite. Requires Administrator privileges (UAC prompt).
'
' Output: CDE Beta_Test\Deploy\CDE_Diagnostic_Suite_<timestamp>.iso
'
'##############################################################################

Option Explicit

Dim scriptDir, ps1Path, psArgs, answer, customPath, outputArg
Dim objShell

' Derive the directory this VBS lives in (CDE Beta_Test root)
scriptDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
ps1Path   = scriptDir & "Scripts\CreateISO.ps1"

' Verify the PS1 exists before proceeding
If Not (CreateObject("Scripting.FileSystemObject").FileExists(ps1Path)) Then
    MsgBox "ERROR: CreateISO.ps1 not found at:" & vbCrLf & vbCrLf & _
           "  " & ps1Path & vbCrLf & vbCrLf & _
           "Ensure this file is in the CDE Beta_Test\Scripts\ folder.", _
           vbCritical, "Create CDE ISO"
    WScript.Quit
End If

' Ask: default path or custom?
answer = MsgBox( _
    "Build CDE Diagnostic Suite ISO?" & vbCrLf & vbCrLf & _
    "Default output location:" & vbCrLf & _
    "  " & scriptDir & "Deploy\CDE_Diagnostic_Suite_<timestamp>.iso" & vbCrLf & vbCrLf & _
    "Click YES to use the default location." & vbCrLf & _
    "Click NO  to enter a custom output path.", _
    vbYesNoCancel + vbQuestion, "Create CDE ISO")

If answer = vbCancel Then WScript.Quit

outputArg = ""

If answer = vbNo Then
    customPath = InputBox( _
        "Enter the full output path for the ISO file:" & vbCrLf & vbCrLf & _
        "Example:  D:\Backups\CDE.iso", _
        "Custom Output Path", _
        "D:\Robert\Desktop\CDE_Diagnostic_Suite.iso")
    If Trim(customPath) = "" Then WScript.Quit
    outputArg = " -OutputPath """ & customPath & """"
End If

' Build the PowerShell argument string
psArgs = "-NoProfile -ExecutionPolicy Bypass" & _
         " -File """ & ps1Path & """" & outputArg & _
         " ; Write-Host '' ; Write-Host 'Press any key to close...' -ForegroundColor Yellow ; $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')"

MsgBox "A PowerShell window will open to build the ISO." & vbCrLf & _
       "You will be prompted for Administrator access." & vbCrLf & vbCrLf & _
       "Watch the PowerShell window for progress." & vbCrLf & _
    "It will say 'ISO BUILD COMPLETE' when finished." & vbCrLf & vbCrLf & _
    "Windows launcher on generated media:" & vbCrLf & _
    "  Default: CDE.exe (root)" & vbCrLf & _
    "  Fallback: Scripts\\Launch\\CDE_Portable.bat", _
       vbInformation, "Create CDE ISO"

' Launch elevated PowerShell (triggers UAC)
Set objShell = CreateObject("Shell.Application")
objShell.ShellExecute "powershell.exe", psArgs, _
    Left(scriptDir, Len(scriptDir) - 1), "runas", 1

Set objShell = Nothing
