#Requires -Version 5.1

param(
    [switch]$AutoSelect,
    [switch]$AutoLoad,
    [switch]$Quiet,
    [string]$ProgressFile = ""
)

<##
.SYNOPSIS
    Detect and optionally load an offline Windows installation and its user registry hives when running in WinPE.
.DESCRIPTION
    This helper is invoked from startnet.cmd in WinPE. It scans attached drives for Windows installations,
    prompts the operator to choose one, and loads the offline SOFTWARE/SYSTEM/SAM hives plus user NTUSER.DAT hives.

    For custom startup UX, this script can run in hidden/non-interactive mode:
      -AutoSelect -AutoLoad -Quiet -ProgressFile <path>
##>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'OfflineRuntime.ps1')

# PSScriptRoot = ...\Toolkit\Scripts\Core - toolkit root is two levels up.
$ToolkitRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Clear-OfflineRuntimeSessionFiles -ToolkitRoot $ToolkitRoot
Ensure-OfflineRuntimeDirectory -ToolkitRoot $ToolkitRoot | Out-Null
$EnvFile = Get-OfflineEnvFilePath -ToolkitRoot $ToolkitRoot

if (-not [string]::IsNullOrWhiteSpace($ProgressFile)) {
    try {
        $progressDir = Split-Path -Parent $ProgressFile
        if (-not [string]::IsNullOrWhiteSpace($progressDir) -and -not (Test-Path $progressDir)) {
            New-Item -Path $progressDir -ItemType Directory -Force | Out-Null
        }
        if (Test-Path $ProgressFile) {
            Remove-Item -Path $ProgressFile -Force -ErrorAction SilentlyContinue
        }
    }
    catch { }
}

function Write-Status {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [int]$Percent = 0,
        [switch]$Warning
    )

    $pct = [Math]::Min(100, [Math]::Max(0, $Percent))

    if (-not [string]::IsNullOrWhiteSpace($ProgressFile)) {
        try {
            Add-Content -Path $ProgressFile -Value ("{0}|{1}" -f $pct, $Message) -Encoding ASCII
        }
        catch { }
    }

    if ($Quiet) {
        return
    }

    if ($Warning) {
        Write-Warning $Message
    }
    else {
        Write-Host $Message
    }
}

function Get-WindowsInstallations {
    $candidates = [System.Collections.Generic.List[object]]::new()
    for ($driveCode = [int][char]'C'; $driveCode -le [int][char]'Z'; $driveCode++) {
        $drive = ([char]$driveCode).ToString()
        if ($drive -eq 'X') { continue }
        $root = "$drive`:\"
        if (Test-Path "$root\Windows\System32\config\SYSTEM") {
            $candidates.Add([PSCustomObject]@{
                Drive = $drive
                Root  = $root
                WindowsPath = "$root\Windows"
                SystemHive   = "$root\Windows\System32\config\SYSTEM"
                SoftwareHive = "$root\Windows\System32\config\SOFTWARE"
                SamHive      = "$root\Windows\System32\config\SAM"
                UsersPath    = "$root\Users"
            })
        }
    }
    return $candidates
}

# Read-HostWithTimeout: prompts the user and returns their input.
# If no key is pressed within $TimeoutSec seconds, returns $DefaultValue silently.
function Read-HostWithTimeout {
    param(
        [string]$Prompt,
        [string]$DefaultValue = '',
        [int]   $TimeoutSec   = 30
    )
    Write-Host -NoNewline "$Prompt (auto-skip in $TimeoutSec s): "
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $input     = ''
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'Enter') { Write-Host ''; return $input }
            if ($key.Key -eq 'Backspace') {
                if ($input.Length -gt 0) {
                    $input = $input.Substring(0, $input.Length - 1)
                    Write-Host -NoNewline "`b `b"
                }
            }
            else {
                $input += $key.KeyChar
                Write-Host -NoNewline $key.KeyChar
            }
        }
        Start-Sleep -Milliseconds 100
    }
    Write-Host ''
    Write-Host "  (no input - using default: '$DefaultValue')"
    return $DefaultValue
}

function Sanitize-HiveName($name) {
    return ($name -replace '[^A-Za-z0-9_]','_')
}

