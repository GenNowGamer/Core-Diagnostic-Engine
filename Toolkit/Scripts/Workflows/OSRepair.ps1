#Requires -Version 5.1
<#
.SYNOPSIS
    OSRepair.ps1 - Individual OS repair tools dispatcher.
    Pass -ToolName to run a specific tool, or omit for SFC+DISM.
#>

param(
    [string]$ToolName     = 'All',
    [string]$WindowsDir   = 'C:\Windows',
    [string]$UpdateAction = '',
    [string]$PackageName  = '',
    [string]$DismSource   = '',
    [int]$DismSourceIndex = 0,
    [switch]$ElevatedRelay
)

# --- Offline update package enumeration (GUI picker query mode) -------------
# Read-only. Lists installed/removable update packages on the offline image as
# JSON, then returns WITHOUT running the workflow. The GUI calls this first to
# populate the package picker. -WindowsDir is supplied explicitly by the GUI.
# NOTE: DISM field labels are English (Package Identity / State / Release Type /
#       Install Time); a localized WinPE would need label mapping.
if ($ToolName -eq 'OfflineUpdateUninstall' -and $UpdateAction -eq 'ListPackages') {
    $ErrorActionPreference = 'Stop'
    $imageRoot = ($WindowsDir | Split-Path -Qualifier) + '\'
    $raw = (& dism.exe "/Image:$imageRoot" /Get-Packages 2>&1 | Out-String)
    $packages = @()
    $cur = $null
    foreach ($line in ($raw -split "`r?`n")) {
        if     ($line -match '^\s*Package Identity\s*:\s*(.+?)\s*$') {
            if ($cur) { $packages += $cur }
            $cur = [PSCustomObject]@{ PackageName = $Matches[1]; State = ''; ReleaseType = ''; InstallTime = '' }
        }
        elseif ($cur -and $line -match '^\s*State\s*:\s*(.+?)\s*$')        { $cur.State       = $Matches[1] }
        elseif ($cur -and $line -match '^\s*Release Type\s*:\s*(.+?)\s*$') { $cur.ReleaseType = $Matches[1] }
        elseif ($cur -and $line -match '^\s*Install Time\s*:\s*(.+?)\s*$') { $cur.InstallTime = $Matches[1] }
    }
    if ($cur) { $packages += $cur }
    $packages = $packages | Where-Object { $_.State -match 'Installed' -and $_.ReleaseType -match 'Update' }
    @($packages) | ConvertTo-Json -Depth 3
    return
}

$Script:OSRepairScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir  = Split-Path $Script:OSRepairScriptPath
$CoreModule = Join-Path $ScriptDir '..\Core\Toolkit.Core.psm1'
$ElevationModule = Join-Path $ScriptDir '..\Core\Toolkit.Elevation.psm1'
Import-Module $CoreModule -Force -DisableNameChecking
Import-Module $ElevationModule -Force -DisableNameChecking

$Script:OSRepairElevationTools = @('SFC', 'DISM', 'NetworkReset', 'WindowsUpdateRepair', 'All')

function Get-OSRepairRelayArgumentString {
    $parts = [System.Collections.Generic.List[string]]::new()
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'ToolName' -Value $ToolName
    Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'ElevatedRelay' -IsSwitch
    if (-not [string]::IsNullOrWhiteSpace($WindowsDir) -and $WindowsDir -ne 'C:\Windows') {
        Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'WindowsDir' -Value $WindowsDir
    }
    if (-not [string]::IsNullOrWhiteSpace($UpdateAction)) {
        Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'UpdateAction' -Value $UpdateAction
    }
    if (-not [string]::IsNullOrWhiteSpace($PackageName)) {
        Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'PackageName' -Value $PackageName
    }
    if (-not [string]::IsNullOrWhiteSpace($DismSource)) {
        Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'DismSource' -Value $DismSource
    }
    if ($DismSourceIndex -gt 0) {
        Add-ToolkitQuotedRelayArgument -Parts $parts -Name 'DismSourceIndex' -Value ([string]$DismSourceIndex)
    }
    return Join-ToolkitRelayArgumentString -Parts $parts
}

