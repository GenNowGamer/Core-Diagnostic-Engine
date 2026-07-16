#Requires -Version 5.1
param(
    [string]$Action = 'List',
    [string]$UninstallKey = '',
    [string]$UninstallStr = '',
    [string]$QuietUninstallStr = '',
    [string]$InstallLocation = '',
    [string]$DisplayName = '',
    [string]$Publisher = '',
    [string]$FolderPath = '',
    [switch]$PreferQuiet,
    [switch]$RemoveInstallFolder,
    [switch]$ElevatedRelay
)

$ErrorActionPreference = if ($Action -eq 'List' -or $Action -eq 'InspectLeftovers') { 'SilentlyContinue' } else { 'Stop' }

$Script:UninstallManagerScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir = Split-Path $Script:UninstallManagerScriptPath
$ElevationModule = Join-Path $ScriptDir '..\Core\Toolkit.Elevation.psm1'
Import-Module $ElevationModule -Force -DisableNameChecking

function Get-UninstallManagerRelayArgumentString {
    $parts = [System.Collections.Generic.List[string]]::new()
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'Action' -Value $Action
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'ElevatedRelay' -IsSwitch
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'UninstallKey' -Value $UninstallKey
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'UninstallStr' -Value $UninstallStr
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'QuietUninstallStr' -Value $QuietUninstallStr
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'InstallLocation' -Value $InstallLocation
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'DisplayName' -Value $DisplayName
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'Publisher' -Value $Publisher
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'FolderPath' -Value $FolderPath
    if ($PreferQuiet) {
        Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'PreferQuiet' -IsSwitch
    }
    if ($RemoveInstallFolder) {
        Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'RemoveInstallFolder' -IsSwitch
    }
    return Join-ToolkitRelayArgumentString -Parts $parts
}

function Test-UninstallKeyRequiresElevation {
    param([string]$Key)

    if ([string]::IsNullOrWhiteSpace($Key)) { return $false }
    return ($Key -match '(?i)(?:^HKLM:|\\HKEY_LOCAL_MACHINE\\|Registry::HKEY_LOCAL_MACHINE)')
}

