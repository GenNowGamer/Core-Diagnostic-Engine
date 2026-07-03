#Requires -Version 5.1
<#
.SYNOPSIS
    Paths and helpers for WinPE offline session state (offline_env.txt, progress log).
#>

function Get-ToolkitRootFromScript {
    param([string]$ScriptRoot = $PSScriptRoot)

    if (-not [string]::IsNullOrWhiteSpace($env:TOOLKIT_ROOT) -and (Test-Path -LiteralPath $env:TOOLKIT_ROOT)) {
        return $env:TOOLKIT_ROOT.TrimEnd('\')
    }

    if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
        return ''
    }

    return (Split-Path -Parent (Split-Path -Parent $ScriptRoot))
}

function Get-OfflineRuntimeDirectory {
    param([string]$ToolkitRoot = '')

    if ([string]::IsNullOrWhiteSpace($ToolkitRoot)) {
        $ToolkitRoot = Get-ToolkitRootFromScript
    }

    if ([string]::IsNullOrWhiteSpace($ToolkitRoot)) {
        throw 'Toolkit root could not be resolved for offline runtime paths.'
    }

    return Join-Path $ToolkitRoot 'CDE\Runtime'
}

function Get-OfflineEnvFilePath {
    param([string]$ToolkitRoot = '')

    return Join-Path (Get-OfflineRuntimeDirectory -ToolkitRoot $ToolkitRoot) 'offline_env.txt'
}

function Get-OfflineProgressLogPath {
    param([string]$ToolkitRoot = '')

    return Join-Path (Get-OfflineRuntimeDirectory -ToolkitRoot $ToolkitRoot) 'offline_progress.log'
}

function Get-LegacyOfflineEnvFilePath {
    param([string]$ToolkitRoot = '')

    if ([string]::IsNullOrWhiteSpace($ToolkitRoot)) {
        $ToolkitRoot = Get-ToolkitRootFromScript
    }

    return Join-Path $ToolkitRoot 'offline_env.txt'
}

function Get-LegacyOfflineProgressLogPath {
    param([string]$ToolkitRoot = '')

    if ([string]::IsNullOrWhiteSpace($ToolkitRoot)) {
        $ToolkitRoot = Get-ToolkitRootFromScript
    }

    return Join-Path $ToolkitRoot 'offline_progress.log'
}

function Ensure-OfflineRuntimeDirectory {
    param([string]$ToolkitRoot = '')

    $dir = Get-OfflineRuntimeDirectory -ToolkitRoot $ToolkitRoot
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    return $dir
}

function Test-OfflineSoftwareHiveLoaded {
    return Test-Path -LiteralPath 'HKLM:\Offline_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
}

function Test-OfflineRegistrySessionActive {
    if ($env:OFFLINE_REGISTRY_LOADED -ne '1') {
        return $false
    }

    return Test-OfflineSoftwareHiveLoaded
}

function Remove-LegacyOfflineRuntimeArtifacts {
    param([string]$ToolkitRoot = '')

    foreach ($path in @(
        (Get-LegacyOfflineEnvFilePath -ToolkitRoot $ToolkitRoot),
        (Get-LegacyOfflineProgressLogPath -ToolkitRoot $ToolkitRoot)
    )) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

function Clear-OfflineRuntimeSessionFiles {
    param([string]$ToolkitRoot = '')

    Remove-LegacyOfflineRuntimeArtifacts -ToolkitRoot $ToolkitRoot

    $runtimeDir = Get-OfflineRuntimeDirectory -ToolkitRoot $ToolkitRoot
    if (Test-Path -LiteralPath $runtimeDir) {
        Get-ChildItem -LiteralPath $runtimeDir -Force -ErrorAction SilentlyContinue |
            Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    }
}

function Resolve-OfflineEnvFilePath {
    param([string]$ToolkitRoot = '')

    $preferred = Get-OfflineEnvFilePath -ToolkitRoot $ToolkitRoot
    if (Test-Path -LiteralPath $preferred) {
        return $preferred
    }

    $legacy = Get-LegacyOfflineEnvFilePath -ToolkitRoot $ToolkitRoot
    if (Test-Path -LiteralPath $legacy) {
        return $legacy
    }

    return $preferred
}

function Get-OfflineWindowsPathFromEnv {
    $raw = $env:OFFLINE_WINDOWS_ROOT
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return ''
    }

    $trimmed = $raw.Trim().TrimEnd('\')
    if ($trimmed -match '^([A-Za-z]):') {
        $windowsPath = Join-Path "$($matches[1]):\" 'Windows'
        if (Test-Path -LiteralPath $windowsPath) {
            return $windowsPath
        }
    }

    return ''
}

function Sync-OfflineRegistryLoadedEnv {
    if (-not (Test-OfflineRegistrySessionActive)) {
        if ($env:OFFLINE_REGISTRY_LOADED -eq '1') {
            Remove-Item Env:OFFLINE_REGISTRY_LOADED -ErrorAction SilentlyContinue
        }
        return $false
    }

    return $true
}
