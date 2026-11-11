@echo off
:: =============================================================
:: CDE Diagnostic Suite - WinPE Startup Script
:: startnet.cmd is executed automatically by WinPE after shell init
:: =============================================================

:: Initialize WinPE (loads drivers, networking)
wpeinit

:: Set window title and clear screen
title CDE Diagnostic Suite - Boot Menu
cls

:: ---------------------------------------------------------------
:: Detect CDE media drive
:: Check all lettered drives for CDE signature in autorun.inf
:: ---------------------------------------------------------------
set CDE_ROOT=

for %%d in (A B C D E F G H I J K L M N O P Q R S T U V W) do (
    if exist "%%d:\autorun.inf" (
        findstr /C:"CDE Diagnostic Suite" "%%d:\autorun.inf" >nul 2>&1
        if not errorlevel 1 (
            if "%CDE_ROOT%"=="" set CDE_ROOT=%%d:
        )
    )
)

:: Fallback: search by ToolkitGUI presence
if "%CDE_ROOT%"=="" (
    for %%d in (A B C D E F G H I J K L M N O P Q R S T U V W) do (
        if exist "%%d:\CDE\ToolkitGUI\bin\Release\net8.0-windows\ToolkitGUI.exe" (
            if "%CDE_ROOT%"=="" set CDE_ROOT=%%d:
        )
    )
)

:: Fallback: search by CDE.exe presence
if "%CDE_ROOT%"=="" (
    for %%d in (A B C D E F G H I J K L M N O P Q R S T U V W) do (
        if exist "%%d:\CDE.exe" (
            if "%CDE_ROOT%"=="" set CDE_ROOT=%%d:
        )
    )
)

:: Final fallback: assume same drive structure from boot media
if "%CDE_ROOT%"=="" (
    echo WARNING: Could not auto-detect CDE media drive.
    echo.
    set /p CDE_ROOT= Enter drive letter (e.g. D:^): 
)

:: Export TOOLKIT_ROOT for child processes and PowerShell scripts
set TOOLKIT_ROOT=%CDE_ROOT%
setx TOOLKIT_ROOT %CDE_ROOT% >nul 2>&1

:: ---------------------------------------------------------------
:: AUTO-LAUNCH CDE TOOLKIT GUI
:: The WPF app hosts its own boot menu (boot options, offline OS
:: choice, and progress splash are all in-app). This script only
:: initializes the environment and launches ToolkitGUI directly.
:: Falls back to a text menu only when ToolkitGUI.exe is absent.
:: ---------------------------------------------------------------
set TOOLKITGUI_EXE=%CDE_ROOT%\CDE\ToolkitGUI\bin\Release\net8.0-windows\ToolkitGUI.exe
if not exist "%TOOLKITGUI_EXE%" (
    if exist "%CDE_ROOT%\CDE.exe" set TOOLKITGUI_EXE=%CDE_ROOT%\CDE.exe
)
set DOTNET_ROOT=%CDE_ROOT%\CDE\ToolkitGUI\bin\Release\net8.0-windows
set PATH=%DOTNET_ROOT%;%PATH%

if not exist "%TOOLKITGUI_EXE%" (
    echo.
    echo  [WARNING] ToolkitGUI.exe not found at:
    echo  %TOOLKITGUI_EXE%
    echo.
    echo  Falling back to text menu...
    timeout /t 3 >nul
    goto FALLBACK_MENU
)

cls
echo.
echo   Starting CDE Diagnostic Suite...
echo.
start /wait "" "%TOOLKITGUI_EXE%"
goto RECOVERY_MENU

:: ---------------------------------------------------------------
:: RECOVERY MENU - shown after CDE exits
:: ---------------------------------------------------------------
:RECOVERY_MENU
cls
echo.
echo  ================================================================
echo   CDE DIAGNOSTIC SUITE  -  Session Ended
echo  ================================================================
echo.
echo    CDE Toolkit GUI has closed.
echo.
echo    [1]  Relaunch CDE Toolkit GUI
echo    [2]  WinPE Command Prompt
echo    [3]  PowerShell (WinPE)
echo    [4]  Reboot System
echo    [5]  Shutdown System
echo.
echo  ================================================================
echo.
set CHOICE=
set /p CHOICE= Select option [1-5]: 

