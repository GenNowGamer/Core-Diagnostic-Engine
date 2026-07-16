#Requires -Version 5.1
param(
    [string]$Action  = 'List',
    # List | ListStartupItems | ListDrivers | ListUserLogon | ListExtensions | Enable | Disable | Delete | EnableEntry | DisableEntry | DeleteEntry | ResetWinlogonEntry | UndoWinlogonEntry | ListServices | StartService | StopService | SetStartType
    [string]$Category = '',
    [string]$RowType = '',
    [string]$EntryKey = '',   # registry key path for startup actions
    [string]$EntryName = '',  # value name within the key
    [string]$RegistryPath = '',
    [string]$ValueName = '',
    [string]$EntryPath = '',  # file path for startup folder actions
    [string]$ServiceName = '',
    [string]$ActionStatePayload = '',
    [string]$StartType = 'Manual',
    [string]$SourceGroup = '',
    [switch]$IncludeWindowsScheduledTasks,
    [switch]$ElevatedRelay
)

$Script:StartupManagerScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir = Split-Path $Script:StartupManagerScriptPath
$ElevationModule = Join-Path $ScriptDir '..\Core\Toolkit.Elevation.psm1'
Import-Module $ElevationModule -Force -DisableNameChecking

$Script:StartupMutatingActions = @(
    'Enable', 'Disable', 'Delete',
    'EnableEntry', 'DisableEntry', 'DeleteEntry',
    'ResetWinlogonEntry', 'UndoWinlogonEntry',
    'StartService', 'StopService', 'SetStartType', 'RestartService'
)

function Get-StartupManagerRelayArgumentString {
    $parts = [System.Collections.Generic.List[string]]::new()
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'Action' -Value $Action
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'ElevatedRelay' -IsSwitch
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'Category' -Value $Category
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'RowType' -Value $RowType
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'EntryKey' -Value $EntryKey
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'EntryName' -Value $EntryName
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'RegistryPath' -Value $RegistryPath
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'ValueName' -Value $ValueName
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'EntryPath' -Value $EntryPath
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'ServiceName' -Value $ServiceName
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'ActionStatePayload' -Value $ActionStatePayload
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'StartType' -Value $StartType
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'SourceGroup' -Value $SourceGroup
    if ($IncludeWindowsScheduledTasks) {
        Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'IncludeWindowsScheduledTasks' -IsSwitch
    }
    return Join-ToolkitRelayArgumentString -Parts $parts
}

