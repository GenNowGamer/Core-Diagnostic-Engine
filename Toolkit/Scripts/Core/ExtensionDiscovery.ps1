#Requires -Version 5.1
<#
.SYNOPSIS
    Legacy IE/COM extension resolution and installed browser extension discovery for Startup Manager.
#>

function Test-IsClsidString {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    $trimmed = $Text.Trim().TrimEnd('!')
    if ($trimmed -match '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') {
        return $true
    }

    return ($trimmed -match '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$')
}

function Normalize-ClsidString {
    param([string]$Clsid)

    $trimmed = [string]$Clsid
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return ''
    }

    $trimmed = $trimmed.Trim().TrimEnd('!')
    if ($trimmed.StartsWith('{')) {
        return $trimmed
    }

    return "{${trimmed}}"
}

function Expand-ExtensionModulePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    $expanded = [Environment]::ExpandEnvironmentVariables([string]$Path)
    if ($expanded -match '^\\SystemRoot\\') {
        $sysRoot = Get-StartupResolutionSystemRoot
        $expanded = $expanded -replace '^\\SystemRoot\\', "$sysRoot\"
    }

    if ($expanded.StartsWith('\??\')) {
        $expanded = $expanded.Substring(4)
    }

    return $expanded
}

function Resolve-ClsidModulePath {
    param([string]$Clsid)

    $norm = Normalize-ClsidString -Clsid $Clsid
    if ([string]::IsNullOrWhiteSpace($norm)) {
        return [PSCustomObject]@{
            Path   = ''
            Detail = 'Missing CLSID'
        }
    }

    $lookupRoots = @(
        'HKLM:\SOFTWARE\Classes\CLSID',
        'HKLM:\SOFTWARE\WOW6432Node\Classes\CLSID',
        'HKCU:\SOFTWARE\Classes\CLSID'
    )

    foreach ($root in $lookupRoots) {
        $serverKey = Join-Path $root "$norm\InprocServer32"
        if (-not (Test-Path -LiteralPath $serverKey)) {
            continue
        }

        try {
            $props = Get-ItemProperty -LiteralPath $serverKey -ErrorAction Stop
            $dll = [string]$props.'(default)'
            if ([string]::IsNullOrWhiteSpace($dll)) {
                continue
            }

            $dll = Expand-ExtensionModulePath -Path $dll
            if ([string]::IsNullOrWhiteSpace($dll)) {
                continue
            }

            if (Test-Path -LiteralPath $dll -PathType Leaf) {
                try {
                    $dll = (Get-Item -LiteralPath $dll -ErrorAction Stop).FullName
                } catch { }
            }

            return [PSCustomObject]@{
                Path   = $dll
                Detail = "Resolved via $norm"
            }
        } catch { }
    }

    return [PSCustomObject]@{
        Path   = ''
        Detail = "CLSID $norm is not registered to a module"
    }
}

function Resolve-LegacyExtensionReference {
    param(
        [string]$Reference,
        [string]$FallbackClsid = ''
    )

    $text = [string]$Reference
    if ([string]::IsNullOrWhiteSpace($text) -and -not [string]::IsNullOrWhiteSpace($FallbackClsid)) {
        $text = $FallbackClsid
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        return [PSCustomObject]@{
            Clsid            = ''
            ModulePath       = ''
            DisplayReference = ''
            Detail           = 'No extension reference'
        }
    }

    $trimmed = $text.Trim()
    if (Test-IsClsidString -Text $trimmed) {
        $clsid = Normalize-ClsidString -Clsid $trimmed
        $resolved = Resolve-ClsidModulePath -Clsid $clsid
        return [PSCustomObject]@{
            Clsid            = $clsid
            ModulePath       = [string]$resolved.Path
            DisplayReference = $clsid
            Detail           = [string]$resolved.Detail
        }
    }

    $expanded = Expand-ExtensionModulePath -Path $trimmed
    if (Test-Path -LiteralPath $expanded -PathType Leaf) {
        try {
            $expanded = (Get-Item -LiteralPath $expanded -ErrorAction Stop).FullName
        } catch { }
        return [PSCustomObject]@{
            Clsid            = ''
            ModulePath       = $expanded
            DisplayReference = $expanded
            Detail           = 'Direct module path'
        }
    }

    $target = Resolve-StartupTarget -Command $trimmed
    if ($target.Exists -and -not [string]::IsNullOrWhiteSpace($target.ResolvedPath)) {
        return [PSCustomObject]@{
            Clsid            = ''
            ModulePath       = [string]$target.ResolvedPath
            DisplayReference = [string]$target.ResolvedPath
            Detail           = if ([string]::IsNullOrWhiteSpace($target.Detail)) { 'Resolved executable path' } else { [string]$target.Detail }
        }
    }

    return [PSCustomObject]@{
        Clsid            = ''
        ModulePath       = ''
        DisplayReference = $trimmed
        Detail           = if ([string]::IsNullOrWhiteSpace($target.Detail)) { 'Registry reference without a resolvable module' } else { [string]$target.Detail }
    }
}

