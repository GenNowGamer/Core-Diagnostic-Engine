#Requires -Version 5.1
<#
.SYNOPSIS
    Shared process inspection helpers for ProcessAnalyzer.ps1.
#>

function Get-ProcessCpuPercentMap {
    param(
        [int]$SampleMs = 1000
    )

    if ($SampleMs -lt 200) { $SampleMs = 200 }

    $snap1 = @{}
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Id -gt 0) {
            $snap1[$_.Id] = [double]$_.CPU
        }
    }

    Start-Sleep -Milliseconds $SampleMs

    $cores = [Environment]::ProcessorCount
    if ($cores -lt 1) { $cores = 1 }
    $intervalSec = $SampleMs / 1000.0

    $result = @{}
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        $id = $_.Id
        if (-not $snap1.ContainsKey($id)) { return }
        $delta = [double]$_.CPU - $snap1[$id]
        if ($delta -lt 0) { $delta = 0 }
        $pct = ($delta / $intervalSec / $cores) * 100.0
        $result[$id] = [math]::Round($pct, 1)
    }

    return $result
}

function Get-PeMachineArch {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }

    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $br = New-Object System.IO.BinaryReader($fs)
            if ($fs.Length -lt 0x40) { return '' }
            $fs.Seek(0x3C, [System.IO.SeekOrigin]::Begin) | Out-Null
            $peOffset = $br.ReadInt32()
            if ($peOffset -le 0 -or ($peOffset + 6) -gt $fs.Length) { return '' }
            $fs.Seek($peOffset + 4, [System.IO.SeekOrigin]::Begin) | Out-Null
            switch ($br.ReadUInt16()) {
                0x014c { return 'x86' }
                0x8664 { return 'x64' }
                0xAA64 { return 'ARM64' }
                default { return '?' }
            }
        }
        finally {
            $fs.Dispose()
        }
    }
    catch {
        return ''
    }
}

function Format-ProcessCreationTime {
    param($CreationDate)

    if ($null -eq $CreationDate) { return '' }

    try {
        if ($CreationDate -is [datetime]) {
            return $CreationDate.ToString('yyyy-MM-dd HH:mm:ss')
        }

        return ([Management.ManagementDateTimeConverter]::ToDateTime([string]$CreationDate)).ToString('yyyy-MM-dd HH:mm:ss')
    }
    catch {
        return ''
    }
}

function Get-ProcessOwnerName {
    param($WmiProcess)

    if ($null -eq $WmiProcess) { return '' }
    try {
        $owner = $null
        if ($WmiProcess -is [Microsoft.Management.Infrastructure.CimInstance]) {
            $owner = Invoke-CimMethod -InputObject $WmiProcess -MethodName GetOwner -ErrorAction Stop
        }
        elseif ($WmiProcess.PSObject.Methods['GetOwner']) {
            $owner = $WmiProcess.GetOwner()
        }
        else {
            $owner = Invoke-CimMethod -InputObject $WmiProcess -MethodName GetOwner -ErrorAction Stop
        }

        if ($null -eq $owner) { return '' }

        if ($owner.PSObject.Properties['ReturnValue'] -and [int]$owner.ReturnValue -ne 0) {
            return ''
        }

        $domain = [string]$owner.Domain
        $user = [string]$owner.User
        if ([string]::IsNullOrWhiteSpace($user)) { return '' }
        if ([string]::IsNullOrWhiteSpace($domain) -or $domain -eq '.') { return $user }
        return "$domain\$user"
    }
    catch {
        return ''
    }
}

function Get-ProcessRiskInfo {
    param(
        [string]$Name,
        [string]$FilePath,
        [string]$CommandLine,
        [nullable[bool]]$IsSigned,
        [double]$CpuPercent,
        [double]$RamMB,
        [string]$Status
    )

    $flags = [System.Collections.Generic.List[string]]::new()
    $score = 70

    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        $flags.Add('no_image_path') | Out-Null
        $score -= 25
    }

    if ($Status -eq 'Not Responding') {
        $flags.Add('not_responding') | Out-Null
        $score -= 10
    }

    if ($null -ne $IsSigned -and -not $IsSigned -and $FilePath -and $FilePath -notmatch '(?i)\\Windows\\') {
        $flags.Add('unsigned') | Out-Null
        $score -= 15
    }

    if ($FilePath -match '(?i)\\Temp\\|\\Downloads\\|AppData\\Local\\Temp') {
        $flags.Add('writable_path') | Out-Null
        $score -= 20
    }

    if ($CpuPercent -gt 50) {
        $flags.Add('high_cpu') | Out-Null
        $score -= 5
    }

    if ($RamMB -gt 1024) {
        $flags.Add('high_ram') | Out-Null
        $score -= 5
    }

    if ($FilePath -and $Name) {
        $fileLeaf = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
        if ($fileLeaf -and ($Name -ne $fileLeaf) -and $Name -notmatch '^(svchost|RuntimeBroker|dllhost|conhost)$') {
            $flags.Add('name_mismatch') | Out-Null
            $score -= 15
        }
    }

    if ($Name -match '^(powershell|pwsh|wscript|cscript|mshta|cmd)$' -and $CommandLine -match '(?i)(encodedcommand|downloadstring|downloadfile|hidden|bypass|frombase64)') {
        $flags.Add('suspicious_cmdline') | Out-Null
        $score -= 25
    }

    if ($score -gt 100) { $score = 100 }
    if ($score -lt 0) { $score = 0 }

    $band = 'Caution'
    if ($score -ge 70) { $band = 'Safe' }
    elseif ($score -lt 40) { $band = 'Warning' }

    return [PSCustomObject]@{
        Score = $score
        Band  = $band
        Flags = ($flags -join ',')
    }
}