function Try-LoadHive {
    param(
        [string]$RegPath,
        [string]$HivePath,
        [int]$Percent
    )

    if (-not (Test-Path $HivePath)) {
        Write-Status -Message "Hive not found: $HivePath" -Percent $Percent -Warning
        return $false
    }

    $existing = & reg.exe query "$RegPath" 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Status -Message "Hive already loaded: $RegPath" -Percent $Percent
        return $true
    }

    Write-Status -Message "Loading registry hive: $RegPath" -Percent $Percent
    & reg.exe load "$RegPath" "$HivePath" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Status -Message "Failed loading hive: $RegPath" -Percent $Percent -Warning
        return $false
    }
    return $true
}

function Load-OfflineUserHives {
    param([string]$WindowsRoot)

    $userRoot = Join-Path $WindowsRoot 'Users'
    if (-not (Test-Path $userRoot)) {
        Write-Status -Message "Offline user folder not found: $userRoot" -Percent 62 -Warning
        return
    }

    Write-Status -Message 'Loading offline user profile hives...' -Percent 62

    $profiles = Get-ChildItem -Path $userRoot -Directory -ErrorAction SilentlyContinue
    $profileCount = [Math]::Max(1, $profiles.Count)
    $index = 0

    foreach ($profile in $profiles) {
        $index++
        $ntUserPath = Join-Path $profile.FullName 'NTUSER.DAT'
        if (-not (Test-Path $ntUserPath)) { continue }

        $hiveName = "Offline_$((Sanitize-HiveName $profile.Name))"
        $regPath = "HKU\$hiveName"
        $pct = 62 + [int](8 * ($index / $profileCount))

        if (Test-Path "$regPath") {
            Write-Status -Message "Profile hive already loaded: $regPath" -Percent $pct
            continue
        }

        Try-LoadHive -RegPath $regPath -HivePath $ntUserPath -Percent $pct | Out-Null
    }
}

function Load-OfflineDrivers {
    param([string]$OfflineRoot)

    Write-Status -Message 'Loading offline network and storage drivers...' -Percent 72

    # Use DriverStore packages — each is self-contained (INF + .sys in same folder)
    $driverStorePath = Join-Path $OfflineRoot 'Windows\System32\DriverStore\FileRepository'
    if (-not (Test-Path $driverStorePath)) {
        Write-Status -Message "Offline DriverStore not found: $driverStorePath" -Percent 92 -Warning
        return 0
    }

    # Class GUIDs for Network and Disk/Storage only — system/boot/filter drivers excluded
    $targetClasses = @(
        '{4d36e972-e325-11ce-bfc1-08002be10318}',  # Net
        '{4d36e967-e325-11ce-bfc1-08002be10318}',  # DiskDrive
        '{4d36e973-e325-11ce-bfc1-08002be10318}'   # NetClient
    )

    # Known problematic packages that can stall drvload in some WinPE/hardware combos.
    $blockedPackageRegex = @(
        '^mt7612us_'
    )

    $driverLoadTimeoutSec = 8

    $loaded = 0
    $packages = Get-ChildItem -Path $driverStorePath -Directory -ErrorAction SilentlyContinue
    $pkgCount = [Math]::Max(1, $packages.Count)
    $pkgIndex = 0

    foreach ($pkg in $packages) {
        $pkgIndex++

        $inf = Get-ChildItem -Path $pkg.FullName -Filter '*.inf' -File -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($null -eq $inf) { continue }

        try {
            # Read only the [Version] section (first 50 lines) to check ClassGuid — avoids loading large INFs
            $content = Get-Content -Path $inf.FullName -TotalCount 50 -ErrorAction SilentlyContinue | Out-String
            if ([string]::IsNullOrEmpty($content)) { continue }

            $match = $false
            foreach ($guid in $targetClasses) {
                if ($content -imatch [regex]::Escape($guid)) { $match = $true; break }
            }
            if (-not $match) { continue }

            $blocked = $false
            foreach ($pattern in $blockedPackageRegex) {
                if ($pkg.Name -imatch $pattern) {
                    $blocked = $true
                    break
                }
            }
            if ($blocked) {
                Write-Status -Message "Skipping blocked driver package: $($pkg.Name)" -Percent 90 -Warning
                continue
            }

            $pct = 72 + [int](20 * ($pkgIndex / $pkgCount))
            Write-Status -Message "Loading driver package: $($pkg.Name)" -Percent $pct

            $proc = Start-Process -FilePath 'drvload.exe' -ArgumentList @($inf.FullName) -PassThru -WindowStyle Hidden
            if (-not $proc.WaitForExit($driverLoadTimeoutSec * 1000)) {
                try { $proc.Kill() } catch { }
                Write-Status -Message "Driver load timed out: $($pkg.Name)" -Percent $pct -Warning
                continue
            }

            if ($proc.ExitCode -eq 0) {
                $loaded++
            }
            else {
                Write-Status -Message "Driver load skipped: $($pkg.Name) (exit $($proc.ExitCode))" -Percent $pct -Warning
            }
        }
        catch {
            Write-Status -Message "Skipping driver package: $($pkg.Name)" -Percent 90 -Warning
        }
    }

    Write-Status -Message "Loaded $loaded offline driver package(s)." -Percent 94
    return $loaded
}