function Invoke-StartupManagerElevationRelay {
    if ($ElevatedRelay) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($env:OFFLINE_WINDOWS_ROOT)) { return $false }
    if ($Script:StartupMutatingActions -notcontains $Action) { return $false }
    return (Invoke-ToolkitWorkflowElevationRelay -ScriptPath $Script:StartupManagerScriptPath `
        -ArgumentString (Get-StartupManagerRelayArgumentString) -ElevatedRelay:$ElevatedRelay)
}

$StartupRiskScript = Join-Path $ScriptDir '..\Core\StartupRisk.ps1'
. $StartupRiskScript
$MsixStartupScript = Join-Path $ScriptDir '..\Core\MsixStartup.ps1'
. $MsixStartupScript
$StartupApprovedScript = Join-Path $ScriptDir '..\Core\StartupApproved.ps1'
. $StartupApprovedScript
$StartupScheduledTaskScript = Join-Path $ScriptDir '..\Core\StartupScheduledTask.ps1'
. $StartupScheduledTaskScript
$StartupCorrelationScript = Join-Path $ScriptDir '..\Core\StartupCorrelation.ps1'
. $StartupCorrelationScript
$ExtensionDiscoveryScript = Join-Path $ScriptDir '..\Core\ExtensionDiscovery.ps1'
. $ExtensionDiscoveryScript

function Get-StartupFolderContexts {
    $contexts = [System.Collections.Generic.List[object]]::new()

    $offlineRoot = $env:OFFLINE_WINDOWS_ROOT
    if ($offlineRoot) { $offlineRoot = $offlineRoot.TrimEnd('\\') }

    if ($offlineRoot) {
        $startupFolders = @()
        $userProfiles = Get-ChildItem "$offlineRoot\Users" -Directory -ErrorAction SilentlyContinue
        foreach ($userProfile in $userProfiles) {
            $startupFolders += @{
                Path         = "$($userProfile.FullName)\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
                DisabledPath = "$($userProfile.FullName)\AppData\Local\CDE\DisabledStartup"
                Source       = "User Startup ($($userProfile.Name))"
            }
        }
        $startupFolders += @{
            Path         = "$offlineRoot\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
            DisabledPath = "$offlineRoot\ProgramData\CDE\DisabledStartup"
            Source       = 'All Users Startup'
        }
    } else {
        $startupFolders = @(
            @{ Path = [System.Environment]::GetFolderPath('Startup');       DisabledPath = (Join-Path $env:LOCALAPPDATA 'CDE\DisabledStartup'); Source = 'User Startup' },
            @{ Path = [System.Environment]::GetFolderPath('CommonStartup'); DisabledPath = (Join-Path $env:ProgramData  'CDE\DisabledStartup'); Source = 'All Users Startup' }
        )
    }

    foreach ($folder in $startupFolders) {
        if ([string]::IsNullOrWhiteSpace($folder.Path)) { continue }

        $contexts.Add([PSCustomObject]@{
            ActivePath   = $folder.Path
            DisabledPath = $folder.DisabledPath
            Source       = $folder.Source
        })
    }

    return @($contexts)
}

function Resolve-DirectoryPath {
    param([string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    $full = $full.TrimEnd('\')
    return ($full + '\')
}

function Resolve-ServiceStartType {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 'Manual'
    }

    switch -Regex ($Value.Trim()) {
        '^(Auto|Automatic|AutomaticDelayedStart)$' { return 'Automatic' }
        '^(Manual|Demand)$' { return 'Manual' }
        '^Disabled$' { return 'Disabled' }
        '^(Boot|System)$' { return 'Automatic' }
        default { return 'Manual' }
    }
}

function Test-ServiceExists {
    param([string]$ServiceName)

    if ([string]::IsNullOrWhiteSpace($ServiceName)) {
        return $false
    }

    try {
        $null = Get-Service -Name $ServiceName -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Get-ServiceActionFailure {
    param(
        [string]$Action,
        [string]$ServiceName,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $message = $ErrorRecord.Exception.Message
    $normalized = $message.ToLowerInvariant()
    $code = 'EXECUTION_ERROR'

    if ($normalized -match 'access is denied|cannot be configured|cannot open .* service on computer') {
        $code = 'ACCESS_DENIED'
    } elseif ($normalized -match 'service .* was not found|cannot find any service with service name|does not exist as an installed service|cannot open .* service on computer .* does not exist') {
        $code = 'SERVICE_NOT_FOUND'
    } elseif ($normalized -match 'already running|already been started|already stopped|has not been started') {
        $code = 'ALREADY_IN_DESIRED_STATE'
    } elseif ($normalized -match 'cannot be stopped|cannot accept control messages|not valid due to the current state|not supported') {
        $code = 'PROTECTED_OR_UNSUPPORTED'
    }

    return "${code}: ${Action} failed for ${ServiceName}: $message"
}

function New-StartupRow {
    param(
        [string]$Category,
        [string]$RowType,
        [string]$SourceGroup,
        [string]$Name,
        [string]$Publisher = 'Unknown',
        [string]$FilePath = '',
        [string]$Source = '',
        [string]$RegistryPath = '',
        [string]$ValueName = '',
        [string]$RegistryKey = '',
        [string]$RiskLevel = 'Caution',
        [bool]$IsSigned = $false,
        [bool]$IsEnabled = $true,
        [string]$ServiceName = '',
        [string]$OriginalData = '',
        [bool]$IsCritical = $false,
        [bool]$SupportsEnable = $true,
        [bool]$SupportsDisable = $true,
        [bool]$SupportsDelete = $true,
        [bool]$SupportsReset = $false,
        [bool]$SupportsUndo = $false,
        [bool]$IsDeviated = $false,
        [string]$DeviationReason = '',
        [bool]$PreserveRiskLevel = $false,
        [string]$AnalysisFilePath = '',
        [string]$Clsid = '',
        [string]$User = '',
        [string]$CorrelationGroupId = '',
        [string]$CorrelationSummary = '',
        [string]$ActionStatePayload = '',
        [string]$MsixTaskId = '',
        [string]$TaskActionKind = '',
        [bool]$ComServerExists = $false
    )

    $analysisPath = if (-not [string]::IsNullOrWhiteSpace($AnalysisFilePath)) { $AnalysisFilePath } else { $FilePath }
    if ([string]::IsNullOrWhiteSpace($TaskActionKind) -and $RowType -eq 'ScheduledTask') {
        if (-not [string]::IsNullOrWhiteSpace($Clsid)) {
            $TaskActionKind = 'Com'
        } elseif ($FilePath -match '\(COM\b' -or $FilePath -match '\(no executable path\)') {
            $TaskActionKind = 'Com'
        } elseif (-not [string]::IsNullOrWhiteSpace($AnalysisFilePath)) {
            $TaskActionKind = 'Exec'
        }
    }

    if ($RowType -eq 'BrowserExtension') {
        $sigInfo = Get-BrowserExtensionSignatureInfo -AnalysisFilePath $analysisPath
        $analysis = Get-BrowserExtensionAnalysisInfo -VersionPath $FilePath -AnalysisFilePath $analysisPath
        if ($sigInfo.SignatureStatus) {
            $IsSigned = $sigInfo.IsSigned
        }
    } elseif ($Category -eq 'Extensions' -and -not [string]::IsNullOrWhiteSpace($analysisPath)) {
        $sigInfo = Get-FileSignatureInfo -FilePath $analysisPath
        if ($sigInfo.SignatureStatus) {
            $IsSigned = $sigInfo.IsSigned
        }
        $analysis = Get-FileAnalysisInfo -FilePath $analysisPath
    } elseif ($Category -eq 'Extensions' -and [string]::IsNullOrWhiteSpace($analysisPath)) {
        $sigInfo = [PSCustomObject]@{
            IsSigned         = $false
            SignedBy         = ''
            SignedDisplay    = 'N/A'
            SignatureStatus  = ''
            ResolutionDetail = 'Registry-only extension reference'
        }
        $analysis = [PSCustomObject]@{
            Level      = 'NA'
            Detail     = 'No module path for this extension entry'
            HasWarning = $false
        }
    } elseif ($RowType -eq 'DriverService' -and [string]::IsNullOrWhiteSpace($analysisPath)) {
        # Inbox / kernel-registered drivers often omit ImagePath; treat as Windows plumbing, not a missing file.
        $sigInfo = [PSCustomObject]@{
            IsSigned         = $true
            SignedBy         = 'Microsoft Corporation'
            SignedDisplay    = 'Windows driver'
            SignatureStatus  = 'WindowsDriverNoImagePath'
            ResolutionDetail = 'Driver service has no ImagePath (inbox/registered)'
        }
        $IsSigned = $true
        if ([string]::IsNullOrWhiteSpace($Publisher) -or $Publisher -eq 'Unknown') {
            $Publisher = 'Microsoft Corporation'
        }
        $analysis = [PSCustomObject]@{
            Level      = 'OK'
            Detail     = 'Windows driver service with no ImagePath'
            HasWarning = $false
        }
        $PreserveRiskLevel = $true
        $RiskLevel = 'Safe'
    } elseif ($SourceGroup -eq 'Boot Execute' -or ($RowType -eq 'RegistryValue' -and $Name -eq 'BootExecute')) {
        $bootCommand = if (-not [string]::IsNullOrWhiteSpace($analysisPath)) { $analysisPath } else { $FilePath }
        $bootTarget = Resolve-StartupTarget -Command $bootCommand
        if ($bootTarget.Exists -and -not [string]::IsNullOrWhiteSpace($bootTarget.ResolvedPath)) {
            $sigInfo = Get-FileSignatureInfo -FilePath $bootTarget.ResolvedPath
            if ($sigInfo.SignatureStatus -or $sigInfo.SignedDisplay -eq 'Not found') {
                $IsSigned = $sigInfo.IsSigned
            }
            $analysis = Get-FileAnalysisInfo -FilePath $bootTarget.ResolvedPath
            if (-not $analysis.HasWarning) {
                $analysis = [PSCustomObject]@{
                    Level      = 'OK'
                    Detail     = "BootExecute → $($bootTarget.ResolvedPath)"
                    HasWarning = $false
                }
            }
        } else {
            $sigInfo = [PSCustomObject]@{
                IsSigned         = $true
                SignedBy         = 'Microsoft Corporation'
                SignedDisplay    = 'Windows boot'
                SignatureStatus  = 'WindowsBootExecute'
                ResolutionDetail = [string]$bootTarget.Detail
            }
            $IsSigned = $true
            $analysis = [PSCustomObject]@{
                Level      = 'OK'
                Detail     = 'Windows BootExecute command (Session Manager)'
                HasWarning = $false
            }
        }
        $PreserveRiskLevel = $true
        if ([string]::IsNullOrWhiteSpace($RiskLevel) -or $RiskLevel -eq 'Warning' -or $RiskLevel -eq 'Caution') {
            $RiskLevel = 'Safe'
        }
        if ([string]::IsNullOrWhiteSpace($Publisher) -or $Publisher -eq 'Unknown') {
            $Publisher = 'Microsoft Corporation'
        }
    } elseif ($RowType -eq 'MsixStartupTask') {
        $sigInfo = Get-MsixStartupSignatureInfo `
            -PackageFamilyName $ServiceName `
            -TaskId $MsixTaskId `
            -Publisher $Publisher
        if ($sigInfo.SignatureStatus) {
            $IsSigned = $sigInfo.IsSigned
        }
        $analysis = Get-MsixStartupAnalysisInfo `
            -PackageFamilyName $ServiceName `
            -TaskId $MsixTaskId `
            -Publisher $Publisher
    } elseif ($RowType -eq 'ScheduledTask' -and $TaskActionKind -in @('Com', 'None')) {
        $comPath = $AnalysisFilePath
        if ([string]::IsNullOrWhiteSpace($comPath) -and -not [string]::IsNullOrWhiteSpace($Clsid)) {
            $comResolved = Resolve-ComHandlerServerPath -ClassId $Clsid
            if ($comResolved.Exists) {
                $comPath = $comResolved.ServerPath
                $ComServerExists = $true
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($comPath)) {
            $sigInfo = Get-FileSignatureInfo -FilePath $comPath
            if ($sigInfo.SignatureStatus -or $sigInfo.SignedDisplay -eq 'Not found') {
                $IsSigned = $sigInfo.IsSigned
            }
            $analysis = Get-FileAnalysisInfo -FilePath $comPath
            if (-not $analysis.HasWarning) {
                $prefix = if ($Clsid) { "COM handler $Clsid" } else { 'COM handler' }
                $analysis = [PSCustomObject]@{
                    Level      = 'OK'
                    Detail     = "$prefix → $comPath"
                    HasWarning = $false
                }
            }
        } elseif ($PreserveRiskLevel -or $IsCritical) {
            $sigInfo = [PSCustomObject]@{
                IsSigned         = $true
                SignedBy         = 'Microsoft Corporation'
                SignedDisplay    = 'Windows COM'
                SignatureStatus  = 'WindowsComTask'
                ResolutionDetail = if ($Clsid) { "COM ClassId $Clsid" } else { 'Windows COM scheduled task' }
            }
            $IsSigned = $true
            $analysis = [PSCustomObject]@{
                Level      = 'OK'
                Detail     = if ($Clsid) {
                    "Windows COM handler $Clsid (server image unavailable)"
                } else {
                    'Windows COM scheduled task (no file image)'
                }
                HasWarning = $false
            }
        } else {
            $sigInfo = [PSCustomObject]@{
                IsSigned         = $false
                SignedBy         = ''
                SignedDisplay    = 'N/A (COM)'
                SignatureStatus  = 'ComHandler'
                ResolutionDetail = if ($Clsid) { "COM ClassId $Clsid unresolved" } else { 'COM handler with no executable' }
            }
            $IsSigned = $false
            $analysis = [PSCustomObject]@{
                Level      = 'NA'
                Detail     = 'COM handler; server DLL/EXE not resolved'
                HasWarning = $false
            }
        }
    } else {
        $commandForAnalysis = if (-not [string]::IsNullOrWhiteSpace($analysisPath)) { $analysisPath } else { $FilePath }
        $resolvedForAnalysis = Resolve-StartupTarget -Command $commandForAnalysis
        $pathForAnalysis = if ($resolvedForAnalysis.Exists -and -not [string]::IsNullOrWhiteSpace($resolvedForAnalysis.ResolvedPath)) {
            [string]$resolvedForAnalysis.ResolvedPath
        } else {
            $commandForAnalysis
        }
        $sigInfo = Get-FileSignatureInfo -FilePath $pathForAnalysis
        if ($sigInfo.SignatureStatus) {
            $IsSigned = $sigInfo.IsSigned
        }
        $analysis = Get-FileAnalysisInfo -FilePath $pathForAnalysis

        # Optional Windows components may be referenced by plumbing tasks but not installed.
        if (($PreserveRiskLevel -or $IsCritical) -and
            $RowType -eq 'ScheduledTask' -and
            -not $resolvedForAnalysis.Exists -and
            ($sigInfo.SignedDisplay -eq 'Not found' -or $analysis.HasWarning)) {
            $sigInfo = [PSCustomObject]@{
                IsSigned         = $true
                SignedBy         = 'Microsoft Corporation'
                SignedDisplay    = 'Windows task'
                SignatureStatus  = 'WindowsTaskMissingImage'
                ResolutionDetail = [string]$resolvedForAnalysis.Detail
            }
            $IsSigned = $true
            $analysis = [PSCustomObject]@{
                Level      = 'OK'
                Detail     = 'Windows scheduled task image not present (optional/absent component)'
                HasWarning = $false
            }
        }
    }

    if ($RowType -eq 'WinlogonValue' -and $Name -in @('Userinit', 'Shell')) {
        if ($IsDeviated) {
            $detail = if ([string]::IsNullOrWhiteSpace($DeviationReason)) {
                'Winlogon value deviates from expected default'
            } else {
                $DeviationReason
            }
            $analysis = [PSCustomObject]@{
                Level      = 'Warning'
                Detail     = $detail
                HasWarning = $true
            }
            $sigInfo = [PSCustomObject]@{
                IsSigned        = $false
                SignedBy        = ''
                SignedDisplay   = 'Compromised'
                SignatureStatus = 'Deviated'
            }
            $IsSigned = $false
        } else {
            $analysis = [PSCustomObject]@{
                Level      = 'OK'
                Detail     = 'Expected Winlogon value'
                HasWarning = $false
            }
            $sigInfo = [PSCustomObject]@{
                IsSigned        = $false
                SignedBy        = ''
                SignedDisplay   = ''
                SignatureStatus = ''
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($User)) {
        $user = Get-EntryUserDisplay -Source $Source -RegistryPath $RegistryPath -SourceGroup $SourceGroup -RowType $RowType
    } else {
        $user = $User
    }

    if ([string]::IsNullOrWhiteSpace($Publisher) -or $Publisher -eq 'Unknown') {
        $publisherPath = if (-not [string]::IsNullOrWhiteSpace($AnalysisFilePath)) { $AnalysisFilePath } else { $FilePath }
        $target = Resolve-StartupTarget -Command $publisherPath
        if ($target.Exists -and -not [string]::IsNullOrWhiteSpace($target.ResolvedPath)) {
            try {
                $company = (Get-Item -LiteralPath $target.ResolvedPath -ErrorAction Stop).VersionInfo.CompanyName
                if (-not [string]::IsNullOrWhiteSpace($company)) {
                    $Publisher = $company
                }
            } catch {}
        }
        if (($Publisher -eq 'Unknown' -or [string]::IsNullOrWhiteSpace($Publisher)) -and
            -not [string]::IsNullOrWhiteSpace($sigInfo.SignedDisplay) -and
            $sigInfo.SignedDisplay -notin @('N/A', 'Not found', 'Unsigned', 'Unknown', 'N/A (COM)', 'Windows COM', 'Windows task', 'Windows driver', 'Windows boot')) {
            $Publisher = $sigInfo.SignedDisplay
        }
    }

    $riskPath = if (-not [string]::IsNullOrWhiteSpace($AnalysisFilePath)) { $AnalysisFilePath } else { $FilePath }
    $risk = Get-EntryRisk -Publisher $Publisher -FilePath $riskPath -IsSigned $IsSigned -IsCritical $IsCritical
    if (-not $PreserveRiskLevel -and -not [string]::IsNullOrWhiteSpace($risk.Band)) {
        $RiskLevel = $risk.Band
    }

    # Do not escalate protected Windows COM tasks to Warning just because there is no Exec image.
    $skipMissingFileRiskBump = $PreserveRiskLevel -and $RowType -eq 'ScheduledTask' -and $TaskActionKind -in @('Com', 'None')
    if ($analysis.HasWarning -and $RiskLevel -eq 'Safe' -and -not $skipMissingFileRiskBump -and -not ($RowType -eq 'WinlogonValue' -and $Name -in @('Userinit', 'Shell'))) {
        $RiskLevel = if ($analysis.Level -eq 'Warning') { 'Warning' } else { 'Caution' }
    }

    $entryType = switch ($RowType) {
        'WinlogonValue' { 'Winlogon' }
        'ScheduledTask' { 'ScheduledTask' }
        'MsixStartupTask' { 'MsixStartupTask' }
        default {
            if ($SourceGroup -match '\(GPO\)') { 'GpoRun' }
            elseif ($RowType -eq 'FileStartupItem') { 'Folder' }
            else { 'Registry' }
        }
    }
    $isGpoRun = ($SourceGroup -match '\(GPO\)') -or ($entryType -eq 'GpoRun')
    if ($isGpoRun) {
        $SupportsDelete = $false
    }
    $isRunOnce = $SourceGroup -match 'RunOnce'
    $resolvedPath = $FilePath
    $targetExists = $false
    if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
        $target = Resolve-StartupTarget -Command $FilePath
        if ($target.ResolvedPath) { $resolvedPath = [string]$target.ResolvedPath }
        $targetExists = [bool]$target.Exists
    }
    $hijackSuspicion = Test-PostOpStartupSuspicious `
        -Name $Name `
        -SourceGroup $SourceGroup `
        -ResolvedPath $resolvedPath `
        -Publisher $Publisher `
        -IsSigned $IsSigned `
        -RiskBand $RiskLevel `
        -IsRunOnce $isRunOnce `
        -TargetExists $targetExists `
        -EntryType $entryType `
        -IsWinlogonDeviated $IsDeviated `
        -WinlogonDeviationReason $DeviationReason

    return [PSCustomObject]@{
        Name = $Name
        Publisher = if ($Publisher) { $Publisher } else { 'Unknown' }
        FilePath = $FilePath
        Source = if ($Source) { $Source } else { $SourceGroup }
        Category = $Category
        RowType = $RowType
        SourceGroup = $SourceGroup
        RegistryPath = $RegistryPath
        ValueName = $ValueName
        RegistryKey = if ($RegistryKey) { $RegistryKey } else { $RegistryPath }
        OriginalData = $OriginalData
        ServiceName = $ServiceName
        Clsid = if ($Clsid) { $Clsid } else { '' }
        IsCritical = $IsCritical
        SupportsEnable = $SupportsEnable
        SupportsDisable = $SupportsDisable
        SupportsDelete = $SupportsDelete
        SupportsReset = $SupportsReset
        SupportsUndo = $SupportsUndo
        IsDeviated = $IsDeviated
        DeviationReason = $DeviationReason
        ActionStatePayload = if ($ActionStatePayload) { $ActionStatePayload } else { '' }
        CorrelationGroupId = if ($CorrelationGroupId) { $CorrelationGroupId } else { '' }
        CorrelationSummary = if ($CorrelationSummary) { $CorrelationSummary } else { '' }
        ReputationScore = $risk.Score
        ReputationBand = $risk.Band
        RiskLevel = $RiskLevel
        IsSigned = $IsSigned
        IsEnabled = $IsEnabled
        User = $user
        SignedBy = $sigInfo.SignedBy
        SignedDisplay = $sigInfo.SignedDisplay
        SignatureStatus = $sigInfo.SignatureStatus
        AnalysisLevel = $analysis.Level
        AnalysisDetail = $analysis.Detail
        HasAnalysisWarning = $analysis.HasWarning
        IsHijackSuspicious = [bool]$hijackSuspicion.IsSuspicious
    }
}

