$ErrorActionPreference = 'Stop'

function global:Get-EnvironmentMode {
    # X:\ is the WinPE RAM drive - always present in any WinPE environment
    if (Test-Path 'X:\' -ErrorAction SilentlyContinue) { return 'WinPE' }
    # MiniNT registry key is set by the WinPE loader
    if (Test-Path 'HKLM:\System\CurrentControlSet\Control\MiniNT' -ErrorAction SilentlyContinue) { return 'WinPE' }
    return 'Windows'
}

function global:Get-CommandCaptureText {
    param(
        [AllowNull()][string]$Stdout,
        [AllowNull()][string]$Stderr,
        [string]$Delimiter = "`n"
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($chunk in @($Stdout, $Stderr)) {
        if ($null -eq $chunk) { continue }
        $trimmed = $chunk.Trim()
        if ($trimmed.Length -gt 0) {
            $parts.Add($trimmed) | Out-Null
        }
    }

    return ($parts -join $Delimiter)
}

function global:Invoke-BootloaderCommandCaptured {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$StepName
    )

    try {
        if (-not [System.IO.Path]::IsPathRooted($FilePath)) {
            $resolved = Get-Command $FilePath -CommandType Application -ErrorAction SilentlyContinue
            $FilePath = if ($resolved) { $resolved.Source } else { Join-Path "$env:SystemRoot\System32" $FilePath }
        }

        $tempDir = if ($env:TEMP) { $env:TEMP } elseif ($env:TMP) { $env:TMP } else { "$env:SystemRoot\Temp" }
        $stdoutPath = Join-Path $tempDir 'bootloader_stdout.txt'
        $stderrPath = Join-Path $tempDir 'bootloader_stderr.txt'

        if (Test-Path -LiteralPath $stdoutPath) { Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $stderrPath) { Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue }

        $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

        $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw -Encoding Default } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -Encoding Default } else { '' }
        $combined = Get-CommandCaptureText -Stdout $stdout -Stderr $stderr

        return [PSCustomObject]@{
            Name     = $StepName
            Status   = if ($proc.ExitCode -eq 0) { 'Pass' } else { 'Warn' }
            ExitCode = $proc.ExitCode
            Output   = $combined
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

function global:Get-BootsectVolumeSpecifier {
    param([Parameter(Mandatory)][string]$DriveRoot)

    $spec = [string]$DriveRoot
    $spec = $spec.Trim().TrimEnd('\')
    if (-not $spec.EndsWith(':')) {
        $spec = "${spec}:"
    }

    return $spec
}

function global:Invoke-BootsectOnBootloaderTarget {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$StepName,
        [switch]$IncludeMbr
    )

    $vol = Get-BootsectVolumeSpecifier -DriveRoot $Target.DriveRoot
    $argumentList = [System.Collections.Generic.List[string]]::new()
    $argumentList.Add('/nt60') | Out-Null
    $argumentList.Add($vol) | Out-Null
    if ($IncludeMbr) {
        $argumentList.Add('/mbr') | Out-Null
    }
    $argumentList.Add('/force') | Out-Null

    return Invoke-BootloaderCommandCaptured -FilePath 'bootsect.exe' -ArgumentList $argumentList.ToArray() -StepName $StepName
}

function global:Get-EfiSystemVolumes {
    $volumes = [System.Collections.Generic.List[object]]::new()

    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        try {
            if (-not $drive.IsReady) { continue }
            $root = $drive.RootDirectory.FullName.TrimEnd('\')
            if ($root -like 'X:*') { continue }

            $efiBcd = Join-Path $root 'EFI\Microsoft\Boot\BCD'
            if (-not (Test-Path -LiteralPath $efiBcd -PathType Leaf)) { continue }

            $windowsDir = Join-Path $root 'Windows'
            $hasWindows = Test-Path -LiteralPath $windowsDir -PathType Container

            $volumes.Add([PSCustomObject]@{
                DriveRoot   = $root
                EfiBcdPath  = $efiBcd
                HasWindows  = $hasWindows
                WindowsDir  = if ($hasWindows) { $windowsDir } else { '' }
            }) | Out-Null
        } catch {
            continue
        }
    }

    return @($volumes | Sort-Object -Property @{ Expression = 'HasWindows'; Descending = $true }, DriveRoot)
}

function global:Get-BootloaderTargets {
    $candidates = @()

    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        try {
            if (-not $drive.IsReady) { continue }
            $root = $drive.RootDirectory.FullName
            if ($root -like 'X:*') { continue }

            $windowsDir = Join-Path $root 'Windows'
            if (-not (Test-Path -LiteralPath $windowsDir -PathType Container)) { continue }

            $efiBcd  = Join-Path $root 'EFI\Microsoft\Boot\BCD'
            $biosBcd = Join-Path $root 'Boot\BCD'

            $efiInfo = Resolve-TargetEfiBcdPath -WindowsDriveRoot $root.TrimEnd('\')
            if ($efiInfo -and (Test-Path -LiteralPath $efiInfo.EfiBcdPath -PathType Leaf)) {
                $efiBcd = $efiInfo.EfiBcdPath
            }

            $score = 0
            if (Test-Path -LiteralPath $efiBcd  -PathType Leaf) { $score += 2 }
            if (Test-Path -LiteralPath $biosBcd -PathType Leaf) { $score += 1 }

            $candidates += [PSCustomObject]@{
                DriveRoot    = $root.TrimEnd('\')
                WindowsDir   = $windowsDir
                EfiBcdPath   = $efiBcd
                EfiDriveRoot = if ($efiInfo) { $efiInfo.EfiDriveRoot } else { $root.TrimEnd('\') }
                BiosBcdPath  = $biosBcd
                Score        = $score
            }
        } catch {
            continue
        }
    }

    if ($candidates.Count -eq 0) {
        throw 'No offline Windows installations were detected on mounted volumes.'
    }

    return $candidates | Sort-Object -Property Score -Descending
}

function global:Resolve-PreselectedBootloaderItem {
    param(
        [Parameter(Mandatory)]$Items,
        [string]$PreSelectedDrive = ''
    )

    if ([string]::IsNullOrWhiteSpace($PreSelectedDrive)) {
        return $null
    }

    $clean = $PreSelectedDrive.Trim().TrimEnd('\')
    if (-not $clean.EndsWith(':')) {
        $clean = "${clean}:"
    }

    return @($Items | Where-Object { $_.DriveRoot -eq $clean } | Select-Object -First 1)[0]
}

function global:Select-BootloaderItemFromList {
    param(
        [Parameter(Mandatory)]$Items,
        [Parameter(Mandatory)][string]$PromptTitle,
        [switch]$AllowCancel
    )

    $itemList = @($Items)
    if ($itemList.Count -eq 0) {
        throw "No items were available for $PromptTitle."
    }

    if ($itemList.Count -eq 1) {
        return $itemList[0]
    }

    Write-Host ''
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host $PromptTitle -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host ''

    $rowIndex = 1
    $rows = @()
    foreach ($item in $itemList) {
        $rows += [PSCustomObject]@{
            Index = $rowIndex
            Item  = $item
        }
        $rowIndex++
    }

    foreach ($row in $rows) {
        $line = if ($row.Item.PSObject.Properties['DisplayLine']) {
            [string]$row.Item.DisplayLine
        } elseif ($row.Item.PSObject.Properties['FullName']) {
            [string]$row.Item.FullName
        } elseif ($row.Item.PSObject.Properties['DriveRoot']) {
            [string]$row.Item.DriveRoot
        } else {
            [string]$row.Item
        }
        Write-Host ("  {0}. {1}" -f $row.Index, $line)
    }

    while ($true) {
        $cancelHint = if ($AllowCancel) { ', 0=skip' } else { ', 0=cancel' }
        Write-Host ("Enter selection (1-{0}{1}): " -f $itemList.Count, $cancelHint) -ForegroundColor Cyan -NoNewline
        $raw = Read-Host
        if ($raw -eq '0') {
            if ($AllowCancel) {
                return $null
            }
            throw "Operation cancelled by operator during $PromptTitle."
        }

        $n = 0
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $itemList.Count) {
            return $rows[$n - 1].Item
        }

        Write-Host "Invalid selection. Enter a number between 1 and $($itemList.Count)." -ForegroundColor Red
    }
}

function global:Select-BootloaderTargetWithConfirmation {
    param(
        [Parameter(Mandatory)]$Targets,
        [Parameter(Mandatory)][string]$ActionName,
        [string]$PreSelectedDrive = '',
        [switch]$SkipConfirmation
    )

    $targetList = @($Targets)
    if ($targetList.Count -eq 0) {
        throw 'No bootloader targets were provided for selection.'
    }

    $found = Resolve-PreselectedBootloaderItem -Items $targetList -PreSelectedDrive $PreSelectedDrive
    if ($found) {
        Write-Host "Target pre-selected: $($found.WindowsDir)" -ForegroundColor Cyan
        return $found
    }

    if (-not [string]::IsNullOrWhiteSpace($PreSelectedDrive)) {
        Write-Host "WARNING: Pre-selected drive '$PreSelectedDrive' not found in target list. Falling through to manual selection." -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host 'Bootloader Target Selection'             -ForegroundColor Cyan
    Write-Host "Action: $ActionName"                     -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Available Windows Installations:' -ForegroundColor Yellow
    Write-Host ''

    $rowIndex = 1
    $rows = @()
    foreach ($t in $targetList) {
        $rows += [PSCustomObject]@{
            Index   = $rowIndex
            Drive   = $t.DriveRoot
            Windows = $t.WindowsDir
            EFI     = if (Test-Path -LiteralPath $t.EfiBcdPath  -PathType Leaf) { 'Yes' } else { 'No' }
            BIOS    = if (Test-Path -LiteralPath $t.BiosBcdPath -PathType Leaf) { 'Yes' } else { 'No' }
            Score   = $t.Score
            _ref    = $t
        }
        $rowIndex++
    }

    $rows | Format-Table -Property Index, Drive, Windows, EFI, BIOS, Score -AutoSize

    $selectedIndex = 0
    while ($true) {
        Write-Host "Enter target number (1-$($targetList.Count), 0=cancel): " -ForegroundColor Cyan -NoNewline
        $raw = Read-Host
        if ($raw -eq '0') {
            throw 'Operation cancelled by operator at target selection.'
        }
        $n = 0
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $targetList.Count) {
            $selectedIndex = $n
            break
        }
        Write-Host "Invalid selection. Enter a number between 1 and $($targetList.Count)." -ForegroundColor Red
    }

    $target = $rows[$selectedIndex - 1]._ref

    Write-Host ''
    Write-Host 'Selected target:' -ForegroundColor Yellow
    Write-Host "  Drive:    $($target.DriveRoot)"
    Write-Host "  Windows:  $($target.WindowsDir)"
    Write-Host "  EFI BCD:  $(if (Test-Path -LiteralPath $target.EfiBcdPath)  { $target.EfiBcdPath  } else { 'Not found' })"
    Write-Host "  BIOS BCD: $(if (Test-Path -LiteralPath $target.BiosBcdPath) { $target.BiosBcdPath } else { 'Not found' })"
    Write-Host ''

    if (-not $SkipConfirmation) {
        $choice = $null
        while ($choice -ne 'Y' -and $choice -ne 'N') {
            Write-Host "Proceed with $ActionName on this target? (Y/N): " -ForegroundColor Cyan -NoNewline
            $choice = (Read-Host).ToUpper()
        }
        if ($choice -eq 'N') {
            throw 'Operation cancelled by operator at target confirmation.'
        }
    }

    Write-Host ''
    return $target
}

function global:Select-BootloaderEfiVolumeWithConfirmation {
    param(
        [string]$PreSelectedDrive = ''
    )

    $efiVolumes = @(Get-EfiSystemVolumes)
    if ($efiVolumes.Count -eq 0) {
        throw 'No EFI system volumes with a BCD store were detected on mounted volumes.'
    }

    $found = Resolve-PreselectedBootloaderItem -Items $efiVolumes -PreSelectedDrive $PreSelectedDrive
    if ($found) {
        Write-Host "EFI volume pre-selected: $($found.DriveRoot)" -ForegroundColor Cyan
        return $found
    }

    $displayItems = @($efiVolumes | ForEach-Object {
        $kind = if ($_.HasWindows) { 'Windows+EFI' } else { 'EFI only' }
        [PSCustomObject]@{
            DriveRoot   = $_.DriveRoot
            EfiBcdPath  = $_.EfiBcdPath
            HasWindows  = $_.HasWindows
            WindowsDir  = $_.WindowsDir
            DisplayLine = "$($_.DriveRoot)  [$kind]  $($_.EfiBcdPath)"
        }
    })

    return Select-BootloaderItemFromList -Items $displayItems -PromptTitle 'EFI System Volume Selection'
}

function global:Normalize-DriveRoot {
    param([Parameter(Mandatory)][string]$DriveRoot)

    $clean = $DriveRoot.Trim().TrimEnd('\')
    if (-not $clean.EndsWith(':')) {
        $clean = "${clean}:"
    }

    return $clean
}

function global:Get-UsedDriveLetters {
    $used = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if ($drive.Name.Length -ge 2) {
            [void]$used.Add([string]$drive.Name[0])
        }
    }

    return $used
}

function global:Ensure-PartitionDriveLetter {
    param($Partition)

    if ($Partition.DriveLetter) {
        return (Normalize-DriveRoot -DriveRoot ([string]$Partition.DriveLetter))
    }

    if (-not (Get-Command Set-Partition -ErrorAction SilentlyContinue)) {
        return $null
    }

    $used = Get-UsedDriveLetters
    $skip = @('X')
    $candidates = @('S', 'T', 'U', 'V', 'W', 'Y', 'Z', 'R', 'Q', 'P', 'O', 'N', 'M', 'L', 'K', 'J', 'I', 'H', 'G', 'F', 'E', 'D', 'C', 'B', 'A')
    foreach ($letter in $candidates) {
        if ($skip -contains $letter) { continue }
        if ($used.Contains($letter)) { continue }

        try {
            Set-Partition -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -NewDriveLetter $letter -ErrorAction Stop
            Start-Sleep -Milliseconds 200
            return (Normalize-DriveRoot -DriveRoot $letter)
        } catch {
            continue
        }
    }

    return $null
}

function global:Resolve-TargetEfiBcdPath {
    param([Parameter(Mandatory)][string]$WindowsDriveRoot)

    $windowsRoot = Normalize-DriveRoot -DriveRoot $WindowsDriveRoot
    $onWindows = Join-Path $windowsRoot 'EFI\Microsoft\Boot\BCD'
    if (Test-Path -LiteralPath $onWindows -PathType Leaf) {
        return [PSCustomObject]@{
            EfiDriveRoot = $windowsRoot
            EfiBcdPath   = $onWindows
            Source       = 'WindowsVolume'
            Mounted      = $true
        }
    }

    $letter = $windowsRoot.TrimEnd(':')
    if ($letter.Length -eq 1 -and (Get-Command Get-Partition -ErrorAction SilentlyContinue)) {
        $winPart = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($winPart) {
            $efiPart = Get-Partition -DiskNumber $winPart.DiskNumber -ErrorAction SilentlyContinue |
                Where-Object {
                    ($_.GptType -and $_.GptType.ToString() -ieq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}') -or
                    ($_.Type -eq 'System')
                } |
                Select-Object -First 1

            if ($efiPart) {
                $efiRoot = Ensure-PartitionDriveLetter -Partition $efiPart
                if ($efiRoot) {
                    $efiBcd = Join-Path $efiRoot 'EFI\Microsoft\Boot\BCD'
                    if (Test-Path -LiteralPath $efiBcd -PathType Leaf) {
                        return [PSCustomObject]@{
                            EfiDriveRoot = $efiRoot
                            EfiBcdPath   = $efiBcd
                            Source       = 'EfiSystemPartition'
                            Mounted      = $true
                        }
                    }
                }
            }
        }
    }

    foreach ($efi in @(Get-EfiSystemVolumes)) {
        return [PSCustomObject]@{
            EfiDriveRoot = $efi.DriveRoot
            EfiBcdPath   = $efi.EfiBcdPath
            Source       = 'MountedVolumeScan'
            Mounted      = $true
        }
    }

    return [PSCustomObject]@{
        EfiDriveRoot = $windowsRoot
        EfiBcdPath   = $onWindows
        Source       = 'NotFound'
        Mounted      = $false
    }
}

function global:Get-BcdBackupInventory {
    param([Parameter(Mandatory)][string]$BackupRoot)

    if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) {
        return [PSCustomObject]@{
            EfiBackups  = @()
            BiosBackups = @()
        }
    }

    $efiPatterns = @('EFI_BCDExport_*.bcd', 'EFI_BCD_*.bcd')
    $biosPatterns = @('BIOS_BCDExport_*.bcd', 'BIOS_BCD_*.bcd')

    $efiBackups = @()
    foreach ($pattern in $efiPatterns) {
        $efiBackups += @(Get-ChildItem -LiteralPath $BackupRoot -Filter $pattern -File -ErrorAction SilentlyContinue)
    }
    $efiBackups = @($efiBackups | Sort-Object LastWriteTime -Descending -Unique)

    $biosBackups = @()
    foreach ($pattern in $biosPatterns) {
        $biosBackups += @(Get-ChildItem -LiteralPath $BackupRoot -Filter $pattern -File -ErrorAction SilentlyContinue)
    }
    $biosBackups = @($biosBackups | Sort-Object LastWriteTime -Descending -Unique)

    return [PSCustomObject]@{
        EfiBackups  = $efiBackups
        BiosBackups = $biosBackups
    }
}

function global:Clear-BcdStoreFileAttributes {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    try {
        attrib -R -S -H $Path 2>$null | Out-Null
    } catch {
        try {
            $item = Get-Item -LiteralPath $Path -Force
            $item.Attributes = [System.IO.FileAttributes]::Normal
        } catch { }
    }
}

function global:Invoke-BcdEditExport {
    param(
        [Parameter(Mandatory)][string]$BcdStorePath,
        [Parameter(Mandatory)][string]$ExportPath,
        [Parameter(Mandatory)][string]$StepName
    )

    if (-not (Test-Path -LiteralPath $BcdStorePath -PathType Leaf)) {
        return [PSCustomObject]@{
            Name     = $StepName
            Status   = 'Warn'
            ExitCode = 1
            Output   = "BCD store not found: $BcdStorePath"
        }
    }

    $exportDir = Split-Path -Parent $ExportPath
    if (-not (Test-Path -LiteralPath $exportDir -PathType Container)) {
        New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
    }

    # bcdedit /export and /import are valid only for the active system store (Microsoft Learn).
    # WinPE repair targets offline client stores (e.g. S:\EFI\Microsoft\Boot\BCD) via file copy.
    try {
        Copy-Item -LiteralPath $BcdStorePath -Destination $ExportPath -Force -ErrorAction Stop
        $size = (Get-Item -LiteralPath $ExportPath -ErrorAction Stop).Length
        if ($size -lt 1) {
            throw 'Backup file is empty after copy.'
        }

        return [PSCustomObject]@{
            Name     = $StepName
            Status   = 'Pass'
            ExitCode = 0
            Output   = "Copied BCD store to $ExportPath ($size bytes). Offline stores are backed up by file copy because bcdedit /export applies only to the active system store."
        }
    } catch {
        return [PSCustomObject]@{
            Name     = $StepName
            Status   = 'Fail'
            ExitCode = 1
            Output   = $_.Exception.Message
        }
    }
}

function global:Invoke-BcdEditImport {
    param(
        [Parameter(Mandatory)][string]$BcdStorePath,
        [Parameter(Mandatory)][string]$ImportPath,
        [Parameter(Mandatory)][string]$StepName
    )

    if (-not (Test-Path -LiteralPath $ImportPath -PathType Leaf)) {
        return [PSCustomObject]@{
            Name     = $StepName
            Status   = 'Fail'
            ExitCode = 1
            Output   = "BCD backup file not found: $ImportPath"
        }
    }

    if (-not (Test-Path -LiteralPath $BcdStorePath -PathType Leaf)) {
        return [PSCustomObject]@{
            Name     = $StepName
            Status   = 'Warn'
            ExitCode = 1
            Output   = "BCD destination not found: $BcdStorePath"
        }
    }

    $safetyPath = "$BcdStorePath.preimport_$(Get-Date -Format 'yyyyMMdd_HHmmss').bak"
    try {
        Copy-Item -LiteralPath $BcdStorePath -Destination $safetyPath -Force -ErrorAction Stop
        Clear-BcdStoreFileAttributes -Path $BcdStorePath
        Copy-Item -LiteralPath $ImportPath -Destination $BcdStorePath -Force -ErrorAction Stop
        $size = (Get-Item -LiteralPath $BcdStorePath -ErrorAction Stop).Length
        if ($size -lt 1) {
            throw 'Restored BCD store is empty after copy.'
        }

        return [PSCustomObject]@{
            Name     = $StepName
            Status   = 'Pass'
            ExitCode = 0
            Output   = @(
                "Restored BCD store from $ImportPath ($size bytes)."
                "Safety snapshot: $safetyPath"
                'Offline stores are restored by file copy because bcdedit /import applies only to the active system store.'
            ) -join "`n"
        }
    } catch {
        return [PSCustomObject]@{
            Name     = $StepName
            Status   = 'Fail'
            ExitCode = 1
            Output   = $_.Exception.Message
        }
    }
}

function global:Resolve-BcdBackupSelection {
    param(
        [Parameter(Mandatory)]$Inventory,
        [string]$Kind,
        [string]$PreselectedPath = ''
    )

    $files = if ($Kind -eq 'EFI') { @($Inventory.EfiBackups) } else { @($Inventory.BiosBackups) }
    if ($files.Count -eq 0) {
        return $null
    }

    if (-not [string]::IsNullOrWhiteSpace($PreselectedPath)) {
        $match = @($files | Where-Object { $_.FullName -eq $PreselectedPath } | Select-Object -First 1)[0]
        if ($match) {
            return $match
        }

        if (Test-Path -LiteralPath $PreselectedPath -PathType Leaf) {
            return Get-Item -LiteralPath $PreselectedPath
        }

        throw "Selected $Kind backup file was not found: $PreselectedPath"
    }

    $displayItems = @($files | ForEach-Object {
        [PSCustomObject]@{
            FullName    = $_.FullName
            DisplayLine = "$($_.Name)  ($($_.LastWriteTime.ToString('g')))"
        }
    })

    return Select-BootloaderItemFromList -Items $displayItems -PromptTitle "Select $Kind BCD backup to restore" -AllowCancel
}

function global:Confirm-BootloaderWriteAction {
    param([Parameter(Mandatory)][string]$Message, [switch]$Force)

    # When called from ToolkitGUI (-NonInteractive), GUI click serves as confirmation
    if ($Force) {
        Write-Host "Write action confirmed by GUI: $Message" -ForegroundColor Cyan
        return $true
    }

    Write-Host ''
    Write-Host $Message -ForegroundColor Yellow
    Write-Host ''
    $choice = $null
    while ($choice -ne 'Y' -and $choice -ne 'N') {
        Write-Host 'Proceed? (Y/N): ' -ForegroundColor Cyan -NoNewline
        $choice = (Read-Host).ToUpper()
    }
    return ($choice -eq 'Y')
}

function global:Assert-WinPeOrThrow {
    param([Parameter(Mandatory)]$Result)

    if ((Get-EnvironmentMode) -ne 'WinPE') {
        $step = [PSCustomObject]@{
            Name     = 'WinPEGate'
            Status   = 'Fail'
            ExitCode = -1
            Output   = 'WinPE Only: this tool cannot run in normal Windows mode.'
        }
        $Result.Steps.Add($step)
        throw 'WinPE Only: this tool cannot run in normal Windows mode.'
    }
}

function global:Complete-BootloaderWorkflow {
    param([Parameter(Mandatory)]$WorkflowResult)

    foreach ($step in @($WorkflowResult.Steps)) {
        if ($step.PSObject.Properties.Name -notcontains 'Output' -or [string]::IsNullOrWhiteSpace([string]$step.Output)) {
            $detail = if ($step.PSObject.Properties.Name -contains 'Detail') { [string]$step.Detail } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($detail)) {
                $step | Add-Member -NotePropertyName Output -NotePropertyValue $detail -Force
            }
        }
    }

    $null = Set-WorkflowOverallHealth -WorkflowResult $WorkflowResult
    $WorkflowResult | ConvertTo-Json -Depth 10
    Generate-Report -WorkflowResult $WorkflowResult | Out-Null
}

function global:Merge-BootloaderChildWorkflow {
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$ScriptPath,
        [hashtable]$Arguments = @{},
        [Parameter(Mandatory)][string]$GroupName
    )

    if (-not (Get-Command Merge-ChildWorkflowJson -ErrorAction SilentlyContinue)) {
        $coreDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\Core'
        . (Join-Path $coreDir 'HealthCheckOrchestrator.ps1')
    }

    Merge-ChildWorkflowJson -WorkflowResult $Result -ScriptPath $ScriptPath -Arguments $Arguments -CheckId $GroupName
}

function global:Add-BootloaderStep {
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)]$Step)
    $Result.Steps.Add($Step)
}
