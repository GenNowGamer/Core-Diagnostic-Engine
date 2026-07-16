#Requires -Version 5.1
<#
.SYNOPSIS
    Shared startup path resolution and risk scoring for Startup Manager and Post-Op audit.
#>

. (Join-Path $PSScriptRoot 'OfflineRuntime.ps1')

function Get-StartupResolutionSystemRoot {
    $offlineWindows = Get-OfflineWindowsPathFromEnv
    if (-not [string]::IsNullOrWhiteSpace($offlineWindows)) {
        return $offlineWindows
    }

    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        return $env:SystemRoot
    }

    return 'C:\Windows'
}

function Parse-StartupCommandLine {
    param([string]$Command)

    $trimmed = [string]$Command
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return [PSCustomObject]@{ ExecutablePath = ''; Arguments = '' }
    }

    $trimmed = $trimmed.Trim()
    if ($trimmed -match '\.lnk$' -and ($trimmed -match '^"[^"]+\.lnk"' -or $trimmed -match '[\\/]' -or $trimmed -match '^[A-Za-z]:')) {
        if ($trimmed.StartsWith('"')) {
            $parts = $trimmed -split '"'
            if ($parts.Length -ge 2) {
                return [PSCustomObject]@{ ExecutablePath = $parts[1]; Arguments = '' }
            }
        }
        return [PSCustomObject]@{ ExecutablePath = $trimmed; Arguments = '' }
    }

    if ($trimmed.StartsWith('"')) {
        $parts = $trimmed -split '"'
        if ($parts.Length -ge 2) {
            $exe = $parts[1].TrimEnd(',')
            $args = ''
            if ($parts.Length -ge 3) {
                $args = ($parts[2..($parts.Length - 1)] -join '"').Trim()
            }
            return [PSCustomObject]@{ ExecutablePath = $exe; Arguments = $args }
        }
    }

    # Unquoted absolute paths with spaces before arguments (common in scheduled tasks).
    if ($trimmed -match '^[A-Za-z]:\\' -or $trimmed.StartsWith('\\')) {
        $extMatch = [regex]::Match(
            $trimmed,
            '\.(exe|dll|com|bat|cmd|scr|msi)\b',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($extMatch.Success) {
            $exeEnd = $extMatch.Index + $extMatch.Length
            $exe = $trimmed.Substring(0, $exeEnd).Trim()
            $args = ''
            if ($exeEnd -lt $trimmed.Length) {
                $args = $trimmed.Substring($exeEnd).Trim()
            }
            return [PSCustomObject]@{ ExecutablePath = $exe; Arguments = $args }
        }
    }

    $spaceIndex = $trimmed.IndexOf(' ')
    if ($spaceIndex -lt 0) {
        return [PSCustomObject]@{ ExecutablePath = $trimmed.TrimEnd(','); Arguments = '' }
    }

    return [PSCustomObject]@{
        ExecutablePath = $trimmed.Substring(0, $spaceIndex).TrimEnd(',')
        Arguments      = $trimmed.Substring($spaceIndex + 1).Trim()
    }
}