function New-ServiceRow {
    param(
        [string]$ServiceName,
        [string]$DisplayName,
        [string]$Status,
        [string]$StartupType,
        [string]$Description,
        [string]$PathName = '',
        [string]$StartName = ''
    )

    $sigInfo = Get-FileSignatureInfo -FilePath $PathName
    $analysis = Get-FileAnalysisInfo -FilePath $PathName
    $user = Get-EntryUserDisplay -ServiceStartName $StartName -RowType 'Service'

    return [PSCustomObject]@{
        ServiceName        = $ServiceName
        DisplayName        = $DisplayName
        Status             = $Status
        StartupType        = $StartupType
        Description        = $Description
        FilePath           = $PathName
        User               = $user
        SignedBy           = $sigInfo.SignedBy
        SignedDisplay      = $sigInfo.SignedDisplay
        SignatureStatus    = $sigInfo.SignatureStatus
        IsSigned           = $sigInfo.IsSigned
        AnalysisLevel      = $analysis.Level
        AnalysisDetail     = $analysis.Detail
        HasAnalysisWarning = $analysis.HasWarning
    }
}

function Resolve-StartupFolderEntryContext {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Entry path is required for startup folder actions.'
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    foreach ($context in (Get-StartupFolderContexts)) {
        $activeRoot = Resolve-DirectoryPath -Path $context.ActivePath
        $disabledRoot = Resolve-DirectoryPath -Path $context.DisabledPath

        if ($fullPath.StartsWith($disabledRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [PSCustomObject]@{
                FullPath    = $fullPath
                Context     = $context
                IsDisabled  = $true
            }
        }

        if ($fullPath.StartsWith($activeRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [PSCustomObject]@{
                FullPath    = $fullPath
                Context     = $context
                IsDisabled  = $false
            }
        }
    }

    throw "Path is not in a managed startup folder: $Path"
}

function Get-UniqueDestinationPath {
    param(
        [string]$Directory,
        [string]$Name
    )

    $candidate = Join-Path $Directory $Name
    if (-not (Test-Path -LiteralPath $candidate)) {
        return $candidate
    }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $extension = [System.IO.Path]::GetExtension($Name)
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'

    for ($i = 1; $i -le 999; $i++) {
        $altName = "{0}__migrated_{1}_{2}{3}" -f $baseName, $stamp, $i, $extension
        $candidate = Join-Path $Directory $altName
        if (-not (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    throw "Unable to generate a unique destination path in $Directory for $Name"
}

function Invoke-LegacyDisabledStartupMigration {
    # Moves items out of the old CDE_AutorunsDisabled subfolder (inside the Startup folder)
    # to the new external disabled path, preventing Windows from opening that folder in
    # Explorer on every boot.
    foreach ($context in (Get-StartupFolderContexts)) {
        $legacyPath = Join-Path $context.ActivePath 'CDE_AutorunsDisabled'
        if (-not (Test-Path $legacyPath)) { continue }

        if (-not (Test-Path -LiteralPath $context.DisabledPath)) {
            New-Item -Path $context.DisabledPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }

        Get-ChildItem -LiteralPath $legacyPath -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $dest = Join-Path $context.DisabledPath $_.Name
            if (Test-Path -LiteralPath $dest) {
                $dest = Get-UniqueDestinationPath -Directory $context.DisabledPath -Name $_.Name
            }

            Move-Item -LiteralPath $_.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
        }

        # Always remove legacy folder recursively to prevent Explorer auto-opening it on boot.
        if (Test-Path -LiteralPath $legacyPath) {
            Remove-Item -LiteralPath $legacyPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Add-StartupRegistryRunEntries {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[object]]$Entries,
        [string]$Category = 'StartupItems'
    )

    foreach ($k in @(Get-StandardStartupRunKeyDefinitions)) {
        $regPath = "$($k.Hive):\$($k.Key)"
        $sourceGroup = [string]$k.SourceGroup

        if (Test-Path $regPath -ErrorAction SilentlyContinue) {
            $props = Get-ItemProperty $regPath -ErrorAction SilentlyContinue
            if ($props) {
                $props.PSObject.Properties |
                Where-Object { $_.Name -notlike 'PS*' } |
                ForEach-Object {
                    $isEnabled = Get-StartupApprovedEnabledState `
                        -SourceGroup $sourceGroup `
                        -RowType 'RegistryValue' `
                        -ValueName $_.Name `
                        -Name $_.Name `
                        -FilePath ([string]$_.Value) `
                        -IsInActiveLocation $true
                    $registryPath = [string]$k.RegistryPath
                    $Entries.Add((New-StartupRow -Category $Category -RowType 'RegistryValue' -SourceGroup $sourceGroup -Name $_.Name -Publisher 'Unknown' -FilePath ([string]$_.Value) -Source $k.Hive -RegistryPath $registryPath -ValueName $_.Name -RegistryKey $registryPath -RiskLevel 'Caution' -IsEnabled $isEnabled)) | Out-Null
                }
            }
        }

        $disabledPath = "$($k.Hive):\$($k.Key)\AutorunsDisabled"
        if (Test-Path $disabledPath) {
            $props = Get-ItemProperty $disabledPath -ErrorAction SilentlyContinue
            if ($props) {
                $props.PSObject.Properties |
                Where-Object { $_.Name -notlike 'PS*' } |
                ForEach-Object {
                    $registryPath = [string]$k.RegistryPath
                    $Entries.Add((New-StartupRow -Category $Category -RowType 'RegistryValue' -SourceGroup $sourceGroup -Name $_.Name -Publisher 'Unknown' -FilePath ([string]$_.Value) -Source $k.Hive -RegistryPath $registryPath -ValueName $_.Name -RegistryKey $registryPath -RiskLevel 'Caution' -IsSigned $false -IsEnabled $false)) | Out-Null
                }
            }
        }
    }
}

function Add-StartupFolderEntries {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[object]]$Entries,
        [string]$Category = 'StartupItems'
    )

    foreach ($folderContext in (Get-StartupFolderContexts)) {
        if (Test-Path $folderContext.ActivePath) {
            Get-ChildItem $folderContext.ActivePath -File -ErrorAction SilentlyContinue | ForEach-Object {
                $isEnabled = Get-StartupApprovedEnabledState `
                    -SourceGroup $folderContext.Source `
                    -RowType 'FileStartupItem' `
                    -ValueName '' `
                    -Name $_.BaseName `
                    -FilePath $_.FullName `
                    -IsInActiveLocation $true
                $Entries.Add((New-StartupRow -Category $Category -RowType 'FileStartupItem' -SourceGroup $folderContext.Source -Name $_.BaseName -Publisher 'Unknown' -FilePath $_.FullName -Source $folderContext.Source -RegistryPath '' -ValueName '' -RegistryKey '' -RiskLevel 'Caution' -IsEnabled $isEnabled)) | Out-Null
            }
        }

        if (Test-Path $folderContext.DisabledPath) {
            Get-ChildItem $folderContext.DisabledPath -File -ErrorAction SilentlyContinue | ForEach-Object {
                $Entries.Add((New-StartupRow -Category $Category -RowType 'FileStartupItem' -SourceGroup $folderContext.Source -Name $_.BaseName -Publisher 'Unknown' -FilePath $_.FullName -Source $folderContext.Source -RegistryPath '' -ValueName '' -RegistryKey '' -RiskLevel 'Caution' -IsEnabled $false)) | Out-Null
            }
        }
    }
}

function Finalize-StartupEntryList {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[object]]$Entries
    )

    Add-StartupEntryCorrelations -Entries $Entries
    return ($Entries | ConvertTo-Json -Depth 4)
}

function Get-StartupEntries {
    $entries = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in (Get-WinlogonEntries)) {
        $entries.Add($entry)
    }

    Add-StartupRegistryRunEntries -Entries $entries -Category 'StartupItems'
    Add-StartupFolderEntries -Entries $entries -Category 'StartupItems'

    foreach ($msixRow in @(Get-MsixStartupTaskRows)) {
        $entries.Add((New-StartupRow @msixRow))
    }

    foreach ($taskRow in @(Get-StartupScheduledTaskRows -IncludeWindowsScheduledTasks:$IncludeWindowsScheduledTasks)) {
        $entries.Add((New-StartupRow @taskRow))
    }

    Finalize-StartupEntryList -Entries $entries
}