if "%CHOICE%"=="1" (
    if exist "%TOOLKITGUI_EXE%" (
        start /wait "" "%TOOLKITGUI_EXE%"
        goto RECOVERY_MENU
    )
    echo.
    echo  ERROR: ToolkitGUI.exe not found.
    timeout /t 3 >nul
    goto RECOVERY_MENU
)
if "%CHOICE%"=="2" goto CMD_PROMPT
if "%CHOICE%"=="3" goto PS_PROMPT
if "%CHOICE%"=="4" goto REBOOT
if "%CHOICE%"=="5" goto SHUTDOWN
echo Invalid selection. Try again.
timeout /t 2 >nul
goto RECOVERY_MENU

:: ---------------------------------------------------------------
:: FALLBACK TEXT MENU - only when ToolkitGUI.exe is absent
:: ---------------------------------------------------------------
:FALLBACK_MENU
cls
echo.
echo  ================================================================
echo   CDE DIAGNOSTIC SUITE  -  Boot Menu (Text Fallback)
echo  ================================================================
echo.
echo   NOTE: ToolkitGUI.exe was not found. GUI is unavailable.
echo.
echo    [1]  WinPE Command Prompt
echo    [2]  PowerShell (WinPE)
echo    [3]  Network Setup (wpeinit)
echo    [4]  Reboot System
echo    [5]  Shutdown System
if /I "%SHOW_LEGACY_CST_MENU%"=="1" (
    echo    [6]  Run CST Malware Scan (Offline - Auto^)  [legacy]
)
echo.
echo  ================================================================
echo.
set CHOICE=
if /I "%SHOW_LEGACY_CST_MENU%"=="1" (
    set /p CHOICE= Select option [1-6]:
) else (
    set /p CHOICE= Select option [1-5]:
)

if "%CHOICE%"=="1" goto CMD_PROMPT
if "%CHOICE%"=="2" goto PS_PROMPT
if "%CHOICE%"=="3" goto NET_CONFIG
if "%CHOICE%"=="4" goto REBOOT
if "%CHOICE%"=="5" goto SHUTDOWN
if /I "%SHOW_LEGACY_CST_MENU%"=="1" if "%CHOICE%"=="6" goto CST_AUTO
echo Invalid selection. Try again.
timeout /t 2 >nul
goto FALLBACK_MENU

:: ---------------------------------------------------------------
:: OPTION 3 - WinPE Command Prompt
:: ---------------------------------------------------------------
:CMD_PROMPT
cls
echo Opening WinPE Command Prompt...
echo Type EXIT to return to CDE Boot Menu.
echo.
cmd.exe /k "prompt CDE-PE $P$G && echo CDE WinPE Shell  -  TOOLKIT_ROOT=%TOOLKIT_ROOT% && echo."
goto RECOVERY_MENU

:: ---------------------------------------------------------------
:: OPTION 4 - PowerShell
:: ---------------------------------------------------------------
:PS_PROMPT
cls
echo Opening PowerShell (WinPE)...
echo Type exit to return to CDE Boot Menu.
echo.
X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NoLogo -Command "& { Write-Host 'CDE WinPE PowerShell' -ForegroundColor Cyan; Write-Host \"TOOLKIT_ROOT = $env:TOOLKIT_ROOT\" -ForegroundColor Yellow; $host.UI.RawUI.WindowTitle = 'CDE WinPE PowerShell' }" ; X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NoLogo
goto RECOVERY_MENU

:: ---------------------------------------------------------------
:: OPTION 5 - Network Configuration
:: ---------------------------------------------------------------
:NET_CONFIG
cls
echo Running wpeinit for network configuration...
wpeinit
echo.
echo Network initialization complete.
pause
goto RECOVERY_MENU

:: ---------------------------------------------------------------
:: OPTION 6 - Reboot
:: ---------------------------------------------------------------
:REBOOT
cls
echo Rebooting system...
wpeutil Reboot
goto :eof

:: ---------------------------------------------------------------
:: OPTION 7 - Shutdown
:: ---------------------------------------------------------------
:SHUTDOWN
cls
echo Shutting down system...
wpeutil Shutdown
goto :eof