function Expand-StartupEnvironmentVariables {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $systemRoot = Get-StartupResolutionSystemRoot
    $expanded = [regex]::Replace([string]$Text, '%SystemRoot%', $systemRoot.TrimEnd('\'), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    return [Environment]::ExpandEnvironmentVariables($expanded).Trim()
}

function Expand-WindowsImagePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    $systemRoot = Get-StartupResolutionSystemRoot
    $candidate = [string]$Path
    $candidate = $candidate.Trim().Trim('"')

    # NT object-manager / Win32 device prefixes used by service ImagePath values.
    # Real driver paths are typically "\??\C:\Windows\..." (leading backslash before ??).
    if ($candidate.StartsWith('\??\')) {
        $candidate = $candidate.Substring(4)
    } elseif ($candidate -match '^\?\?\\') {
        $candidate = $candidate.Substring(3)
    }

    if ($candidate.StartsWith('\\?\')) {
        $candidate = $candidate.Substring(4)
    } elseif ($candidate.StartsWith('\\.\')) {
        $candidate = $candidate.Substring(4)
    }

    if ($candidate -match '(?i)^\\+SystemRoot\\') {
        $candidate = Join-Path $systemRoot ($candidate -replace '(?i)^\\+SystemRoot\\', '')
    } elseif ($candidate -match '(?i)^\\+SystemRoot$') {
        $candidate = $systemRoot
    }

    $candidate = Expand-StartupEnvironmentVariables -Text $candidate

    if ($candidate -match '(?i)^system32\\' -and $candidate -notmatch '^[A-Za-z]:') {
        $candidate = Join-Path $systemRoot $candidate
    } elseif ($candidate -match '(?i)^drivers\\' -and $candidate -notmatch '^[A-Za-z]:') {
        $candidate = Join-Path (Join-Path $systemRoot 'system32') $candidate
    }

    return $candidate
}

function Test-StartupPathQualified {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $text = [string]$Path
    if ($text.StartsWith('\\')) { return $true }
    if ($text -match ':') { return $true }
    if ($text -match '\\') { return $true }
    return $false
}

function Get-LnkShortcutTarget {
    param([string]$LnkPath)

    $result = [PSCustomObject]@{
        TargetPath = ''
        Arguments  = ''
        Detail     = ''
    }

    if ([string]::IsNullOrWhiteSpace($LnkPath) -or -not (Test-Path -LiteralPath $LnkPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $result
    }

    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($LnkPath)
        $result.TargetPath = [string]$shortcut.TargetPath
        $result.Arguments = [string]$shortcut.Arguments
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)

        if (-not [string]::IsNullOrWhiteSpace($result.TargetPath) -and
            $result.TargetPath -match '\\Windows\\Installer\\') {
            $result.Detail = 'MSI shortcut placeholder; true target requires MsiGetShortcutTarget'
        }
    } catch {
        $result.Detail = $_.Exception.Message
    }

    return $result
}

function Find-StartupExecutableAppPaths {
    param([string]$ExeName)

    if ([string]::IsNullOrWhiteSpace($ExeName)) {
        return ''
    }

    $lookupName = [string]$ExeName
    if ($lookupName -notmatch '\.') {
        $lookupName = "$lookupName.exe"
    }

    $appPathsKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$lookupName"
    try {
        $props = Get-ItemProperty -LiteralPath $appPathsKey -ErrorAction Stop
        $defaultPath = [string]$props.'(default)'
        if (-not [string]::IsNullOrWhiteSpace($defaultPath)) {
            $expanded = Expand-WindowsImagePath -Path $defaultPath
            if (Test-Path -LiteralPath $expanded -PathType Leaf -ErrorAction SilentlyContinue) {
                return $expanded
            }
        }
    } catch { }

    return ''
}

function Find-StartupExecutableOnPath {
    param([string]$ExeName)

    if ([string]::IsNullOrWhiteSpace($ExeName)) {
        return ''
    }

    $lookupName = [string]$ExeName
    if ($lookupName -notmatch '\.') {
        $lookupName = "$lookupName.exe"
    }

    $pathValue = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if (-not [string]::IsNullOrWhiteSpace($userPath)) {
        if ([string]::IsNullOrWhiteSpace($pathValue)) {
            $pathValue = $userPath
        } else {
            $pathValue = "$pathValue;$userPath"
        }
    }
    if ([string]::IsNullOrWhiteSpace($pathValue)) {
        $pathValue = $env:PATH
    }

    foreach ($dir in ($pathValue -split ';')) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        $candidate = Join-Path $dir.Trim() $lookupName
        $candidate = Expand-WindowsImagePath -Path $candidate
        if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue) {
            return $candidate
        }
    }

    return ''
}

function Invoke-StartupOfflinePathRemap {
    param([string]$Path)

    $result = [PSCustomObject]@{
        Path   = $Path
        Exists = $false
        Detail = ''
    }

    $offlineRoot = $env:OFFLINE_WINDOWS_ROOT
    if ([string]::IsNullOrWhiteSpace($offlineRoot)) {
        return $result
    }

    $offlineRoot = $offlineRoot.TrimEnd('\')
    $liveRoot = $env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($liveRoot)) {
        return $result
    }

    $liveRoot = $liveRoot.TrimEnd('\')
    if (-not $Path.StartsWith($liveRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $result
    }

    $suffix = $Path.Substring($liveRoot.Length).TrimStart('\')
    $offlineWindows = Join-Path $offlineRoot 'Windows'
    $offlinePath = if ([string]::IsNullOrWhiteSpace($suffix)) { $offlineWindows } else { Join-Path $offlineWindows $suffix }
    $result.Path = $offlinePath
    $result.Exists = Test-Path -LiteralPath $offlinePath -PathType Leaf -ErrorAction SilentlyContinue
    if (-not $result.Exists) {
        $result.Detail = 'Offline remapped path missing (orphaned entry)'
    }

    return $result
}

function New-StartupTargetResult {
    param(
        [string]$RawInput,
        [string]$ExecutablePath,
        [string]$Arguments,
        [string]$ResolvedPath,
        [bool]$Exists,
        [string]$ResolutionMethod,
        [string]$Detail
    )

    return [PSCustomObject]@{
        RawInput         = $RawInput
        ExecutablePath   = $ExecutablePath
        Arguments        = $Arguments
        ResolvedPath     = $ResolvedPath
        Exists           = $Exists
        ResolutionMethod = $ResolutionMethod
        Detail           = $Detail
    }
}

function Resolve-OneDriveStaleInstallPath {
    <#
    .SYNOPSIS
        Remap versioned OneDrive install paths to a currently installed launcher/binary.
    #>
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    # C:\Program Files\Microsoft OneDrive\<version>\OneDriveLauncher.exe
    # C:\Users\...\AppData\Local\Microsoft\OneDrive\<version>\...
    if ($Path -notmatch '(?i)^(.*?\\Microsoft OneDrive)\\([^\\]+)\\(.+)$') {
        return $null
    }

    $root = $Matches[1]
    $relative = $Matches[3]
    $leaf = Split-Path -Path $relative -Leaf

    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($candidateRoot in @(
            $root,
            (Join-Path ${env:ProgramFiles} 'Microsoft OneDrive'),
            (Join-Path ${env:ProgramFiles(x86)} 'Microsoft OneDrive'),
            (Join-Path $env:LOCALAPPDATA 'Microsoft OneDrive')
        )) {
        if (-not [string]::IsNullOrWhiteSpace($candidateRoot) -and (Test-Path -LiteralPath $candidateRoot -PathType Container -ErrorAction SilentlyContinue)) {
            if ($roots -notcontains $candidateRoot) {
                $roots.Add($candidateRoot) | Out-Null
            }
        }
    }

    foreach ($candidateRoot in $roots) {
        $direct = Join-Path $candidateRoot $relative
        if (Test-Path -LiteralPath $direct -PathType Leaf -ErrorAction SilentlyContinue) {
            try { return (Get-Item -LiteralPath $direct -ErrorAction Stop).FullName } catch { return $direct }
        }

        # Prefer same leaf under newest version folder.
        $versionDirs = @(Get-ChildItem -LiteralPath $candidateRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d' } |
            Sort-Object { $_.Name } -Descending)
        foreach ($dir in $versionDirs) {
            $hit = Join-Path $dir.FullName $leaf
            if (Test-Path -LiteralPath $hit -PathType Leaf -ErrorAction SilentlyContinue) {
                try { return (Get-Item -LiteralPath $hit -ErrorAction Stop).FullName } catch { return $hit }
            }
            if ($relative -ne $leaf) {
                $hitRel = Join-Path $dir.FullName $relative
                if (Test-Path -LiteralPath $hitRel -PathType Leaf -ErrorAction SilentlyContinue) {
                    try { return (Get-Item -LiteralPath $hitRel -ErrorAction Stop).FullName } catch { return $hitRel }
                }
            }
        }

        $rootLeaf = Join-Path $candidateRoot $leaf
        if (Test-Path -LiteralPath $rootLeaf -PathType Leaf -ErrorAction SilentlyContinue) {
            try { return (Get-Item -LiteralPath $rootLeaf -ErrorAction Stop).FullName } catch { return $rootLeaf }
        }
    }

    return $null
}

function Resolve-StartupTarget {
    param([string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) {
        return (New-StartupTargetResult -RawInput '' -ExecutablePath '' -Arguments '' -ResolvedPath '' -Exists $false -ResolutionMethod 'Unresolved' -Detail 'Empty input')
    }

    $rawInput = $Command.Trim()

    # Synthetic COM display strings are not filesystem paths.
    if ($rawInput -match '\(COM\b' -or $rawInput -match '\(no executable path\)') {
        return (New-StartupTargetResult -RawInput $rawInput -ExecutablePath '' -Arguments '' -ResolvedPath '' -Exists $false -ResolutionMethod 'Unresolved' -Detail 'COM or non-file scheduled task action')
    }

    # Session Manager BootExecute values (e.g. "autocheck autochk *") are not file paths.
    if ($rawInput -match '(?i)^\s*autocheck\b') {
        $systemRoot = Get-StartupResolutionSystemRoot
        $autochk = Join-Path $systemRoot 'System32\autochk.exe'
        if (Test-Path -LiteralPath $autochk -PathType Leaf -ErrorAction SilentlyContinue) {
            $resolvedAutochk = $autochk
            try { $resolvedAutochk = (Get-Item -LiteralPath $autochk -ErrorAction Stop).FullName } catch { }
            return (New-StartupTargetResult -RawInput $rawInput -ExecutablePath $autochk -Arguments '' -ResolvedPath $resolvedAutochk -Exists $true -ResolutionMethod 'BootExecute' -Detail 'Mapped BootExecute autochk to System32\autochk.exe')
        }

        return (New-StartupTargetResult -RawInput $rawInput -ExecutablePath '' -Arguments '' -ResolvedPath '' -Exists $false -ResolutionMethod 'BootExecute' -Detail 'Windows BootExecute command (no file image)')
    }

    # Expand NT prefixes (\??\, \SystemRoot\, etc.) before absolute-path classification.
    $directPath = Expand-WindowsImagePath -Path $rawInput
    if (($directPath -match '^[A-Za-z]:\\' -or $directPath.StartsWith('\\')) -and $directPath -notmatch '\.lnk$') {
        if (Test-Path -LiteralPath $directPath -PathType Leaf -ErrorAction SilentlyContinue) {
            $resolvedDirect = $directPath
            try { $resolvedDirect = (Get-Item -LiteralPath $directPath -ErrorAction Stop).FullName } catch { }
            return (New-StartupTargetResult -RawInput $rawInput -ExecutablePath $rawInput -Arguments '' -ResolvedPath $resolvedDirect -Exists $true -ResolutionMethod 'Absolute' -Detail '')
        }

        $oneDriveHit = Resolve-OneDriveStaleInstallPath -Path $directPath
        if (-not [string]::IsNullOrWhiteSpace($oneDriveHit)) {
            return (New-StartupTargetResult -RawInput $rawInput -ExecutablePath $rawInput -Arguments '' -ResolvedPath $oneDriveHit -Exists $true -ResolutionMethod 'OneDriveRemap' -Detail 'Remapped stale OneDrive version path')
        }
    }

    $parsed = Parse-StartupCommandLine -Command $rawInput
    $exePath = $parsed.ExecutablePath
    $arguments = $parsed.Arguments
    $method = 'Unresolved'
    $detail = ''

    if ($exePath -match '\.lnk$' -and (Test-Path -LiteralPath $exePath -PathType Leaf -ErrorAction SilentlyContinue)) {
        $lnk = Get-LnkShortcutTarget -LnkPath $exePath
        if ([string]::IsNullOrWhiteSpace($lnk.TargetPath)) {
            $missingDetail = if ([string]::IsNullOrWhiteSpace($lnk.Detail)) { 'Shortcut target missing' } else { $lnk.Detail }
            return (New-StartupTargetResult -RawInput $rawInput -ExecutablePath $exePath -Arguments $arguments -ResolvedPath '' -Exists $false -ResolutionMethod 'Unresolved' -Detail $missingDetail)
        }

        $exePath = $lnk.TargetPath
        if (-not [string]::IsNullOrWhiteSpace($lnk.Arguments)) {
            $arguments = if ([string]::IsNullOrWhiteSpace($arguments)) { $lnk.Arguments } else { "$($lnk.Arguments) $arguments" }
        }
        $method = 'LnkTarget'
        if (-not [string]::IsNullOrWhiteSpace($lnk.Detail)) {
            $detail = $lnk.Detail
        }
    }

    $normalized = Expand-WindowsImagePath -Path $exePath
    if (Test-Path -LiteralPath $normalized -PathType Leaf -ErrorAction SilentlyContinue) {
        $resolved = $normalized
        try { $resolved = (Get-Item -LiteralPath $normalized -ErrorAction Stop).FullName } catch { }
        if ($method -eq 'Unresolved') { $method = 'Absolute' }
        return (New-StartupTargetResult -RawInput $rawInput -ExecutablePath $exePath -Arguments $arguments -ResolvedPath $resolved -Exists $true -ResolutionMethod $method -Detail $detail)
    }

    $oneDriveRemap = Resolve-OneDriveStaleInstallPath -Path $normalized
    if (-not [string]::IsNullOrWhiteSpace($oneDriveRemap)) {
        $remapDetail = 'Remapped stale OneDrive version path'
        if (-not [string]::IsNullOrWhiteSpace($detail)) {
            $remapDetail = "$detail; $remapDetail"
        }
        return (New-StartupTargetResult -RawInput $rawInput -ExecutablePath $exePath -Arguments $arguments -ResolvedPath $oneDriveRemap -Exists $true -ResolutionMethod 'OneDriveRemap' -Detail $remapDetail)
    }

    $offline = Invoke-StartupOfflinePathRemap -Path $normalized
    if ($offline.Exists) {
        $resolved = $offline.Path
        try { $resolved = (Get-Item -LiteralPath $offline.Path -ErrorAction Stop).FullName } catch { }
        return (New-StartupTargetResult -RawInput $rawInput -ExecutablePath $exePath -Arguments $arguments -ResolvedPath $resolved -Exists $true -ResolutionMethod 'OfflineRemap' -Detail $detail)
    }
    if (-not [string]::IsNullOrWhiteSpace($offline.Detail)) {
        $detail = $offline.Detail
    }

    if (-not (Test-StartupPathQualified -Path $normalized)) {
        $appHit = Find-StartupExecutableAppPaths -ExeName $normalized
        if (-not [string]::IsNullOrWhiteSpace($appHit)) {
            $resolved = $appHit
            try { $resolved = (Get-Item -LiteralPath $appHit -ErrorAction Stop).FullName } catch { }
            return (New-StartupTargetResult -RawInput $rawInput -ExecutablePath $exePath -Arguments $arguments -ResolvedPath $resolved -Exists $true -ResolutionMethod 'AppPaths' -Detail $detail)
        }

        $pathHit = Find-StartupExecutableOnPath -ExeName $normalized
        if (-not [string]::IsNullOrWhiteSpace($pathHit)) {
            $resolved = $pathHit
            try { $resolved = (Get-Item -LiteralPath $pathHit -ErrorAction Stop).FullName } catch { }
            return (New-StartupTargetResult -RawInput $rawInput -ExecutablePath $exePath -Arguments $arguments -ResolvedPath $resolved -Exists $true -ResolutionMethod 'SearchPath' -Detail $detail)
        }

        $bareDetail = 'Unresolved bare name: not in App Paths or PATH'
        if (-not [string]::IsNullOrWhiteSpace($detail)) {
            $bareDetail = "$detail; $bareDetail"
        }
        return (New-StartupTargetResult -RawInput $rawInput -ExecutablePath $exePath -Arguments $arguments -ResolvedPath $normalized -Exists $false -ResolutionMethod 'Unresolved' -Detail $bareDetail)
    }

    $missingDetail = "Path not found: $normalized"
    if (-not [string]::IsNullOrWhiteSpace($detail)) {
        $missingDetail = "$detail; $missingDetail"
    }
    return (New-StartupTargetResult -RawInput $rawInput -ExecutablePath $exePath -Arguments $arguments -ResolvedPath $normalized -Exists $false -ResolutionMethod 'Unresolved' -Detail $missingDetail)
}

function Resolve-CommandPath {
    param([string]$Command)

    $target = Resolve-StartupTarget -Command $Command
    return [string]$target.ResolvedPath
}

function Test-StartupPeExtension {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $ext = [System.IO.Path]::GetExtension($Path)
    return $ext -in @('.exe', '.dll', '.sys', '.scr', '.ocx', '.cpl')
}

function Test-PeLinkerTimestampPlausible {
    param([Nullable[datetime]]$Timestamp)

    if (-not $Timestamp) {
        return $false
    }

    $value = $Timestamp.Value
    if ($value.Year -lt 1980) {
        return $false
    }
    if ($value -gt (Get-Date).AddDays(1)) {
        return $false
    }

    return $true
}

function Get-PeLinkerTimestamp {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            if ($stream.Length -lt 0x40) { return $null }

            $reader = New-Object System.IO.BinaryReader($stream)
            $null = $reader.ReadBytes(0x3C)
            $peOffset = $reader.ReadInt32()
            if ($peOffset -le 0 -or ($peOffset + 12) -ge $stream.Length) { return $null }

            $null = $stream.Seek($peOffset, [System.IO.SeekOrigin]::Begin)
            $signatureBytes = $reader.ReadBytes(4)
            $signature = [System.Text.Encoding]::ASCII.GetString($signatureBytes)
            if ($signature -ne "PE`0`0") { return $null }

            $timestamp = $reader.ReadUInt32()
            if ($timestamp -eq 0) { return $null }

            return [DateTimeOffset]::FromUnixTimeSeconds($timestamp).LocalDateTime
        } finally {
            $stream.Dispose()
        }
    } catch {
        return $null
    }
}

function Get-FileSignatureInfo {
    param([string]$FilePath)

    $result = [PSCustomObject]@{
        IsSigned         = $false
        SignedBy         = ''
        SignedDisplay    = 'N/A'
        SignatureStatus  = ''
        ResolutionDetail = ''
    }

    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        return $result
    }

    $target = Resolve-StartupTarget -Command $FilePath
    $result.ResolutionDetail = [string]$target.Detail
    if (-not $target.Exists -or [string]::IsNullOrWhiteSpace($target.ResolvedPath)) {
        $result.SignedDisplay = 'Not found'
        return $result
    }

    $resolved = $target.ResolvedPath

    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $resolved -ErrorAction Stop
        $result.SignatureStatus = [string]$sig.Status
        $result.IsSigned = $sig.Status -eq 'Valid'

        if ($sig.SignerCertificate -and $sig.SignerCertificate.Subject) {
            $subject = [string]$sig.SignerCertificate.Subject
            $result.SignedBy = $subject
            if ($subject -match 'CN=([^,]+)') {
                $result.SignedDisplay = $Matches[1].Trim('"')
            } else {
                $result.SignedDisplay = $subject
            }
        } elseif ($result.IsSigned) {
            $result.SignedDisplay = 'Signed'
        } else {
            $result.SignedDisplay = switch ($sig.Status) {
                'NotSigned' { 'Unsigned' }
                'HashMismatch' { 'Hash mismatch' }
                default { if ([string]::IsNullOrWhiteSpace($sig.Status)) { 'Unsigned' } else { [string]$sig.Status } }
            }
        }
    } catch {
        $result.SignedDisplay = 'Unknown'
    }

    return $result
}

function Get-FileAnalysisInfo {
    param([string]$FilePath)

    $warnings = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        return [PSCustomObject]@{
            Level       = 'NA'
            Detail      = 'No file path'
            HasWarning  = $false
        }
    }

    $target = Resolve-StartupTarget -Command $FilePath
    if (-not $target.Exists -or [string]::IsNullOrWhiteSpace($target.ResolvedPath)) {
        $detail = if ([string]::IsNullOrWhiteSpace($target.Detail)) { 'File not found' } else { $target.Detail }
        return [PSCustomObject]@{
            Level      = 'Warning'
            Detail     = $detail
            HasWarning = $true
        }
    }

    $resolved = $target.ResolvedPath
    if (-not [string]::IsNullOrWhiteSpace($target.Detail)) {
        $warnings.Add($target.Detail) | Out-Null
    }

    try {
        $item = Get-Item -LiteralPath $resolved -ErrorAction Stop
        $modified = $item.LastWriteTime
        $created = $item.CreationTime

        if (Test-StartupPeExtension -Path $resolved) {
            $compile = Get-PeLinkerTimestamp -Path $resolved
            $plausibleCompile = Test-PeLinkerTimestampPlausible -Timestamp $compile

            if ($compile -and $plausibleCompile) {
                if ($modified -lt $compile.AddDays(-2)) {
                    $warnings.Add("Modified ($($modified.ToString('g'))) is earlier than PE compile date ($($compile.ToString('g')))") | Out-Null
                }
                if ($modified -gt $compile.AddYears(5)) {
                    $warnings.Add('Modified date is much newer than PE compile date') | Out-Null
                }
            }
        }

        $isDriverStorePath = $resolved -match '\\DriverStore\\'
        if (-not $isDriverStorePath -and $modified -lt $created.AddDays(-1)) {
            $warnings.Add('Modified date predates creation date') | Out-Null
        }

        if (Test-StartupPeExtension -Path $resolved) {
            $sig = Get-AuthenticodeSignature -LiteralPath $resolved -ErrorAction SilentlyContinue
            if ($sig -and $sig.Status -eq 'HashMismatch') {
                $warnings.Add('Authenticode hash mismatch') | Out-Null
            }
        }
    } catch {
        $warnings.Add($_.Exception.Message) | Out-Null
    }

    $level = 'OK'
    if ($warnings.Count -gt 0) {
        $level = if ($warnings | Where-Object { $_ -match 'hash mismatch|earlier than PE compile|Path not found|target missing|orphaned entry|Unresolved bare name' }) {
            'Warning'
        } else {
            'Caution'
        }
    }

    return [PSCustomObject]@{
        Level      = $level
        Detail     = if ($warnings.Count -gt 0) { ($warnings -join '; ') } else { 'No inconsistencies detected' }
        HasWarning = ($warnings.Count -gt 0)
    }
}

