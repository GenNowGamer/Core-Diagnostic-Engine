#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$scriptPath = [System.IO.Path]::GetFullPath((Join-Path (Split-Path $MyInvocation.MyCommand.Path) '..\Workflows\TempFileCleaner.ps1'))
if (-not (Test-Path -LiteralPath $scriptPath)) {
    Write-Error "TempFileCleaner.ps1 not found at $scriptPath"
    exit 1
}

# 1. Syntax parse check
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors -and $errors.Count -gt 0) {
    Write-Error ("Parse errors in TempFileCleaner.ps1:`n{0}" -f ($errors | Out-String))
    exit 1
}

# 2. Static guard for Firefox cache path (must never target Roaming\Profiles)
$rawScript = Get-Content -LiteralPath $scriptPath -Raw
if ($rawScript -match [regex]::Escape('AppData\Roaming\Mozilla\Firefox\Profiles')) {
    Write-Error 'Unsafe Firefox Roaming profile path still present in TempFileCleaner.ps1'
    exit 1
}
if ($rawScript -notmatch [regex]::Escape('AppData\Local\Mozilla\Firefox\Profiles') -or $rawScript -notmatch 'cache2') {
    Write-Error 'Expected AppData\Local\Mozilla\Firefox\Profiles\<profile>\cache2 targeting in TempFileCleaner.ps1'
    exit 1
}

# 3. End-to-end Clean execution via powershell.exe -File with spaces in paths, read-only files, and junction safety
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('Cde TempCleaner Test ' + [guid]::NewGuid().ToString('N'))
$origToolkitRoot = $env:TOOLKIT_ROOT
try {
    $toolkitRoot = Join-Path $root 'toolkit'
    $targetDir = Join-Path $root 'target temp'
    $nestedDir = Join-Path $targetDir 'sub folder'
    $externalDir = Join-Path $root 'external junction target'
    $junctionPath = Join-Path $targetDir 'link_out'
    $controlDir = Join-Path $root 'control files'

    New-Item -ItemType Directory -Path $toolkitRoot, $nestedDir, $externalDir, $controlDir -Force | Out-Null

    $normalFile = Join-Path $targetDir 'a.tmp'
    $nestedFile = Join-Path $nestedDir 'b.tmp'
    $readOnlyFile = Join-Path $targetDir 'ro.tmp'
    $externalKeep = Join-Path $externalDir 'keep.txt'

    Set-Content -LiteralPath $normalFile -Value ('X' * 128) -Encoding ASCII
    Set-Content -LiteralPath $nestedFile -Value ('Y' * 256) -Encoding ASCII
    Set-Content -LiteralPath $readOnlyFile -Value ('Z' * 64) -Encoding ASCII
    [System.IO.File]::SetAttributes($readOnlyFile, [System.IO.FileAttributes]::ReadOnly)
    Set-Content -LiteralPath $externalKeep -Value 'DO NOT DELETE' -Encoding ASCII

    $mklinkOut = & cmd.exe /c "mklink /J `"$junctionPath`" `"$externalDir`"" 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $junctionPath)) {
        throw "Failed to create test junction: $mklinkOut"
    }

    $pathsJson = Join-Path $controlDir "paths 'test'.json"
    $whitelistJson = Join-Path $controlDir "whitelist 'test'.json"
    Set-Content -LiteralPath $pathsJson -Value (ConvertTo-Json -InputObject @($targetDir)) -Encoding UTF8
    Set-Content -LiteralPath $whitelistJson -Value (ConvertTo-Json -InputObject @($targetDir)) -Encoding UTF8

    $env:TOOLKIT_ROOT = $toolkitRoot

    $cleanOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $scriptPath -Action Clean -PathsFile $pathsJson -WhitelistFile $whitelistJson -ElevatedRelay 2>&1
    $cleanExit = $LASTEXITCODE
    $cleanText = ($cleanOutput | Out-String)
    if ($cleanExit -ne 0) {
        throw "Expected exit code 0 from Clean, got $cleanExit.`nOutput:`n$cleanText"
    }

    $workflowsDir = Join-Path $toolkitRoot 'CDE\Runtime\Data\workflows'
    $reportFile = Get-ChildItem -LiteralPath $workflowsDir -Filter 'TempFileCleaner_Clean_*.json' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $reportFile) {
        throw "Expected TempFileCleaner_Clean JSON report under $workflowsDir"
    }

    $report = Get-Content -LiteralPath $reportFile.FullName -Raw | ConvertFrom-Json
    if ($report.OverallHealth -ne 'Healthy') {
        throw "Expected OverallHealth 'Healthy', got '$($report.OverallHealth)'"
    }

    $topStep = @($report.Steps | Where-Object { $_.Name -eq 'TempFileClean' }) | Select-Object -First 1
    if ($null -eq $topStep -or $topStep.Output -notmatch 'Cleaned 3 items') {
        throw "Expected 'Cleaned 3 items' in TempFileClean output, got: $($topStep.Output)"
    }
    if ($topStep.Output -match 'freed ~0 B') {
        throw "Expected positive FreedBytes in TempFileClean output, got: $($topStep.Output)"
    }

    if (Test-Path -LiteralPath $normalFile) { throw 'Normal file was not deleted' }
    if (Test-Path -LiteralPath $nestedFile) { throw 'Nested file was not deleted' }
    if (Test-Path -LiteralPath $readOnlyFile) { throw 'Read-only file was not deleted' }
    if (Test-Path -LiteralPath $nestedDir) { throw 'Empty nested subdirectory was not deleted' }
    if (-not (Test-Path -LiteralPath $externalKeep)) { throw 'Junction target file keep.txt was deleted!' }

    # 4. Missing input file must fail with non-zero exit code (no silent false-success)
    $missingPaths = Join-Path $root 'nonexistent\missing.json'
    $missingOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $scriptPath -Action Clean -PathsFile $missingPaths -WhitelistFile $whitelistJson -ElevatedRelay 2>&1
    $missingExit = $LASTEXITCODE
    if ($missingExit -eq 0) {
        throw "Expected non-zero exit code when -PathsFile is missing, got 0.`nOutput:`n$($missingOutput | Out-String)"
    }

    Write-Host 'Test-TempFileCleaner: PASS'
    exit 0
}
finally {
    $env:TOOLKIT_ROOT = $origToolkitRoot
    $junctionToRemove = Join-Path $root 'target temp\link_out'
    if (Test-Path -LiteralPath $junctionToRemove) {
        try { [System.IO.Directory]::Delete($junctionToRemove) } catch {}
    }
    if (Test-Path -LiteralPath $root) {
        Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                if (($_.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0) {
                    $_.Attributes = ($_.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly))
                }
            } catch {}
        }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
