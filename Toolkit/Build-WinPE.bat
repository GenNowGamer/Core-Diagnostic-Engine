@echo off
setlocal EnableDelayedExpansion
set "CDE_BAT_ARGS=%*"

:: Check for Administrator elevation
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges...
    if "%~1"=="" (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList $env:CDE_BAT_ARGS -Verb RunAs"
    )
    exit /b
)

title Core Diagnostic Engine - WinPE Customizer
cd /d "%~dp0"

set "SCRIPT=%~dp0Scripts\Customize-WinPE.ps1"
if not exist "%SCRIPT%" (
    echo [ERROR] Could not find Customize-WinPE.ps1 at:
    echo "%SCRIPT%"
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*

if %errorlevel% neq 0 (
    echo.
    echo [Notice] WinPE customization script finished or exited with code %errorlevel%.
)

echo.
pause