function Get-LegacyExtensionDisplayName {
    param(
        [string]$Clsid,
        [string]$RegistrySubKey = '',
        [string]$Fallback = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($RegistrySubKey) -and (Test-Path -LiteralPath $RegistrySubKey)) {
        try {
            $defaultName = (Get-ItemProperty -LiteralPath $RegistrySubKey -ErrorAction Stop).'(default)'
            if (-not [string]::IsNullOrWhiteSpace($defaultName)) {
                return [string]$defaultName
            }
        } catch { }
    }

    $norm = Normalize-ClsidString -Clsid $Clsid
    if (-not [string]::IsNullOrWhiteSpace($norm)) {
        foreach ($root in @('HKLM:\SOFTWARE\Classes\CLSID', 'HKLM:\SOFTWARE\WOW6432Node\Classes\CLSID')) {
            $clsidKey = Join-Path $root $norm
            if (-not (Test-Path -LiteralPath $clsidKey)) {
                continue
            }

            try {
                $defaultName = (Get-ItemProperty -LiteralPath $clsidKey -ErrorAction Stop).'(default)'
                if (-not [string]::IsNullOrWhiteSpace($defaultName)) {
                    return [string]$defaultName
                }
            } catch { }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Fallback)) {
        return $Fallback
    }

    if (-not [string]::IsNullOrWhiteSpace($norm)) {
        return $norm
    }

    return 'Unknown extension'
}

function Resolve-LocalizedExtensionManifestText {
    param(
        [string]$Text,
        [string]$VersionPath,
        [string]$DefaultLocale
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    if ($Text -notmatch '^__MSG_(.+?)__$') {
        return [string]$Text
    }

    $messageKey = $Matches[1]
    $localeCandidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($DefaultLocale)) {
        $localeCandidates.Add($DefaultLocale) | Out-Null
    }

    foreach ($fallbackLocale in @('en_US', 'en', 'en-GB')) {
        if (-not $localeCandidates.Contains($fallbackLocale)) {
            $localeCandidates.Add($fallbackLocale) | Out-Null
        }
    }

    foreach ($locale in $localeCandidates) {
        $messagesPath = Join-Path $VersionPath ("_locales\$locale\messages.json")
        if (-not (Test-Path -LiteralPath $messagesPath)) {
            continue
        }

        try {
            $messages = Get-Content -LiteralPath $messagesPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($messages.PSObject.Properties[$messageKey]) {
                $messageEntry = $messages.$messageKey
                if ($messageEntry -and $messageEntry.PSObject.Properties['message']) {
                    $resolved = [string]$messageEntry.message
                    if (-not [string]::IsNullOrWhiteSpace($resolved)) {
                        return $resolved
                    }
                }
            }
        } catch { }
    }

    return [string]$Text
}