function Invoke-OSRepairElevationRelay {
    if ($ElevatedRelay) { return $false }
    if ((Get-EnvironmentMode) -ne 'Windows') { return $false }
    if ($Script:OSRepairElevationTools -notcontains $ToolName) { return $false }
    return (Invoke-ToolkitWorkflowElevationRelay -ScriptPath $Script:OSRepairScriptPath `
        -ArgumentString (Get-OSRepairRelayArgumentString) -ElevatedRelay:$ElevatedRelay)
}

# In WinPE, target the offline Windows volume the operator selected at boot
# (exported as OFFLINE_WINDOWS_ROOT) instead of defaulting to C:\. An explicit
# -WindowsDir passed by the GUI takes priority and is left untouched.
if ((Get-EnvironmentMode) -eq 'WinPE' -and $WindowsDir -eq 'C:\Windows' -and -not [string]::IsNullOrWhiteSpace($env:OFFLINE_WINDOWS_ROOT)) {
    $offlineWin = Join-Path ($env:OFFLINE_WINDOWS_ROOT.TrimEnd('\')) 'Windows'
    if (Test-Path -LiteralPath $offlineWin) {
        $WindowsDir = $offlineWin
        Write-Log "Offline target resolved from OFFLINE_WINDOWS_ROOT: $WindowsDir"
    }
}

function Test-DismSourceMissingError {
    param(
        [string]$Output,
        [int]$ExitCode
    )

    if ($ExitCode -eq -2146498529) {
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($Output)) {
        return $false
    }

    return ($Output -match '0x800f081f' -or $Output -match '(?i)source files could not be found')
}

function Write-DismSourceMissingGuidance {
    param(
        [bool]$SourceWasProvided
    )

    if ($SourceWasProvided) {
        Write-Log @'
DISM could not use the supplied repair source (0x800f081f).
Verify the install.wim/install.esd edition and build match this PC, then retry.
'@ -Level Warning
        return
    }

    Write-Log @'
DISM could not download repair files from Windows Update (0x800f081f).
Retry with a matching Windows install.wim from ISO media:
  1. Mount a Windows ISO that matches this PC edition/build.
  2. In CDE, run DISM Image Repair again and browse to sources\install.wim.
  3. Or run elevated:
     DISM /Online /Cleanup-Image /RestoreHealth /Source:wim:D:\sources\install.wim:INDEX /LimitAccess
Also try Windows Update Repair in OS Repair, then rerun DISM.
'@ -Level Warning
}

function Resolve-DismRepairWimPath {
    param(
        [Parameter(Mandatory)]
        [string]$Source
    )

    $path = $Source.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $path)) {
        throw "DISM source path not found: $Source"
    }

    if (Test-Path -LiteralPath $path -PathType Container) {
        $candidates = @(
            (Join-Path $path 'install.wim')
            (Join-Path $path 'install.esd')
            (Join-Path $path 'sources\install.wim')
            (Join-Path $path 'sources\install.esd')
        )
        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        }

        throw "No install.wim or install.esd found under: $Source"
    }

    $leaf = [System.IO.Path]::GetFileName($path)
    if ($leaf -notin @('install.wim', 'install.esd')) {
        Write-Log "DISM source is not install.wim/install.esd ($leaf); proceeding anyway." -Level Warning
    }

    return $path
}

function Get-DismWimIndex {
    param(
        [Parameter(Mandatory)]
        [string]$WimPath,
        [int]$PreferredIndex = 0
    )

    if ($PreferredIndex -gt 0) {
        return $PreferredIndex
    }

    $raw = (& dism.exe /Get-WimInfo "/WimFile:$WimPath" 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "DISM /Get-WimInfo failed for $WimPath (exit $LASTEXITCODE)`n$raw"
    }

    $indexes = New-Object System.Collections.Generic.List[object]
    $current = $null
    foreach ($line in ($raw -split "`r?`n")) {
        if ($line -match '^\s*Index\s*:\s*(\d+)\s*$') {
            if ($current) { $indexes.Add($current) | Out-Null }
            $current = [PSCustomObject]@{ Index = [int]$Matches[1]; Name = '' }
        }
        elseif ($current -and $line -match '^\s*Name\s*:\s*(.+?)\s*$') {
            $current.Name = $Matches[1].Trim()
        }
    }
    if ($current) { $indexes.Add($current) | Out-Null }

    if ($indexes.Count -eq 0) {
        throw "Could not read WIM indexes from $WimPath"
    }
    if ($indexes.Count -eq 1) {
        return [int]$indexes[0].Index
    }

    $caption = ''
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $caption = [string]$os.Caption
    } catch {
        $caption = ''
    }

    if ($caption) {
        $shortCaption = ($caption -replace '^Microsoft\s+', '').Trim()
        $match = $indexes | Where-Object { $_.Name -like "*$shortCaption*" } | Select-Object -First 1
        if ($match) {
            Write-Log "Using WIM index $($match.Index) ($($match.Name))"
            return [int]$match.Index
        }
    }

    $usable = @($indexes | Where-Object { $_.Name -notmatch '(?i)setup|Windows PE' })
    if ($usable.Count -gt 0) {
        Write-Log "Using WIM index $($usable[0].Index) ($($usable[0].Name))"
        return [int]$usable[0].Index
    }

    Write-Log "Using WIM index $($indexes[0].Index) ($($indexes[0].Name))"
    return [int]$indexes[0].Index
}

