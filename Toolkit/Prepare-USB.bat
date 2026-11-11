@echo off
setlocal EnableDelayedExpansion

:: Check for Administrator elevation
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

title Core Diagnostic Engine - Bootable USB Creator
cd /d "%~dp0"

set "SCRIPT=%~dp0Scripts\Prepare-BootableUSB.ps1"
if not exist "%SCRIPT%" (
    echo [ERROR] Could not find Prepare-BootableUSB.ps1 at:
    echo "%SCRIPT%"
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*

if %errorlevel% neq 0 (
    echo.
    echo [Notice] USB preparation script finished or exited with code %errorlevel%.
)

echo.
pause