function Find-BrowserExtensionNativeModule {
    param([string]$VersionPath)

    if ([string]::IsNullOrWhiteSpace($VersionPath) -or -not (Test-Path -LiteralPath $VersionPath)) {
        return ''
    }

    $preferred = @(
        (Join-Path $VersionPath 'background.dll'),
        (Join-Path $VersionPath 'native.dll'),
        (Join-Path $VersionPath 'plugin.dll')
    )

    foreach ($candidate in $preferred) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    $nativeFiles = @(Get-ChildItem -LiteralPath $VersionPath -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.dll', '.exe', '.node') } |
        Sort-Object Length -Descending)

    if ($nativeFiles.Count -gt 0) {
        return $nativeFiles[0].FullName
    }

    return ''
}

function Get-BrowserExtensionSignatureInfo {
    param([string]$AnalysisFilePath)

    if (-not [string]::IsNullOrWhiteSpace($AnalysisFilePath) -and (Test-Path -LiteralPath $AnalysisFilePath -PathType Leaf)) {
        if ($AnalysisFilePath.EndsWith('.xpi', [StringComparison]::OrdinalIgnoreCase)) {
            return [PSCustomObject]@{
                IsSigned         = $false
                SignedBy         = ''
                SignedDisplay    = 'N/A'
                SignatureStatus  = ''
                ResolutionDetail = 'Firefox extension package'
            }
        }

        return Get-FileSignatureInfo -FilePath $AnalysisFilePath
    }

    return [PSCustomObject]@{
        IsSigned         = $false
        SignedBy         = ''
        SignedDisplay    = 'N/A'
        SignatureStatus  = ''
        ResolutionDetail = 'Web extension package'
    }
}

function Get-BrowserExtensionAnalysisInfo {
    param(
        [string]$VersionPath,
        [string]$AnalysisFilePath
    )

    if (-not [string]::IsNullOrWhiteSpace($AnalysisFilePath) -and (Test-Path -LiteralPath $AnalysisFilePath -PathType Leaf)) {
        if ($AnalysisFilePath.EndsWith('.xpi', [StringComparison]::OrdinalIgnoreCase)) {
            return [PSCustomObject]@{
                Level      = 'OK'
                Detail     = 'Firefox extension package'
                HasWarning = $false
            }
        }

        return Get-FileAnalysisInfo -FilePath $AnalysisFilePath
    }

    $manifestPath = Join-Path $VersionPath 'manifest.json'
    if (Test-Path -LiteralPath $manifestPath) {
        return [PSCustomObject]@{
            Level      = 'OK'
            Detail     = 'Web extension (manifest present)'
            HasWarning = $false
        }
    }

    return [PSCustomObject]@{
        Level      = 'NA'
        Detail     = 'No manifest or native module'
        HasWarning = $false
    }
}