function Get-DismRestoreHealthCommandLine {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Online', 'Offline')]
        [string]$Mode,
        [string]$ImageDrive = '',
        [string]$SourcePath = '',
        [int]$SourceIndex = 0
    )

    $args = if ($Mode -eq 'Online') {
        @('/Online', '/Cleanup-Image', '/RestoreHealth')
    } else {
        @("/Image:$ImageDrive", '/Cleanup-Image', '/RestoreHealth')
    }

    if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
        $wimPath = Resolve-DismRepairWimPath -Source $SourcePath
        $index = Get-DismWimIndex -WimPath $wimPath -PreferredIndex $SourceIndex
        $sourceSpec = "wim:`"$wimPath`":$index"
        $args += "/Source:$sourceSpec"
        $args += '/LimitAccess'
        Write-Log "DISM repair source: $wimPath (index $index)"
    }

    return ('dism ' + ($args -join ' '))
}

function Invoke-DismRestoreHealthStep {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Online', 'Offline')]
        [string]$Mode,
        [string]$StepName,
        [string]$ImageDrive = '',
        [string]$SourcePath = '',
        [int]$SourceIndex = 0
    )

    $commandLine = Get-DismRestoreHealthCommandLine -Mode $Mode -ImageDrive $ImageDrive `
        -SourcePath $SourcePath -SourceIndex $SourceIndex
    Write-Log "Running: $commandLine"

    $step = Invoke-CommandStreamed -CommandLine $commandLine -StepName $StepName -ProgressKind 'DISM'
    if (Test-DismSourceMissingError -Output $step.Output -ExitCode $step.ExitCode) {
        Write-DismSourceMissingGuidance -SourceWasProvided:(-not [string]::IsNullOrWhiteSpace($SourcePath))
    }

    return $step
}

