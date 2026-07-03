#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$coreDir = Join-Path $testsRoot '..\Core'
Import-Module (Join-Path $coreDir 'Toolkit.Core.psm1') -Force -DisableNameChecking

Write-Host 'Test-InstalledSoftwareFormat'

$sample = @(
    [PSCustomObject]@{
        DisplayName     = '7-Zip 23.01 (x64)'
        DisplayVersion  = '23.01'
        Publisher       = 'Igor Pavlov'
        InstallLocation = 'C:\Program Files\7-Zip'
        InstallDate     = '20240315'
    },
    [PSCustomObject]@{
        DisplayName     = 'Adobe Acrobat (64-bit)'
        DisplayVersion  = '26.001.21662'
        Publisher       = 'Adobe'
        InstallLocation = ''
        InstallDate     = '20241128'
        DisplayIcon     = 'C:\Program Files\Adobe\Acrobat DC\Acrobat\Acrobat.exe,0'
        UninstallString = '"C:\Program Files\Adobe\Acrobat DC\Acrobat\Acrobat.exe" /uninstall'
    }
)

$output = Format-SoftwareList -Software $sample
$required = @('PROGRAM 1 :', 'PROGRAM 2 :', 'Install Path', 'Installed On', '2024-03-15', '2024-11-28', 'C:\Program Files\7-Zip', 'C:\Program Files\Adobe\Acrobat DC\Acrobat')
foreach ($fragment in $required) {
    if ($output -notmatch [regex]::Escape($fragment)) {
        Write-Error "Format-SoftwareList output missing: $fragment"
        exit 1
    }
}

if ($output -match '\$\{\{') {
    Write-Error 'Format-SoftwareList should not emit template placeholder names.'
    exit 1
}

Write-Host '  PASS: Format-SoftwareList includes grouped program blocks'
Write-Host 'Test-InstalledSoftwareFormat: PASS'
exit 0