function Test-ProcessPathInStartup {
    param([string]$ExePath)

    if ([string]::IsNullOrWhiteSpace($ExePath)) { return $false }

    $needle = $ExePath.Trim().Trim('"').ToLowerInvariant()
    $leaf = [System.IO.Path]::GetFileName($needle)

    $runKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    )

    foreach ($key in $runKeys) {
        try {
            $item = Get-ItemProperty -Path $key -ErrorAction Stop
            foreach ($prop in $item.PSObject.Properties) {
                if ($prop.Name -in @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')) { continue }
                $val = ([string]$prop.Value).ToLowerInvariant()
                if ($val -and ($val.Contains($needle) -or ($leaf -and $val.Contains($leaf)))) {
                    return $true
                }
            }
        }
        catch { }
    }

    $startupFolders = @(
        [Environment]::GetFolderPath('Startup'),
        [Environment]::GetFolderPath('CommonStartup')
    )

    foreach ($folder in $startupFolders) {
        if ([string]::IsNullOrWhiteSpace($folder) -or -not (Test-Path -LiteralPath $folder)) { continue }
        try {
            foreach ($item in @(Get-ChildItem -LiteralPath $folder -ErrorAction SilentlyContinue)) {
                $target = $item.FullName.ToLowerInvariant()
                if ($target -eq $needle -or $target.Contains($leaf)) { return $true }
            }
        }
        catch { }
    }

    return $false
}

function Get-ProcessParentChain {
    param(
        [int]$ProcessId,
        [int]$MaxDepth = 5
    )

    $chain = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $currentId = $ProcessId
    $depth = 0

    while ($currentId -gt 0 -and $depth -lt $MaxDepth -and -not $seen.ContainsKey($currentId)) {
        $seen[$currentId] = $true
        $wmi = Get-CimInstance Win32_Process -Filter "ProcessId=$currentId" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $wmi) { break }

        $chain.Add([PSCustomObject]@{
            Pid         = [int]$wmi.ProcessId
            ParentPid   = [int]$wmi.ParentProcessId
            Name        = [string]$wmi.Name
            CommandLine = [string]$wmi.CommandLine
            FilePath    = [string]$wmi.ExecutablePath
        }) | Out-Null

        $currentId = [int]$wmi.ParentProcessId
        $depth++
    }

    return @($chain)
}

function Get-SvchostServiceNames {
    param([int]$ProcessId)

    if ($ProcessId -le 0) { return @() }

    $names = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($svc in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue)) {
            if ([int]$svc.ProcessId -eq $ProcessId) {
                $names.Add([string]$svc.Name) | Out-Null
            }
        }
    }
    catch { }

    return @($names)
}

function Get-ProcessLoadedModules {
    param(
        [int]$ProcessId,
        [int]$MaxModules = 15
    )

    $modules = [System.Collections.Generic.List[string]]::new()
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        if ($null -eq $proc.Modules) { return @() }
        foreach ($mod in @($proc.Modules)) {
            if ($null -eq $mod) { continue }
            $path = [string]$mod.FileName
            if ([string]::IsNullOrWhiteSpace($path)) { continue }
            $modules.Add($path) | Out-Null
            if ($modules.Count -ge $MaxModules) { break }
        }
    }
    catch { }

    return @($modules)
}

function Test-ProcessPathSigned {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        return ($sig.Status -eq 'Valid')
    }
    catch {
        return $null
    }
}

function Get-ToolkitRootFromScript {
    param([string]$WorkflowScriptRoot)
    return (Resolve-Path (Join-Path $WorkflowScriptRoot '..\\..')).Path
}

function Get-ProcessImagePath {
    param(
        [int]$ProcessId,
        $WmiProcess = $null
    )

    $path = ''
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        try { $path = [string]$proc.Path } catch { }
    }
    catch { }

    if ([string]::IsNullOrWhiteSpace($path) -and $null -ne $WmiProcess) {
        $path = [string]$WmiProcess.ExecutablePath
    }

    if ([string]::IsNullOrWhiteSpace($path)) {
        $wmi = if ($null -ne $WmiProcess) { $WmiProcess } else {
            Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if ($null -ne $wmi) {
            $path = [string]$wmi.ExecutablePath
        }
    }

    return $path.Trim()
}

function Invoke-ProcessCstCustomScan {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$ToolkitRoot
    )

    $cstScript = Join-Path $ToolkitRoot 'Security\CST\CoreSecurityTool.ps1'
    if (-not (Test-Path -LiteralPath $cstScript)) {
        return [PSCustomObject]@{
            Available = $false
            Message   = 'CST runtime not found on this toolkit.'
        }
    }

    $target = $TargetPath.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $target)) {
        return [PSCustomObject]@{
            Available = $true
            Success   = $false
            Message   = "Target not found: $target"
        }
    }

    $output = (& $cstScript -Operation Scan -Mode CustomScan -Target $target -EmitJson -MaxMinutes 3 2>&1 | Out-String)
    return [PSCustomObject]@{
        Available = $true
        Success   = ($LASTEXITCODE -eq 0)
        Output    = $output.Trim()
        ExitCode  = $LASTEXITCODE
    }
}