function Invoke-CommandCaptured {
    param([string]$FilePath, [string[]]$ArgumentList, [string]$StepName)

    try {
        $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList `
                              -Wait -PassThru -NoNewWindow `
                              -RedirectStandardOutput "$env:TEMP\repair_stdout.txt" `
                              -RedirectStandardError "$env:TEMP\repair_stderr.txt"

        $stdout = if (Test-Path "$env:TEMP\repair_stdout.txt") {
            Get-Content "$env:TEMP\repair_stdout.txt" -Raw -Encoding Default
        } else {
            ''
        }

        return [PSCustomObject]@{
            Name     = $StepName
            Status   = if ($proc.ExitCode -eq 0) { 'Pass' } else { 'Warn' }
            ExitCode = $proc.ExitCode
            Output   = $stdout.Trim()
        }
    } catch {
        return [PSCustomObject]@{
            Name     = $StepName
            Status   = 'Fail'
            ExitCode = -1
            Output   = $_.Exception.Message
        }
    }
}

function Get-SfcProgressPercent {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }

    $normalized = [regex]::Replace($Line, '(?<=[\p{L}\d])\s+(?=[\p{L}\d])', '')
    $match = [regex]::Match($normalized, 'Verification\s*(?<percent>\d{1,3})\s*%\s*complete', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        return [int]$match.Groups['percent'].Value
    }

    $compact = [regex]::Replace($Line, '[^A-Za-z0-9%]', '')
    $compactMatch = [regex]::Match($compact, 'verification(?<percent>\d{1,3})%complete', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($compactMatch.Success) {
        return [int]$compactMatch.Groups['percent'].Value
    }

    return $null
}

function Get-DismProgressPercent {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }

    $match = [regex]::Match($Line, '(?<percent>\d{1,3}(?:\.\d+)?)\s*%')
    if ($match.Success) {
        $value = [double]$match.Groups['percent'].Value
        if ($value -lt 0) { $value = 0 }
        if ($value -gt 100) { $value = 100 }
        return [int][math]::Floor($value)
    }

    return $null
}

function Invoke-CommandStreamed {
    param(
        [string]$CommandLine,
        [string]$StepName,
        [ValidateSet('SFC', 'DISM')][string]$ProgressKind
    )

    try {
        $lines = New-Object System.Collections.Generic.List[string]
        $lastPercent = -1

        cmd.exe /c $CommandLine 2>&1 | ForEach-Object {
            $line = [string]$_
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $lines.Add($line)
            }

            $percent = if ($ProgressKind -eq 'SFC') {
                Get-SfcProgressPercent -Line $line
            } else {
                Get-DismProgressPercent -Line $line
            }

            if ($null -ne $percent -and $percent -ne $lastPercent) {
                $lastPercent = $percent
                Write-Host ("{0}_PROGRESS:{1}" -f $ProgressKind, $percent)
            }
        }

        $exit = $LASTEXITCODE

        # Drop progress-only lines so the captured Output (used for structured
        # results) does not spam every percentage; keep meaningful summary lines.
        $meaningful = $lines | Where-Object {
            $p = if ($ProgressKind -eq 'SFC') {
                Get-SfcProgressPercent -Line $_
            } else {
                Get-DismProgressPercent -Line $_
            }
            $null -eq $p
        }

        return [PSCustomObject]@{
            Name     = $StepName
            Status   = if ($exit -eq 0) { 'Pass' } else { 'Warn' }
            ExitCode = $exit
            Output   = (($meaningful -join "`r`n").Trim())
        }
    } catch {
        return [PSCustomObject]@{
            Name     = $StepName
            Status   = 'Fail'
            ExitCode = -1
            Output   = $_.Exception.Message
        }
    }
}

function Invoke-SFC {
    param($r)

    $envMode = Get-EnvironmentMode

    if ($envMode -eq 'Windows') {
        Write-Log 'Running SFC /scannow...'
        Write-CdeEvent -Payload @{ type = 'progress'; tool = 'OSRepair'; step = 'SFC'; pct = 0; message = 'Starting SFC' }
        $step = Invoke-CommandStreamed -CommandLine 'sfc /scannow' -StepName 'SFC' -ProgressKind 'SFC'
        $r.Steps.Add($step)
        Write-Log "SFC Result: $($step.Status) (ExitCode $($step.ExitCode))"
        if ($step.Output) { Write-Log $step.Output }
    } else {
        # SFC offline mode requires VSS and CBS stack — both unavailable in WinPE.
        # Use DISM offline CheckHealth + RestoreHealth instead.
        $imageDrive = ($WindowsDir | Split-Path -Qualifier) + '\'
        Write-Log "SFC unavailable in WinPE — running DISM offline repair on $imageDrive"

        $checkStep = Invoke-CommandStreamed `
            -CommandLine "dism /Image:$imageDrive /Cleanup-Image /CheckHealth" `
            -StepName 'DISM_CheckHealth' -ProgressKind 'DISM'
        $r.Steps.Add($checkStep)
        Write-Log "DISM CheckHealth: $($checkStep.Status) (ExitCode $($checkStep.ExitCode))"
        if ($checkStep.Output) { Write-Log $checkStep.Output }

        $restoreStep = Invoke-DismRestoreHealthStep -Mode Offline -StepName 'DISM_RestoreHealth' `
            -ImageDrive $imageDrive -SourcePath $DismSource -SourceIndex $DismSourceIndex
        $r.Steps.Add($restoreStep)
        Write-Log "DISM RestoreHealth: $($restoreStep.Status) (ExitCode $($restoreStep.ExitCode))"
        if ($restoreStep.Output) { Write-Log $restoreStep.Output }
    }
}

