#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads the latest rules.json from the CDE threat rules feed on GitHub
    and replaces the local copy atomically. No API key required.

.PARAMETER RulesPath
    Path to rules.json. Auto-resolved from script location if omitted.

.EXAMPLE
    .\Update-CstRulesFromGitHub.ps1
#>
param(
    [string]$RulesPath = ''
)

$ErrorActionPreference = 'Stop'
$RulesUrl = 'https://raw.githubusercontent.com/GenNowGamer/CDE-threat-rules/main/rules.json'

# --- Resolve rules.json path ---
if ([string]::IsNullOrWhiteSpace($RulesPath)) {
    $candidates = @()

    if (-not [string]::IsNullOrWhiteSpace($env:TOOLKIT_ROOT)) {
        $candidates += Join-Path $env:TOOLKIT_ROOT 'Security\CST\rules\rules.json'
    }

    # Relative to this script: updates\ -> parent (CST\) -> rules\rules.json
    $candidates += Join-Path $PSScriptRoot '..\rules\rules.json'

    foreach ($c in $candidates) {
        $resolved = [System.IO.Path]::GetFullPath($c)
        $dir = Split-Path $resolved -Parent
        if (Test-Path $dir) {
            $RulesPath = $resolved
            break
        }
    }
}

if ([string]::IsNullOrWhiteSpace($RulesPath)) {
    Write-Error 'Cannot resolve rules.json path. Set TOOLKIT_ROOT or pass -RulesPath explicitly.'
    exit 1
}

# --- Download ---
Write-Output "Fetching rules from CDE threat rules feed..."
try {
    $response = Invoke-WebRequest -Uri $RulesUrl -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    $remoteJson = $response.Content
    # Strip UTF-8 BOM if present (PS 5.1 Set-Content -Encoding UTF8 writes a BOM)
    if ($remoteJson.Length -gt 0 -and [int][char]$remoteJson[0] -eq 0xFEFF) {
        $remoteJson = $remoteJson.Substring(1)
    }
} catch {
    Write-Error "Download failed: $($_.Exception.Message)"
    exit 1
}

# --- Validate JSON structure ---
try {
    $remote = $remoteJson | ConvertFrom-Json
} catch {
    Write-Error "Invalid JSON received from GitHub."
    exit 1
}

if (-not $remote.PSObject.Properties['rulesVersion'] -or -not $remote.PSObject.Properties['hashes']) {
    Write-Error "Downloaded file is missing expected fields (rulesVersion, hashes). Update aborted."
    exit 1
}

$remoteHashCount = @($remote.hashes).Count
Write-Output "Remote: rules v$($remote.rulesVersion), $remoteHashCount hash IOCs, updated $($remote.updatedUtc)"

# --- Check if already current ---
if (Test-Path $RulesPath) {
    try {
        $local = Get-Content -Path $RulesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($local.updatedUtc -eq $remote.updatedUtc) {
            Write-Output "Already up to date (updatedUtc: $($remote.updatedUtc)). No update needed."
            exit 0
        }
        Write-Output "Local : rules v$($local.rulesVersion), $(@($local.hashes).Count) hash IOCs, updated $($local.updatedUtc)"
    } catch {
        Write-Output "Local rules.json could not be parsed - will overwrite."
    }
}

# --- Ensure rules directory exists ---
$rulesDir = Split-Path $RulesPath -Parent
if (-not (Test-Path $rulesDir)) {
    New-Item -ItemType Directory -Path $rulesDir -Force | Out-Null
}

# --- Atomic write via .tmp ---
$tmpPath = "$RulesPath.tmp"
try {
    [System.IO.File]::WriteAllText($tmpPath, $remoteJson, [System.Text.Encoding]::UTF8)
} catch {
    Write-Error "Failed to write temporary file: $($_.Exception.Message)"
    exit 1
}

# --- Verify round-trip before committing ---
try {
    $verify = Get-Content -Path $tmpPath -Raw | ConvertFrom-Json
    if (-not $verify.rulesVersion -or @($verify.hashes).Count -ne $remoteHashCount) {
        Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
        Write-Error "Post-write verification failed: hash count mismatch. Update aborted."
        exit 1
    }
} catch {
    Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
    Write-Error "Post-write verification failed: $($_.Exception.Message)"
    exit 1
}

Move-Item -Path $tmpPath -Destination $RulesPath -Force

Write-Output ""
Write-Output "rules.json updated successfully."
Write-Output "  Path       : $RulesPath"
Write-Output "  Version    : $($remote.rulesVersion)"
Write-Output "  Updated    : $($remote.updatedUtc)"
Write-Output "  Hash IOCs  : $remoteHashCount"
