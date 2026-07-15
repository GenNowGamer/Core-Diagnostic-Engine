#Requires -Version 5.1
<#
.SYNOPSIS
    Discovery and state control for MSIX / UWP StartupTask entries (Task Manager parity).
#>

. (Join-Path $PSScriptRoot 'OfflineRuntime.ps1')

function Get-MsixStartupTaskRegistryRoot {
    return 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'
}

function Test-MsixStartupStateEnabled {
    param([object]$State)

    if ($null -eq $State) {
        return $false
    }

    try {
        return ([int]$State -ge 2)
    } catch {
        return $false
    }
}

function ConvertTo-MsixStartupRegistryPath {
    param([string]$PsPath)

    if ([string]::IsNullOrWhiteSpace($PsPath)) {
        return ''
    }

    $text = [string]$PsPath
    $text = $text -replace '^Microsoft\.PowerShell\.Core\\Registry::HKEY_CURRENT_USER\\', 'HKCU\'
    $text = $text -replace '^HKCU:\\', 'HKCU\'
    return $text
}

function Get-MsixStartupAppDisplayNameMap {
    $map = @{}

    try {
        Get-StartApps -ErrorAction SilentlyContinue | ForEach-Object {
            if ([string]::IsNullOrWhiteSpace($_.AppID)) { return }
            if ($_.AppID -match '^([^!\\]+)!') {
                $family = $matches[1]
                if (-not $map.ContainsKey($family)) {
                    $map[$family] = [string]$_.Name
                }
            }
        }
    } catch {}

    return $map
}

function Get-MsixPackageMetadataMap {
  $map = @{}

    try {
        Get-AppxPackage -ErrorAction SilentlyContinue | ForEach-Object {
            $family = [string]$_.PackageFamilyName
            if ([string]::IsNullOrWhiteSpace($family)) { return }
            if (-not $map.ContainsKey($family)) {
                $map[$family] = $_
            }
        }
    } catch {}

    return $map
}

function Format-MsixPublisherName {
    param([string]$Publisher)

    if ([string]::IsNullOrWhiteSpace($Publisher)) {
        return 'Unknown'
    }

    if ($Publisher -match '(?:^|,)O=([^,]+)') {
        return $matches[1].Trim()
    }

    if ($Publisher -match '^CN=([^,]+)') {
        return $matches[1].Trim()
    }

    return $Publisher.Trim()
}

function Get-MsixStartupTaskDisplayName {
    param(
        [string]$PackageFamilyName,
        [string]$TaskName,
        [hashtable]$DisplayNameMap,
        [hashtable]$PackageMap
    )

    if ($DisplayNameMap.ContainsKey($PackageFamilyName) -and -not [string]::IsNullOrWhiteSpace($DisplayNameMap[$PackageFamilyName])) {
        return [string]$DisplayNameMap[$PackageFamilyName]
    }

    if ($PackageMap.ContainsKey($PackageFamilyName)) {
        $pkgName = [string]$PackageMap[$PackageFamilyName].Name
        if (-not [string]::IsNullOrWhiteSpace($pkgName)) {
            return $pkgName
        }
    }

    $fallback = $PackageFamilyName -replace '_8wekyb3d8bbwe$',''
    $fallback = $fallback -replace '\.',' '
    if (-not [string]::IsNullOrWhiteSpace($TaskName) -and $fallback -notmatch [regex]::Escape($TaskName)) {
        return "$fallback ($TaskName)"
    }

    return $fallback
}

