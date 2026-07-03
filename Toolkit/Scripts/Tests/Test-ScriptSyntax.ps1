#Requires -Version 5.1
<#
.SYNOPSIS
    Validates PowerShell syntax for all scripts under Toolkit/Scripts.
#>

$ErrorActionPreference = 'Stop'

$scriptsRoot = Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..'
$files = Get-ChildItem -LiteralPath $scriptsRoot -Filter '*.ps1' -Recurse -File
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

foreach ($file in $files) {
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        foreach ($err in $errors) {
            $failures.Add("$($file.FullName): $($err.Message)") | Out-Null
        }
        Write-Host "FAIL: $($file.FullName)" -ForegroundColor Red
    } else {
        $passed++
        Write-Host "PASS: $($file.Name)" -ForegroundColor Green
    }
}

Write-Host "`n--- SUMMARY ---" -ForegroundColor Cyan
Write-Host "Parsed: $($files.Count)"
Write-Host "Passed: $passed"
Write-Host "Failed: $($failures.Count)"
if ($failures.Count -gt 0) {
    foreach ($failure in $failures) {
        Write-Host "  $failure" -ForegroundColor Red
    }
    exit 1
}

exit 0