:: ---------------------------------------------------------------
:: OPTION 8 - CST Malware Scan (Offline - Auto-Detect)
:: Discovers Windows installations on any drive automatically
:: ---------------------------------------------------------------
:CST_AUTO
cls
echo  ================================================================
echo   CST - Core Security Tool  ^|  Offline Malware Scan
echo  ================================================================
echo.
echo  Scanning for offline Windows installations...
echo  (Any drive C-Z with \Windows\System32 will be scanned)
echo.

set CST_SCRIPT=%CDE_ROOT%\Security\CST\CoreSecurityTool.ps1

if not exist "%CST_SCRIPT%" (
    echo ERROR: CoreSecurityTool.ps1 not found at:
    echo   %CST_SCRIPT%
    echo.
    pause
    goto RECOVERY_MENU
)

set TIMESTAMP=%DATE:~10,4%%DATE:~4,2%%DATE:~7,2%_%TIME:~0,2%%TIME:~3,2%%TIME:~6,2%
set TIMESTAMP=%TIMESTAMP: =0%
set CST_OUT=%CDE_ROOT%\Logs\CST_Result_%TIMESTAMP%.json

echo Starting scan... Results will be saved to:
echo   %CST_OUT%
echo.
echo Press any key to begin, or Ctrl+C to cancel.
pause >nul

X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass ^
    -Command "& '%CST_SCRIPT%' -Mode ThreatScan -ActionMode ScanAndQuarantine -DetectionScope All -EmitJson -OutputPath '%CST_OUT%'"

echo.
if exist "%CST_OUT%" (
    echo Scan complete. Results saved to:
    echo   %CST_OUT%
) else (
    echo Scan complete. No output file produced.
)
echo.
pause
goto RECOVERY_MENU

:: ---------------------------------------------------------------
:: OPTION 9 - CST Malware Scan (Offline - Manual Drive)
:: User specifies the drive letter of the offline Windows install
:: ---------------------------------------------------------------
:CST_MANUAL
cls
echo  ================================================================
echo   CST - Core Security Tool  ^|  Offline Scan (Manual Drive)
echo  ================================================================
echo.
echo  Enter the drive letter of the Windows installation to scan.
echo  Example: C  (scans C:\Windows, C:\Users, C:\ProgramData)
echo  Leave blank to cancel.
echo.
set OFFLINE_DRIVE=
set /p OFFLINE_DRIVE= Offline drive letter (letter only, no colon): 

if "%OFFLINE_DRIVE%"=="" (
    echo Cancelled.
    timeout /t 2 >nul
    goto RECOVERY_MENU
)

set CST_SCRIPT=%CDE_ROOT%\Security\CST\CoreSecurityTool.ps1

if not exist "%CST_SCRIPT%" (
    echo ERROR: CoreSecurityTool.ps1 not found.
    pause
    goto RECOVERY_MENU
)

if not exist "%OFFLINE_DRIVE%:\Windows\System32" (
    echo ERROR: No Windows installation found at %OFFLINE_DRIVE%:\Windows\System32
    echo Verify the drive letter and try again.
    pause
    goto RECOVERY_MENU
)

set TIMESTAMP=%DATE:~10,4%%DATE:~4,2%%DATE:~7,2%_%TIME:~0,2%%TIME:~3,2%%TIME:~6,2%
set TIMESTAMP=%TIMESTAMP: =0%
set CST_OUT=%CDE_ROOT%\Logs\CST_Result_%TIMESTAMP%.json

echo Scanning %OFFLINE_DRIVE%:\ ...
echo Results will be saved to:
echo   %CST_OUT%
echo.
echo Press any key to begin, or Ctrl+C to cancel.
pause >nul

X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass ^
    -Command "$env:OFFLINE_WINDOWS_ROOT = '%OFFLINE_DRIVE%:\'; & '%CST_SCRIPT%' -Mode FullScan -ActionMode ScanAndQuarantine -DetectionScope All -EmitJson -OutputPath '%CST_OUT%'"

echo.
if exist "%CST_OUT%" (
    echo Scan complete. Results saved to:
    echo   %CST_OUT%
) else (
    echo Scan complete. No output file produced.
)
echo.
pause
goto RECOVERY_MENU

