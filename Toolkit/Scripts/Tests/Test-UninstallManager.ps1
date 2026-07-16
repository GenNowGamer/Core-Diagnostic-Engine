#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstall Manager self-tests (quiet/MSI preference, safe folder paths).
#>
$ErrorActionPreference = 'Stop'
$script = Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Workflows\UninstallManager.ps1'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Action SelfTest
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
exit 0