function Invoke-DISM {
    param($r)

    $envMode = Get-EnvironmentMode
    Write-Log 'Running DISM /RestoreHealth...'
    Write-CdeEvent -Payload @{ type = 'progress'; tool = 'OSRepair'; step = 'DISM'; pct = 0; message = 'Starting DISM RestoreHealth' }

    if ($envMode -eq 'Windows') {
        $step = Invoke-DismRestoreHealthStep -Mode Online -StepName 'DISM_Online' `
            -SourcePath $DismSource -SourceIndex $DismSourceIndex
    } else {
        $imageDrive = ($WindowsDir | Split-Path -Qualifier) + '\'
        $step = Invoke-DismRestoreHealthStep -Mode Offline -StepName 'DISM_Offline' `
            -ImageDrive $imageDrive -SourcePath $DismSource -SourceIndex $DismSourceIndex
    }

    $r.Steps.Add($step)
    Write-Log "DISM Result: $($step.Status) (ExitCode $($step.ExitCode))"
    if ($step.Output) { Write-Log $step.Output }
}

function Invoke-BCDRepair {
    param($r)

    Write-Log "Running BCD repair..."
    try {
        $bcdedit = Invoke-CommandCaptured -FilePath 'bcdedit.exe' -ArgumentList '/enum', 'all' -StepName 'BCDEnum'
        $r.Steps.Add($bcdedit)

        if ($bcdedit.ExitCode -ne 0) {
            Write-Log "BCD appears corrupted. Running bootrec..." -Level Warning

            $pairs = @(
                @('BootrecFixMBR', '/fixmbr'),
                @('BootrecFixBoot', '/fixboot'),
                @('BootrecRebuildBCD', '/rebuildbcd')
            )

            foreach ($pair in $pairs) {
                $step = Invoke-CommandCaptured -FilePath 'bootrec.exe' -ArgumentList $pair[1] -StepName $pair[0]
                $r.Steps.Add($step)
                Write-Log "$($pair[0]): $($step.Status)"
            }
        } else {
            Write-Log "BCD looks healthy - no repair needed."
        }
    } catch {
        $r.Steps.Add([PSCustomObject]@{ Name='BCDRepair'; Status='Fail'; Output=$_.Exception.Message })
    }
}

function Invoke-NetworkReset {
    param($r)

    if ((Get-EnvironmentMode) -ne 'Windows') {
        $r.Steps.Add([PSCustomObject]@{ Name='NetworkReset'; Status='N/A'; Output='Not applicable in WinPE. Requires live Windows network services and adapter stack.' })
        return
    }

    Write-Log "Resetting network stack..."
    @(
        @{ cmd='netsh';    args=@('int','ip','reset');    name='NetIPReset' },
        @{ cmd='netsh';    args=@('winsock','reset');     name='WinsockReset' },
        @{ cmd='netsh';    args=@('advfirewall','reset'); name='FirewallReset' }
    ) | ForEach-Object {
        $step = Invoke-CommandCaptured -FilePath $_.cmd -ArgumentList $_.args -StepName $_.name
        $r.Steps.Add($step)
        Write-Log "$($_.name): $($step.Status)"
    }
}

