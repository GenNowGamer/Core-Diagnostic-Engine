#Requires -Version 5.1
<#
.SYNOPSIS
    Validates MD4 and DES-RID SAM crypto without touching a live hive.
.DESCRIPTION
    Confirms NT OWF vector (password -> 8846F7EAEE8FB117AD06BDD830B7586C) and
    DES encrypt/decrypt round-trip for RID 500 per chntpw/pwdump layout.
#>
$ErrorActionPreference = 'Stop'

$ScriptDir  = Split-Path $MyInvocation.MyCommand.Path
$SamModule  = Join-Path $ScriptDir '..\Core\OfflineSamAccount.psm1'
Import-Module $SamModule -Force -DisableNameChecking

$result = Test-OfflineSamCryptoValidation

if ($result.Pass) {
    Write-Host "PASS: MD4=$($result.Md4Hex) DES round-trip RID $($result.Rid)" -ForegroundColor Green
    exit 0
}

Write-Host 'FAIL: Offline SAM crypto validation failed.' -ForegroundColor Red
foreach ($err in $result.Errors) {
    Write-Host "  - $err" -ForegroundColor Red
}
exit 1
