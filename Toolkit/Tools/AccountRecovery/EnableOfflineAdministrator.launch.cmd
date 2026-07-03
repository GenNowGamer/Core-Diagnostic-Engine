@echo off
setlocal
set "CDE_ROOT=%~dp0..\..\"
if defined TOOLKIT_ROOT set "CDE_ROOT=%TOOLKIT_ROOT%\"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%CDE_ROOT%Scripts\Workflows\EnableOfflineAdministrator.ps1" %*
exit /b %ERRORLEVEL%