function Get-WinlogonEntries {
    $entries = [System.Collections.Generic.List[object]]::new()

    $winlogonContext = Get-WinlogonRegistryContext
    if (-not (Test-Path -LiteralPath $winlogonContext.PsPath -ErrorAction SilentlyContinue)) {
        return @($entries)
    }

    foreach ($name in @('Userinit', 'Shell')) {
        $valueText = Get-WinlogonRegistryValueText -Path $winlogonContext.PsPath -Name $name
        $publisher = 'Unknown'
        $isSigned = $false

        if (-not [string]::IsNullOrWhiteSpace($valueText)) {
            $resolved = Resolve-CommandPath -Command $valueText
            try {
                $item = Get-Item $resolved -ErrorAction SilentlyContinue
                if ($item) {
                    $publisher = $item.VersionInfo.CompanyName
                    $sig = Get-AuthenticodeSignature $item.FullName -ErrorAction SilentlyContinue
                    $isSigned = $sig.Status -eq 'Valid'
                }
            } catch {}
        }

        $deviation = Test-WinlogonValueDeviation -ValueName $name -CurrentValue $valueText
        $riskLevel = if ($deviation.IsDeviated) { 'Warning' } else { 'Safe' }
        $supportsReset = [bool]$deviation.IsDeviated
        $supportsUndo = Test-WinlogonUndoAvailable -ValueName $name -CurrentValue $valueText
        $displayValue = if ([string]::IsNullOrWhiteSpace($valueText)) { '(missing or empty)' } else { $valueText }

        $entries.Add((New-StartupRow -Category 'UserLogon' -RowType 'WinlogonValue' -SourceGroup 'Winlogon' -Name $name -Publisher $publisher -FilePath $displayValue -Source 'HKLM' -RegistryPath $winlogonContext.RegistryPath -ValueName $name -RegistryKey $winlogonContext.RegistryPath -RiskLevel $riskLevel -IsSigned $isSigned -IsEnabled $true -IsCritical $true -SupportsEnable $false -SupportsDisable $false -SupportsDelete $false -SupportsReset $supportsReset -SupportsUndo $supportsUndo -IsDeviated ([bool]$deviation.IsDeviated) -DeviationReason ([string]$deviation.Reason) -PreserveRiskLevel $true))
    }

    return @($entries)
}

function Reset-WinlogonRegistryValue {
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)]
        [ValidateSet('Userinit', 'Shell')]
        [string]$ValueName
    )

    if ($env:OFFLINE_WINDOWS_ROOT) {
        throw 'PROTECTED_OR_UNSUPPORTED: Winlogon reset is not supported for offline registry mode in this build.'
    }

    $fullKey = Resolve-StartupMutationRegistryPath -RawPath $RegistryPath
    $currentValue = Get-WinlogonRegistryValueText -Path $fullKey -Name $ValueName
    $deviation = Test-WinlogonValueDeviation -ValueName $ValueName -CurrentValue $currentValue
    if (-not $deviation.IsDeviated) {
        throw "Reset is only available when a confirmed deviation is detected for '$ValueName'."
    }

    $defaultValue = Get-WinlogonDefaultValue -ValueName $ValueName
    $backup = [PSCustomObject]@{
        valueName     = $ValueName
        registryPath  = $RegistryPath
        previousValue = $currentValue
        resetToDefault = $defaultValue
        backedUpAt    = (Get-Date).ToString('o')
        machineName   = $env:COMPUTERNAME
    }

    $backupPath = Get-WinlogonBackupFilePath -ValueName $ValueName
    $backup | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $backupPath -Encoding UTF8 -Force

    Set-WinlogonRegistryProperty -Path $fullKey -ValueName $ValueName -Value $defaultValue
    $verify = Get-WinlogonRegistryValueText -Path $fullKey -Name $ValueName
    if (-not (Test-WinlogonValueMatchesDefault -ValueName $ValueName -CurrentValue $verify)) {
        throw "Reset verification failed for '$ValueName'."
    }

    if ($ValueName -eq 'Userinit') {
        $kind = Get-WinlogonRegistryValueKind -ValueName 'Userinit'
        if ($kind -ne 'ExpandString') {
            throw "Reset verification failed for '$ValueName': expected REG_EXPAND_SZ."
        }
    }
}