function Resolve-ServiceAccountDisplay {
    param([string]$StartName)

    if ([string]::IsNullOrWhiteSpace($StartName)) { return 'SYSTEM' }
    if ($StartName -match 'LocalSystem|NT AUTHORITY\\SYSTEM') { return 'SYSTEM' }
    if ($StartName -match 'LocalService|NT AUTHORITY\\LOCAL SERVICE') { return 'LOCAL SERVICE' }
    if ($StartName -match 'NetworkService|NT AUTHORITY\\NETWORK SERVICE') { return 'NETWORK SERVICE' }
    if ($StartName -match '\\([^\\]+)$') { return $Matches[1] }
    return $StartName
}

function Get-EntryUserDisplay {
    param(
        [string]$Source = '',
        [string]$RegistryPath = '',
        [string]$SourceGroup = '',
        [string]$RowType = '',
        [string]$ServiceStartName = ''
    )

    if ($SourceGroup -match 'User Startup \(([^)]+)\)') { return $Matches[1] }
    if ($Source -eq 'All Users Startup' -or $SourceGroup -eq 'All Users Startup') { return 'All Users' }

    if ($RegistryPath -match 'Offline_([^\\]+)\\') {
        $hive = $Matches[1]
        if ($hive -notin @('SOFTWARE', 'SYSTEM', 'SAM', 'DEFAULT', 'SECURITY')) {
            return $hive
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ServiceStartName)) {
        return Resolve-ServiceAccountDisplay -StartName $ServiceStartName
    }

    switch ($Source) {
        'HKCU' {
            if ($env:USERNAME) { return $env:USERNAME }
            return 'Current User'
        }
        'HKLM' { return 'All Users' }
        'HKU'  { return 'User' }
    }

    if ($RowType -eq 'DriverService') { return 'SYSTEM' }
    if ($SourceGroup -match 'Winlogon') { return 'All Users' }
    if ($Source -match 'User Startup') {
        if ($env:USERNAME) { return $env:USERNAME }
        return 'Current User'
    }
    return 'All Users'
}