function Get-ExtensionScanUserRoots {
    $roots = [System.Collections.Generic.List[string]]::new()
    $offlineRoot = $env:OFFLINE_WINDOWS_ROOT
    if (-not [string]::IsNullOrWhiteSpace($offlineRoot)) {
        $offlineRoot = $offlineRoot.TrimEnd('\')
        $usersRoot = Join-Path $offlineRoot 'Users'
    } else {
        $usersRoot = 'C:\Users'
    }

    if (-not (Test-Path -LiteralPath $usersRoot)) {
        return @()
    }

    $excluded = @('Public', 'Default', 'Default User', 'All Users')
    foreach ($userDir in @(Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($excluded -contains $userDir.Name) {
            continue
        }

        $roots.Add($userDir.FullName) | Out-Null
    }

    return $roots.ToArray()
}

function Get-ChromiumBrowserDefinitions {
    return @(
        @{ Browser = 'Chrome'; RelativeUserData = 'AppData\Local\Google\Chrome\User Data' },
        @{ Browser = 'Chrome Beta'; RelativeUserData = 'AppData\Local\Google\Chrome Beta\User Data' },
        @{ Browser = 'Chrome Dev'; RelativeUserData = 'AppData\Local\Google\Chrome Dev\User Data' },
        @{ Browser = 'Chrome Canary'; RelativeUserData = 'AppData\Local\Google\Chrome SxS\User Data' },
        @{ Browser = 'Edge'; RelativeUserData = 'AppData\Local\Microsoft\Edge\User Data' },
        @{ Browser = 'Edge Beta'; RelativeUserData = 'AppData\Local\Microsoft\Edge Beta\User Data' },
        @{ Browser = 'Edge Dev'; RelativeUserData = 'AppData\Local\Microsoft\Edge Dev\User Data' },
        @{ Browser = 'Edge Canary'; RelativeUserData = 'AppData\Local\Microsoft\Edge SxS\User Data' },
        @{ Browser = 'Brave'; RelativeUserData = 'AppData\Local\BraveSoftware\Brave-Browser\User Data' },
        @{ Browser = 'Vivaldi'; RelativeUserData = 'AppData\Local\Vivaldi\User Data' },
        @{ Browser = 'Chromium'; RelativeUserData = 'AppData\Local\Chromium\User Data' },
        @{ Browser = 'Opera'; RelativeUserData = 'AppData\Roaming\Opera Software\Opera Stable'; OperaLayout = $true },
        @{ Browser = 'Opera GX'; RelativeUserData = 'AppData\Roaming\Opera Software\Opera GX Stable'; OperaLayout = $true }
    )
}

function Get-ChromiumProfileExtensionRoots {
    param(
        [string]$UserRoot,
        [hashtable]$BrowserDefinition
    )

    $userDataPath = Join-Path $UserRoot $BrowserDefinition.RelativeUserData
    if (-not (Test-Path -LiteralPath $userDataPath)) {
        return @()
    }

    $profiles = [System.Collections.Generic.List[object]]::new()
    if ($BrowserDefinition.OperaLayout) {
        $extensionsRoot = Join-Path $userDataPath 'Extensions'
        if (Test-Path -LiteralPath $extensionsRoot) {
            $profiles.Add([PSCustomObject]@{
                Browser        = [string]$BrowserDefinition.Browser
                Profile        = 'Default'
                ExtensionsRoot = $extensionsRoot
            }) | Out-Null
        }
        return $profiles.ToArray()
    }

    foreach ($profileDir in @(Get-ChildItem -LiteralPath $userDataPath -Directory -ErrorAction SilentlyContinue)) {
        if ($profileDir.Name -in @('SwReporter', 'Crashpad', 'GrShaderCache', 'ShaderCache', 'WidevineCdm', 'MEIPreload', 'RecoveryImproved')) {
            continue
        }

        $extensionsRoot = Join-Path $profileDir.FullName 'Extensions'
        if (Test-Path -LiteralPath $extensionsRoot) {
            $profiles.Add([PSCustomObject]@{
                Browser        = [string]$BrowserDefinition.Browser
                Profile        = $profileDir.Name
                ExtensionsRoot = $extensionsRoot
            }) | Out-Null
        }
    }

    return $profiles.ToArray()
}

function New-ChromiumExtensionDiscoveryRow {
    param(
        [string]$Browser,
        [string]$Profile,
        [string]$UserName,
        [string]$ExtensionId,
        [string]$VersionPath,
        [string]$ExtensionName,
        [string]$Version,
        [bool]$IsEnabled = $true
    )

    $nativeModule = Find-BrowserExtensionNativeModule -VersionPath $VersionPath
    $displayPath = if (-not [string]::IsNullOrWhiteSpace($nativeModule)) { $nativeModule } else { $VersionPath }
    $name = if (-not [string]::IsNullOrWhiteSpace($ExtensionName)) { $ExtensionName } else { $ExtensionId }
    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $name = "$name ($Version)"
    }

    return @{
        Category           = 'Extensions'
        RowType            = 'BrowserExtension'
        SourceGroup        = "$Browser Extensions"
        Name               = $name
        Publisher          = $Browser
        FilePath           = $displayPath
        AnalysisFilePath   = $nativeModule
        Source             = 'Profile'
        RegistryPath       = ''
        ValueName          = ''
        RegistryKey        = ''
        Clsid              = $ExtensionId
        RiskLevel          = 'Caution'
        IsSigned           = $false
        IsEnabled          = $IsEnabled
        User               = $UserName
        SupportsEnable     = $false
        SupportsDisable    = $false
        SupportsDelete     = $false
    }
}

function Get-ChromiumExtensionDiscoveryRows {
    param([string]$UserRoot)

    $userName = Split-Path $UserRoot -Leaf
    $rows = [System.Collections.Generic.List[object]]::new()

    foreach ($browser in Get-ChromiumBrowserDefinitions) {
        foreach ($profile in @(Get-ChromiumProfileExtensionRoots -UserRoot $UserRoot -BrowserDefinition $browser)) {
            $extensionFolders = @(Get-ChildItem -LiteralPath $profile.ExtensionsRoot -Directory -ErrorAction SilentlyContinue)
            foreach ($extensionFolder in $extensionFolders) {
                $extensionId = $extensionFolder.Name
                $versionFolders = @(Get-ChildItem -LiteralPath $extensionFolder.FullName -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
                if ($versionFolders.Count -eq 0) {
                    continue
                }

                $selectedVersion = $versionFolders[$versionFolders.Count - 1]
                $versionPath = $selectedVersion.FullName
                $manifestName = ''
                $defaultLocale = ''
                $manifestPath = Join-Path $versionPath 'manifest.json'
                if (Test-Path -LiteralPath $manifestPath) {
                    try {
                        $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                        if ($manifest.PSObject.Properties['default_locale']) {
                            $defaultLocale = [string]$manifest.default_locale
                        }
                        if ($manifest.PSObject.Properties['name']) {
                            $manifestName = Resolve-LocalizedExtensionManifestText -Text ([string]$manifest.name) -VersionPath $versionPath -DefaultLocale $defaultLocale
                        }
                    } catch { }
                }

                $rows.Add((New-ChromiumExtensionDiscoveryRow -Browser $profile.Browser -Profile $profile.Profile -UserName $userName -ExtensionId $extensionId -VersionPath $versionPath -ExtensionName $manifestName -Version $selectedVersion.Name)) | Out-Null
            }
        }
    }

    return $rows.ToArray()
}

function Convert-FileUriToPath {
    param([string]$Uri)

    if ([string]::IsNullOrWhiteSpace($Uri)) {
        return ''
    }

    try {
        if ($Uri.StartsWith('file:///')) {
            $path = [Uri]::UnescapeDataString($Uri.Substring(8))
            return $path.Replace('/', '\')
        }

        if ($Uri.StartsWith('file://')) {
            $path = [Uri]::UnescapeDataString($Uri.Substring(7))
            return $path.Replace('/', '\')
        }
    } catch { }

    return ''
}

function Get-FirefoxExtensionDiscoveryRows {
    param([string]$UserRoot)

    $userName = Split-Path $UserRoot -Leaf
    $rows = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    $profilesRoot = Join-Path $UserRoot 'AppData\Roaming\Mozilla\Firefox\Profiles'
    if (-not (Test-Path -LiteralPath $profilesRoot)) {
        return @()
    }

    foreach ($profileFolder in @(Get-ChildItem -LiteralPath $profilesRoot -Directory -ErrorAction SilentlyContinue)) {
        $profileName = $profileFolder.Name
        $profileDir = $profileFolder.FullName
        $extensionsJson = Join-Path $profileDir 'extensions.json'

        if (Test-Path -LiteralPath $extensionsJson) {
            try {
                $addonData = Get-Content -LiteralPath $extensionsJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ($addonData.PSObject.Properties['addons']) {
                    foreach ($addon in @($addonData.addons)) {
                        $addonId = ''
                        $addonName = ''
                        $addonVersion = ''
                        $addonPath = ''
                        $isEnabled = $true

                        if ($addon.PSObject.Properties['id']) { $addonId = [string]$addon.id }
                        if ($addon.PSObject.Properties['version']) { $addonVersion = [string]$addon.version }
                        if ($addon.PSObject.Properties['defaultLocale'] -and $addon.defaultLocale -and $addon.defaultLocale.PSObject.Properties['name']) {
                            $addonName = [string]$addon.defaultLocale.name
                        }
                        if ($addon.PSObject.Properties['userDisabled']) { $isEnabled = -not [bool]$addon.userDisabled }
                        if ($addon.PSObject.Properties['active']) { $isEnabled = [bool]$addon.active }
                        if ($addon.PSObject.Properties['rootURI']) { $addonPath = Convert-FileUriToPath -Uri ([string]$addon.rootURI) }

                        if ([string]::IsNullOrWhiteSpace($addonId)) {
                            continue
                        }

                        $dedupeKey = "$profileName|$addonId"
                        if (-not $seen.Add($dedupeKey)) {
                            continue
                        }

                        $analysisPath = ''
                        if (-not [string]::IsNullOrWhiteSpace($addonPath) -and (Test-Path -LiteralPath $addonPath)) {
                            if ((Get-Item -LiteralPath $addonPath).PSIsContainer) {
                                $analysisPath = Find-BrowserExtensionNativeModule -VersionPath $addonPath
                                if ([string]::IsNullOrWhiteSpace($analysisPath)) {
                                    $analysisPath = ''
                                }
                            } elseif ($addonPath.EndsWith('.xpi', [StringComparison]::OrdinalIgnoreCase)) {
                                $analysisPath = $addonPath
                            }
                        }

                        $displayPath = if (-not [string]::IsNullOrWhiteSpace($analysisPath)) { $analysisPath }
                            elseif (-not [string]::IsNullOrWhiteSpace($addonPath)) { $addonPath }
                            else { $extensionsJson }

                        $name = if (-not [string]::IsNullOrWhiteSpace($addonName)) { $addonName } else { $addonId }
                        if (-not [string]::IsNullOrWhiteSpace($addonVersion)) {
                            $name = "$name ($addonVersion)"
                        }

                        $rows.Add(@{
                            Category           = 'Extensions'
                            RowType            = 'BrowserExtension'
                            SourceGroup        = 'Firefox Extensions'
                            Name               = $name
                            Publisher          = 'Firefox'
                            FilePath           = $displayPath
                            AnalysisFilePath   = $analysisPath
                            Source             = 'Profile'
                            RegistryPath       = ''
                            ValueName          = ''
                            RegistryKey        = ''
                            Clsid              = $addonId
                            RiskLevel          = 'Caution'
                            IsSigned           = $false
                            IsEnabled          = $isEnabled
                            User               = $userName
                            SupportsEnable     = $false
                            SupportsDisable    = $false
                            SupportsDelete     = $false
                        }) | Out-Null
                    }
                }
            } catch { }
        }

        $legacyExtensionsDir = Join-Path $profileDir 'extensions'
        if (Test-Path -LiteralPath $legacyExtensionsDir) {
            foreach ($xpi in @(Get-ChildItem -LiteralPath $legacyExtensionsDir -File -Filter '*.xpi' -ErrorAction SilentlyContinue)) {
                $addonId = $xpi.BaseName
                $dedupeKey = "$profileName|$addonId"
                if (-not $seen.Add($dedupeKey)) {
                    continue
                }

                $rows.Add(@{
                    Category           = 'Extensions'
                    RowType            = 'BrowserExtension'
                    SourceGroup        = 'Firefox Extensions'
                    Name               = "$addonId (legacy XPI)"
                    Publisher          = 'Firefox'
                    FilePath           = $xpi.FullName
                    AnalysisFilePath   = $xpi.FullName
                    Source             = 'Profile'
                    RegistryPath       = ''
                    ValueName          = ''
                    RegistryKey        = ''
                    Clsid              = $addonId
                    RiskLevel          = 'Caution'
                    IsSigned           = $false
                    IsEnabled          = $true
                    User               = $userName
                    SupportsEnable     = $false
                    SupportsDisable    = $false
                    SupportsDelete     = $false
                }) | Out-Null
            }
        }
    }

    return $rows.ToArray()
}

function Get-LegacyIeExtensionDiscoveryRows {
    $rows = [System.Collections.Generic.List[object]]::new()
    $extensionKeys = @(
        @{ Hive = 'HKLM'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Browser Helper Objects'; Group = 'Browser Helper Objects' },
        @{ Hive = 'HKLM'; Key = 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\Browser Helper Objects'; Group = 'Browser Helper Objects' },
        @{ Hive = 'HKCU'; Key = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Browser Helper Objects'; Group = 'Browser Helper Objects' },
        @{ Hive = 'HKLM'; Key = 'SOFTWARE\Microsoft\Internet Explorer\Toolbar'; Group = 'Internet Explorer Toolbars' },
        @{ Hive = 'HKLM'; Key = 'SOFTWARE\WOW6432Node\Microsoft\Internet Explorer\Toolbar'; Group = 'Internet Explorer Toolbars' },
        @{ Hive = 'HKCU'; Key = 'SOFTWARE\Microsoft\Internet Explorer\Toolbar'; Group = 'Internet Explorer Toolbars' },
        @{ Hive = 'HKLM'; Key = 'SOFTWARE\Microsoft\Internet Explorer\URLSearchHooks'; Group = 'URL Search Hooks' },
        @{ Hive = 'HKCU'; Key = 'SOFTWARE\Microsoft\Internet Explorer\URLSearchHooks'; Group = 'URL Search Hooks' }
    )

    foreach ($k in $extensionKeys) {
        $regPath = "$($k.Hive):\$($k.Key)"
        if (-not (Test-Path -LiteralPath $regPath)) {
            continue
        }

        $props = Get-ItemProperty -LiteralPath $regPath -ErrorAction SilentlyContinue
        if ($props) {
            $props.PSObject.Properties |
                Where-Object { $_.Name -notlike 'PS*' } |
                ForEach-Object {
                    $valueText = [string]$_.Value
                    if (-not (Test-IsClsidString -Text $valueText)) {
                        return
                    }

                    $resolved = Resolve-LegacyExtensionReference -Reference $valueText
                    $displayPath = if (-not [string]::IsNullOrWhiteSpace($resolved.ModulePath)) { $resolved.ModulePath } else { $resolved.DisplayReference }
                    $rows.Add(@{
                        Category           = 'Extensions'
                        RowType            = 'RegistryValue'
                        SourceGroup        = $k.Group
                        Name               = $_.Name
                        Publisher          = 'Unknown'
                        FilePath           = $displayPath
                        AnalysisFilePath   = $resolved.ModulePath
                        Source             = $k.Hive
                        RegistryPath       = "$($k.Hive)\$($k.Key)"
                        ValueName          = $_.Name
                        RegistryKey        = "$($k.Hive)\$($k.Key)"
                        Clsid              = $resolved.Clsid
                        RiskLevel          = 'Caution'
                        IsSigned           = $false
                        IsEnabled          = $true
                    }) | Out-Null
                }
        }

        $disabledValuesPath = Join-Path $regPath 'AutorunsDisabled'
        if (Test-Path -LiteralPath $disabledValuesPath) {
            $disabledProps = Get-ItemProperty -LiteralPath $disabledValuesPath -ErrorAction SilentlyContinue
            if ($disabledProps) {
                $disabledProps.PSObject.Properties |
                    Where-Object { $_.Name -notlike 'PS*' } |
                    ForEach-Object {
                        $valueText = [string]$_.Value
                        if (-not (Test-IsClsidString -Text $valueText)) {
                            return
                        }

                        $resolved = Resolve-LegacyExtensionReference -Reference $valueText
                        $displayPath = if (-not [string]::IsNullOrWhiteSpace($resolved.ModulePath)) { $resolved.ModulePath } else { $resolved.DisplayReference }
                        $rows.Add(@{
                            Category           = 'Extensions'
                            RowType            = 'RegistryValue'
                            SourceGroup        = $k.Group
                            Name               = $_.Name
                            Publisher          = 'Unknown'
                            FilePath           = $displayPath
                            AnalysisFilePath   = $resolved.ModulePath
                            Source             = $k.Hive
                            RegistryPath       = "$($k.Hive)\$($k.Key)"
                            ValueName          = $_.Name
                            RegistryKey        = "$($k.Hive)\$($k.Key)"
                            Clsid              = $resolved.Clsid
                            RiskLevel          = 'Caution'
                            IsSigned           = $false
                            IsEnabled          = $false
                        }) | Out-Null
                    }
            }
        }

        Get-ChildItem -LiteralPath $regPath -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -ne 'AutorunsDisabled' -and $_.PSChildName -ne 'CDE_Disabled' } |
            ForEach-Object {
                $clsid = Normalize-ClsidString -Clsid $_.PSChildName
                if (-not (Test-IsClsidString -Text $clsid)) {
                    return
                }

                $subKeyPath = $_.PSPath
                $resolved = Resolve-LegacyExtensionReference -Reference $clsid -FallbackClsid $clsid
                $displayName = Get-LegacyExtensionDisplayName -Clsid $clsid -RegistrySubKey $subKeyPath -Fallback $clsid
                $displayPath = if (-not [string]::IsNullOrWhiteSpace($resolved.ModulePath)) { $resolved.ModulePath } else { $clsid }
                $rows.Add(@{
                    Category           = 'Extensions'
                    RowType            = 'RegistryKey'
                    SourceGroup        = $k.Group
                    Name               = $displayName
                    Publisher          = 'Unknown'
                    FilePath           = $displayPath
                    AnalysisFilePath   = $resolved.ModulePath
                    Source             = $k.Hive
                    RegistryPath       = "$($k.Hive)\$($k.Key)"
                    ValueName          = ''
                    RegistryKey        = "$($k.Hive)\$($k.Key)"
                    Clsid              = $clsid
                    RiskLevel          = 'Caution'
                    IsSigned           = $false
                    IsEnabled          = $true
                    SupportsEnable     = $true
                    SupportsDisable    = $true
                    SupportsDelete     = $true
                }) | Out-Null
            }

        $disabledSubkeysPath = Join-Path $regPath 'CDE_Disabled'
        if (Test-Path -LiteralPath $disabledSubkeysPath) {
            Get-ChildItem -LiteralPath $disabledSubkeysPath -ErrorAction SilentlyContinue | ForEach-Object {
                $clsid = Normalize-ClsidString -Clsid $_.PSChildName
                if (-not (Test-IsClsidString -Text $clsid)) {
                    return
                }

                $subKeyPath = $_.PSPath
                $resolved = Resolve-LegacyExtensionReference -Reference $clsid -FallbackClsid $clsid
                $displayName = Get-LegacyExtensionDisplayName -Clsid $clsid -RegistrySubKey $subKeyPath -Fallback $clsid
                $displayPath = if (-not [string]::IsNullOrWhiteSpace($resolved.ModulePath)) { $resolved.ModulePath } else { $clsid }
                $rows.Add(@{
                    Category           = 'Extensions'
                    RowType            = 'RegistryKey'
                    SourceGroup        = $k.Group
                    Name               = $displayName
                    Publisher          = 'Unknown'
                    FilePath           = $displayPath
                    AnalysisFilePath   = $resolved.ModulePath
                    Source             = $k.Hive
                    RegistryPath       = "$($k.Hive)\$($k.Key)"
                    ValueName          = ''
                    RegistryKey        = "$($k.Hive)\$($k.Key)"
                    Clsid              = $clsid
                    RiskLevel          = 'Caution'
                    IsSigned           = $false
                    IsEnabled          = $false
                    SupportsEnable     = $true
                    SupportsDisable    = $true
                    SupportsDelete     = $true
                }) | Out-Null
            }
        }
    }

    return $rows.ToArray()
}

function Get-InstalledBrowserExtensionDiscoveryRows {
    $rows = [System.Collections.Generic.List[object]]::new()

    foreach ($userRoot in @(Get-ExtensionScanUserRoots)) {
        foreach ($row in @(Get-ChromiumExtensionDiscoveryRows -UserRoot $userRoot)) {
            $rows.Add($row) | Out-Null
        }
        foreach ($row in @(Get-FirefoxExtensionDiscoveryRows -UserRoot $userRoot)) {
            $rows.Add($row) | Out-Null
        }
    }

    return $rows.ToArray()
}