function Undo-WinlogonRegistryValue {
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)]
        [ValidateSet('Userinit', 'Shell')]
        [string]$ValueName
    )

    if ($env:OFFLINE_WINDOWS_ROOT) {
        throw 'PROTECTED_OR_UNSUPPORTED: Winlogon undo is not supported for offline registry mode in this build.'
    }

    $backup = Get-WinlogonBackupRecord -ValueName $ValueName
    if ($null -eq $backup) {
        throw "No Winlogon backup is available for '$ValueName'."
    }

    $fullKey = Resolve-StartupMutationRegistryPath -RawPath $RegistryPath
    $currentValue = Get-ItemPropertyValue -Path $fullKey -Name $ValueName -ErrorAction Stop
    if (-not (Test-WinlogonUndoAvailable -ValueName $ValueName -CurrentValue ([string]$currentValue))) {
        throw "Undo is only available after a reset has restored '$ValueName' to the default value."
    }

    $restoreValue = [string]$backup.previousValue
    Set-WinlogonRegistryProperty -Path $fullKey -ValueName $ValueName -Value $restoreValue
    $verify = Get-WinlogonRegistryValueText -Path $fullKey -Name $ValueName
    if (-not (Test-WinlogonRegistryValuesEqual -Left $verify -Right $restoreValue)) {
        throw "Undo verification failed for '$ValueName'."
    }

    $backupPath = Get-WinlogonBackupFilePath -ValueName $ValueName
    if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-DriversEntries {
    $entries = [System.Collections.Generic.List[object]]::new()
    $servicesRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services'

    if (Test-Path $servicesRoot) {
        Get-ChildItem $servicesRoot -ErrorAction SilentlyContinue | ForEach-Object {
            $svcKey = $_
            $props = Get-ItemProperty -Path $svcKey.PSPath -ErrorAction SilentlyContinue
            if (-not $props) { return }

            $type = 0
            try { $type = [int]$props.Type } catch {}
            $isDriver = (($type -band 0x1) -ne 0) -or (($type -band 0x2) -ne 0) -or (($type -band 0x8) -ne 0)
            if (-not $isDriver) { return }

            $start = 3
            try { $start = [int]$props.Start } catch {}
            $isEnabled = $start -ne 4
            $isCritical = $start -eq 0 -or $start -eq 1

            $imagePath = [string]$props.ImagePath
            $supportsDisable = -not $isCritical
            $entries.Add((New-StartupRow -Category 'Drivers' -RowType 'DriverService' -SourceGroup 'Services Drivers' -Name $svcKey.PSChildName -Publisher 'Unknown' -FilePath $imagePath -Source 'HKLM' -RegistryPath ("HKLM\\SYSTEM\\CurrentControlSet\\Services\\{0}" -f $svcKey.PSChildName) -ValueName 'Start' -RegistryKey ("HKLM\\SYSTEM\\CurrentControlSet\\Services\\{0}" -f $svcKey.PSChildName) -RiskLevel 'Caution' -IsEnabled $isEnabled -ServiceName $svcKey.PSChildName -OriginalData ([string]$start) -IsCritical $isCritical -SupportsEnable $true -SupportsDisable $supportsDisable -SupportsDelete $false))
        }
    }

    $bootExecutePath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    if (Test-Path $bootExecutePath) {
        $bootExecute = Get-ItemPropertyValue -Path $bootExecutePath -Name 'BootExecute' -ErrorAction SilentlyContinue
        if ($bootExecute) {
            $commands = @($bootExecute)
            foreach ($command in $commands) {
                $entries.Add((New-StartupRow -Category 'Drivers' -RowType 'RegistryValue' -SourceGroup 'Boot Execute' -Name 'BootExecute' -Publisher 'Microsoft Corporation' -FilePath ([string]$command) -Source 'HKLM' -RegistryPath 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager' -ValueName 'BootExecute' -RegistryKey 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager' -RiskLevel 'Safe' -PreserveRiskLevel $true -IsSigned $true -IsEnabled $true -IsCritical $true -SupportsEnable $false -SupportsDisable $false -SupportsDelete $false))
            }
        }
    }

    $entries | ConvertTo-Json -Depth 5
}

function Get-UserLogonEntries {
    $entries = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in (Get-WinlogonEntries)) {
        $entries.Add($entry)
    }

    Add-StartupRegistryRunEntries -Entries $entries -Category 'UserLogon'
    Add-StartupFolderEntries -Entries $entries -Category 'UserLogon'

    foreach ($msixRow in @(Get-MsixStartupTaskRows)) {
        $entries.Add((New-StartupRow @msixRow))
    }

    foreach ($taskRow in @(Get-StartupScheduledTaskRows -IncludeWindowsScheduledTasks:$IncludeWindowsScheduledTasks)) {
        $entries.Add((New-StartupRow @taskRow))
    }

    Finalize-StartupEntryList -Entries $entries
}

function Get-ExtensionsEntries {
    $entries = [System.Collections.Generic.List[object]]::new()

    foreach ($row in @(Get-LegacyIeExtensionDiscoveryRows)) {
        $entries.Add((New-StartupRow @row)) | Out-Null
    }

    foreach ($row in @(Get-InstalledBrowserExtensionDiscoveryRows)) {
        $entries.Add((New-StartupRow @row)) | Out-Null
    }

    @($entries | Sort-Object SourceGroup, User, Name) | ConvertTo-Json -Depth 5
}

function Set-DriverEntryState {
    param(
        [string]$ServiceName,
        [string]$RegistryPath,
        [bool]$Enable,
        [string]$OriginalStart = ''
    )

    if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
        throw 'RegistryPath is required for driver entry actions.'
    }

    $fullKey = Resolve-StartupMutationRegistryPath -RawPath $RegistryPath
    $start = Get-ItemPropertyValue -Path $fullKey -Name 'Start' -ErrorAction Stop
    $isCritical = ([int]$start -eq 0) -or ([int]$start -eq 1)

    if (-not $Enable -and $isCritical) {
        throw "PROTECTED_OR_UNSUPPORTED: Cannot disable boot/system critical driver '$ServiceName'."
    }

    $priorStartProperty = 'CDE_PriorStart'
    if ($Enable) {
        $targetStart = 3
        try {
            $priorStart = Get-ItemPropertyValue -Path $fullKey -Name $priorStartProperty -ErrorAction Stop
            $targetStart = [int]$priorStart
            Remove-ItemProperty -Path $fullKey -Name $priorStartProperty -ErrorAction SilentlyContinue
        } catch {
            if (-not [string]::IsNullOrWhiteSpace($OriginalStart)) {
                try { $targetStart = [int]$OriginalStart } catch { }
            }
        }

        if ($targetStart -eq 4) {
            $targetStart = 3
        }
    } else {
        Set-ItemProperty -Path $fullKey -Name $priorStartProperty -Value ([int]$start) -ErrorAction Stop
        $targetStart = 4
    }

    Set-ItemProperty -Path $fullKey -Name 'Start' -Value $targetStart -ErrorAction Stop

    $verify = Get-ItemPropertyValue -Path $fullKey -Name 'Start' -ErrorAction Stop
    if ([int]$verify -ne $targetStart) {
        throw "Driver start-state verification failed for '$ServiceName'."
    }
}

function Set-RegistryValueEntryState {
    param(
        [string]$RegistryPath,
        [string]$ValueName,
        [bool]$Enable,
        [string]$SourceGroup = ''
    )

    if ([string]::IsNullOrWhiteSpace($RegistryPath) -or [string]::IsNullOrWhiteSpace($ValueName)) {
        throw 'RegistryPath and ValueName are required for registry value actions.'
    }

    $fullKey = Resolve-StartupMutationRegistryPath -RawPath $RegistryPath
    $disabledKey = "$fullKey\AutorunsDisabled"
    $approvedCategory = Get-StartupApprovedCategoryForSource -SourceGroup $SourceGroup -RowType 'RegistryValue'
    if ([string]::IsNullOrWhiteSpace($SourceGroup)) {
        if ($RegistryPath -match 'WOW6432Node') { $approvedCategory = 'Run32' }
    }

    if ($Enable) {
        if (Test-Path $disabledKey) {
            $value = Get-ItemPropertyValue -Path $disabledKey -Name $ValueName -ErrorAction Stop
            Set-ItemProperty -Path $fullKey -Name $ValueName -Value $value -ErrorAction Stop
            Remove-ItemProperty -Path $disabledKey -Name $ValueName -ErrorAction Stop
            Set-StartupApprovedEntryEnabled -Category $approvedCategory -EntryName $ValueName -Enable $true
            return
        }

        if (Test-Path $fullKey) {
            $null = Get-ItemPropertyValue -Path $fullKey -Name $ValueName -ErrorAction Stop
            Set-StartupApprovedEntryEnabled -Category $approvedCategory -EntryName $ValueName -Enable $true
            return
        }

        throw "Disabled key not found: $disabledKey"
    }

    if (-not (Test-Path $fullKey)) {
        throw "Active registry key not found: $RegistryPath"
    }

    $value = Get-ItemPropertyValue -Path $fullKey -Name $ValueName -ErrorAction Stop
    Set-StartupApprovedEntryEnabled -Category $approvedCategory -EntryName $ValueName -Enable $false
    if (-not (Test-Path $disabledKey)) {
        New-Item -Path $disabledKey -Force -ErrorAction Stop | Out-Null
    }

    Set-ItemProperty -Path $disabledKey -Name $ValueName -Value $value -ErrorAction Stop
    Remove-ItemProperty -Path $fullKey -Name $ValueName -ErrorAction Stop
}

