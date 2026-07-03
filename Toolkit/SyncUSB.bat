@echo off
setlocal EnableExtensions EnableDelayedExpansion
title CDE - Sync Files to USB

set "SKIP_ELEVATE_CHECK=0"
if /i "%~1"=="--elevated" set "SKIP_ELEVATE_CHECK=1"

:: ============================================================
:: Self-elevate if not already running as Administrator
:: ============================================================
if "%SKIP_ELEVATE_CHECK%"=="0" (
    net session >nul 2>&1
    if %errorlevel% neq 0 (
        echo Requesting Administrator privileges...
        powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'cmd.exe' -WorkingDirectory '%~dp0' -ArgumentList '/k ""%~f0"" --elevated' -Verb RunAs"
        exit /b
    )
)

pushd "%~dp0" >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo  ERROR: Could not switch to script directory:
    echo         %~dp0
    echo.
    pause
    goto :EOF
)

:: ============================================================
:: CDE USB Sync
:: Copies updated CDE files to an existing USB drive.
:: Does NOT format or wipe - only overwrites changed files.
:: ============================================================

set "SRC=%~dp0"
:: Remove trailing backslash from SRC
if "%SRC:~-1%"=="\" set "SRC=%SRC:~0,-1%"
set "STARTNET_PATH=%SRC%\Mount\WinPEWork\startnet.cmd"
set "BOOTWIM_PATH=%SRC%\sources\boot.wim"

cls
echo.
echo  ================================================================
echo    CDE Diagnostic Suite  ^|  Sync Files to USB
echo  ================================================================
echo.
echo  SOURCE: %SRC%
echo.
echo  This copies all CDE files to a USB drive using robocopy.
echo  Files that are already up to date are skipped.
echo  The USB is NOT formatted - existing files are preserved.
echo.
echo  The following are excluded (dev/build only):
echo    Deploy\   Mount\   Logs\   App\   .git\   .venv\   .vscode\   Tools\Deploy\   Tools\.staging\
echo    goodware.db (NSRL dev-only; not deployed to USB)
echo.
echo  Default Windows launcher copied to USB root: CDE.exe
echo  Fallback launcher copied to USB: Scripts\Launch\CDE_Portable.bat
echo.
echo  ================================================================
echo.

:: List available drives to help the user pick
echo  Available drives:
echo.
for %%D in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%D:\" (
        set "VOL="
        for /f "tokens=2 delims==" %%L in (
            'wmic logicaldisk where "DeviceID='%%D:'" get VolumeName /value 2^>nul'
        ) do (
            set "VOL=%%L"
        )
        echo    %%D:\  !VOL!
    )
)
echo.

:ASK_DRIVE
set "DRIVE="
set /p "DRIVE=Enter USB drive letter (letter only, no colon): "
if not defined DRIVE (
    echo.
    echo  Please enter a drive letter.
    echo.
    goto :ASK_DRIVE
)
set "DRIVE=%DRIVE:~0,1%"

:: Verify the drive exists
if not exist "%DRIVE%:\" (
    echo.
    echo  ERROR: Drive %DRIVE%:\ not found.
    echo.
    goto :ASK_DRIVE
)

:: Warn if user typed the same drive as source (safety check)
set "SRCROOT=%SRC:~0,1%"
if /i "%DRIVE%"=="%SRCROOT%" (
    echo.
    echo  ERROR: Source and destination are the same drive %DRIVE%:\
    echo         Select a different drive.
    echo.
    goto :ASK_DRIVE
)

echo.
echo  ----------------------------------------------------------------
echo   Ready to sync:
echo     From: %SRC%\
echo     To:   %DRIVE%:\
echo.
echo   Existing files on %DRIVE%:\ will be overwritten with newer versions.
echo.

set "WIM_STALE=0"
if exist "%STARTNET_PATH%" if exist "%BOOTWIM_PATH%" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "$s=Get-Item -LiteralPath '%STARTNET_PATH%'; $w=Get-Item -LiteralPath '%BOOTWIM_PATH%'; if($s.LastWriteTime -gt $w.LastWriteTime){ exit 3 } else { exit 0 }"
    if errorlevel 3 set "WIM_STALE=1"
)
ver >nul

if "%WIM_STALE%"=="1" (
    echo  [WARNING] WinPE startup script is newer than sources\boot.wim.
    echo            Your recent boot menu/startnet changes are NOT in boot.wim yet.
    echo.
    echo            Run this first in an elevated PowerShell:
    echo              powershell -NoProfile -ExecutionPolicy Bypass -File ".\Scripts\Customize-WinPE.ps1"
    echo.
    echo            Then run SyncUSB.bat again to copy the updated boot.wim.
    echo.
)
echo.