function Invoke-WindowsUpdateRepair {
    param($r)

    if ((Get-EnvironmentMode) -ne 'Windows') {
        $r.Steps.Add([PSCustomObject]@{ Name='WURepair'; Status='N/A'; Output='Not applicable in WinPE. Requires live Windows Update services and SoftwareDistribution state.' })
        return
    }

    Write-Log "Stopping Windows Update services..."
    foreach ($svc in @('wuauserv', 'cryptSvc', 'bits', 'msiserver')) {
        $r.Steps.Add((Invoke-CommandCaptured -FilePath 'sc' -ArgumentList @('stop', $svc) -StepName "Stop_$svc"))
    }

    foreach ($folder in @('C:\Windows\SoftwareDistribution', 'C:\Windows\System32\catroot2')) {
        if (Test-Path $folder) {
            $backup = "${folder}.old_$(Get-Date -Format 'yyyyMMddHHmmss')"
            try {
                Rename-Item -Path $folder -NewName $backup -ErrorAction Stop
                $r.Steps.Add([PSCustomObject]@{ Name='RenameFolder'; Status='Pass'; Output="Renamed $folder to $backup" })
                Write-Log "Renamed: $folder"
            } catch {
                $r.Steps.Add([PSCustomObject]@{ Name='RenameFolder'; Status='Warn'; Output="Could not rename ${folder}: $_" })
            }
        }
    }

    Write-Log "Restarting Windows Update services..."
    foreach ($svc in @('wuauserv', 'cryptSvc', 'bits', 'msiserver')) {
        $r.Steps.Add((Invoke-CommandCaptured -FilePath 'sc' -ArgumentList @('start', $svc) -StepName "Start_$svc"))
    }

    Write-Log "Windows Update components reset."
}

function Invoke-OfflineUpdateUninstall {
    param($r)
    $envMode = Get-EnvironmentMode
    if ($envMode -ne 'WinPE') {
        $r.Steps.Add([PSCustomObject]@{ Name = 'OfflineUpdateUninstall'; Status = 'N/A'; Output = 'Offline update uninstallation targets an offline image and is intended to run from WinPE.' })
        return
    }

    $imageRoot = ($WindowsDir | Split-Path -Qualifier) + '\'
    Write-Log "Offline update servicing target: $imageRoot (WindowsDir=$WindowsDir)"

    # Step 1 - Always revert any interrupted/pending servicing first.
    Write-Log "Running DISM /RevertPendingActions on $imageRoot..."
    $revert = Invoke-CommandCaptured -FilePath 'dism.exe' `
        -ArgumentList "/Image:$imageRoot", '/Cleanup-Image', '/RevertPendingActions' `
        -StepName 'RevertPendingActions'
    $r.Steps.Add($revert)
    if ($revert.Output) { Write-Log $revert.Output }

    # Step 2 - Remove the operator-selected update package (optional).
    if (-not [string]::IsNullOrWhiteSpace($PackageName)) {
        Write-Log "Removing offline package: $PackageName"
        $remove = Invoke-CommandCaptured -FilePath 'dism.exe' `
            -ArgumentList "/Image:$imageRoot", '/Remove-Package', "/PackageName:$PackageName" `
            -StepName 'RemovePackage'
        $r.Steps.Add($remove)
        if ($remove.Output) { Write-Log $remove.Output }
    } else {
        $r.Steps.Add([PSCustomObject]@{ Name = 'RemovePackage'; Status = 'N/A'; Output = 'No package selected; performed RevertPendingActions only.' })
    }
}

$workflowName = if ($ToolName -eq 'All') { 'OSRepair_All' } else { "OSRepair_$ToolName" }

if (Invoke-OSRepairElevationRelay) { exit 0 }

$workflow = Start-Workflow -WorkflowName $workflowName -ScriptBlock {
    param($r)

    switch ($ToolName) {
        'SFC'                 { Invoke-SFC $r }
        'DISM'                { Invoke-DISM $r }
        'NetworkReset'        { Invoke-NetworkReset $r }
        'WindowsUpdateRepair' { Invoke-WindowsUpdateRepair $r }
        'OfflineUpdateUninstall' { Invoke-OfflineUpdateUninstall $r }
        default               { Invoke-DISM $r; Invoke-SFC $r }
    }

    $counts = Get-WorkflowStepCounts -Steps $r.Steps
    $failCount = $counts.Fail
    $warnCount = $counts.Warn
    $summary = if ($failCount) {
        'Some operations failed'
    } elseif ($warnCount) {
        'Completed with warnings'
    } else {
        'All operations completed successfully'
    }
    Write-Log "Summary: $summary"
}

Generate-Report -WorkflowResult $workflow | Out-Null

if ($workflow.Status -eq 'Failed') { exit 1 }