function Get-EntryRisk {
    param(
        [string]$Publisher,
        [string]$FilePath,
        [bool]$IsSigned,
        [bool]$IsCritical
    )

    $score = 50
    if ($IsSigned) { $score += 25 } else { $score -= 10 }
    if ($Publisher -match 'Microsoft') { $score += 15 }
    if ($FilePath -match '\\Windows\\System32\\') { $score += 10 }
    if ($FilePath -match 'Temp|AppData\\Local\\Temp|\\Downloads\\') { $score -= 20 }
    if ($IsCritical) { $score -= 10 }

    if ($score -gt 100) { $score = 100 }
    if ($score -lt 0) { $score = 0 }

    $band = 'Caution'
    if ($score -ge 70) { $band = 'Safe' }
    elseif ($score -lt 40) { $band = 'Warning' }

    return [PSCustomObject]@{
        Score = $score
        Band  = $band
    }
}

function Get-ServiceRiskPathRegex {
    return '(?i)(\\appdata\\(local\\)?temp\\|\\windows\\temp\\|\\users\\public\\|\\downloads\\|\\desktop\\|\\documents\\|\\programdata\\vendorcache\\)'
}

function Test-ServiceImageUsesLauncherBinary {
    param([string]$ImagePath)

    if ([string]::IsNullOrWhiteSpace($ImagePath)) { return $false }

    $parsed = Parse-StartupCommandLine -Command $ImagePath
    $exeName = [IO.Path]::GetFileName((Expand-WindowsImagePath -Path $parsed.ExecutablePath)).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($exeName)) { return $false }

    return $exeName -in @(
        'cmd.exe', 'powershell.exe', 'pwsh.exe', 'wscript.exe', 'cscript.exe',
        'mshta.exe', 'rundll32.exe', 'regsvr32.exe', 'bitsadmin.exe', 'ftp.exe'
    )
}

function Test-ServiceIsWindowsServiceHost {
    param(
        [string]$ImagePath,
        [string]$ResolvedPath
    )

    foreach ($candidate in @($ResolvedPath, $ImagePath)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $expanded = Expand-WindowsImagePath -Path $candidate
        if ($expanded -match '(?i)\\system32\\svchost\.exe(\s|$)') { return $true }
        if ($expanded -match '(?i)\\system32\\services\.exe(\s|$)') { return $true }
    }

    return $false
}