function Test-UninstallCommandRequiresElevation {
    param([string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    if ($Command -match '(?i)msiexec') { return $true }
    return $false
}

function Invoke-UninstallManagerElevationRelay {
    if ($ElevatedRelay) { return $false }

    $needsElevation = $false
    switch ($Action) {
        'ForceRemove' {
            $needsElevation = (Test-UninstallKeyRequiresElevation -Key $UninstallKey) -or $RemoveInstallFolder
        }
        'Uninstall' {
            $cmd = if ($PreferQuiet -and -not [string]::IsNullOrWhiteSpace($QuietUninstallStr)) {
                $QuietUninstallStr
            } else {
                $UninstallStr
            }
            $needsElevation = (Test-UninstallKeyRequiresElevation -Key $UninstallKey) -or
                (Test-UninstallCommandRequiresElevation -Command $cmd) -or
                (Test-UninstallCommandRequiresElevation -Command $UninstallStr) -or
                (Test-UninstallCommandRequiresElevation -Command $QuietUninstallStr)
        }
        'RemoveFolder' {
            $needsElevation = $true
        }
        default { $needsElevation = $false }
    }

    if (-not $needsElevation) { return $false }
    return (Invoke-ToolkitWorkflowElevationRelay -ScriptPath $Script:UninstallManagerScriptPath `
        -ArgumentString (Get-UninstallManagerRelayArgumentString) -ElevatedRelay:$ElevatedRelay)
}

if (Invoke-UninstallManagerElevationRelay) { exit 0 }

function Format-SizeHuman {
    param([Parameter(Mandatory)][long]$Bytes)

    if ($Bytes -lt 0) { $Bytes = 0 }

    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $value = [double]$Bytes
    $unitIndex = 0
    while ($value -ge 1024 -and $unitIndex -lt ($units.Count - 1)) {
        $value /= 1024
        $unitIndex++
    }

    $decimals = if ($unitIndex -le 1) { 0 } else { 1 }
    return ('{0:N' + $decimals + '} {1}') -f $value, $units[$unitIndex]
}

function Get-ProductCodeFromUninstallKey {
    param([string]$KeyPath)

    if ([string]::IsNullOrWhiteSpace($KeyPath)) { return '' }
    $leaf = Split-Path -Leaf ($KeyPath -replace '::', '\')
    if ($leaf -match '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') {
        return $leaf
    }
    return ''
}

function Get-ProductCodeFromUninstallCommand {
    param([string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) { return '' }
    if ($Command -match '(?i)(?:/I|/X|/x)\s*(?<guid>\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\})') {
        return $Matches['guid']
    }
    if ($Command -match '(?<guid>\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\})') {
        return $Matches['guid']
    }
    return ''
}

function Test-IsMsiUninstallCommand {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    return ($Command -match '(?i)msiexec') -or (-not [string]::IsNullOrWhiteSpace((Get-ProductCodeFromUninstallCommand -Command $Command)))
}

function Resolve-InstallFolderHint {
    param(
        [string]$InstallLocation,
        [string]$DisplayIcon
    )

    if (-not [string]::IsNullOrWhiteSpace($InstallLocation)) {
        $loc = $InstallLocation.Trim().Trim('"')
        if (Test-Path -LiteralPath $loc -PathType Container -ErrorAction SilentlyContinue) {
            return $loc
        }
        if (Test-Path -LiteralPath $loc -PathType Leaf -ErrorAction SilentlyContinue) {
            return [System.IO.Path]::GetDirectoryName($loc)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($DisplayIcon)) {
        $icon = ($DisplayIcon -split ',')[0].Trim().Trim('"')
        if (-not [string]::IsNullOrWhiteSpace($icon) -and (Test-Path -LiteralPath $icon -PathType Leaf -ErrorAction SilentlyContinue)) {
            return [System.IO.Path]::GetDirectoryName($icon)
        }
    }

    return ''
}

function Resolve-PreferredUninstallCommand {
    param(
        [string]$UninstallString,
        [string]$QuietUninstallString,
        [string]$ProductCode,
        [bool]$PreferQuiet = $true
    )

    $result = [PSCustomObject]@{
        Command     = ''
        Method      = 'None'
        IsMsi       = $false
        ProductCode = $ProductCode
        Detail      = ''
    }

    $msiGuid = $ProductCode
    if ([string]::IsNullOrWhiteSpace($msiGuid)) {
        $msiGuid = Get-ProductCodeFromUninstallCommand -Command $QuietUninstallString
    }
    if ([string]::IsNullOrWhiteSpace($msiGuid)) {
        $msiGuid = Get-ProductCodeFromUninstallCommand -Command $UninstallString
    }
    $result.ProductCode = $msiGuid
    $result.IsMsi = -not [string]::IsNullOrWhiteSpace($msiGuid) -or
        (Test-IsMsiUninstallCommand -Command $UninstallString) -or
        (Test-IsMsiUninstallCommand -Command $QuietUninstallString)

    if ($PreferQuiet -and -not [string]::IsNullOrWhiteSpace($QuietUninstallString)) {
        $result.Command = $QuietUninstallString.Trim()
        $result.Method = 'QuietUninstallString'
        $result.Detail = 'Using QuietUninstallString'
        return $result
    }

    if ($PreferQuiet -and -not [string]::IsNullOrWhiteSpace($msiGuid)) {
        $result.Command = "msiexec.exe /x $msiGuid /qn /norestart"
        $result.Method = 'MsiQuiet'
        $result.Detail = "Normalized MSI quiet uninstall for $msiGuid"
        return $result
    }

    if (-not [string]::IsNullOrWhiteSpace($msiGuid) -and (
            [string]::IsNullOrWhiteSpace($UninstallString) -or
            ($UninstallString -match '(?i)msiexec')
        )) {
        $result.Command = "msiexec.exe /x $msiGuid"
        $result.Method = 'MsiInteractive'
        $result.Detail = "Normalized MSI uninstall for $msiGuid"
        return $result
    }

    if (-not [string]::IsNullOrWhiteSpace($UninstallString)) {
        $result.Command = $UninstallString.Trim()
        $result.Method = 'UninstallString'
        $result.Detail = 'Using UninstallString'
        return $result
    }

    $result.Detail = 'No uninstall command available'
    return $result
}

function Split-UninstallCommandLine {
    param([string]$Command)

    $cmd = if ($null -eq $Command) { '' } else { $Command.Trim() }
    $exe = $null
    $args = ''

    if ($cmd -match '^\s*"(?<exe>[^"]+)"\s*(?<args>.*)$') {
        $exe = $Matches['exe']
        $args = $Matches['args']
    } elseif ($cmd -match '^\s*(?<exe>\S+)\s*(?<args>.*)$') {
        $exe = $Matches['exe']
        $args = $Matches['args']
    }

    return [PSCustomObject]@{
        Executable = $exe
        Arguments  = $args
        Raw        = $cmd
    }
}

function Resolve-UninstallExecutablePath {
    param([string]$Exe)

    if ([string]::IsNullOrWhiteSpace($Exe)) { return '' }

    if (Test-Path -LiteralPath $Exe -PathType Leaf -ErrorAction SilentlyContinue) {
        return $Exe
    }

    # msiexec / system tools on PATH
    if ($Exe -match '(?i)^msiexec(\.exe)?$') {
        $sys = Join-Path $env:SystemRoot 'System32\msiexec.exe'
        if (Test-Path -LiteralPath $sys -PathType Leaf) { return $sys }
    }

    try {
        $cmd = Get-Command $Exe -ErrorAction Stop
        if ($cmd -and $cmd.Source) { return [string]$cmd.Source }
    } catch { }

    return $Exe
}

function Get-SafeUninstallFolderRoots {
    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @(
            ${env:ProgramFiles}
            ${env:ProgramFiles(x86)}
            $env:ProgramData
            (Join-Path $env:SystemDrive 'Program Files')
            (Join-Path $env:SystemDrive 'Program Files (x86)')
        )) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            $full = [System.IO.Path]::GetFullPath($candidate.TrimEnd('\'))
            if (-not [string]::IsNullOrWhiteSpace($full)) {
                $roots.Add($full) | Out-Null
            }
        } catch { }
    }
    return @($roots | Select-Object -Unique)
}

function Test-SafeUninstallFolderPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }

    try {
        $full = [System.IO.Path]::GetFullPath($Path.Trim().Trim('"'))
    } catch {
        return $false
    }

    if (-not (Test-Path -LiteralPath $full -PathType Container -ErrorAction SilentlyContinue)) {
        return $false
    }

    $blockedNames = @('Windows', 'System32', 'SysWOW64', 'Program Files', 'Program Files (x86)', 'ProgramData', 'Users', 'PerfLogs')
    $leaf = [System.IO.Path]::GetFileName($full.TrimEnd('\'))
    if ($blockedNames -contains $leaf) { return $false }

    $win = [System.IO.Path]::GetFullPath($env:SystemRoot)
    if ($full.StartsWith($win, [StringComparison]::OrdinalIgnoreCase)) { return $false }

    $roots = Get-SafeUninstallFolderRoots
    foreach ($root in $roots) {
        $prefix = $root.TrimEnd('\') + '\'
        if ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and
            $full.Length -gt $prefix.Length) {
            return $true
        }
    }

    return $false
}

function Get-NormalizedNameTokens {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $clean = ($Text -replace '[^\w\s]', ' ' -replace '\s+', ' ').Trim()
    $parts = @($clean -split '\s+' | Where-Object {
            $_.Length -ge 3 -and $_ -notin @(
                'the', 'and', 'for', 'inc', 'llc', 'ltd', 'corp', 'corporation',
                'software', 'systems', 'technology', 'technologies', 'microsoft', 'windows'
            )
        })
    return $parts
}

function Test-FolderNameMatchesProduct {
    param(
        [string]$FolderName,
        [string]$DisplayName,
        [string]$Publisher
    )

    if ([string]::IsNullOrWhiteSpace($FolderName)) { return $false }
    $folderLower = $FolderName.ToLowerInvariant()

    $nameTokens = Get-NormalizedNameTokens -Text $DisplayName
    if ($nameTokens.Count -ge 1) {
        $joined = ($nameTokens -join ' ').ToLowerInvariant()
        if ($folderLower -eq ($DisplayName.ToLowerInvariant()) -or
            $folderLower.Contains(($nameTokens[0]).ToLowerInvariant())) {
            # Prefer stronger match when multiple tokens exist
            if ($nameTokens.Count -eq 1) { return $true }
            $hit = 0
            foreach ($t in $nameTokens) {
                if ($folderLower.Contains($t.ToLowerInvariant())) { $hit++ }
            }
            if ($hit -ge [Math]::Min(2, $nameTokens.Count)) { return $true }
            if ($folderLower -eq $joined -or $folderLower.Replace(' ', '') -eq $joined.Replace(' ', '')) {
                return $true
            }
        }
    }

    $pubTokens = Get-NormalizedNameTokens -Text $Publisher
    if ($pubTokens.Count -ge 1 -and $folderLower.Contains(($pubTokens[0]).ToLowerInvariant()) -and
        $nameTokens.Count -ge 1 -and $folderLower.Contains(($nameTokens[0]).ToLowerInvariant())) {
        return $true
    }

    return $false
}

function Get-UninstallLeftovers {
    param(
        [string]$UninstallKey,
        [string]$DisplayName,
        [string]$Publisher,
        [string]$InstallLocation
    )

    $arpStillPresent = $false
    if (-not [string]::IsNullOrWhiteSpace($UninstallKey)) {
        $arpStillPresent = Test-Path -LiteralPath $UninstallKey -ErrorAction SilentlyContinue
    }

    $installFolder = Resolve-InstallFolderHint -InstallLocation $InstallLocation -DisplayIcon ''
    $installFolderExists = -not [string]::IsNullOrWhiteSpace($installFolder) -and
        (Test-Path -LiteralPath $installFolder -PathType Container -ErrorAction SilentlyContinue)

    $candidates = [System.Collections.Generic.List[object]]::new()
    $seen = @{}

    if ($installFolderExists -and (Test-SafeUninstallFolderPath -Path $installFolder)) {
        $seen[$installFolder.ToLowerInvariant()] = $true
        $candidates.Add([PSCustomObject]@{
            Path   = $installFolder
            Reason = 'InstallLocation'
            Safe   = $true
        }) | Out-Null
    }

    $searchRoots = Get-SafeUninstallFolderRoots
    foreach ($root in $searchRoots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $dir = $_.FullName
            $key = $dir.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { return }
            if (-not (Test-FolderNameMatchesProduct -FolderName $_.Name -DisplayName $DisplayName -Publisher $Publisher)) {
                return
            }
            if (-not (Test-SafeUninstallFolderPath -Path $dir)) { return }
            $seen[$key] = $true
            $candidates.Add([PSCustomObject]@{
                Path   = $dir
                Reason = 'NameMatch'
                Safe   = $true
            }) | Out-Null
        }

        # One level of publisher\product under Program* roots
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $publisherDir = $_
            $parentLooksLikePublisher = Test-FolderNameMatchesProduct `
                -FolderName $publisherDir.Name `
                -DisplayName $Publisher `
                -Publisher $Publisher

            Get-ChildItem -LiteralPath $publisherDir.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $dir = $_.FullName
                $key = $dir.ToLowerInvariant()
                if ($seen.ContainsKey($key)) { return }

                $leafMatchesProduct = Test-FolderNameMatchesProduct `
                    -FolderName $_.Name `
                    -DisplayName $DisplayName `
                    -Publisher $Publisher

                if (-not $leafMatchesProduct -and -not (
                        $parentLooksLikePublisher -and
                        (Test-FolderNameMatchesProduct -FolderName $_.Name -DisplayName $DisplayName -Publisher '')
                    )) {
                    return
                }

                if (-not (Test-SafeUninstallFolderPath -Path $dir)) { return }
                $seen[$key] = $true
                $candidates.Add([PSCustomObject]@{
                    Path   = $dir
                    Reason = 'NestedNameMatch'
                    Safe   = $true
                }) | Out-Null
            }
        }
    }

    return [PSCustomObject]@{
        ArpKeyStillPresent   = $arpStillPresent
        InstallFolder        = $installFolder
        InstallFolderExists  = $installFolderExists
        LeftoverFolders      = @($candidates)
        DisplayName          = $DisplayName
        Publisher            = $Publisher
    }
}

function Remove-UninstallFolderSafe {
    param([string]$Path)

    if (-not (Test-SafeUninstallFolderPath -Path $Path)) {
        throw "Refusing to delete unsafe or blocked path: $Path"
    }

    $full = [System.IO.Path]::GetFullPath($Path.Trim().Trim('"'))
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $full) {
        throw "Folder still present after delete: $full"
    }

    return "Removed folder: $full"
}

function Get-InstalledPrograms {
    $regPaths = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Arch = 'x64' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Arch = 'x86' },
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Arch = 'x64' }
    )

    $programs = [System.Collections.Generic.List[object]]::new()

    foreach ($reg in $regPaths) {
        if (Test-Path $reg.Path) {
            Get-ChildItem $reg.Path -ErrorAction SilentlyContinue | ForEach-Object {
                $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                if ($props -and $props.DisplayName) {
                    $sizeDisplay = ''
                    if ($props.EstimatedSize) {
                        $bytes = [long]$props.EstimatedSize * 1KB
                        $sizeDisplay = Format-SizeHuman -Bytes $bytes
                    }

                    $uninstallStr = if ($props.UninstallString) { [string]$props.UninstallString } else { '' }
                    $quietStr = if ($props.QuietUninstallString) { [string]$props.QuietUninstallString } else { '' }
                    $installLoc = if ($props.InstallLocation) { [string]$props.InstallLocation } else { '' }
                    $displayIcon = if ($props.DisplayIcon) { [string]$props.DisplayIcon } else { '' }
                    $productCode = Get-ProductCodeFromUninstallKey -KeyPath $_.PSPath
                    if ([string]::IsNullOrWhiteSpace($productCode)) {
                        $productCode = Get-ProductCodeFromUninstallCommand -Command $uninstallStr
                    }
                    $folderHint = Resolve-InstallFolderHint -InstallLocation $installLoc -DisplayIcon $displayIcon
                    $preferred = Resolve-PreferredUninstallCommand `
                        -UninstallString $uninstallStr `
                        -QuietUninstallString $quietStr `
                        -ProductCode $productCode `
                        -PreferQuiet $true

                    $programs.Add([PSCustomObject]@{
                        Name                 = $props.DisplayName
                        Publisher            = if ($props.Publisher) { $props.Publisher } else { '' }
                        Version              = if ($props.DisplayVersion) { $props.DisplayVersion } else { '' }
                        InstallDate          = if ($props.InstallDate) { $props.InstallDate } else { '' }
                        SizeDisplay          = $sizeDisplay
                        UninstallKey         = $_.PSPath
                        UninstallStr         = $uninstallStr
                        QuietUninstallStr    = $quietStr
                        InstallLocation      = if (-not [string]::IsNullOrWhiteSpace($folderHint)) { $folderHint } else { $installLoc }
                        ProductCode          = $productCode
                        PreferredUninstallStr = $preferred.Command
                        UninstallMethod      = $preferred.Method
                        IsMsi                = [bool]$preferred.IsMsi
                        HasQuietUninstall    = -not [string]::IsNullOrWhiteSpace($quietStr)
                        Arch                 = $reg.Arch
                    })
                }
            }
        }
    }

    $programs | Sort-Object Name | ConvertTo-Json -Depth 3
}

function Invoke-UninstallCommand {
    param([string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) {
        throw 'No uninstall command available. Use Force Remove for orphaned or spoofed entries.'
    }

    $parsed = Split-UninstallCommandLine -Command $Command
    if ([string]::IsNullOrWhiteSpace($parsed.Executable)) {
        throw "Unable to parse uninstall command: $Command"
    }

    $exe = Resolve-UninstallExecutablePath -Exe $parsed.Executable
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf -ErrorAction SilentlyContinue)) {
        throw "Uninstaller not found: $exe. Use Force Remove if this is a broken or orphaned entry."
    }

    $exitCode = 0
    if ([string]::IsNullOrWhiteSpace($parsed.Arguments)) {
        $proc = Start-Process -FilePath $exe -Wait -PassThru -ErrorAction Stop
    } else {
        $proc = Start-Process -FilePath $exe -ArgumentList $parsed.Arguments -Wait -PassThru -ErrorAction Stop
    }
    if ($null -ne $proc) {
        $exitCode = [int]$proc.ExitCode
    }

    # MSI success codes: 0 success, 3010 reboot required, 1641 reboot initiated
    $ok = ($exitCode -eq 0 -or $exitCode -eq 3010 -or $exitCode -eq 1641)
    return [PSCustomObject]@{
        Launched = $true
        ExitCode = $exitCode
        Success  = $ok
        Exe      = $exe
        Args     = $parsed.Arguments
    }
}

switch ($Action) {
    'List' { Get-InstalledPrograms }

    'Uninstall' {
        $productCode = Get-ProductCodeFromUninstallKey -KeyPath $UninstallKey
        if ([string]::IsNullOrWhiteSpace($productCode)) {
            $productCode = Get-ProductCodeFromUninstallCommand -Command $QuietUninstallStr
        }
        if ([string]::IsNullOrWhiteSpace($productCode)) {
            $productCode = Get-ProductCodeFromUninstallCommand -Command $UninstallStr
        }

        $preferred = Resolve-PreferredUninstallCommand `
            -UninstallString $UninstallStr `
            -QuietUninstallString $QuietUninstallStr `
            -ProductCode $productCode `
            -PreferQuiet:([bool]$PreferQuiet)

        if ([string]::IsNullOrWhiteSpace($preferred.Command)) {
            Write-Error 'No UninstallString on this entry. Use Force Remove to delete the registry key (orphaned or spoofed entries).'
            exit 1
        }

        try {
            $launch = Invoke-UninstallCommand -Command $preferred.Command
            $payload = [PSCustomObject]@{
                Status       = if ($launch.Success) { 'Completed' } else { 'CompletedWithExitCode' }
                Message      = "Uninstaller finished (method=$($preferred.Method), exit=$($launch.ExitCode))"
                Method       = $preferred.Method
                Command      = $preferred.Command
                ExitCode     = $launch.ExitCode
                Success      = $launch.Success
                UninstallKey = $UninstallKey
            }
            $payload | ConvertTo-Json -Depth 3 -Compress
            if (-not $launch.Success) { exit 1 }
        } catch {
            Write-Error ("Failed to launch uninstaller: " + $_.Exception.Message)
            exit 1
        }
    }

    'ForceRemove' {
        if ([string]::IsNullOrWhiteSpace($UninstallKey)) {
            Write-Error 'UninstallKey is required for ForceRemove.'
            exit 1
        }

        $removedKey = $false
        if (Test-Path -LiteralPath $UninstallKey -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $UninstallKey -Recurse -Force -ErrorAction Stop
            $removedKey = -not (Test-Path -LiteralPath $UninstallKey -ErrorAction SilentlyContinue)
        } else {
            $removedKey = $true
        }

        $folderResult = ''
        if ($RemoveInstallFolder -and -not [string]::IsNullOrWhiteSpace($InstallLocation)) {
            $folderResult = Remove-UninstallFolderSafe -Path $InstallLocation
        }

        $payload = [PSCustomObject]@{
            Status              = 'Completed'
            Message             = if ($folderResult) {
                "Registry key removed; $folderResult"
            } else {
                "Registry key removed: $UninstallKey"
            }
            ArpKeyRemoved       = $removedKey
            InstallFolderRemoved = -not [string]::IsNullOrWhiteSpace($folderResult)
            FolderDetail        = $folderResult
        }
        $payload | ConvertTo-Json -Depth 3 -Compress
    }

    'InspectLeftovers' {
        $report = Get-UninstallLeftovers `
            -UninstallKey $UninstallKey `
            -DisplayName $DisplayName `
            -Publisher $Publisher `
            -InstallLocation $InstallLocation
        $report | ConvertTo-Json -Depth 4
    }

    'RemoveFolder' {
        if ([string]::IsNullOrWhiteSpace($FolderPath)) {
            Write-Error 'FolderPath is required for RemoveFolder.'
            exit 1
        }
        try {
            $msg = Remove-UninstallFolderSafe -Path $FolderPath
            [PSCustomObject]@{
                Status  = 'Completed'
                Message = $msg
                Path    = $FolderPath
            } | ConvertTo-Json -Depth 2 -Compress
        } catch {
            Write-Error $_.Exception.Message
            exit 1
        }
    }

    'SelfTest' {
        $failures = [System.Collections.Generic.List[string]]::new()
        function Assert-True([string]$Name, [bool]$Condition) {
            if ($Condition) { Write-Output "PASS: $Name" }
            else { $script:failures.Add($Name) | Out-Null; Write-Output "FAIL: $Name" }
        }

        $quietPref = Resolve-PreferredUninstallCommand `
            -UninstallString 'C:\App\uninstall.exe' `
            -QuietUninstallString '"C:\App\uninstall.exe" /S' `
            -ProductCode '' `
            -PreferQuiet $true
        Assert-True 'Prefers QuietUninstallString' ($quietPref.Method -eq 'QuietUninstallString')

        $guid = '{01234567-89AB-CDEF-0123-456789ABCDEF}'
        $msiQuiet = Resolve-PreferredUninstallCommand `
            -UninstallString "MsiExec.exe /X$guid" `
            -QuietUninstallString '' `
            -ProductCode $guid `
            -PreferQuiet $true
        Assert-True 'Normalizes MSI to quiet msiexec' (
            $msiQuiet.Method -eq 'MsiQuiet' -and $msiQuiet.Command -match '/qn'
        )

        $msiInteractive = Resolve-PreferredUninstallCommand `
            -UninstallString "MsiExec.exe /X$guid" `
            -QuietUninstallString '' `
            -ProductCode $guid `
            -PreferQuiet $false
        Assert-True 'Interactive MSI omits /qn' (
            $msiInteractive.Method -eq 'MsiInteractive' -and $msiInteractive.Command -notmatch '/qn'
        )

        Assert-True 'Blocks System32 folder delete' (-not (Test-SafeUninstallFolderPath -Path "$env:SystemRoot\System32"))
        Assert-True 'Blocks Program Files root delete' (-not (Test-SafeUninstallFolderPath -Path ${env:ProgramFiles}))

        $pfChild = Get-ChildItem -LiteralPath ${env:ProgramFiles} -Directory -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($pfChild) {
            Assert-True 'Allows Program Files child folder' (Test-SafeUninstallFolderPath -Path $pfChild.FullName)
        } else {
            Write-Output 'INFO: No Program Files child to assert safe-path allow'
        }

        $parsed = Split-UninstallCommandLine -Command '"C:\Program Files\App\uninstall.exe" /S'
        Assert-True 'Parses quoted uninstall exe' ($parsed.Executable -eq 'C:\Program Files\App\uninstall.exe')
        Assert-True 'Parses uninstall args' ($parsed.Arguments.Trim() -eq '/S')

        if ($failures.Count -gt 0) {
            Write-Error ("SelfTest failed: " + ($failures -join '; '))
            exit 1
        }
        Write-Output "SelfTest passed ($($failures.Count) failures)"
    }

    default {
        Write-Error "Unknown action: $Action"
        exit 1
    }
}