function Remove-RegistryValueEntry {
    param(
        [string]$RegistryPath,
        [string]$ValueName,
        [string]$SourceGroup = ''
    )

    if ([string]::IsNullOrWhiteSpace($RegistryPath) -or [string]::IsNullOrWhiteSpace($ValueName)) {
        throw 'RegistryPath and ValueName are required for registry value delete.'
    }

    $fullKey = Resolve-StartupMutationRegistryPath -RawPath $RegistryPath
    $disabledKey = "$fullKey\AutorunsDisabled"

    try {
        Remove-ItemProperty -Path $fullKey -Name $ValueName -ErrorAction Stop
    } catch {
        $removeErr = $_.Exception.Message
        $stillPresent = $false
        try {
            $null = Get-ItemPropertyValue -Path $fullKey -Name $ValueName -ErrorAction Stop
            $stillPresent = $true
        } catch {
            $stillPresent = $false
        }

        if ($stillPresent) {
            throw "Delete failed for registry value '$ValueName' under $RegistryPath`: $removeErr"
        }
    }

    if (Test-Path $disabledKey) {
        try {
            Remove-ItemProperty -Path $disabledKey -Name $ValueName -ErrorAction Stop
        } catch {
            $disabledErr = $_.Exception.Message
            $disabledPresent = $false
            try {
                $null = Get-ItemPropertyValue -Path $disabledKey -Name $ValueName -ErrorAction Stop
                $disabledPresent = $true
            } catch {
                $disabledPresent = $false
            }

            if ($disabledPresent) {
                throw "Delete failed for disabled registry value '$ValueName' under $disabledKey`: $disabledErr"
            }
        }
    }

    $verifyActive = $false
    try {
        $null = Get-ItemPropertyValue -Path $fullKey -Name $ValueName -ErrorAction Stop
        $verifyActive = $true
    } catch {
        $verifyActive = $false
    }

    if ($verifyActive) {
        throw "Delete verification failed for registry value '$ValueName' under $RegistryPath"
    }

    Sync-StartupApprovedAfterMutation -SourceGroup $SourceGroup -RegistryPath $RegistryPath -RowType 'RegistryValue' -ValueName $ValueName -Name $ValueName -Action Remove
}

function Set-RegistrySubKeyEntryState {
    param(
        [string]$RegistryPath,
        [string]$SubKeyName,
        [string]$Action
    )

    if ([string]::IsNullOrWhiteSpace($RegistryPath) -or [string]::IsNullOrWhiteSpace($SubKeyName)) {
        throw 'RegistryPath and SubKeyName are required for registry subkey actions.'
    }

    $fullKey = Resolve-StartupMutationRegistryPath -RawPath $RegistryPath
    $disabledContainer = "$fullKey\CDE_Disabled"
    $activeSubKey = "$fullKey\$SubKeyName"
    $disabledSubKey = "$disabledContainer\$SubKeyName"

    switch ($Action) {
        'Enable' {
            if (-not (Test-Path $disabledSubKey)) {
                throw "Disabled subkey not found: $disabledSubKey"
            }

            if (Test-Path $activeSubKey) {
                throw "Active subkey already exists: $activeSubKey"
            }

            Copy-Item -Path $disabledSubKey -Destination $activeSubKey -Recurse -Force -ErrorAction Stop
            Remove-Item -Path $disabledSubKey -Recurse -Force -ErrorAction Stop
        }
        'Disable' {
            if (-not (Test-Path $activeSubKey)) {
                throw "Active subkey not found: $activeSubKey"
            }

            if (-not (Test-Path $disabledContainer)) {
                New-Item -Path $disabledContainer -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }

            if (Test-Path $disabledSubKey) {
                throw "Disabled subkey already exists: $disabledSubKey"
            }

            Copy-Item -Path $activeSubKey -Destination $disabledSubKey -Recurse -Force -ErrorAction Stop
            Remove-Item -Path $activeSubKey -Recurse -Force -ErrorAction Stop
        }
        'Delete' {
            $removed = $false
            if (Test-Path $activeSubKey) {
                Remove-Item -Path $activeSubKey -Recurse -Force -ErrorAction Stop
                $removed = $true
            }

            if (Test-Path $disabledSubKey) {
                Remove-Item -Path $disabledSubKey -Recurse -Force -ErrorAction Stop
                $removed = $true
            }

            if (-not $removed) {
                throw "Registry subkey not found: $SubKeyName"
            }
        }
    }
}

function Get-Services {
    $services = @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue)
    if ($services.Count -gt 0) {
        $services | ForEach-Object {
            $normalizedStartType = Resolve-ServiceStartType -Value ([string]$_.StartMode)
            New-ServiceRow `
                -ServiceName $(if ([string]::IsNullOrWhiteSpace($_.Name)) { 'Unknown' } else { [string]$_.Name }) `
                -DisplayName $(if ([string]::IsNullOrWhiteSpace($_.DisplayName)) { [string]$_.Name } else { [string]$_.DisplayName }) `
                -Status $(if ([string]::IsNullOrWhiteSpace($_.State)) { 'Unknown' } else { [string]$_.State }) `
                -StartupType $normalizedStartType `
                -Description $(if ([string]::IsNullOrWhiteSpace($_.Description)) { '' } else { [string]$_.Description }) `
                -PathName $(if ($_.PathName) { [string]$_.PathName } else { '' }) `
                -StartName $(if ($_.StartName) { [string]$_.StartName } else { '' })
        } | ConvertTo-Json -Depth 3
        return
    }

    Get-Service -ErrorAction SilentlyContinue | ForEach-Object {
        $svc = $_
        $status = 'Unknown'
        $startup = 'Manual'
        $display = ''
        $pathName = ''
        $startName = ''

        try { $display = $svc.DisplayName } catch {}
        try { $status = [string]$svc.Status } catch {}
        try { $startup = Resolve-ServiceStartType -Value ([string]$svc.StartType) } catch {}
        try {
            $cim = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f ($svc.Name -replace "'", "''")) -ErrorAction SilentlyContinue
            if ($cim) {
                $pathName = [string]$cim.PathName
                $startName = [string]$cim.StartName
            }
        } catch {}

        New-ServiceRow `
            -ServiceName ([string]$svc.Name) `
            -DisplayName $(if ([string]::IsNullOrWhiteSpace($display)) { [string]$svc.Name } else { $display }) `
            -Status $status `
            -StartupType $startup `
            -Description '' `
            -PathName $pathName `
            -StartName $startName
    } | ConvertTo-Json -Depth 3
}

function Resolve-RegistryPath {
    param([string]$RawPath)

    if ([string]::IsNullOrWhiteSpace($RawPath)) {
        throw "Registry key path is required for this action."
    }

    $fullKey = $RawPath -replace '^HKLM\\','HKLM:\\' -replace '^HKCU\\','HKCU:\\' -replace '^HKU\\','HKU:\\'
    if ($fullKey -notmatch '^(HKLM:|HKCU:|HKU:)') {
        throw "Unsupported registry path: $RawPath"
    }

    return $fullKey
}

function ConvertTo-StartupRegistryComparePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $normalized = $Path.Trim()
    $normalized = $normalized -replace '\\+', '\'
    $normalized = $normalized -replace ':$', ''
    $normalized = $normalized -replace '^HKLM:', 'HKLM\' -replace '^HKCU:', 'HKCU\' -replace '^HKU:', 'HKU\'
    $normalized = $normalized -replace '\\+', '\'
    return $normalized.TrimEnd('\').ToUpperInvariant()
}

