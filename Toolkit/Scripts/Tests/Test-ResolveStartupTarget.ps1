#Requires -Version 5.1
<#
.SYNOPSIS
    Smoke tests for Resolve-StartupTarget path resolution.
#>

$ErrorActionPreference = 'Stop'

$startupRiskScript = Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Core\StartupRisk.ps1'
. $startupRiskScript

$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

function Assert-StartupTarget {
    param(
        [string]$Name,
        [string]$CommandText,
        [bool]$ExpectExists,
        [string[]]$AllowedMethods = @(),
        [string]$DetailContains = ''
    )

    $target = Resolve-StartupTarget -Command $CommandText
    $ok = $true
    $messages = [System.Collections.Generic.List[string]]::new()

    if ($target.Exists -ne $ExpectExists) {
        $ok = $false
        $messages.Add("Exists expected $ExpectExists but was $($target.Exists)") | Out-Null
    }

    if ($AllowedMethods.Count -gt 0 -and $target.ResolutionMethod -notin $AllowedMethods) {
        $ok = $false
        $messages.Add("ResolutionMethod '$($target.ResolutionMethod)' not in [$($AllowedMethods -join ', ')]") | Out-Null
    }

    if ($ExpectExists -and [string]::IsNullOrWhiteSpace($target.ResolvedPath)) {
        $ok = $false
        $messages.Add('ResolvedPath is empty') | Out-Null
    }

    if ($DetailContains -and $target.Detail -notlike "*$DetailContains*") {
        $ok = $false
        $messages.Add("Detail '$($target.Detail)' does not contain '$DetailContains'") | Out-Null
    }

    if ($ok) {
        $script:passed++
        Write-Host "PASS: $Name"
        return
    }

    $script:failures.Add("$Name :: $($messages -join '; ') :: Method=$($target.ResolutionMethod) Path=$($target.ResolvedPath) Detail=$($target.Detail)") | Out-Null
    Write-Host "FAIL: $Name"
}

$notepadPath = Join-Path $env:SystemRoot 'System32\notepad.exe'
Assert-StartupTarget -Name 'Absolute notepad path' -CommandText $notepadPath -ExpectExists $true -AllowedMethods @('Absolute')
Assert-StartupTarget -Name 'Quoted absolute path' -CommandText "`"$notepadPath`" /param" -ExpectExists $true -AllowedMethods @('Absolute')
$programFilesPath = Join-Path ${env:ProgramFiles} 'Windows NT\Accessories\wordpad.exe'
if (Test-Path -LiteralPath $programFilesPath) {
    Assert-StartupTarget -Name 'Unquoted Program Files path with args' -CommandText "$programFilesPath /param" -ExpectExists $true -AllowedMethods @('Absolute')
}
Assert-StartupTarget -Name 'Bare notepad.exe' -CommandText 'notepad.exe' -ExpectExists $true -AllowedMethods @('AppPaths', 'SearchPath')
Assert-StartupTarget -Name 'SystemRoot backslash path' -CommandText '\SystemRoot\System32\notepad.exe' -ExpectExists $true -AllowedMethods @('Absolute')
Assert-StartupTarget -Name 'Percent SystemRoot path' -CommandText '%SystemRoot%\System32\notepad.exe' -ExpectExists $true -AllowedMethods @('Absolute')

$missingPath = Join-Path $env:TEMP "CDE-Missing-$([Guid]::NewGuid().ToString('N')).exe"
Assert-StartupTarget -Name 'Missing qualified path' -CommandText $missingPath -ExpectExists $false -AllowedMethods @('Unresolved') -DetailContains 'Path not found'
Assert-StartupTarget -Name 'Missing bare name' -CommandText 'CDE-Nonexistent-StartupTarget-9f3a.exe' -ExpectExists $false -AllowedMethods @('Unresolved') -DetailContains 'Unresolved bare name'

$tempLnk = Join-Path $env:TEMP "CDE-ResolveStartupTarget-$([Guid]::NewGuid().ToString('N')).lnk"
try {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($tempLnk)
    $shortcut.TargetPath = $notepadPath
    $shortcut.Save()
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)

    Assert-StartupTarget -Name 'Shortcut target resolution' -CommandText $tempLnk -ExpectExists $true -AllowedMethods @('LnkTarget')
} finally {
    if (Test-Path -LiteralPath $tempLnk) {
        Remove-Item -LiteralPath $tempLnk -Force -ErrorAction SilentlyContinue
    }
}

$wrapperPath = Resolve-CommandPath -Command $notepadPath
if ([string]::IsNullOrWhiteSpace($wrapperPath) -or -not (Test-Path -LiteralPath $wrapperPath)) {
    $failures.Add('Resolve-CommandPath wrapper failed for notepad') | Out-Null
    Write-Host 'FAIL: Resolve-CommandPath wrapper'
} else {
    $passed++
    Write-Host 'PASS: Resolve-CommandPath wrapper'
}

Write-Host ''
Write-Host "Passed: $passed"
Write-Host "Failed: $($failures.Count)"

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) {
        Write-Host $failure
    }
    exit 1
}

exit 0
