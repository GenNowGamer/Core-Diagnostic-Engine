#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$csPath = Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Core\CdeSmartReader.cs'
$cs = Get-Content -LiteralPath $csPath -Raw

if ($cs -notmatch 'IsMediaFailureAta') {
    Write-Error 'Expected IsMediaFailureAta in CdeSmartReader.cs'
    exit 1
}
if ($cs -notmatch 'IsInterconnectAta') {
    Write-Error 'Expected IsInterconnectAta in CdeSmartReader.cs'
    exit 1
}
if ($cs -notmatch 'else if \(IsInterconnectAta\(id\) && a\.Raw > 0\)\s*\{(?:\s*//[^\r\n]*)?\s*st = "Info";') {
    Write-Error 'Expected interconnect attributes (188/199) to be tiered as Info'
    exit 1
}
if ($cs -notmatch 'mediaErrors >= 10') {
    Write-Error 'Expected NVMe mediaErrors elevation threshold'
    exit 1
}
if ($cs -notmatch 'TemperatureC > 80') {
    Write-Error 'Expected NVMe temp gate at 80C'
    exit 1
}

# Compile a throwaway type to ensure C# still builds under Add-Type
$tmp = Join-Path $env:TEMP ("CdeSmartReader_compile_" + [guid]::NewGuid().ToString('N') + ".cs")
Copy-Item -LiteralPath $csPath -Destination $tmp -Force
try {
    Add-Type -Path $tmp -ErrorAction Stop | Out-Null
} catch {
    Write-Error "CdeSmartReader.cs failed to compile: $_"
    exit 1
} finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}

Write-Host 'Test-SmartAttributeTiers: PASS'
exit 0
