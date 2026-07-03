<#
.SYNOPSIS
    Delegates to the canonical publish script under Toolkit\App\.

.NOTES
    User-facing launcher is always:
    D:\Robert\Desktop\App Project Builds\Core Diagnostic Engine\Toolkit\CDE.exe
#>
param(
    [switch]$Clean,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$canonicalScript = Join-Path $PSScriptRoot '..\App\Publish-ToolkitGUI.ps1'
$canonicalScript = [System.IO.Path]::GetFullPath($canonicalScript)

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
