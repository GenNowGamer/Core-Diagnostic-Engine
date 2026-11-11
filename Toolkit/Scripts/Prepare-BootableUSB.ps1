<#
.SYNOPSIS
    CDE Bootable USB Preparation Script
    Creates a bootable USB drive from the CDE folder structure or ISO.
.DESCRIPTION
    Two modes:
    1. DIRECT  - Copy CDE folder structure directly to USB (fastest)
    2. ISO     - Extract ISO contents to USB (requires ISO path)
    
    USB partitioning uses diskpart first (Storage module fallback). Supports BIOS + UEFI.
    
.PARAMETER DiskNumber
    Optional: The disk number from 'list disk' (NOT the partition letter). If omitted, an interactive menu is displayed.
.PARAMETER IsoPath
    Optional: If provided, extracts the ISO. Otherwise copies CDE folder directly.
.EXAMPLE
    .\Prepare-BootableUSB.ps1 -DiskNumber 2
    .\Prepare-BootableUSB.ps1 -DiskNumber 2 -IsoPath "Deploy\CDE_Diagnostic_Suite.iso"
.NOTES
    *** DANGER: -DiskNumber selection will WIPE the selected disk ***
    Double-check your disk number before confirming.
    Run as Administrator.
#>

param(
    [int]$DiskNumber = -1,
    
    [string]$IsoPath = ""
)

