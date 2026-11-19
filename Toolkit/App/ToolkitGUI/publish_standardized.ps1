<#
.SYNOPSIS
    Delegates to the canonical publish script under Toolkit\App\Publish-ToolkitGUI.ps1.
#>
param(
    [switch]$Clean,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$canonicalScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Publish-ToolkitGUI.ps1'))
if (-not (Test-Path -LiteralPath $canonicalScript)) {
    throw "Canonical publish script not found: $canonicalScript"
}

$argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $canonicalScript)
if ($Clean) { $argsList += '-Clean' }
if ($Force) { $argsList += '-Force' }

& powershell.exe @argsList
if ($LASTEXITCODE -ne 0) {
    throw "Canonical publish failed with exit code $LASTEXITCODE"
}