:ASK_CONFIRM
set "CONFIRM="
set /p "CONFIRM=Type YES to proceed, or N to cancel: "
if not defined CONFIRM (
    echo.
    echo  Please type YES to continue or N to cancel.
    echo.
    goto :ASK_CONFIRM
)
if /i "%CONFIRM%"=="N" goto :CANCELLED
if /i "%CONFIRM%"=="NO" goto :CANCELLED
if /i "%CONFIRM%"=="Y" set "CONFIRM=YES"
if /i not "%CONFIRM%"=="YES" (
    echo.
    echo  Invalid entry. Type YES or N.
    echo.
    goto :ASK_CONFIRM
)

echo.
echo  ================================================================
echo   Copying files... (this may take a few minutes for boot.wim)
echo  ================================================================
echo.

robocopy "%SRC%" "%DRIVE%:" /E ^
    /XD "%SRC%\Deploy" "%SRC%\Mount" "%SRC%\Logs" "%SRC%\App" "%SRC%\.git" "%SRC%\.venv" "%SRC%\.vscode" "%SRC%\Tools\Deploy" "%SRC%\Tools\.staging" ^
    /XF "CreateISO.vbs" "Run-CustomizeWinPE.vbs" "SyncUSB.bat" "SyncUSB_Debug.bat" "*.md" ".gitignore" "script_output.txt" "CreateISO.ps1" "Customize-WinPE.ps1" "update_script.ps1" "do_update.ps1" "goodware.db" "goodware.db-wal" "goodware.db-shm" ^
    /R:2 /W:1 /NJH /NJS

set RCODE=%ERRORLEVEL%

echo.
if %RCODE% gtr 7 goto :ROBOCOPY_ERROR

echo  ================================================================
echo   SYNC COMPLETE - Post-sync verification
echo  ================================================================
echo.
echo   Files copied to %DRIVE%:\
echo.
echo   Clearing WinPE session state (auto-generated, not part of payload)...
if exist "%DRIVE%:\CDE\Runtime" rmdir /s /q "%DRIVE%:\CDE\Runtime" 2>nul
if exist "%DRIVE%:\offline_env.txt" del /f /q "%DRIVE%:\offline_env.txt" 2>nul
if exist "%DRIVE%:\offline_progress.log" del /f /q "%DRIVE%:\offline_progress.log" 2>nul
echo   [OK] Removed CDE\Runtime and legacy offline_env artifacts
echo.
echo   Verifying UEFI rEFInd fallback launcher...

if exist "%DRIVE%:\EFI\refind\refind_x64.efi" (
    copy /Y "%DRIVE%:\EFI\refind\refind_x64.efi" "%DRIVE%:\EFI\boot\bootx64.efi" >nul 2>&1
    if exist "%DRIVE%:\EFI\boot\bootx64.efi" (
        fc /b "%DRIVE%:\EFI\refind\refind_x64.efi" "%DRIVE%:\EFI\boot\bootx64.efi" >nul 2>&1
        if errorlevel 1 (
            echo   [ERROR] Failed to set UEFI fallback launcher
            echo          bootx64.efi does not match EFI\refind\refind_x64.efi
        ) else (
            echo   [OK] UEFI fallback launcher bootx64.efi verified as rEFInd
        )
    ) else (
        echo   [ERROR] Failed to set UEFI fallback launcher
        echo          bootx64.efi was not created at EFI\boot\bootx64.efi
    )
) else (
    echo   [ERROR] rEFInd binary not found at EFI\refind\refind_x64.efi
)

if exist "%DRIVE%:\CDE.exe" (
    echo   [OK] Default Windows launcher present: %DRIVE%:\CDE.exe
) else (
    echo   [ERROR] Missing default launcher: %DRIVE%:\CDE.exe
)

if exist "%DRIVE%:\Scripts\Launch\CDE_Portable.bat" (
    echo   [OK] Fallback batch launcher present: %DRIVE%:\Scripts\Launch\CDE_Portable.bat
) else (
    echo   [ERROR] Missing fallback launcher: %DRIVE%:\Scripts\Launch\CDE_Portable.bat
)

echo.
echo   NOTE: UEFI boot is covered by the EFI\ folder just copied.
echo   For BIOS boot on older PCs, re-run Prepare-BootableUSB.ps1
echo   which applies the bootsect.exe boot sector.
echo.
goto :SYNC_DONE

:ROBOCOPY_ERROR
echo  ================================================================
echo   ERROR: robocopy exited with code %RCODE%
echo  ================================================================
echo.
echo   Some files may not have copied correctly.
echo   Check the output above for details.
echo.

:SYNC_DONE

pause
goto :EOF

:CANCELLED
echo.
echo  Cancelled. No changes were made.
echo.
pause