function Load-OfflineWindowsInstallation {
    param($Installation)

    Write-Status -Message "Starting offline load from $($Installation.Root)" -Percent 12
    $loaded = $false

    $hives = @(
        [PSCustomObject]@{ RegPath = 'HKLM\Offline_SYSTEM';   HivePath = $Installation.SystemHive;   Percent = 24 },
        [PSCustomObject]@{ RegPath = 'HKLM\Offline_SOFTWARE'; HivePath = $Installation.SoftwareHive; Percent = 36 },
        [PSCustomObject]@{ RegPath = 'HKLM\Offline_SAM';      HivePath = $Installation.SamHive;      Percent = 48 }
    )

    foreach ($hive in $hives) {
        if (Try-LoadHive -RegPath $hive.RegPath -HivePath $hive.HivePath -Percent $hive.Percent) {
            $loaded = $true
        }
    }

    if ($loaded) {
        Load-OfflineUserHives -WindowsRoot $Installation.Root
        $driversLoaded = Load-OfflineDrivers -OfflineRoot $Installation.Root
        Ensure-OfflineRuntimeDirectory -ToolkitRoot $ToolkitRoot | Out-Null
        $envLines = @(
            "OFFLINE_WINDOWS_ROOT=$($Installation.Root)",
            'OFFLINE_REGISTRY_LOADED=1',
            "OFFLINE_DRIVERS_LOADED=$driversLoaded"
        )
        Set-Content -Path $EnvFile -Value $envLines -Encoding ASCII
        Remove-LegacyOfflineRuntimeArtifacts -ToolkitRoot $ToolkitRoot
        Write-Status -Message "Offline environment configured at $($Installation.Root)" -Percent 100
    }
    else {
        Write-Status -Message 'No offline registry hives were loaded.' -Percent 100 -Warning
    }
}

Write-Status -Message 'Scanning drives for offline Windows installations...' -Percent 4
$candidates = @(Get-WindowsInstallations)
if ($candidates.Count -eq 0) {
    Write-Status -Message 'No offline Windows installation was detected on attached drives.' -Percent 100
    return
}

Write-Status -Message ("Detected {0} offline Windows installation(s)." -f $candidates.Count) -Percent 8

if (-not $Quiet) {
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $item = $candidates[$i]
        Write-Host "  [$($i + 1)] $($item.Root)"
    }
}

$selection = 0
if ($AutoSelect -or $candidates.Count -eq 1) {
    $selection = 1
}
else {
    $raw = Read-HostWithTimeout -Prompt "Enter the number of the Windows installation to load, or press Enter to skip" `
                                -DefaultValue '' -TimeoutSec 30
    $parsed = 0
    if (-not [string]::IsNullOrWhiteSpace($raw) -and [int]::TryParse($raw.Trim(), [ref]$parsed)) {
        $selection = $parsed
    }
}

if ($selection -lt 1 -or $selection -gt $candidates.Count) {
    Write-Status -Message 'Skipping offline load. Startup will continue without loading an offline Windows registry.' -Percent 100
    return
}

$chosen = $candidates[$selection - 1]
$shouldLoad = $false

if ($AutoLoad) {
    $shouldLoad = $true
}
else {
    # Always prompt for confirmation in interactive mode.
    # Default is 'N' (skip) if no input is provided within the timeout.
    $yn = Read-HostWithTimeout -Prompt "Load offline Windows at $($chosen.Root) and its registry hives? [Y/N]" `
                               -DefaultValue 'N' -TimeoutSec 30
    $shouldLoad = ($yn.Trim().ToUpperInvariant() -eq 'Y')
}

if ($shouldLoad) {
    Load-OfflineWindowsInstallation -Installation $chosen
}
else {
    Write-Status -Message 'Offline load declined. Startup will continue without binding offline registry hives.' -Percent 100
}
