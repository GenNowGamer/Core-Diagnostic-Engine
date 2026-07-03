@echo off
:: =============================================================
:: CDE Diagnostic Suite - Portable Windows Launcher (Fallback)
:: This fallback script is kept under Scripts\Launch.
:: =============================================================

:: Resolve Toolkit root from Scripts\Launch\
set CDE_ROOT=%~dp0\..\..
for %%I in ("%CDE_ROOT%") do set CDE_ROOT=%%~fI

:: Remove trailing backslash
if "%CDE_ROOT:~-1%"=="\" set CDE_ROOT=%CDE_ROOT:~0,-1%

:: Export TOOLKIT_ROOT so ToolkitGUI.exe picks it up
set TOOLKIT_ROOT=%CDE_ROOT%

:: Path to ToolkitGUI executable
set TOOLKIT_EXE=%CDE_ROOT%\CDE\ToolkitGUI\bin\Release\net8.0-windows\ToolkitGUI.exe

echo CDE Diagnostic Suite - Portable Mode (Fallback)
echo ================================================
echo CDE Root:  %CDE_ROOT%
echo Toolkit:   %TOOLKIT_EXE%
echo.

if not exist "%TOOLKIT_EXE%" (
    echo ERROR: ToolkitGUI.exe not found.
    echo Expected: %TOOLKIT_EXE%
    echo.
    echo Make sure the CDE folder structure is intact.
    pause
    exit /b 1
)

echo Launching CDE Toolkit...
start "" "%TOOLKIT_EXE%"
exit /b 0