function Get-StartupMutationAllowedRegistryRoots {
    $roots = [System.Collections.Generic.List[string]]::new()

    foreach ($def in @(Get-StandardStartupRunKeyDefinitions)) {
        $path = ConvertTo-StartupRegistryComparePath -Path ([string]$def.RegistryPath)
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $roots.Add($path) | Out-Null
        }
    }

    $winlogon = Get-WinlogonRegistryContext
    $roots.Add((ConvertTo-StartupRegistryComparePath -Path ([string]$winlogon.RegistryPath))) | Out-Null

    $roots.Add((ConvertTo-StartupRegistryComparePath -Path 'HKLM\SYSTEM\CurrentControlSet\Services')) | Out-Null
    $roots.Add((ConvertTo-StartupRegistryComparePath -Path 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager')) | Out-Null
    $roots.Add((ConvertTo-StartupRegistryComparePath -Path (Get-StartupApprovedRegistryRoot))) | Out-Null
    $roots.Add((ConvertTo-StartupRegistryComparePath -Path (Get-MsixStartupTaskRegistryRoot))) | Out-Null

    $extensionKeys = @(
        'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Browser Helper Objects',
        'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\Browser Helper Objects',
        'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Browser Helper Objects',
        'HKLM\SOFTWARE\Microsoft\Internet Explorer\Toolbar',
        'HKLM\SOFTWARE\WOW6432Node\Microsoft\Internet Explorer\Toolbar',
        'HKCU\SOFTWARE\Microsoft\Internet Explorer\Toolbar',
        'HKLM\SOFTWARE\Microsoft\Internet Explorer\URLSearchHooks',
        'HKCU\SOFTWARE\Microsoft\Internet Explorer\URLSearchHooks'
    )
    foreach ($key in $extensionKeys) {
        $roots.Add((ConvertTo-StartupRegistryComparePath -Path $key)) | Out-Null
    }

    return @($roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Assert-StartupMutationPathAllowed {
    param([Parameter(Mandatory)][string]$RegistryPath)

    $candidate = ConvertTo-StartupRegistryComparePath -Path $RegistryPath
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        throw "PROTECTED_OR_UNSUPPORTED: Empty registry path is not allowed for mutation."
    }

    foreach ($root in @(Get-StartupMutationAllowedRegistryRoots)) {
        if ($candidate -eq $root -or $candidate.StartsWith($root + '\', [System.StringComparison]::Ordinal)) {
            return
        }
    }

    throw "PROTECTED_OR_UNSUPPORTED: Registry path is outside Startup Manager mutation allowlist: $RegistryPath"
}

function Resolve-StartupMutationRegistryPath {
    param([string]$RawPath)

    $fullKey = Resolve-RegistryPath -RawPath $RawPath
    Assert-StartupMutationPathAllowed -RegistryPath $fullKey
    return $fullKey
}

function Sync-StartupApprovedAfterMutation {
    param(
        [string]$SourceGroup = '',
        [string]$RegistryPath = '',
        [string]$RowType = 'RegistryValue',
        [string]$ValueName = '',
        [string]$Name = '',
        [string]$FilePath = '',
        [ValidateSet('Enable', 'Disable', 'Remove')]
        [string]$Action = 'Remove'
    )

    $category = Get-StartupApprovedCategoryForSource -SourceGroup $SourceGroup -RowType $RowType
    if ([string]::IsNullOrWhiteSpace($SourceGroup) -and $RegistryPath -match 'WOW6432Node') {
        $category = 'Run32'
    }

    $entryName = Get-StartupApprovedEntryName -RowType $RowType -ValueName $ValueName -Name $Name -FilePath $FilePath
    if ([string]::IsNullOrWhiteSpace($category) -or [string]::IsNullOrWhiteSpace($entryName)) {
        return
    }

    switch ($Action) {
        'Enable' { Set-StartupApprovedEntryEnabled -Category $category -EntryName $entryName -Enable $true }
        'Disable' { Set-StartupApprovedEntryEnabled -Category $category -EntryName $entryName -Enable $false }
        'Remove' { Remove-StartupApprovedEntry -Category $category -EntryName $entryName }
    }
}

# Keep startup-folder migration active across all actions so legacy paths are cleaned
# even when callers do not first execute the List action.
if (Invoke-StartupManagerElevationRelay) { exit 0 }

Invoke-LegacyDisabledStartupMigration

switch ($Action) {
    'List'         { Get-StartupEntries }
    'ListStartupItems' { Get-StartupEntries }
    'ListDrivers'  { Get-DriversEntries }
    'ListUserLogon' { Get-UserLogonEntries }
    'ListExtensions' { Get-ExtensionsEntries }
    'ListServices' { Get-Services }
    'EnableEntry' {
        try {
            switch ($RowType) {
                'DriverService' {
                    Set-DriverEntryState -ServiceName $ServiceName -RegistryPath $RegistryPath -Enable $true -OriginalStart $ActionStatePayload
                    Write-Output "Enabled: $ServiceName"
                }
                'RegistryValue' {
                    Set-RegistryValueEntryState -RegistryPath $RegistryPath -ValueName $ValueName -Enable $true -SourceGroup $SourceGroup
                    Write-Output "Enabled: $ValueName"
                }
                'RegistryKey' {
                    Set-RegistrySubKeyEntryState -RegistryPath $RegistryPath -SubKeyName $EntryName -Action 'Enable'
                    Write-Output "Enabled: $EntryName"
                }
                'MsixStartupTask' {
                    Set-MsixStartupTaskEntryState -RegistryPath $RegistryPath -ValueName $ValueName -Enable $true
                    Write-Output "Enabled: $EntryName"
                }
                'ScheduledTask' {
                    Set-StartupScheduledTaskEntryState -TaskName $ServiceName -TaskPath $ActionStatePayload -Enable $true
                    Write-Output "Enabled: $EntryName"
                }
                default {
                    throw "Unsupported row type for EnableEntry: $RowType"
                }
            }
        } catch {
            Write-Error "EnableEntry failed for ${EntryName}: $($_.Exception.Message)"
        }
    }
    'DisableEntry' {
        try {
            switch ($RowType) {
                'DriverService' {
                    Set-DriverEntryState -ServiceName $ServiceName -RegistryPath $RegistryPath -Enable $false
                    Write-Output "Disabled: $ServiceName"
                }
                'RegistryValue' {
                    Set-RegistryValueEntryState -RegistryPath $RegistryPath -ValueName $ValueName -Enable $false -SourceGroup $SourceGroup
                    Write-Output "Disabled: $ValueName"
                }
                'RegistryKey' {
                    Set-RegistrySubKeyEntryState -RegistryPath $RegistryPath -SubKeyName $EntryName -Action 'Disable'
                    Write-Output "Disabled: $EntryName"
                }
                'MsixStartupTask' {
                    Set-MsixStartupTaskEntryState -RegistryPath $RegistryPath -ValueName $ValueName -Enable $false
                    Write-Output "Disabled: $EntryName"
                }
                'ScheduledTask' {
                    Set-StartupScheduledTaskEntryState -TaskName $ServiceName -TaskPath $ActionStatePayload -Enable $false
                    Write-Output "Disabled: $EntryName"
                }
                default {
                    throw "Unsupported row type for DisableEntry: $RowType"
                }
            }
        } catch {
            Write-Error "DisableEntry failed for ${EntryName}: $($_.Exception.Message)"
        }
    }
    'DeleteEntry' {
        try {
            switch ($RowType) {
                'DriverService' {
                    throw "PROTECTED_OR_UNSUPPORTED: Delete is not supported for driver services."
                }
                'RegistryValue' {
                    Remove-RegistryValueEntry -RegistryPath $RegistryPath -ValueName $ValueName -SourceGroup $SourceGroup
                    Write-Output "Deleted: $ValueName"
                }
                'RegistryKey' {
                    Set-RegistrySubKeyEntryState -RegistryPath $RegistryPath -SubKeyName $EntryName -Action 'Delete'
                    Write-Output "Deleted: $EntryName"
                }
                'MsixStartupTask' {
                    throw 'PROTECTED_OR_UNSUPPORTED: Delete is not supported for MSIX startup tasks. Disable instead.'
                }
                'ScheduledTask' {
                    Remove-StartupScheduledTaskEntry -TaskName $ServiceName -TaskPath $ActionStatePayload
                    Write-Output "Deleted: $EntryName"
                }
                default {
                    throw "Unsupported row type for DeleteEntry: $RowType"
                }
            }
        } catch {
            Write-Error "DeleteEntry failed for ${EntryName}: $($_.Exception.Message)"
        }
    }
    'ResetWinlogonEntry' {
        try {
            if ($RowType -ne 'WinlogonValue') {
                throw "Unsupported row type for ResetWinlogonEntry: $RowType"
            }

            $targetName = if (-not [string]::IsNullOrWhiteSpace($ValueName)) { $ValueName } else { $EntryName }
            Reset-WinlogonRegistryValue -RegistryPath $RegistryPath -ValueName $targetName
            Write-Output "Reset: $targetName"
        } catch {
            Write-Error "ResetWinlogonEntry failed for ${EntryName}: $($_.Exception.Message)"
        }
    }
    'UndoWinlogonEntry' {
        try {
            if ($RowType -ne 'WinlogonValue') {
                throw "Unsupported row type for UndoWinlogonEntry: $RowType"
            }

            $targetName = if (-not [string]::IsNullOrWhiteSpace($ValueName)) { $ValueName } else { $EntryName }
            Undo-WinlogonRegistryValue -RegistryPath $RegistryPath -ValueName $targetName
            Write-Output "Undo: $targetName"
        } catch {
            Write-Error "UndoWinlogonEntry failed for ${EntryName}: $($_.Exception.Message)"
        }
    }
    'Enable' {
        try {
            if (-not [string]::IsNullOrWhiteSpace($EntryKey)) {
                $fullKey = Resolve-StartupMutationRegistryPath -RawPath $EntryKey
                $disabledKey = "$fullKey\AutorunsDisabled"
                if (-not (Test-Path $disabledKey)) {
                    throw "Disabled key not found: $disabledKey"
                }

                $val = Get-ItemPropertyValue -Path $disabledKey -Name $EntryName -ErrorAction Stop
                Set-ItemProperty -Path $fullKey -Name $EntryName -Value $val -ErrorAction Stop
                Remove-ItemProperty -Path $disabledKey -Name $EntryName -ErrorAction Stop

                $verify = Get-ItemPropertyValue -Path $fullKey -Name $EntryName -ErrorAction Stop
                if ("$verify" -ne "$val") {
                    throw "Enable verification failed for $EntryName"
                }

                $approvedCategory = if ($EntryKey -match 'WOW6432Node') { 'Run32' } else { 'Run' }
                Set-StartupApprovedEntryEnabled -Category $approvedCategory -EntryName $EntryName -Enable $true
            } else {
                $resolved = Resolve-StartupFolderEntryContext -Path $EntryPath
                if (-not $resolved.IsDisabled) {
                    throw "Startup folder item is already enabled: $EntryPath"
                }
                if (-not (Test-Path $resolved.FullPath)) {
                    throw "Startup folder item not found: $EntryPath"
                }

                $targetPath = Join-Path $resolved.Context.ActivePath ([System.IO.Path]::GetFileName($resolved.FullPath))
                if (Test-Path $targetPath) {
                    throw "Enable target already exists: $targetPath"
                }

                Move-Item -LiteralPath $resolved.FullPath -Destination $targetPath -Force -ErrorAction Stop
                if (-not (Test-Path $targetPath)) {
                    throw "Enable verification failed for $EntryPath"
                }

                $fileName = [System.IO.Path]::GetFileName($targetPath)
                Set-StartupApprovedEntryEnabled -Category 'StartupFolder' -EntryName $fileName -Enable $true
            }

            Write-Output "Enabled: $EntryName"
        } catch {
            Write-Error "Enable failed for ${EntryName}: $($_.Exception.Message)"
        }
    }
    'Disable' {
        try {
            if (-not [string]::IsNullOrWhiteSpace($EntryKey)) {
                $fullKey = Resolve-StartupMutationRegistryPath -RawPath $EntryKey
                $val = Get-ItemPropertyValue -Path $fullKey -Name $EntryName -ErrorAction Stop
                $disabledKey = "$fullKey\AutorunsDisabled"
                if (-not (Test-Path $disabledKey)) { New-Item -Path $disabledKey -Force -ErrorAction Stop | Out-Null }

                Set-ItemProperty -Path $disabledKey -Name $EntryName -Value $val -ErrorAction Stop
                Remove-ItemProperty -Path $fullKey -Name $EntryName -ErrorAction Stop

                $disabledVerify = Get-ItemPropertyValue -Path $disabledKey -Name $EntryName -ErrorAction Stop
                $stillEnabled = $false
                try {
                    $null = Get-ItemPropertyValue -Path $fullKey -Name $EntryName -ErrorAction Stop
                    $stillEnabled = $true
                } catch {
                    $stillEnabled = $false
                }

                if ("$disabledVerify" -ne "$val" -or $stillEnabled) {
                    throw "Disable verification failed for $EntryName"
                }

                $approvedCategory = if ($EntryKey -match 'WOW6432Node') { 'Run32' } else { 'Run' }
                Set-StartupApprovedEntryEnabled -Category $approvedCategory -EntryName $EntryName -Enable $false
            } else {
                $resolved = Resolve-StartupFolderEntryContext -Path $EntryPath
                if ($resolved.IsDisabled) {
                    throw "Startup folder item is already disabled: $EntryPath"
                }
                if (-not (Test-Path $resolved.FullPath)) {
                    throw "Startup folder item not found: $EntryPath"
                }

                if (-not (Test-Path $resolved.Context.DisabledPath)) {
                    New-Item -Path $resolved.Context.DisabledPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }

                $targetPath = Join-Path $resolved.Context.DisabledPath ([System.IO.Path]::GetFileName($resolved.FullPath))
                if (Test-Path $targetPath) {
                    throw "Disable target already exists: $targetPath"
                }

                $fileName = [System.IO.Path]::GetFileName($resolved.FullPath)
                Set-StartupApprovedEntryEnabled -Category 'StartupFolder' -EntryName $fileName -Enable $false

                Move-Item -LiteralPath $resolved.FullPath -Destination $targetPath -Force -ErrorAction Stop
                if (-not (Test-Path $targetPath)) {
                    throw "Disable verification failed for $EntryPath"
                }
            }

            Write-Output "Disabled: $EntryName"
        } catch {
            Write-Error "Disable failed for ${EntryName}: $($_.Exception.Message)"
        }
    }
    'Delete' {
        try {
            if (-not [string]::IsNullOrWhiteSpace($EntryKey)) {
                $fullKey = Resolve-StartupMutationRegistryPath -RawPath $EntryKey
                Remove-ItemProperty -Path $fullKey -Name $EntryName -ErrorAction Stop

                $exists = $false
                try {
                    $null = Get-ItemPropertyValue -Path $fullKey -Name $EntryName -ErrorAction Stop
                    $exists = $true
                } catch {
                    $exists = $false
                }

                if ($exists) {
                    throw "Delete verification failed for $EntryName"
                }

                Sync-StartupApprovedAfterMutation -SourceGroup $SourceGroup -RegistryPath $EntryKey -RowType 'RegistryValue' -ValueName $EntryName -Name $EntryName -Action Remove
            } else {
                $resolved = Resolve-StartupFolderEntryContext -Path $EntryPath
                if (-not (Test-Path $resolved.FullPath)) {
                    throw "Startup folder item not found: $EntryPath"
                }

                $fileName = [System.IO.Path]::GetFileName($resolved.FullPath)
                Remove-Item -LiteralPath $resolved.FullPath -Force -ErrorAction Stop
                if (Test-Path $resolved.FullPath) {
                    throw "Delete verification failed for $EntryPath"
                }

                Sync-StartupApprovedAfterMutation -RowType 'FileStartupItem' -Name $EntryName -FilePath $resolved.FullPath -ValueName $fileName -Action Remove
            }

            Write-Output "Deleted: $EntryName"
        } catch {
            Write-Error "Delete failed for ${EntryName}: $($_.Exception.Message)"
        }
    }
    'StartService' {
        try {
            if (-not (Test-ServiceExists -ServiceName $ServiceName)) {
                throw "SERVICE_NOT_FOUND: Service '$ServiceName' was not found"
            }

            $current = Get-Service -Name $ServiceName -ErrorAction Stop
            if ($current.Status -eq 'Running') {
                Write-Output "ALREADY_IN_DESIRED_STATE: Service '$ServiceName' is already running"
                break
            }

            Start-Service -Name $ServiceName -ErrorAction Stop
            $status = (Get-Service -Name $ServiceName -ErrorAction Stop).Status
            if ($status -ne 'Running') { throw "Service status is $status" }
            Write-Output "Started: $ServiceName"
        } catch {
            Write-Error (Get-ServiceActionFailure -Action 'StartService' -ServiceName $ServiceName -ErrorRecord $_)
        }
    }
    'StopService' {
        try {
            if (-not (Test-ServiceExists -ServiceName $ServiceName)) {
                throw "SERVICE_NOT_FOUND: Service '$ServiceName' was not found"
            }

            $current = Get-Service -Name $ServiceName -ErrorAction Stop
            if ($current.Status -eq 'Stopped') {
                Write-Output "ALREADY_IN_DESIRED_STATE: Service '$ServiceName' is already stopped"
                break
            }

            Stop-Service -Name $ServiceName -Force -ErrorAction Stop
            $status = (Get-Service -Name $ServiceName -ErrorAction Stop).Status
            if ($status -ne 'Stopped') { throw "Service status is $status" }
            Write-Output "Stopped: $ServiceName"
        } catch {
            Write-Error (Get-ServiceActionFailure -Action 'StopService' -ServiceName $ServiceName -ErrorRecord $_)
        }
    }
    'SetStartType' {
        try {
            if (-not (Test-ServiceExists -ServiceName $ServiceName)) {
                throw "SERVICE_NOT_FOUND: Service '$ServiceName' was not found"
            }

            $normalizedStartType = Resolve-ServiceStartType -Value $StartType
            $currentType = Resolve-ServiceStartType -Value ((Get-Service -Name $ServiceName -ErrorAction Stop).StartType.ToString())
            if ($currentType -eq $normalizedStartType) {
                Write-Output "ALREADY_IN_DESIRED_STATE: Service '$ServiceName' is already set to $normalizedStartType"
                break
            }

            Set-Service -Name $ServiceName -StartupType $normalizedStartType -ErrorAction Stop
            $actualType = (Get-Service -Name $ServiceName -ErrorAction Stop).StartType.ToString()
            $normalizedActualType = Resolve-ServiceStartType -Value $actualType
            if ($normalizedActualType -ne $normalizedStartType) {
                throw "StartupType verification failed. Expected $normalizedStartType, got $actualType"
            }
            Write-Output "Set $ServiceName to $normalizedStartType"
        } catch {
            Write-Error (Get-ServiceActionFailure -Action 'SetStartType' -ServiceName $ServiceName -ErrorRecord $_)
        }
    }
    'RestartService' {
        try {
            if (-not (Test-ServiceExists -ServiceName $ServiceName)) {
                throw "SERVICE_NOT_FOUND: Service '$ServiceName' was not found"
            }

            $current = Get-Service -Name $ServiceName -ErrorAction Stop
            if ($current.Status -eq 'Stopped') {
                Start-Service -Name $ServiceName -ErrorAction Stop
            } else {
                Restart-Service -Name $ServiceName -Force -ErrorAction Stop
            }

            $status = (Get-Service -Name $ServiceName -ErrorAction Stop).Status
            if ($status -ne 'Running') { throw "Service status is $status" }
            Write-Output "Restarted: $ServiceName"
        } catch {
            Write-Error (Get-ServiceActionFailure -Action 'RestartService' -ServiceName $ServiceName -ErrorRecord $_)
        }
    }
}