# Self-elevation check: ensure Administrator privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    $argsList = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`""
    if ($PSBoundParameters.Count -gt 0) {
        foreach ($key in $PSBoundParameters.Keys) {
            $argsList += " -$key `"$($PSBoundParameters[$key])`""
        }
    }
    Start-Process powershell.exe -ArgumentList $argsList -Verb RunAs
    exit 0
}

$CDE_ROOT  = Split-Path -Parent $PSScriptRoot   # Toolkit\ (parent of Scripts\)
$USB_LABEL = "CDEDATA"

function Get-UsedDriveLetters {
    @(Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter } |
        ForEach-Object { [string]$_.DriveLetter })
}

function Get-DriveLettersOnDisk {
    param(
        [Parameter(Mandatory)]
        [int]$DiskNumber
    )

    @(Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter } |
        ForEach-Object { [string]$_.DriveLetter })
}

function Test-UsbDriveLetterAllowed {
    param(
        [Parameter(Mandatory)]
        [int]$DiskNumber,
        [Parameter(Mandatory)]
        [string]$Letter
    )

    if ($Letter -eq 'C') {
        return [PSCustomObject]@{
            Allowed = $false
            Reason  = 'Cannot use C: - that is the system drive.'
        }
    }

    $owner = Get-Partition -DriveLetter $Letter -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $owner) {
        return [PSCustomObject]@{
            Allowed = $true
            Reason  = 'Letter is free.'
        }
    }

    if ($owner.DiskNumber -eq $DiskNumber) {
        return [PSCustomObject]@{
            Allowed = $true
            Reason  = "Letter ${Letter}: is on the target USB (disk $DiskNumber) and will be reused after wipe."
        }
    }

    return [PSCustomObject]@{
        Allowed = $false
        Reason  = "Drive letter ${Letter}: is used by disk $($owner.DiskNumber), not the target USB (disk $DiskNumber)."
    }
}

function Get-SuggestedDriveLetterForDisk {
    param(
        [Parameter(Mandatory)]
        [int]$DiskNumber
    )

    $onTarget = Get-DriveLettersOnDisk -DiskNumber $DiskNumber | Select-Object -First 1
    if ($onTarget) {
        return $onTarget
    }

    return Get-SuggestedDriveLetter
}

function Get-SuggestedDriveLetter {
    $used = Get-UsedDriveLetters
    foreach ($char in [char[]]([char]'D'..[char]'Z')) {
        $letter = [string]$char
        if ($letter -notin $used) {
            return $letter
        }
    }

    return $null
}

function Write-DiskPartLog($scriptContent, $stdoutPath, $stderrPath) {
    if ($scriptContent) {
        Write-Host "  diskpart script:" -ForegroundColor DarkGray
        $scriptContent -split "`r?`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }

    if (Test-Path $stdoutPath) {
        Write-Host "  diskpart output:" -ForegroundColor DarkGray
        Get-Content -LiteralPath $stdoutPath | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }

    if (Test-Path $stderrPath) {
        Write-Host "  diskpart errors:" -ForegroundColor DarkGray
        Get-Content -LiteralPath $stderrPath | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
}

function Invoke-DiskPartScript {
    param(
        [Parameter(Mandatory)]
        [string[]]$Lines
    )

    $scriptPath = Join-Path $env:TEMP "cde_diskpart_$([Guid]::NewGuid().ToString('N')).txt"
    $stdoutPath = "$scriptPath.out.txt"
    $stderrPath = "$scriptPath.err.txt"

    try {
        $scriptContent = ($Lines + 'exit') -join "`r`n"
        $scriptContent | Out-File -LiteralPath $scriptPath -Encoding ASCII -Force
        $proc = Start-Process -FilePath 'diskpart.exe' -ArgumentList "/s `"$scriptPath`"" -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $output = @()
        if (Test-Path $stdoutPath) { $output += Get-Content -LiteralPath $stdoutPath }
        if (Test-Path $stderrPath) { $output += Get-Content -LiteralPath $stderrPath }

        [PSCustomObject]@{
            ExitCode      = $proc.ExitCode
            Output        = ($output -join "`r`n")
            ScriptContent = $scriptContent
            Stdout        = $stdoutPath
            Stderr        = $stderrPath
        }
    }
    finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-DiskPartOutputHasFatalError {
    param([string]$Output)

    if ([string]::IsNullOrWhiteSpace($Output)) {
        return $false
    }

    if ($Output -notmatch '(?i)error|failed|not valid|no volume selected') {
        return $false
    }

    $lower = $Output.ToLowerInvariant()
    $benignOnly = @(
        'already online'
        'is already online'
        'already gpt'
        'already mbr'
        'is already convertible'
        'specified disk is already'
    )

    $hasBenign = $false
    foreach ($pattern in $benignOnly) {
        if ($lower.Contains($pattern)) {
            $hasBenign = $true
            break
        }
    }

    if ($hasBenign -and $lower -notmatch 'no volume selected|not valid|failed to|cannot|access denied') {
        return $false
    }

    return $true
}

function Set-CdeDiskWritable {
    param(
        [Parameter(Mandatory)]
        [int]$DiskNumber
    )

    $disk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
    if (-not $disk) {
        return
    }

    if ($disk.OperationalStatus -eq 'Offline') {
        Set-Disk -Number $DiskNumber -IsOffline $false -ErrorAction SilentlyContinue
    }

    if ($disk.IsReadOnly) {
        Set-Disk -Number $DiskNumber -IsReadOnly $false -ErrorAction SilentlyContinue
    }
}

function Get-CdeDiskPartScriptLines {
    param(
        [Parameter(Mandatory)]
        [int]$DiskNumber,
        [Parameter(Mandatory)]
        [string]$DriveLetter,
        [Parameter(Mandatory)]
        [bool]$UseMbr,
        [Parameter(Mandatory)]
        [string]$Label,
        [string]$CurrentStyle = ''
    )

    $lines = @(
        "select disk $DiskNumber"
        'attributes disk clear readonly'
        'clean'
    )

    if ($UseMbr) {
        if ($CurrentStyle -ne 'MBR') {
            $lines += 'convert mbr'
        }
        $lines += @(
            'create partition primary'
            'select partition 1'
            'active'
        )
    }
    else {
        if ($CurrentStyle -ne 'GPT') {
            $lines += 'convert gpt'
        }
        $lines += @(
            'create partition primary'
            'select partition 1'
        )
    }

    $lines += @(
        "format fs=fat32 label=$Label quick"
        "assign letter=$DriveLetter"
    )

    return $lines
}

function Test-CdeUsbVolumeReady {
    param(
        [Parameter(Mandatory)]
        [string]$DriveLetter
    )

    $final = Get-Volume -DriveLetter ([char]$DriveLetter) -ErrorAction SilentlyContinue
    return ($final -and $final.FileSystem -eq 'FAT32')
}

function Set-CdeUsbPartitionViaDiskPart {
    param(
        [Parameter(Mandatory)]
        [int]$DiskNumber,
        [Parameter(Mandatory)]
        [string]$DriveLetter,
        [Parameter(Mandatory)]
        [bool]$UseMbr,
        [Parameter(Mandatory)]
        [string]$Label
    )

    $styleLabel = if ($UseMbr) { 'MBR' } else { 'GPT' }
    Write-Host "  Using diskpart ($styleLabel)..." -ForegroundColor Yellow

    Import-Module Storage -ErrorAction SilentlyContinue | Out-Null
    $disk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
    $currentStyle = if ($disk) { [string]$disk.PartitionStyle } else { '' }

    $lines = Get-CdeDiskPartScriptLines -DiskNumber $DiskNumber -DriveLetter $DriveLetter `
        -UseMbr:$UseMbr -Label $Label -CurrentStyle $currentStyle

    $result = Invoke-DiskPartScript -Lines $lines
    Start-Sleep -Seconds 2

    if (Test-CdeUsbVolumeReady -DriveLetter $DriveLetter) {
        return
    }

    if (Test-DiskPartOutputHasFatalError -Output $result.Output) {
        Write-DiskPartLog -scriptContent $result.ScriptContent -stdoutPath $result.Stdout -stderrPath $result.Stderr
        Write-Host $result.Output
        throw "diskpart failed (exit $($result.ExitCode))"
    }

    Write-DiskPartLog -scriptContent $result.ScriptContent -stdoutPath $result.Stdout -stderrPath $result.Stderr
    Write-Host $result.Output

    $final = Get-Volume -DriveLetter ([char]$DriveLetter) -ErrorAction SilentlyContinue
    if (-not $final -or -not $final.FileSystem) {
        throw "diskpart completed but ${DriveLetter}: is not a formatted volume."
    }

    throw "diskpart completed but ${DriveLetter}: is '$($final.FileSystem)', expected FAT32."
}

function Set-CdeUsbPartition {
    param(
        [Parameter(Mandatory)]
        [int]$DiskNumber,
        [Parameter(Mandatory)]
        [string]$DriveLetter,
        [Parameter(Mandatory)]
        [bool]$UseMbr,
        [Parameter(Mandatory)]
        [string]$Label
    )

    Import-Module Storage -ErrorAction Stop

    $partitionStyle = if ($UseMbr) { 'MBR' } else { 'GPT' }
    Write-Host "  Using Windows Storage module ($partitionStyle)..." -ForegroundColor Yellow

    Set-CdeDiskWritable -DiskNumber $DiskNumber
    Clear-Disk -Number $DiskNumber -RemoveData -Confirm:$false -ErrorAction Stop
    Update-HostStorageCache

    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
    if ($disk.PartitionStyle -eq 'RAW' -or [string]::IsNullOrWhiteSpace([string]$disk.PartitionStyle)) {
        Initialize-Disk -Number $DiskNumber -PartitionStyle $partitionStyle -Confirm:$false -ErrorAction Stop
    }
    elseif ($disk.PartitionStyle -ne $partitionStyle) {
        Initialize-Disk -Number $DiskNumber -PartitionStyle $partitionStyle -Confirm:$false -ErrorAction Stop
    }

    $partition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -ErrorAction Stop
    if ($UseMbr) {
        Set-Partition -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber -IsActive $true -ErrorAction Stop
    }

    $letter = [char]$DriveLetter
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber -NewDriveLetter $letter -ErrorAction Stop
    Start-Sleep -Seconds 2

    Format-Volume -DriveLetter $letter -FileSystem FAT32 -NewFileSystemLabel $Label -Force -ErrorAction Stop | Out-Null

    if (-not (Test-CdeUsbVolumeReady -DriveLetter $DriveLetter)) {
        $final = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
        $fs = if ($final) { $final.FileSystem } else { '(none)' }
        throw "USB volume ${DriveLetter}: is '$fs', expected FAT32."
    }
}

function Set-CdeUsbPartitionStorageFallback {
    param(
        [Parameter(Mandatory)]
        [int]$DiskNumber,
        [Parameter(Mandatory)]
        [string]$DriveLetter,
        [Parameter(Mandatory)]
        [bool]$UseMbr,
        [Parameter(Mandatory)]
        [string]$Label
    )

    Write-Host "  diskpart failed; retrying with Storage module..." -ForegroundColor Yellow
    Set-CdeUsbPartition -DiskNumber $DiskNumber -DriveLetter $DriveLetter -UseMbr:$UseMbr -Label $Label
}

function Write-Step($msg) { Write-Host "`n[STEP] $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "[OK]   $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Fail($msg) { Write-Host "[FAIL] $msg" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------
# Safety: Show disk info before doing anything
# ---------------------------------------------------------------
Write-Host "`nCDE Bootable USB Preparation" -ForegroundColor Yellow
Write-Host "=============================" -ForegroundColor Yellow

Write-Step "Current disk list:"
$diskInfo = Get-Disk | Select-Object Number, FriendlyName, Size, PartitionStyle, 
    @{N="Size_GB";E={[math]::Round($_.Size/1GB,1)}}
$diskInfo | Format-Table -AutoSize

if ($DiskNumber -lt 0) {
    do {
        $userInput = Read-Host "`nEnter the Disk Number of your target USB drive (or 'q' to quit)"
        if ($userInput.Trim().ToLower() -eq 'q') {
            Write-Host "Preparation aborted by user."
            exit 0
        }
        if ($userInput -match '^\d+$') {
            $parsedNum = [int]$userInput
            $testDisk = Get-Disk -Number $parsedNum -ErrorAction SilentlyContinue
            if ($testDisk) {
                $DiskNumber = $parsedNum
                break
            } else {
                Write-Warn "Disk $parsedNum was not found in the list above. Please try again."
            }
        } else {
            Write-Warn "Please enter a valid numeric disk number (e.g. 1, 2) or 'q' to quit."
        }
    } while ($true)
}

# Identify target disk
$targetDisk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
if (-not $targetDisk) { Write-Fail "Disk $DiskNumber not found." }

$diskSizeGB  = [math]::Round($targetDisk.Size / 1GB, 1)
$diskName    = $targetDisk.FriendlyName

Write-Host "`n  Target disk: [$DiskNumber] $diskName ($diskSizeGB GB)" -ForegroundColor Yellow
Write-Host "  *** THIS DISK WILL BE COMPLETELY WIPED ***" -ForegroundColor Red

# Safety check: warn if disk > 64 GB (unlikely to be USB)
if ($targetDisk.Size -gt 64GB) {
    Write-Warn "Disk $DiskNumber is $diskSizeGB GB which is unusually large for USB."
    Write-Warn "Are you sure this is the correct disk?"
}

$diskIsMbr = ($targetDisk.PartitionStyle -eq 'MBR')
if ($diskIsMbr) {
    Write-Host "  Disk style detected: MBR (legacy BIOS boot supported)" -ForegroundColor Yellow
} else {
    Write-Host "  Disk style detected: $($targetDisk.PartitionStyle) (UEFI boot path; skipping ACTIVE)" -ForegroundColor Yellow
}

# Choose a drive letter before wiping the disk.
Import-Module Storage -ErrorAction SilentlyContinue | Out-Null

Write-Host ""
$lettersOnTarget = Get-DriveLettersOnDisk -DiskNumber $DiskNumber
$usedLetters = Get-UsedDriveLetters
$otherUsedLetters = @($usedLetters | Where-Object { $_ -notin $lettersOnTarget })

Write-Host "  Drive letters on target USB (disk $DiskNumber):" -ForegroundColor Cyan
if ($lettersOnTarget.Count -gt 0) {
    foreach ($letter in $lettersOnTarget | Sort-Object) {
        Write-Host "    ${letter}:  (on this USB - may be reused)" -ForegroundColor Green
    }
} else {
    Write-Host "    (none - disk has no assigned letter yet)" -ForegroundColor DarkGray
}

if ($otherUsedLetters.Count -gt 0) {
    Write-Host "  Other drive letters in use:" -ForegroundColor Cyan
    foreach ($letter in $otherUsedLetters | Sort-Object) {
        Write-Host "    ${letter}:"
    }
}

$suggestedLetter = Get-SuggestedDriveLetterForDisk -DiskNumber $DiskNumber
if ($suggestedLetter) {
    if ($suggestedLetter -in $lettersOnTarget) {
        Write-Host "  Suggested letter: $suggestedLetter (current USB letter; will be reused)" -ForegroundColor Green
    } else {
        Write-Host "  Suggested free letter: $suggestedLetter" -ForegroundColor Green
    }
} else {
    Write-Fail "No drive letters are available (D-Z). Free a letter and retry."
}

Write-Host ""
$usbLetter = ""
do {
    $defaultHint = if ($suggestedLetter) { " [$suggestedLetter]" } else { "" }
    $_input = (Read-Host "Enter drive letter to assign to USB$defaultHint").Trim().ToUpper() -replace '[^A-Z]', ''
    if ([string]::IsNullOrWhiteSpace($_input) -and $suggestedLetter) {
        $_input = $suggestedLetter
    }

    if ($_input.Length -ne 1) {
        Write-Warn "Please enter a single letter A-Z."
        continue
    }

    $letterCheck = Test-UsbDriveLetterAllowed -DiskNumber $DiskNumber -Letter $_input
    if (-not $letterCheck.Allowed) {
        Write-Warn $letterCheck.Reason
        continue
    }

    if ($letterCheck.Reason -match 'reused after wipe') {
        Write-Host "  $($letterCheck.Reason)" -ForegroundColor Green
    }

    $usbLetter = $_input
} while ($usbLetter -eq "")

Write-Host "  USB will be assigned drive letter: $usbLetter`:" -ForegroundColor Yellow

# Confirm with user
Write-Host ""
$confirm = Read-Host "Type YES to confirm wiping disk $DiskNumber ($diskName)"
if ($confirm.Trim().ToUpper() -ne "YES") { Write-Host "Aborted."; exit 0 }

# ---------------------------------------------------------------
# Partition and format the USB
# ---------------------------------------------------------------
Write-Step "Partitioning disk $DiskNumber..."

$partitionError = $null
try {
    Set-CdeUsbPartitionViaDiskPart -DiskNumber $DiskNumber -DriveLetter $usbLetter -UseMbr:$diskIsMbr -Label $USB_LABEL
}
catch {
    $partitionError = $_.Exception.Message
    Write-Warn $partitionError
    try {
        Set-CdeUsbPartitionStorageFallback -DiskNumber $DiskNumber -DriveLetter $usbLetter -UseMbr:$diskIsMbr -Label $USB_LABEL
    }
    catch {
        Write-Fail @"
USB partitioning failed after the disk was wiped.

What happened:
  The script cleared disk $DiskNumber but could not finish formatting/assigning $usbLetter`:.

diskpart error:
  $partitionError

Storage module error:
  $($_.Exception.Message)

Next steps:
  1. Re-run PrepareUSB.vbs (or Prepare-BootableUSB.ps1 -DiskNumber $DiskNumber)
  2. Choose a drive letter that is free, or the current letter on the target USB disk
  3. If it fails again, try another USB port and re-check disk $DiskNumber in Disk Management
"@
    }
}

Start-Sleep -Seconds 2
Write-OK "USB formatted as FAT32 ($USB_LABEL), assigned $usbLetter`:"

# ---------------------------------------------------------------
# Copy CDE files to USB
# Excluded folders (not needed on bootable USB):
#   Deploy\ - ISO output files (too large, not for USB)
#   Mount\  - DISM working directories
#   Logs\   - local build/runtime logs
#   App\    - source code / project files
# ---------------------------------------------------------------
Write-Step "Copying CDE files to $usbLetter`:\ ..."

$sourceRoot = $CDE_ROOT
$destRoot   = "$usbLetter`:\"

if ($IsoPath) {
    # If ISO path provided, extract it
    if (-not (Test-Path $IsoPath)) { Write-Fail "ISO not found: $IsoPath" }
    Write-Host "  Mode: Extract from ISO"
    $mount = Mount-DiskImage -ImagePath (Resolve-Path $IsoPath).Path -PassThru
    Start-Sleep -Seconds 2
    $isoLetter = ($mount | Get-Volume).DriveLetter
    if (-not $isoLetter) { Write-Fail "Could not determine ISO mount letter." }
    Write-Host "  ISO mounted at $isoLetter`:\"
    $sourceRoot = "$isoLetter`:\"
}

# ---------------------------------------------------------------
# Validate rEFInd source artifacts (UEFI primary boot path)
# ---------------------------------------------------------------
Write-Step "Validating rEFInd source artifacts..."

$refindMainSrc = Join-Path $sourceRoot "EFI\refind\refind_x64.efi"
$refindConfSrc = Join-Path $sourceRoot "EFI\boot\refind.conf"
$refindIconsSrc = Join-Path $sourceRoot "EFI\boot\icons"

if (-not (Test-Path $refindMainSrc)) {
    Write-Fail "Missing required rEFInd binary: $refindMainSrc"
}
if (-not (Test-Path $refindConfSrc)) {
    Write-Fail "Missing required rEFInd config: $refindConfSrc"
}
if (-not (Test-Path $refindIconsSrc)) {
    Write-Fail "Missing required rEFInd icons directory: $refindIconsSrc"
}
Write-OK "rEFInd source artifacts present"

# ---------------------------------------------------------------
# Pre-flight: check available space vs source size
# ---------------------------------------------------------------
Write-Step "Checking available space..."

$excludedFolders = @("Deploy", "Mount", "Logs", "App", ".git", ".venv", ".vscode", "Tools\Deploy", "Tools\.staging")
# Files not needed on the USB (dev tools, repo metadata, docs already handled by *.md)
$excludedFiles   = @("*.md", "CreateISO.vbs", "Run-CustomizeWinPE.vbs", "PrepareUSB.vbs", "SyncUSB.bat", ".gitignore",
                     "script_output.txt",
                     "CreateISO.ps1", "Customize-WinPE.ps1", "Prepare-BootableUSB.ps1",
                     "update_script.ps1", "do_update.ps1")

# Calculate source size excluding the folders that won't be copied
$sourceBytes = 0
Get-ChildItem $sourceRoot -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    # Check if this file is under an excluded folder
    $rel = $_.FullName.Substring($sourceRoot.Length).TrimStart('\')
    $topFolder = ($rel -split '\\')[0]
    if ($topFolder -notin $excludedFolders) {
        $sourceBytes += $_.Length
    }
}
$sourceMB = [math]::Round($sourceBytes / 1MB)
$sourceGB = [math]::Round($sourceBytes / 1GB, 2)

$usbVol = Get-Volume -DriveLetter $usbLetter -ErrorAction SilentlyContinue
if ($usbVol) {
    $freeBytes = $usbVol.SizeRemaining
    $freeMB    = [math]::Round($freeBytes / 1MB)
    Write-Host "  Content to copy: $sourceMB MB  ($sourceGB GB)"
    Write-Host "  USB free space:  $freeMB MB"
    if ($sourceBytes -gt $freeBytes) {
        $shortGB = [math]::Round(($sourceBytes - $freeBytes) / 1GB, 2)
        Write-Fail "Not enough space on USB. Need $sourceGB GB, have $([math]::Round($freeBytes/1GB,2)) GB (short by $shortGB GB)."
    }
    Write-OK "Space check passed ($sourceMB MB needed, $freeMB MB available)"
} else {
    Write-Warn "Could not read USB volume info - proceeding without space check."
}

Write-Host ""
Write-Host "  Source: $sourceRoot  (excluding folders: $($excludedFolders -join ', '))"
Write-Host "  Excluding files:  $($excludedFiles -join ', ')"
Write-Host "  Dest:   $destRoot"
Write-Host "  This may take several minutes depending on USB speed..."
Write-Host ""

# Build robocopy exclusion args for top-level folders (no embedded quotes; PowerShell handles quoting for native exe)
$excludeArgs = $excludedFolders | ForEach-Object { "$sourceRoot\$_" }

& robocopy $sourceRoot $destRoot /E /XD @excludeArgs /XF @excludedFiles /NFL /NDL /NJH /R:2 /W:1
# robocopy exit codes 0-7 are success/informational
$roboexit = $LASTEXITCODE
if ($roboexit -gt 7) { Write-Fail "robocopy failed with exit code $roboexit" }
Write-OK "Files copied successfully (robocopy exit: $roboexit)"

# Ensure UEFI removable fallback path points to rEFInd launcher
Write-Step "Setting UEFI fallback launcher to rEFInd..."
$refindMainDst = "$destRoot\EFI\refind\refind_x64.efi"
$bootx64Dst    = "$destRoot\EFI\boot\bootx64.efi"

if (-not (Test-Path $refindMainDst)) {
    Write-Fail "rEFInd main binary missing on USB after copy: $refindMainDst"
}

Copy-Item $refindMainDst $bootx64Dst -Force
if (-not (Test-Path $bootx64Dst)) {
    Write-Fail "Failed to set fallback launcher at EFI\\boot\\bootx64.efi"
}
Write-OK "UEFI fallback launcher set to rEFInd"

# Dismount ISO if we used one
if ($IsoPath) {
    Dismount-DiskImage -ImagePath (Resolve-Path $IsoPath).Path | Out-Null
    Write-OK "ISO dismounted"
}

# ---------------------------------------------------------------
# Verify boot.wim is present at the canonical BCD path
# ---------------------------------------------------------------
Write-Step "Verifying boot.wim at \sources\boot.wim..."
$wimStd = "$destRoot\sources\boot.wim"
if (Test-Path $wimStd) {
    Write-OK "boot.wim present at \sources\boot.wim"
} else {
    Write-Warn "boot.wim NOT found at \sources\boot.wim - USB will not boot"
}

# ---------------------------------------------------------------
# Make USB bootable with bootsect.exe
# ---------------------------------------------------------------
Write-Step "Applying BIOS boot sector to USB..."

$bootsect = "$CDE_ROOT\boot\bootsect.exe"
if ($diskIsMbr -and (Test-Path $bootsect)) {
    & $bootsect /nt60 "$usbLetter`:" /mbr /force
    if ($LASTEXITCODE -eq 0) { Write-OK "bootsect.exe applied (BIOS bootable)" }
    else { Write-Warn "bootsect.exe returned $LASTEXITCODE - USB may still be UEFI-bootable." }
} elseif (-not $diskIsMbr) {
    Write-OK "Skipping bootsect.exe on GPT disk; USB will boot via UEFI."
} else {
    Write-Warn "bootsect.exe not found. USB may only be UEFI bootable."
}

# ---------------------------------------------------------------
# Validate required UEFI artifacts on USB
# ---------------------------------------------------------------
Write-Step "Validating required UEFI boot artifacts on USB..."

$requiredUefiFiles = @(
    "$destRoot\EFI\boot\bootx64.efi",
    "$destRoot\EFI\refind\refind_x64.efi",
    "$destRoot\EFI\boot\refind.conf",
    "$destRoot\EFI\microsoft\boot\bootmgfw.efi",
    "$destRoot\EFI\CDE\CoreDiag.efi",
    "$destRoot\EFI\CDE\memtest.efi"
)

$requiredUefiDirs = @(
    "$destRoot\EFI\boot\icons"
)

$requiredWindowsLaunchFiles = @(
    "$destRoot\CDE.exe",
    "$destRoot\Scripts\Launch\CDE_Portable.bat"
)

$missingUefi = @($requiredUefiFiles | Where-Object { -not (Test-Path $_) })
$missingUefi += @($requiredUefiDirs | Where-Object { -not (Test-Path $_) })
$missingUefi += @($requiredWindowsLaunchFiles | Where-Object { -not (Test-Path $_) })
if ($missingUefi.Count -gt 0) {
    $missingList = $missingUefi -join "`n    "
    Write-Fail "Missing required boot/launch artifacts on USB:`n    $missingList"
}

# Validate loader paths referenced by refind.conf
$refindConfDst = "$destRoot\EFI\boot\refind.conf"
$loaderLines = Select-String -Path $refindConfDst -Pattern '^\s*loader\s+(.+)$' -AllMatches
foreach ($match in $loaderLines) {
    $rawPath = $match.Matches[0].Groups[1].Value.Trim()
    $cleanPath = $rawPath.Trim('"').Trim("'").Replace('/', '\\').TrimStart('\\')
    if ([string]::IsNullOrWhiteSpace($cleanPath)) { continue }
    $resolved = Join-Path $destRoot $cleanPath
    if (-not (Test-Path $resolved)) {
        Write-Fail "refind.conf references missing loader: $rawPath (resolved: $resolved)"
    }
}
Write-OK "UEFI artifact and refind.conf loader validation passed"

# ---------------------------------------------------------------
# Report
# ---------------------------------------------------------------
$usbUsed = [math]::Round((Get-PSDrive $usbLetter).Used / 1MB, 0)

Write-Host "`n================================================================" -ForegroundColor Green
Write-Host "  USB CREATION COMPLETE" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  Drive:  $usbLetter`:\ ($USB_LABEL)"
Write-Host "  Used:   $usbUsed MB"
Write-Host "  Label:  $USB_LABEL"
Write-Host ""
Write-Host "  Boot methods supported:"
Write-Host "  - BIOS (legacy)  via bootsect + BCD + etfsboot.com"
Write-Host "  - UEFI (modern)  via rEFInd at EFI\boot\bootx64.efi"
Write-Host "  - rEFInd menu:    WinPE / CHU / MemDiag"
Write-Host ""
Write-Host "  To test: Plug into PC, set BIOS to boot from USB."
Write-Host "  To run on Windows: Launch CDE.exe from USB root"
Write-Host "                     Fallback: Scripts\Launch\CDE_Portable.bat"
Write-Host "================================================================`n" -ForegroundColor Green