function Test-ServiceSuspicious {
    param(
        [string]$ServiceName,
        [string]$DisplayName,
        [string]$ImagePath,
        [string]$ResolvedPath,
        [bool]$TargetExists,
        [string]$Publisher,
        [bool]$IsSigned,
        [string]$RiskBand,
        [bool]$HasAnalysisWarning,
        [string]$StartupType = ''
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
    $name = [string]$ServiceName
    $display = [string]$DisplayName
    $pathLower = [string]$ImagePath.ToLowerInvariant()
    $resolvedLower = [string]$ResolvedPath.ToLowerInvariant()
    $riskRegex = Get-ServiceRiskPathRegex

    if ($name -match '(?i)CDEBENCHX?') {
        $reasons.Add('bench lab service tag') | Out-Null
    }

    foreach ($remote in @('AnyDesk', 'TeamViewer', 'UltraViewer', 'RustDesk', 'ScreenConnect', 'Splashtop', 'LogMeIn', 'GoToAssist')) {
        if ($name -match [regex]::Escape($remote)) {
            $reasons.Add("known remote-access service: $remote") | Out-Null
            break
        }
    }

    if (Test-ServiceImageUsesLauncherBinary -ImagePath $ImagePath) {
        $reasons.Add('launcher service binary') | Out-Null
    }

    if (-not (Test-ServiceIsWindowsServiceHost -ImagePath $ImagePath -ResolvedPath $ResolvedPath)) {
        if (-not $TargetExists -and -not [string]::IsNullOrWhiteSpace($ImagePath)) {
            if ($ImagePath -match '\.exe(\s|$)|\.dll(\s|$)|\.sys(\s|$)' -or $ImagePath -match '^[A-Za-z]:\\') {
                $reasons.Add('service image missing') | Out-Null
            }
        }

        if (($resolvedLower -match $riskRegex) -or ($pathLower -match $riskRegex)) {
            $reasons.Add('risky service path') | Out-Null
        }

        if (-not $IsSigned -and $resolvedLower -and
            $resolvedLower -notmatch '\\windows\\' -and
            $resolvedLower -notmatch '\\program files') {
            $reasons.Add('unsigned non-standard path') | Out-Null
        }
    }

    if ($name -cmatch '^[0-9a-fA-F]{8,}$' -or $name -cmatch '^[A-Z0-9]{16,}$') {
        $reasons.Add('opaque service name') | Out-Null
    }

    if ($RiskBand -eq 'Warning') {
        $reasons.Add("risk:$RiskBand") | Out-Null
    }

    if ($HasAnalysisWarning -and $reasons.Count -eq 0) {
        $reasons.Add('file analysis warning') | Out-Null
    }

    if ($display -match '(?i)windows|microsoft|defender|update|security' -and
        (($resolvedLower -match $riskRegex) -or ($pathLower -match $riskRegex) -or (Test-ServiceImageUsesLauncherBinary -ImagePath $ImagePath))) {
        $reasons.Add('display name mimics Windows component') | Out-Null
    }

    if ($StartupType -eq 'Automatic' -and $reasons.Count -gt 0) {
        # Keep reason list; auto-start elevates review priority in the UI only.
    }

    return [PSCustomObject]@{
        IsSuspicious = ($reasons.Count -gt 0)
        Reasons      = @($reasons | Select-Object -Unique)
        Summary      = if ($reasons.Count -gt 0) { ($reasons | Select-Object -Unique) -join '; ' } else { '' }
    }
}

function Get-ProtectedWindowsServiceNames {
    return @(
        'WinDefend', 'wuauserv', 'BITS', 'CryptSvc', 'Dnscache', 'Dhcp', 'EventLog', 'LSM',
        'LanmanServer', 'LanmanWorkstation', 'mpssvc', 'PlugPlay', 'Power', 'ProfSvc',
        'RpcSs', 'SamSs', 'Schedule', 'SENS', 'ShellHWDetection', 'Spooler', 'StateRepository',
        'StorSvc', 'SystemEventsBroker', 'Themes', 'TrkWks', 'TrustedInstaller', 'UserManager',
        'Wcmsvc', 'WdiSystemHost', 'Winmgmt', 'WpnService', 'cbdhsvc', 'CDPSvc', 'BFE', 'nsi'
    )
}

function Test-ServiceDeletionSupported {
    param(
        [string]$ServiceName,
        [string]$ImagePath,
        [string]$ResolvedPath,
        [string]$Publisher,
        [bool]$IsSigned,
        [bool]$IsSuspicious,
        [string]$ServiceType = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($env:OFFLINE_WINDOWS_ROOT)) {
        return [PSCustomObject]@{
            Supported = $false
            Detail    = 'Service delete is not supported while an offline Windows install is attached.'
        }
    }

    $typeLower = [string]$ServiceType.ToLowerInvariant()
    if ($typeLower -match 'kernel|file system|filesystem|driver') {
        return [PSCustomObject]@{
            Supported = $false
            Detail    = 'Kernel/driver services must be managed from the Drivers tab.'
        }
    }

    if (Test-ServiceIsWindowsServiceHost -ImagePath $ImagePath -ResolvedPath $ResolvedPath) {
        return [PSCustomObject]@{
            Supported = $false
            Detail    = 'Protected Windows service host (svchost.exe / services.exe).'
        }
    }

    foreach ($protected in @(Get-ProtectedWindowsServiceNames)) {
        if ([string]$ServiceName -ieq $protected) {
            return [PSCustomObject]@{
                Supported = $false
                Detail    = "Protected Windows service: $protected"
            }
        }
    }

    if ($IsSuspicious) {
        return [PSCustomObject]@{ Supported = $true; Detail = '' }
    }

    $resolvedLower = [string]$ResolvedPath.ToLowerInvariant()
    if ($resolvedLower -match '\\windows\\') {
        return [PSCustomObject]@{
            Supported = $false
            Detail    = 'Service binary is under the Windows folder.'
        }
    }

    if ($IsSigned -and [string]$Publisher -match 'Microsoft') {
        return [PSCustomObject]@{
            Supported = $false
            Detail    = 'Signed Microsoft service (not flagged suspicious).'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($resolvedLower)) {
        return [PSCustomObject]@{ Supported = $true; Detail = '' }
    }

    if (Test-ServiceImageUsesLauncherBinary -ImagePath $ImagePath) {
        return [PSCustomObject]@{ Supported = $true; Detail = '' }
    }

    return [PSCustomObject]@{
        Supported = $false
        Detail    = 'Only unprotected third-party or suspicious services can be deleted here.'
    }
}

function Get-ServiceRiskAssessment {
    param(
        [string]$ServiceName,
        [string]$DisplayName,
        [string]$ImagePath,
        [string]$StartupType = '',
        [string]$ServiceType = ''
    )

    $sigInfo = Get-FileSignatureInfo -FilePath $ImagePath
    $analysis = Get-FileAnalysisInfo -FilePath $ImagePath
    $target = Resolve-StartupTarget -Command $ImagePath
    $resolvedPath = [string]$target.ResolvedPath
    $targetExists = [bool]$target.Exists

    $publisher = ''
    if ($targetExists -and -not [string]::IsNullOrWhiteSpace($resolvedPath)) {
        try {
            $publisher = (Get-Item -LiteralPath $resolvedPath -ErrorAction Stop).VersionInfo.CompanyName
        } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($publisher) -and
        -not [string]::IsNullOrWhiteSpace($sigInfo.SignedDisplay) -and
        $sigInfo.SignedDisplay -notin @('N/A', 'Not found', 'Unsigned', 'Unknown')) {
        $publisher = [string]$sigInfo.SignedDisplay
    }

    $riskPath = if ($targetExists -and $resolvedPath) { $resolvedPath } else { $ImagePath }
    $risk = Get-EntryRisk -Publisher $publisher -FilePath $riskPath -IsSigned ([bool]$sigInfo.IsSigned) -IsCritical:$false
    $riskLevel = [string]$risk.Band
    if ($analysis.HasWarning -and $riskLevel -eq 'Safe') {
        $riskLevel = if ($analysis.Level -eq 'Warning') { 'Warning' } else { 'Caution' }
    }

    $suspicion = Test-ServiceSuspicious `
        -ServiceName $ServiceName `
        -DisplayName $DisplayName `
        -ImagePath $ImagePath `
        -ResolvedPath $resolvedPath `
        -TargetExists $targetExists `
        -Publisher $publisher `
        -IsSigned ([bool]$sigInfo.IsSigned) `
        -RiskBand $riskLevel `
        -HasAnalysisWarning ([bool]$analysis.HasWarning) `
        -StartupType $StartupType

    if ($suspicion.IsSuspicious -and $riskLevel -eq 'Safe') {
        $riskLevel = 'Caution'
    }

    $deleteSupport = Test-ServiceDeletionSupported `
        -ServiceName $ServiceName `
        -ImagePath $ImagePath `
        -ResolvedPath $resolvedPath `
        -Publisher $publisher `
        -IsSigned ([bool]$sigInfo.IsSigned) `
        -IsSuspicious ([bool]$suspicion.IsSuspicious) `
        -ServiceType $ServiceType

    return [PSCustomObject]@{
        Publisher          = if ($publisher) { $publisher } else { 'Unknown' }
        RiskLevel          = $riskLevel
        ReputationScore    = $risk.Score
        ReputationBand     = $risk.Band
        IsSuspicious       = [bool]$suspicion.IsSuspicious
        SuspicionSummary   = [string]$suspicion.Summary
        SupportsDelete     = [bool]$deleteSupport.Supported
        DeletionBlockDetail = [string]$deleteSupport.Detail
        SignedBy           = $sigInfo.SignedBy
        SignedDisplay      = $sigInfo.SignedDisplay
        SignatureStatus    = $sigInfo.SignatureStatus
        IsSigned           = [bool]$sigInfo.IsSigned
        AnalysisLevel      = $analysis.Level
        AnalysisDetail     = $analysis.Detail
        HasAnalysisWarning = [bool]$analysis.HasWarning
        ResolvedPath       = $resolvedPath
    }
}

function Test-PostOpStartupSuspicious {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$SourceGroup,
        [string]$ResolvedPath,
        [string]$Publisher,
        [bool]$IsSigned,
        [string]$RiskBand,
        [bool]$IsRunOnce,
        [bool]$TargetExists,
        [string]$EntryType = '',
        [bool]$IsWinlogonDeviated = $false,
        [string]$WinlogonDeviationReason = ''
    )

    $reasons = [System.Collections.Generic.List[string]]::new()

    if ($EntryType -eq 'Winlogon' -and $IsWinlogonDeviated) {
        $detail = if ([string]::IsNullOrWhiteSpace($WinlogonDeviationReason)) { 'value deviates from Windows default' } else { $WinlogonDeviationReason }
        $reasons.Add("winlogon: $detail") | Out-Null
    }

    if ($IsRunOnce) {
        $reasons.Add('RunOnce key') | Out-Null
    }

    # Trusted MSIX package identity: WindowsApps EXE may be ACL-inaccessible — not a missing target.
    $msixPackageTrusted = ($EntryType -eq 'MsixStartupTask' -and $IsSigned)
    # Non-deviant Winlogon Shell/Userinit is Windows plumbing, not an unsigned 3rd-party binary.
    $winlogonTrustedDefault = ($EntryType -eq 'Winlogon' -and -not $IsWinlogonDeviated)

    if (-not $TargetExists -and -not $msixPackageTrusted) {
        if (-not [string]::IsNullOrWhiteSpace($ResolvedPath)) {
            $reasons.Add('target missing') | Out-Null
        } else {
            $reasons.Add('unresolved target') | Out-Null
        }
    }

    if ($RiskBand -eq 'Warning') {
        $reasons.Add("risk:$RiskBand") | Out-Null
    }
    if ($ResolvedPath -match '\\Temp\\|\\Downloads\\|AppData\\Local\\Temp') {
        $reasons.Add('risky path') | Out-Null
    }
    if (-not $IsSigned -and -not $winlogonTrustedDefault -and $ResolvedPath -and $ResolvedPath -notmatch '\\Windows\\') {
        $reasons.Add('unsigned') | Out-Null
    }
    if ($Name -cmatch '^[0-9a-fA-F]{8,}$' -or $Name -cmatch '^[A-Z0-9]{16,}$') {
        $reasons.Add('opaque name') | Out-Null
    }

    return [PSCustomObject]@{
        IsSuspicious = ($reasons.Count -gt 0)
        Reasons      = @($reasons)
    }
}

function Get-PostOpStartupFolderContexts {
    $contexts = [System.Collections.Generic.List[object]]::new()
    $offlineRoot = $env:OFFLINE_WINDOWS_ROOT
    if ($offlineRoot) { $offlineRoot = $offlineRoot.TrimEnd('\') }

    if ($offlineRoot) {
        $userProfiles = Get-ChildItem "$offlineRoot\Users" -Directory -ErrorAction SilentlyContinue
        foreach ($userProfile in $userProfiles) {
            $contexts.Add([PSCustomObject]@{
                ActivePath = "$($userProfile.FullName)\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
                Source     = "User Startup ($($userProfile.Name))"
            }) | Out-Null
        }
        $contexts.Add([PSCustomObject]@{
            ActivePath = "$offlineRoot\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
            Source     = 'All Users Startup'
        }) | Out-Null
    } else {
        $userStartup = [System.Environment]::GetFolderPath('Startup')
        $commonStartup = [System.Environment]::GetFolderPath('CommonStartup')
        if ($userStartup) {
            $contexts.Add([PSCustomObject]@{ ActivePath = $userStartup; Source = 'User Startup' }) | Out-Null
        }
        if ($commonStartup) {
            $contexts.Add([PSCustomObject]@{ ActivePath = $commonStartup; Source = 'All Users Startup' }) | Out-Null
        }
    }

    return @($contexts)
}

function Get-StandardStartupRunKeyDefinitions {
    $runKeys = [System.Collections.Generic.List[object]]::new()

    $add = {
        param($Hive, $Key, $SourceGroup)
        $registryPath = "$Hive\$Key"
        $runKeys.Add([PSCustomObject]@{
            Hive         = $Hive
            Key          = $Key
            SourceGroup  = $SourceGroup
            RegistryPath = $registryPath
        }) | Out-Null
    }

    & $add 'HKLM' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run' 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    & $add 'HKLM' 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    & $add 'HKCU' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run' 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    & $add 'HKLM' 'SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    & $add 'HKCU' 'SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    & $add 'HKLM' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run' 'HKLM\Policies\Explorer\Run (GPO)'
    & $add 'HKCU' 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run' 'HKCU\Policies\Explorer\Run (GPO)'

    if (Test-OfflineRegistrySessionActive) {
        & $add 'HKLM' 'Offline_SOFTWARE\Microsoft\Windows\CurrentVersion\Run' 'HKLM\Offline_SOFTWARE\...\Run'
        & $add 'HKLM' 'Offline_SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run' 'HKLM\Offline_SOFTWARE\...\Run (WOW64)'
        & $add 'HKLM' 'Offline_SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'HKLM\Offline_SOFTWARE\...\RunOnce'

        try {
            $offlineUserHives = Get-ChildItem -Path 'HKLM:\' -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.PSChildName -like 'Offline_*' -and
                    $_.PSChildName -notlike 'Offline_SOFTWARE*' -and
                    $_.PSChildName -notlike 'Offline_SYSTEM*' -and
                    $_.PSChildName -notlike 'Offline_SAM*'
                }
            foreach ($hive in $offlineUserHives) {
                $hiveName = $hive.PSChildName
                & $add 'HKLM' "$hiveName\Software\Microsoft\Windows\CurrentVersion\Run" "$hiveName\...\Run"
                & $add 'HKLM' "$hiveName\Software\Microsoft\Windows\CurrentVersion\RunOnce" "$hiveName\...\RunOnce"
            }
        } catch { }
    }

    return @($runKeys)
}

function Get-PostOpStartupEntries {
    $entries = [System.Collections.Generic.List[object]]::new()

    $runKeys = @(Get-StandardStartupRunKeyDefinitions)

    foreach ($k in $runKeys) {
        $regPath = "$($k.Hive):\$($k.Key)"
        $isRunOnce = $k.Key -like '*RunOnce*'
        if (-not (Test-Path $regPath -ErrorAction SilentlyContinue)) { continue }

        $props = Get-ItemProperty $regPath -ErrorAction SilentlyContinue
        if (-not $props) { continue }

        $props.PSObject.Properties |
            Where-Object { $_.Name -notlike 'PS*' } |
            ForEach-Object {
                $command = [string]$_.Value
                $target = Resolve-StartupTarget -Command $command
                $resolved = $target.ResolvedPath
                $publisher = ''
                $targetExists = $target.Exists
                if ($targetExists) {
                    try {
                        $publisher = (Get-Item -LiteralPath $resolved -ErrorAction SilentlyContinue).VersionInfo.CompanyName
                    } catch { }
                }
                $sigInfo = Get-FileSignatureInfo -FilePath $command
                $isSigned = $sigInfo.IsSigned
                $risk = Get-EntryRisk -Publisher $publisher -FilePath $resolved -IsSigned $isSigned -IsCritical:$false
                $entryType = if ($k.SourceGroup -match '\(GPO\)') { 'GpoRun' } else { 'Registry' }
                $entries.Add([PSCustomObject]@{
                    Name         = $_.Name
                    SourceGroup  = $k.SourceGroup
                    Command      = $command
                    ResolvedPath = $resolved
                    Publisher    = $publisher
                    IsSigned     = $isSigned
                    RiskBand     = $risk.Band
                    IsRunOnce    = $isRunOnce
                    TargetExists = $targetExists
                    EntryType    = $entryType
                }) | Out-Null
            }
    }

    foreach ($folderContext in (Get-PostOpStartupFolderContexts)) {
        if (-not (Test-Path $folderContext.ActivePath)) { continue }
        Get-ChildItem -LiteralPath $folderContext.ActivePath -File -ErrorAction SilentlyContinue | ForEach-Object {
            $target = Resolve-StartupTarget -Command $_.FullName
            $resolved = $target.ResolvedPath
            $sigInfo = Get-FileSignatureInfo -FilePath $_.FullName
            $risk = Get-EntryRisk -Publisher '' -FilePath $resolved -IsSigned $sigInfo.IsSigned -IsCritical:$false
            $entries.Add([PSCustomObject]@{
                Name         = $_.Name
                SourceGroup  = $folderContext.Source
                Command      = $_.FullName
                ResolvedPath = $resolved
                Publisher    = ''
                IsSigned     = $sigInfo.IsSigned
                RiskBand     = $risk.Band
                IsRunOnce    = $false
                TargetExists = $target.Exists
                EntryType    = 'Folder'
            }) | Out-Null
        }
    }

    $winlogonContext = Get-WinlogonRegistryContext
    if (Test-Path -LiteralPath $winlogonContext.PsPath -ErrorAction SilentlyContinue) {
        foreach ($name in @('Userinit', 'Shell')) {
            $valueText = Get-WinlogonRegistryValueText -Path $winlogonContext.PsPath -Name $name
            $deviation = Test-WinlogonValueDeviation -ValueName $name -CurrentValue $valueText
            $displayValue = if ([string]::IsNullOrWhiteSpace($valueText)) { '(missing or empty)' } else { $valueText }

            $resolvedPath = $displayValue
            $publisher = ''
            $isSigned = $false
            $targetExists = -not [string]::IsNullOrWhiteSpace($valueText)

            if (-not [string]::IsNullOrWhiteSpace($valueText)) {
                $probeCommand = $valueText.Trim()
                if ($name -eq 'Userinit') {
                    $probeCommand = ($probeCommand -split ',')[0].Trim().Trim('"')
                }

                # Default Shell is a bare name; resolve to %SystemRoot%\explorer.exe for signing.
                if ($name -eq 'Shell' -and ($probeCommand -ieq 'explorer.exe')) {
                    if (Test-OfflineRegistrySessionActive) {
                        $driveRoot = Get-WinlogonEvaluationSystemRoot
                        $probeCommand = Join-Path $driveRoot 'Windows\explorer.exe'
                    } else {
                        $probeCommand = Join-Path $env:SystemRoot 'explorer.exe'
                    }
                }

                $target = Resolve-StartupTarget -Command $probeCommand
                if ($target.Exists -and -not [string]::IsNullOrWhiteSpace($target.ResolvedPath)) {
                    $resolvedPath = [string]$target.ResolvedPath
                    $targetExists = $true
                    $sigInfo = Get-FileSignatureInfo -FilePath $resolvedPath
                    $isSigned = [bool]$sigInfo.IsSigned
                    try {
                        $publisher = [string](Get-Item -LiteralPath $resolvedPath -ErrorAction SilentlyContinue).VersionInfo.CompanyName
                    } catch { }
                    if ([string]::IsNullOrWhiteSpace($publisher) -and
                        -not [string]::IsNullOrWhiteSpace($sigInfo.SignedDisplay) -and
                        $sigInfo.SignedDisplay -notin @('N/A', 'Not found', 'Unsigned', 'Unknown')) {
                        $publisher = [string]$sigInfo.SignedDisplay
                    }
                } elseif (-not $deviation.IsDeviated) {
                    # Trusted Windows default even when bare-name resolution is quirky.
                    $targetExists = $true
                    $isSigned = $true
                    $publisher = 'Microsoft Corporation'
                    if ($name -eq 'Shell') {
                        if (Test-OfflineRegistrySessionActive) {
                            $driveRoot = Get-WinlogonEvaluationSystemRoot
                            $resolvedPath = Join-Path $driveRoot 'Windows\explorer.exe'
                        } else {
                            $resolvedPath = Join-Path $env:SystemRoot 'explorer.exe'
                        }
                    }
                }
            }

            # Non-deviant Winlogon defaults are Windows plumbing for audit purposes.
            if (-not $deviation.IsDeviated) {
                $isSigned = $true
                if ([string]::IsNullOrWhiteSpace($publisher)) {
                    $publisher = 'Microsoft Corporation'
                }
            }

            $entries.Add([PSCustomObject]@{
                Name                    = $name
                SourceGroup             = $winlogonContext.SourceGroup
                Command                 = $displayValue
                ResolvedPath            = $resolvedPath
                Publisher               = $publisher
                IsSigned                = $isSigned
                RiskBand                = if ($deviation.IsDeviated) { 'Warning' } else { 'Safe' }
                IsRunOnce               = $false
                TargetExists            = $targetExists
                EntryType               = 'Winlogon'
                IsDeviated              = [bool]$deviation.IsDeviated
                DeviationReason         = [string]$deviation.Reason
            }) | Out-Null
        }
    }

    if (-not (Test-OfflineRegistrySessionActive)) {
        $msixScript = Join-Path $PSScriptRoot 'MsixStartup.ps1'
        $taskScript = Join-Path $PSScriptRoot 'StartupScheduledTask.ps1'
        if (Test-Path -LiteralPath $msixScript) { . $msixScript }
        if (Test-Path -LiteralPath $taskScript) { . $taskScript }

        foreach ($row in @(Get-MsixStartupTaskRows)) {
            $command = [string]$row.FilePath
            $packageFamily = [string]$row.ServiceName
            $taskId = [string]$row.MsixTaskId
            $publisher = [string]$row.Publisher
            $resolved = Resolve-MsixStartupExecutablePath -PackageFamilyName $packageFamily -TaskId $taskId
            $resolvedPath = if ($resolved.Exists -and $resolved.ResolvedPath) {
                $resolved.ResolvedPath
            } elseif ($resolved.ResolvedPath) {
                $resolved.ResolvedPath
            } else {
                $command
            }
            $sigInfo = Get-MsixStartupSignatureInfo -PackageFamilyName $packageFamily -TaskId $taskId -Publisher $publisher
            $isSigned = [bool]$sigInfo.IsSigned
            # Package publisher / known install: treat ACL-locked WindowsApps paths as present for audit.
            $targetExists = [bool]$resolved.Exists
            if (-not $targetExists -and $isSigned -and -not [string]::IsNullOrWhiteSpace($resolvedPath)) {
                $targetExists = $true
            }
            $risk = Get-EntryRisk -Publisher $publisher -FilePath $resolvedPath -IsSigned $isSigned -IsCritical:$false
            $entries.Add([PSCustomObject]@{
                Name         = [string]$row.Name
                SourceGroup  = 'MSIX Startup Task'
                Command      = $command
                ResolvedPath = $resolvedPath
                Publisher    = $publisher
                IsSigned     = $isSigned
                RiskBand     = $risk.Band
                IsRunOnce    = $false
                TargetExists = $targetExists
                EntryType    = 'MsixStartupTask'
            }) | Out-Null
        }

        foreach ($row in @(Get-StartupScheduledTaskRows -IncludeWindowsScheduledTasks:$false)) {
            $command = [string]$row.FilePath
            $analysisPath = if (-not [string]::IsNullOrWhiteSpace([string]$row.AnalysisFilePath)) {
                [string]$row.AnalysisFilePath
            } else {
                ''
            }
            $actionKind = if ($row.ContainsKey('TaskActionKind')) { [string]$row.TaskActionKind } else { '' }
            $comClassId = [string]$row.Clsid

            if ([string]::IsNullOrWhiteSpace($analysisPath) -and $actionKind -eq 'Com' -and -not [string]::IsNullOrWhiteSpace($comClassId)) {
                $comResolved = Resolve-ComHandlerServerPath -ClassId $comClassId
                if ($comResolved.Exists) {
                    $analysisPath = [string]$comResolved.ServerPath
                }
            }

            if ([string]::IsNullOrWhiteSpace($analysisPath)) {
                $analysisPath = $command
            }

            # Prefer the task Execute / COM server path for signature checks; fall back to the full command line.
            $target = Resolve-StartupTarget -Command $analysisPath
            if (-not $target.Exists -and -not [string]::IsNullOrWhiteSpace($command) -and $command -ne $analysisPath) {
                $target = Resolve-StartupTarget -Command $command
            }

            $resolved = [string]$target.ResolvedPath
            $sigProbe = if ($target.Exists -and -not [string]::IsNullOrWhiteSpace($resolved)) {
                $resolved
            } else {
                $analysisPath
            }

            $isWindowsPlumbing = Test-IsWindowsPlumbingScheduledTaskPath -TaskPath ([string]$row.ActionStatePayload)
            $isComOrNone = $actionKind -in @('Com', 'None') -or $command -match '\(COM\b'

            if (-not $target.Exists -and $isComOrNone -and $isWindowsPlumbing) {
                $isSigned = $true
                $publisher = 'Microsoft Corporation'
                $risk = Get-EntryRisk -Publisher $publisher -FilePath 'C:\Windows\System32\' -IsSigned $true -IsCritical:$true
                $entries.Add([PSCustomObject]@{
                    Name         = [string]$row.Name
                    SourceGroup  = 'Scheduled Task (logon/boot)'
                    Command      = $command
                    ResolvedPath = if (-not [string]::IsNullOrWhiteSpace($comClassId)) { "COM $comClassId" } else { $command }
                    Publisher    = $publisher
                    IsSigned     = $isSigned
                    RiskBand     = 'Safe'
                    IsRunOnce    = $false
                    TargetExists = $true
                    EntryType    = 'ScheduledTask'
                }) | Out-Null
                continue
            }

            $sigInfo = Get-FileSignatureInfo -FilePath $sigProbe
            $isSigned = [bool]$sigInfo.IsSigned

            $publisher = ''
            if ($target.Exists -and -not [string]::IsNullOrWhiteSpace($resolved)) {
                try {
                    $publisher = [string](Get-Item -LiteralPath $resolved -ErrorAction SilentlyContinue).VersionInfo.CompanyName
                } catch { }
            }
            if ([string]::IsNullOrWhiteSpace($publisher) -and
                -not [string]::IsNullOrWhiteSpace($sigInfo.SignedDisplay) -and
                $sigInfo.SignedDisplay -notin @('N/A', 'Not found', 'Unsigned', 'Unknown', 'Hash mismatch', 'N/A (COM)', 'Windows COM')) {
                $publisher = [string]$sigInfo.SignedDisplay
            }

            $risk = Get-EntryRisk -Publisher $publisher -FilePath $resolved -IsSigned $isSigned -IsCritical:$false
            $entries.Add([PSCustomObject]@{
                Name         = [string]$row.Name
                SourceGroup  = 'Scheduled Task (logon/boot)'
                Command      = $command
                ResolvedPath = if (-not [string]::IsNullOrWhiteSpace($resolved)) { $resolved } else { $command }
                Publisher    = $publisher
                IsSigned     = $isSigned
                RiskBand     = $risk.Band
                IsRunOnce    = $false
                TargetExists = [bool]$target.Exists
                EntryType    = 'ScheduledTask'
            }) | Out-Null
        }
    }

    return @($entries)
}

function Get-WinlogonRegistryContext {
    if (Test-OfflineRegistrySessionActive) {
        return [PSCustomObject]@{
            PsPath       = 'HKLM:\Offline_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
            RegistryPath = 'HKLM\Offline_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
            SourceGroup  = 'HKLM\Offline_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
            SubKeyPath   = 'Offline_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        }
    }

    return [PSCustomObject]@{
        PsPath       = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        RegistryPath = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        SourceGroup  = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        SubKeyPath   = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    }
}

function Get-WinlogonRegistryValueText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    try {
        $raw = Get-ItemPropertyValue -Path $Path -Name $Name -ErrorAction Stop
        if ($null -eq $raw) {
            return ''
        }

        return [string]$raw
    } catch {
        return ''
    }
}

function Get-WinlogonDefaultValue {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Userinit', 'Shell')]
        [string]$ValueName
    )

    if ($ValueName -eq 'Userinit') {
        return '%SystemRoot%\system32\userinit.exe,'
    }

    return 'explorer.exe'
}

function Get-WinlogonRegistryValueKind {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Userinit', 'Shell')]
        [string]$ValueName
    )

    try {
        $ctx = Get-WinlogonRegistryContext
        $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Default)
        $key = $hive.OpenSubKey($ctx.SubKeyPath)
        if ($null -eq $key) {
            return $null
        }

        return [string]$key.GetValueKind($ValueName)
    } catch {
        return $null
    }
}

function Set-WinlogonRegistryProperty {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]
        [ValidateSet('Userinit', 'Shell')]
        [string]$ValueName,
        [Parameter(Mandatory)][string]$Value
    )

    if ($ValueName -eq 'Userinit') {
        Set-ItemProperty -Path $Path -Name $ValueName -Value $Value -Type ExpandString -ErrorAction Stop
        return
    }

    Set-ItemProperty -Path $Path -Name $ValueName -Value $Value -ErrorAction Stop
}

function Normalize-WinlogonDriveRoot {
    param([string]$Raw)

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return ''
    }

    $trimmed = $Raw.Trim().TrimEnd('\')
    if ($trimmed -match '^([A-Za-z]):') {
        return "$($matches[1]):"
    }

    return ''
}

function Get-WinlogonEvaluationSystemRoot {
    if (Test-OfflineRegistrySessionActive) {
        $fromOffline = Normalize-WinlogonDriveRoot -Raw $env:OFFLINE_WINDOWS_ROOT
        if ($fromOffline) {
            return $fromOffline
        }

        return 'C:'
    }

    return $env:SystemRoot
}

function Get-WinlogonEvaluationSystemRoots {
    $roots = [System.Collections.Generic.List[string]]::new()
    $primary = Get-WinlogonEvaluationSystemRoot
    if (-not [string]::IsNullOrWhiteSpace($primary)) {
        [void]$roots.Add($primary.TrimEnd('\'))
    }

    if (Test-OfflineRegistrySessionActive) {
        if (-not $roots.Contains('C:')) {
            [void]$roots.Add('C:')
        }
    }

    return @($roots)
}

function Expand-WinlogonRegistryValue {
    param(
        [string]$Value,
        [string]$SystemRoot = $(Get-WinlogonEvaluationSystemRoot)
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $text = [string]$Value
    if (-not [string]::IsNullOrWhiteSpace($SystemRoot)) {
        $text = [regex]::Replace($text, '%SystemRoot%', $SystemRoot.TrimEnd('\'), [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }

    return [Environment]::ExpandEnvironmentVariables($text).Trim()
}

function Test-WinlogonExpandedValuesEquivalent {
    param(
        [Parameter(Mandatory)][string]$CurrentValue,
        [Parameter(Mandatory)][string]$DefaultTemplate
    )

    $currentNorm = Expand-WinlogonRegistryValue -Value $CurrentValue
    foreach ($root in (Get-WinlogonEvaluationSystemRoots)) {
        $defaultNorm = Expand-WinlogonRegistryValue -Value $DefaultTemplate -SystemRoot $root
        if ($currentNorm.ToLowerInvariant() -eq $defaultNorm.ToLowerInvariant()) {
            return $true
        }
    }

    return $false
}

function Test-WinlogonSystemBinaryPath {
    param(
        [Parameter(Mandatory)][string]$PathFragment,
        [Parameter(Mandatory)][string]$RelativePathUnderWindows
    )

    $normalized = Normalize-WinlogonPath -Path (Expand-WinlogonRegistryValue -Value $PathFragment)
    $suffix = ($RelativePathUnderWindows -replace '/', '\').TrimStart('\').ToLowerInvariant()

    foreach ($root in (Get-WinlogonEvaluationSystemRoots)) {
        $expected = Normalize-WinlogonPath -Path "$root\Windows\$suffix"
        if ($normalized -eq $expected) {
            return $true
        }
    }

    if (Test-OfflineRegistrySessionActive) {
        $agnostic = "windows\$suffix"
        if ($normalized.EndsWith($agnostic, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Normalize-WinlogonPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    $candidate = [string]$Path
    $candidate = $candidate.Trim().Trim('"')
    $candidate = Expand-WinlogonRegistryValue -Value $candidate

    try {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $candidate = [System.IO.Path]::GetFullPath($candidate)
        }
    } catch { }

    return $candidate.ToLowerInvariant()
}

function Test-WinlogonValueDeviation {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Userinit', 'Shell')]
        [string]$ValueName,
        [Parameter(Mandatory)][string]$CurrentValue
    )

    $defaultValue = Get-WinlogonDefaultValue -ValueName $ValueName
    $trimmed = [string]$CurrentValue
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return [PSCustomObject]@{
            IsDeviated   = $true
            Reason       = 'value is missing or empty'
            DefaultValue = $defaultValue
        }
    }

    $trimmed = $trimmed.Trim()

    if ($ValueName -eq 'Shell') {
        if ($trimmed -ieq 'explorer.exe') {
            return [PSCustomObject]@{
                IsDeviated   = $false
                Reason       = ''
                DefaultValue = $defaultValue
            }
        }

        if (Test-WinlogonSystemBinaryPath -PathFragment $trimmed -RelativePathUnderWindows 'explorer.exe') {
            return [PSCustomObject]@{
                IsDeviated   = $false
                Reason       = ''
                DefaultValue = $defaultValue
            }
        }

        return [PSCustomObject]@{
            IsDeviated   = $true
            Reason       = 'shell is not explorer.exe'
            DefaultValue = $defaultValue
        }
    }

    if (Test-WinlogonExpandedValuesEquivalent -CurrentValue $trimmed -DefaultTemplate $defaultValue) {
        $valueKind = Get-WinlogonRegistryValueKind -ValueName 'Userinit'
        if ($valueKind -eq 'String' -and $trimmed -match '%[^%\s]+%') {
            return [PSCustomObject]@{
                IsDeviated   = $true
                Reason       = 'Userinit contains environment variables but is stored as REG_SZ; logon requires REG_EXPAND_SZ'
                DefaultValue = $defaultValue
            }
        }

        return [PSCustomObject]@{
            IsDeviated   = $false
            Reason       = ''
            DefaultValue = $defaultValue
        }
    }

    $parts = $trimmed -split ','
    $first = [string]$parts[0]
    $first = $first.Trim().Trim('"')

    if (-not (Test-WinlogonSystemBinaryPath -PathFragment $first -RelativePathUnderWindows 'System32\userinit.exe')) {
        return [PSCustomObject]@{
            IsDeviated   = $true
            Reason       = 'primary component is not system32\userinit.exe'
            DefaultValue = $defaultValue
        }
    }

    for ($i = 1; $i -lt $parts.Count; $i++) {
        $segment = [string]$parts[$i]
        $segment = $segment.Trim().Trim('"')
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }

        return [PSCustomObject]@{
            IsDeviated   = $true
            Reason       = "unexpected chained logon component: $segment"
            DefaultValue = $defaultValue
        }
    }

    return [PSCustomObject]@{
        IsDeviated   = $false
        Reason       = ''
        DefaultValue = $defaultValue
    }
}

function Get-WinlogonBackupDirectory {
    $dir = Join-Path $env:ProgramData 'CDE\WinlogonBackups'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    return $dir
}

function Get-WinlogonBackupFilePath {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Userinit', 'Shell')]
        [string]$ValueName
    )

    return Join-Path (Get-WinlogonBackupDirectory) ("{0}.json" -f $ValueName)
}

function Get-WinlogonBackupRecord {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Userinit', 'Shell')]
        [string]$ValueName
    )

    $path = Get-WinlogonBackupFilePath -ValueName $ValueName
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Test-WinlogonRegistryValuesEqual {
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )

    $leftNorm = Expand-WinlogonRegistryValue -Value $Left
    $rightNorm = Expand-WinlogonRegistryValue -Value $Right

    return ($leftNorm.ToLowerInvariant() -eq $rightNorm.ToLowerInvariant())
}

function Test-WinlogonValueMatchesDefault {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Userinit', 'Shell')]
        [string]$ValueName,
        [Parameter(Mandatory)][string]$CurrentValue
    )

    $defaultValue = Get-WinlogonDefaultValue -ValueName $ValueName
    return (Test-WinlogonRegistryValuesEqual -Left $CurrentValue -Right $defaultValue)
}

function Test-WinlogonUndoAvailable {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Userinit', 'Shell')]
        [string]$ValueName,
        [Parameter(Mandatory)][string]$CurrentValue
    )

    $backup = Get-WinlogonBackupRecord -ValueName $ValueName
    if ($null -eq $backup) {
        return $false
    }

    return (Test-WinlogonValueMatchesDefault -ValueName $ValueName -CurrentValue $CurrentValue)
}