function Join-MsixPackageExecutablePath {
    param(
        [string]$InstallLocation,
        [string]$RelativeExecutable
    )

    if ([string]::IsNullOrWhiteSpace($InstallLocation) -or [string]::IsNullOrWhiteSpace($RelativeExecutable)) {
        return ''
    }

    $relative = $RelativeExecutable.Trim().Trim('"')
    if ($relative -match '^[A-Za-z]:\\' -or $relative.StartsWith('\\')) {
        return $relative
    }

    return [System.IO.Path]::Combine($InstallLocation.TrimEnd('\'), $relative)
}

function Get-MsixManifestStartupTaskBindings {
    param($AppxPackage)

    $bindings = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $AppxPackage) {
        return @()
    }

    try {
        $manifest = Get-AppxPackageManifest -Package $AppxPackage -ErrorAction Stop
    } catch {
        return @()
    }

    $installLocation = [string]$AppxPackage.InstallLocation
    $applications = @($manifest.Package.Applications.Application)

    foreach ($application in $applications) {
        $appExecutable = [string]$application.Executable
        $extensions = @()
        if ($null -ne $application.Extensions -and $null -ne $application.Extensions.Extension) {
            $extensions = @($application.Extensions.Extension)
        }

        foreach ($extension in $extensions) {
            if ([string]$extension.Category -ne 'windows.startupTask') {
                continue
            }

            $extensionExecutable = [string]$extension.Executable
            foreach ($startupTask in @($extension.StartupTask)) {
                if ($null -eq $startupTask) { continue }

                $taskId = [string]$startupTask.TaskId
                if ([string]::IsNullOrWhiteSpace($taskId)) { continue }

                $relativeExecutable = if (-not [string]::IsNullOrWhiteSpace($extensionExecutable)) {
                    $extensionExecutable
                } elseif (-not [string]::IsNullOrWhiteSpace($appExecutable)) {
                    $appExecutable
                } else {
                    ''
                }

                $bindings.Add([PSCustomObject]@{
                    TaskId             = $taskId
                    RelativeExecutable = $relativeExecutable
                    ApplicationId      = [string]$application.Id
                    InstallLocation    = $installLocation
                }) | Out-Null
            }
        }
    }

    return @($bindings)
}

function Resolve-MsixStartupExecutablePath {
    param(
        [string]$PackageFamilyName,
        [string]$TaskId,
        $AppxPackage = $null
    )

    $result = [PSCustomObject]@{
        ResolvedPath       = ''
        Exists             = $false
        ResolutionMethod   = 'Unresolved'
        Detail             = ''
        InstallLocation    = ''
        ManifestExecutable = ''
        PackageFamilyName  = $PackageFamilyName
        TaskId             = $TaskId
    }

    if ([string]::IsNullOrWhiteSpace($PackageFamilyName)) {
        $result.Detail = 'Package family name is required'
        return $result
    }

    if ($null -eq $AppxPackage) {
        try {
            $AppxPackage = @(Get-AppxPackage -ErrorAction SilentlyContinue |
                Where-Object { [string]$_.PackageFamilyName -eq $PackageFamilyName } |
                Select-Object -First 1)[0]
        } catch {
            $AppxPackage = $null
        }
    }

    if ($AppxPackage -is [System.Array]) {
        $AppxPackage = $AppxPackage[0]
    }

    if ($null -eq $AppxPackage) {
        $result.Detail = "Package not installed: $PackageFamilyName"
        return $result
    }

    $result.InstallLocation = [string]$AppxPackage.InstallLocation
    $bindings = @(Get-MsixManifestStartupTaskBindings -AppxPackage $AppxPackage)

    $match = $null
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
        $match = @($bindings | Where-Object { $_.TaskId -eq $TaskId } | Select-Object -First 1)
        if ($match.Count -eq 0) {
            $match = @($bindings | Where-Object { $_.TaskId -ieq $TaskId } | Select-Object -First 1)
        }
    }

    $relativeExecutable = ''
    $method = 'Unresolved'

    if ($match -and -not [string]::IsNullOrWhiteSpace($match.RelativeExecutable)) {
        $relativeExecutable = [string]$match.RelativeExecutable
        $method = 'StartupTaskManifest'
    } else {
        try {
            $manifest = Get-AppxPackageManifest -Package $AppxPackage -ErrorAction Stop
            $applications = @($manifest.Package.Applications.Application)
            $primary = @($applications | Where-Object { [string]$_.Id -eq 'App' } | Select-Object -First 1)
            if ($primary.Count -eq 0 -and $applications.Count -gt 0) {
                $primary = @($applications[0])
            }

            if ($primary.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($primary[0].Executable)) {
                $relativeExecutable = [string]$primary[0].Executable
                $method = if ($bindings.Count -gt 0) { 'ApplicationManifestFallback' } else { 'ApplicationManifest' }
                if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
                    $result.Detail = "Startup task '$TaskId' not listed in manifest; using application executable"
                }
            }
        } catch {
            if ([string]::IsNullOrWhiteSpace($result.Detail)) {
                $result.Detail = $_.Exception.Message
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($relativeExecutable)) {
        if ([string]::IsNullOrWhiteSpace($result.Detail)) {
            $result.Detail = 'No executable declared in package manifest'
        }
        return $result
    }

    $fullPath = Join-MsixPackageExecutablePath -InstallLocation $result.InstallLocation -RelativeExecutable $relativeExecutable
    $result.ManifestExecutable = $relativeExecutable
    $result.ResolvedPath = $fullPath
    $result.ResolutionMethod = $method

    if (-not [string]::IsNullOrWhiteSpace($fullPath) -and (Test-Path -LiteralPath $fullPath -PathType Leaf -ErrorAction SilentlyContinue)) {
        $result.Exists = $true
        try {
            $result.ResolvedPath = (Get-Item -LiteralPath $fullPath -ErrorAction Stop).FullName
        } catch { }
        $result.Detail = ''
    } elseif (-not [string]::IsNullOrWhiteSpace($fullPath) -and [string]::IsNullOrWhiteSpace($result.Detail)) {
        $result.Detail = 'Package executable path from manifest is not directly accessible'
    }

    return $result
}

function Get-MsixPackagePublisherSignatureInfo {
    param([string]$Publisher)

    $publisherKnown = -not [string]::IsNullOrWhiteSpace($Publisher) -and $Publisher -ne 'Unknown'
    $signedDisplay = if ($publisherKnown) { "Package ($Publisher)" } else { 'Not found' }

    return [PSCustomObject]@{
        IsSigned         = $false
        SignedBy         = if ($publisherKnown) { $Publisher } else { '' }
        SignedDisplay    = $signedDisplay
        SignatureStatus  = if ($publisherKnown) { 'PackagePublisher' } else { '' }
        ResolutionDetail = if ($publisherKnown) { 'MSIX package publisher from Appx package metadata' } else { '' }
    }
}

function Get-MsixStartupSignatureInfo {
    param(
        [string]$PackageFamilyName,
        [string]$TaskId,
        [string]$Publisher = 'Unknown',
        $AppxPackage = $null
    )

    $resolved = Resolve-MsixStartupExecutablePath -PackageFamilyName $PackageFamilyName -TaskId $TaskId -AppxPackage $AppxPackage

    if ($resolved.Exists -and -not [string]::IsNullOrWhiteSpace($resolved.ResolvedPath)) {
        $fileSig = Get-FileSignatureInfo -FilePath $resolved.ResolvedPath
        if ($fileSig.SignedDisplay -ne 'Not found') {
            return $fileSig
        }
    }

    if (-not $resolved.Exists -and -not [string]::IsNullOrWhiteSpace($resolved.ResolvedPath)) {
        try {
            $sig = Get-AuthenticodeSignature -LiteralPath $resolved.ResolvedPath -ErrorAction Stop
            if ($sig.Status -eq 'Valid') {
                $signedDisplay = 'Signed'
                $signedBy = ''
                if ($sig.SignerCertificate -and $sig.SignerCertificate.Subject) {
                    $subject = [string]$sig.SignerCertificate.Subject
                    $signedBy = $subject
                    if ($subject -match 'CN=([^,]+)') {
                        $signedDisplay = $Matches[1].Trim('"')
                    } else {
                        $signedDisplay = $subject
                    }
                }

                return [PSCustomObject]@{
                    IsSigned         = $true
                    SignedBy         = $signedBy
                    SignedDisplay    = $signedDisplay
                    SignatureStatus  = [string]$sig.Status
                    ResolutionDetail = [string]$resolved.Detail
                }
            }
        } catch { }
    }

    return Get-MsixPackagePublisherSignatureInfo -Publisher $Publisher
}

function Get-MsixStartupAnalysisInfo {
    param(
        [string]$PackageFamilyName,
        [string]$TaskId,
        [string]$Publisher = 'Unknown',
        $AppxPackage = $null
    )

    $resolved = Resolve-MsixStartupExecutablePath -PackageFamilyName $PackageFamilyName -TaskId $TaskId -AppxPackage $AppxPackage

    if ($resolved.Exists -and -not [string]::IsNullOrWhiteSpace($resolved.ResolvedPath)) {
        return Get-FileAnalysisInfo -FilePath $resolved.ResolvedPath
    }

    $publisherKnown = -not [string]::IsNullOrWhiteSpace($Publisher) -and $Publisher -ne 'Unknown'
    $manifestKnown = -not [string]::IsNullOrWhiteSpace($resolved.ResolvedPath)

    if ($publisherKnown -or $manifestKnown) {
        $detailParts = [System.Collections.Generic.List[string]]::new()
        if ($manifestKnown) {
            $detailParts.Add("Manifest executable: $($resolved.ManifestExecutable)") | Out-Null
        }
        if (-not $resolved.Exists -and $manifestKnown) {
            $detailParts.Add('Installed package file not directly accessible (WindowsApps)') | Out-Null
        }
        if ($publisherKnown) {
            $detailParts.Add("Package publisher: $Publisher") | Out-Null
        }

        return [PSCustomObject]@{
            Level      = 'OK'
            Detail     = ($detailParts -join '; ')
            HasWarning = $false
        }
    }

    return [PSCustomObject]@{
        Level      = 'Warning'
        Detail     = if (-not [string]::IsNullOrWhiteSpace($resolved.Detail)) { $resolved.Detail } else { 'MSIX startup task; package or executable unavailable' }
        HasWarning = $true
    }
}

function Get-MsixStartupTaskRows {
    if (Test-OfflineRegistrySessionActive) {
        return @()
    }

    $root = Get-MsixStartupTaskRegistryRoot
    if (-not (Test-Path -LiteralPath $root)) {
        return @()
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    $displayNames = Get-MsixStartupAppDisplayNameMap
    $packages = Get-MsixPackageMetadataMap

    Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
        $packageFamily = $_.PSChildName
        Get-ChildItem -LiteralPath $_.PSPath -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like '*Startup*' } |
            ForEach-Object {
                $taskName = $_.PSChildName
                $props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                if ($null -eq $props -or $null -eq $props.State) { return }

                $registryPath = ConvertTo-MsixStartupRegistryPath -PsPath $_.PSPath
                $displayName = Get-MsixStartupTaskDisplayName `
                    -PackageFamilyName $packageFamily `
                    -TaskName $taskName `
                    -DisplayNameMap $displayNames `
                    -PackageMap $packages

                $publisher = 'Unknown'
                $installLocation = ''
                $pkg = $null
                if ($packages.ContainsKey($packageFamily)) {
                    $pkg = $packages[$packageFamily]
                    $publisher = Format-MsixPublisherName -Publisher ([string]$pkg.Publisher)
                    $installLocation = [string]$pkg.InstallLocation
                }

                $resolved = Resolve-MsixStartupExecutablePath `
                    -PackageFamilyName $packageFamily `
                    -TaskId $taskName `
                    -AppxPackage $pkg

                $displayFilePath = if (-not [string]::IsNullOrWhiteSpace($resolved.ResolvedPath)) {
                    $resolved.ResolvedPath
                } elseif ($installLocation) {
                    $installLocation
                } else {
                    "$packageFamily\$taskName"
                }

                $analysisPath = if (-not [string]::IsNullOrWhiteSpace($resolved.ResolvedPath)) {
                    $resolved.ResolvedPath
                } else {
                    $displayFilePath
                }

                $rows.Add(@{
                    Category           = 'StartupItems'
                    RowType            = 'MsixStartupTask'
                    SourceGroup        = 'MSIX Startup Task'
                    Name               = $displayName
                    Publisher          = $publisher
                    FilePath           = $displayFilePath
                    Source             = 'HKCU'
                    RegistryPath       = $registryPath
                    ValueName          = 'State'
                    RegistryKey        = $registryPath
                    RiskLevel          = 'Caution'
                    IsSigned           = $false
                    IsEnabled          = (Test-MsixStartupStateEnabled -State $props.State)
                    ServiceName        = $packageFamily
                    MsixTaskId         = $taskName
                    OriginalData       = ([string][int]$props.State)
                    IsCritical         = $false
                    SupportsEnable     = $true
                    SupportsDisable    = $true
                    SupportsDelete     = $false
                    SupportsReset      = $false
                    SupportsUndo       = $false
                    IsDeviated         = $false
                    DeviationReason    = ''
                    PreserveRiskLevel  = $false
                    AnalysisFilePath   = $analysisPath
                    Clsid              = ''
                    User               = ''
                })
            }
    }

    return @($rows)
}

function Resolve-MsixStartupRegistryPsPath {
    param([string]$RawPath)

    if ([string]::IsNullOrWhiteSpace($RawPath)) {
        throw 'Registry key path is required for MSIX startup task actions.'
    }

    $fullKey = $RawPath -replace '^HKLM\\', 'HKLM:\' -replace '^HKCU\\', 'HKCU:\' -replace '^HKU\\', 'HKU:\'
    if ($fullKey -notmatch '^(HKLM:|HKCU:|HKU:)') {
        throw "Unsupported registry path: $RawPath"
    }

    $root = (Get-MsixStartupTaskRegistryRoot).TrimEnd('\').ToUpperInvariant() -replace ':$', ''
    $compare = $fullKey.TrimEnd('\').ToUpperInvariant() -replace ':$', ''
    $rootNorm = $root -replace '^HKCU:', 'HKCU\' -replace '^HKLM:', 'HKLM\' -replace '^HKU:', 'HKU\'
    $candNorm = $compare -replace '^HKCU:', 'HKCU\' -replace '^HKLM:', 'HKLM\' -replace '^HKU:', 'HKU\'
    if (-not ($candNorm -eq $rootNorm -or $candNorm.StartsWith($rootNorm + '\', [System.StringComparison]::Ordinal))) {
        throw "PROTECTED_OR_UNSUPPORTED: Registry path is outside MSIX startup mutation allowlist: $RawPath"
    }

    return $fullKey
}

function Set-MsixStartupTaskEntryState {
    param(
        [string]$RegistryPath,
        [string]$ValueName = 'State',
        [bool]$Enable
    )

    if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
        throw 'RegistryPath is required for MSIX startup task actions.'
    }

    if ($env:OFFLINE_WINDOWS_ROOT) {
        throw 'PROTECTED_OR_UNSUPPORTED: MSIX startup tasks are not supported in offline registry mode.'
    }

    $fullKey = Resolve-MsixStartupRegistryPsPath -RawPath $RegistryPath
    if (-not (Test-Path -LiteralPath $fullKey)) {
        throw "MSIX startup task key not found: $RegistryPath"
    }

    $propertyName = if ([string]::IsNullOrWhiteSpace($ValueName)) { 'State' } else { $ValueName }
  $current = Get-ItemPropertyValue -LiteralPath $fullKey -Name $propertyName -ErrorAction Stop

    if ($Enable) {
        if (Test-MsixStartupStateEnabled -State $current) {
            throw 'ALREADY_IN_DESIRED_STATE: MSIX startup task is already enabled.'
        }

        if ([int]$current -eq 0) {
            throw 'PROTECTED_OR_UNSUPPORTED: This startup task is disabled by policy (State=0). Change policy or use Task Manager.'
        }

        $target = 2
        try {
            $priorState = Get-ItemPropertyValue -LiteralPath $fullKey -Name 'CDE_PriorMsixState' -ErrorAction Stop
            $priorInt = [int]$priorState
            if (Test-MsixStartupStateEnabled -State $priorInt) {
                $target = $priorInt
            }
        } catch { }
    } else {
        if (-not (Test-MsixStartupStateEnabled -State $current)) {
            throw 'ALREADY_IN_DESIRED_STATE: MSIX startup task is already disabled.'
        }

        Set-ItemProperty -LiteralPath $fullKey -Name 'CDE_PriorMsixState' -Value ([int]$current) -Type DWord -ErrorAction SilentlyContinue
        $target = 1
    }

    Set-ItemProperty -LiteralPath $fullKey -Name $propertyName -Value $target -Type DWord -ErrorAction Stop
    $verify = Get-ItemPropertyValue -LiteralPath $fullKey -Name $propertyName -ErrorAction Stop
    if ([int]$verify -ne $target) {
        throw "MSIX startup state verification failed. Expected $target, got $verify."
    }

    if ($Enable) {
        Remove-ItemProperty -LiteralPath $fullKey -Name 'CDE_PriorMsixState' -ErrorAction SilentlyContinue
    }
}

if (-not (Get-Command Get-FileSignatureInfo -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'StartupRisk.ps1')
}
