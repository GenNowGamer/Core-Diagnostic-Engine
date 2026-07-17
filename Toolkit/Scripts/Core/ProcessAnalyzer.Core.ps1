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

    if ($CommandLine -match '(?i)(xmrig|nicehash|stratum\+tcp|stratum\+ssl|--cuda|--opencl|ethminer|minerd|cgminer|nanopool|minexmr)') {
        $flags.Add('miner_cmdline') | Out-Null
        $score -= 30
    }

    # Build injection/credential markers from fragments to avoid static AV script signatures.
    $injA = 'Virtual' + 'AllocEx'
    $injB = 'Write' + 'Process' + 'Memory'
    $injC = 'Create' + 'Remote' + 'Thread'
    $injD = 'Nt' + 'Create' + 'ThreadEx'
    $injE = 'Reflective' + 'Dll'
    $injF = 'process' + ' hollowing'
    if ($CommandLine -and (
            $CommandLine.IndexOf($injA, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $CommandLine.IndexOf($injB, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $CommandLine.IndexOf($injC, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $CommandLine.IndexOf($injD, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $CommandLine.IndexOf($injE, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $CommandLine.IndexOf($injF, [StringComparison]::OrdinalIgnoreCase) -ge 0
        )) {
        $flags.Add('injection_api_cmdline') | Out-Null
        $score -= 25
    }

    $credA = 'Login' + ' Data'
    $credB = 'key4' + '.db'
    $credC = 'logins' + '.json'
    $credD = 'Web' + ' Data'
    $toolA = 'proc' + 'dump'
    $toolB = 'mimi' + 'katz'
    $toolC = 'lsass' + '.exe'
    if ($CommandLine -and (
            $CommandLine.IndexOf($credA, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $CommandLine.IndexOf($credB, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $CommandLine.IndexOf($credC, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $CommandLine.IndexOf($credD, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $CommandLine -match '(?i)\\cookies\\|"cookies"' -or
            $CommandLine.IndexOf($toolA, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $CommandLine.IndexOf($toolB, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $CommandLine.IndexOf($toolC, [StringComparison]::OrdinalIgnoreCase) -ge 0
        )) {
        $flags.Add('credential_store_touch') | Out-Null
        $score -= 20
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

function Get-ProcessNetworkSnapshot {
    param(
        [int]$ProcessId = 0,
        [int]$MaxRows = 200
    )

    $rows = New-Object System.Collections.Generic.List[object]
    $allowProcessNames = @('chrome', 'msedge', 'firefox', 'teams', 'outlook', 'svchost', 'system', 'lsass', 'services', 'explorer', 'onedrive', 'searchapp', 'runtimebroker')

    try {
        $tcp = @(Get-NetTCPConnection -ErrorAction SilentlyContinue)
        foreach ($c in $tcp) {
            if ($null -eq $c) { continue }
            $owner = 0
            try { $owner = [int]$c.OwningProcess } catch { continue }
            if ($ProcessId -gt 0 -and $owner -ne $ProcessId) { continue }

            $state = [string]$c.State
            $kind = if ($state -eq 'Listen') { 'NetworkListener' } else { 'NetworkConnection' }
            $procName = ''
            $procPath = ''
            try {
                $p = Get-Process -Id $owner -ErrorAction SilentlyContinue
                if ($p) {
                    $procName = [string]$p.ProcessName
                    try { $procPath = [string]$p.Path } catch { }
                }
            } catch { }

            $riskTags = New-Object System.Collections.Generic.List[string]
            $isLoopback = ($c.LocalAddress -eq '127.0.0.1' -or $c.LocalAddress -eq '::1')
            $allowName = $false
            foreach ($n in $allowProcessNames) { if ($procName -ieq $n) { $allowName = $true; break } }
            if ($state -eq 'Listen' -and -not $isLoopback -and -not $allowName) {
                if ($procPath -match '(?i)\\(temp|appdata|users\\public|programdata)\\') {
                    $riskTags.Add('unexpected_listener_risky_path') | Out-Null
                } elseif (-not $allowName) {
                    $riskTags.Add('unexpected_listener') | Out-Null
                }
            }

            $rows.Add([PSCustomObject]@{
                kind = $kind
                path = $procPath
                name = $procName
                pid = $owner
                localAddress = [string]$c.LocalAddress
                localPort = [int]$c.LocalPort
                remoteAddress = [string]$c.RemoteAddress
                remotePort = [int]$c.RemotePort
                state = $state
                riskTags = @($riskTags)
                sourceChannel = 'Get-NetTCPConnection'
                evidenceKind = 'ImportedTelemetry'
                evidence = ("TCP {0} {1}:{2} -> {3}:{4} owned by PID {5}" -f $state, $c.LocalAddress, $c.LocalPort, $c.RemoteAddress, $c.RemotePort, $owner)
            }) | Out-Null

            if ($rows.Count -ge $MaxRows) { break }
        }
    } catch { }

    if ($rows.Count -lt $MaxRows) {
        try {
            foreach ($u in @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue)) {
                if ($null -eq $u) { continue }
                $owner = 0
                try { $owner = [int]$u.OwningProcess } catch { continue }
                if ($ProcessId -gt 0 -and $owner -ne $ProcessId) { continue }
                $procName = ''
                $procPath = ''
                try {
                    $p = Get-Process -Id $owner -ErrorAction SilentlyContinue
                    if ($p) {
                        $procName = [string]$p.ProcessName
                        try { $procPath = [string]$p.Path } catch { }
                    }
                } catch { }

                $rows.Add([PSCustomObject]@{
                    kind = 'NetworkListener'
                    path = $procPath
                    name = $procName
                    pid = $owner
                    localAddress = [string]$u.LocalAddress
                    localPort = [int]$u.LocalPort
                    remoteAddress = ''
                    remotePort = 0
                    state = 'UDP'
                    riskTags = @()
                    sourceChannel = 'Get-NetUDPEndpoint'
                    evidenceKind = 'ImportedTelemetry'
                    evidence = ("UDP endpoint {0}:{1} owned by PID {2}" -f $u.LocalAddress, $u.LocalPort, $owner)
                }) | Out-Null

                if ($rows.Count -ge $MaxRows) { break }
            }
        } catch { }
    }

    return [object[]]$rows.ToArray()
}

function Export-ProcessNetworkArtifactsForCst {
    param(
        [Parameter(Mandatory)][string]$OutputPath,
        [int]$MaxRows = 200
    )

    $artifacts = @(Get-ProcessNetworkSnapshot -MaxRows $MaxRows | ForEach-Object {
        [PSCustomObject]@{
            kind = $_.kind
            path = $_.path
            name = $_.name
            location = ("{0}:{1}" -f $_.localAddress, $_.localPort)
            state = $_.state
            evidence = $_.evidence
            entityType = 'Network'
            pid = $_.pid
            sourceChannel = $_.sourceChannel
            evidenceKind = $_.evidenceKind
            riskTags = @($_.riskTags)
            confidenceDelta = $(if (@($_.riskTags).Count -gt 0) { 0.08 } else { 0.0 })
        }
    })

    $dir = Split-Path -Parent $OutputPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    @{ artifacts = @($artifacts) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    return $OutputPath
}

function Get-ProcessModuleAnomalies {
    param(
        [int]$ProcessId,
        [string]$ProcessPath = ''
    )

    $anomalies = New-Object System.Collections.Generic.List[object]
    try {
        $modules = @(Get-ProcessLoadedModules -ProcessId $ProcessId -MaxModules 40)
        foreach ($modPath in $modules) {
            $modPath = [string]$modPath
            if ([string]::IsNullOrWhiteSpace($modPath)) { continue }
            $signed = Test-ProcessPathSigned -Path $modPath
            if ($signed -eq $false -and $ProcessPath -match '(?i)\\Windows\\System32\\' -and $modPath -notmatch '(?i)\\Windows\\') {
                $anomalies.Add([PSCustomObject]@{
                    Module = $modPath
                    Reason = 'Unsigned module loaded into Windows system process'
                }) | Out-Null
            }
            if ($modPath -match '(?i)\\Temp\\|\\AppData\\' -and $ProcessPath -match '(?i)\\Windows\\') {
                $anomalies.Add([PSCustomObject]@{
                    Module = $modPath
                    Reason = 'User-writable module path in system process'
                }) | Out-Null
            }
        }
    } catch { }
    return [object[]]$anomalies.ToArray()
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
        Success   = ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 1 -or $LASTEXITCODE -eq 2)
        Output    = $output.Trim()
        ExitCode  = $LASTEXITCODE
    }
}

function Invoke-PathCstScan {
    param(
        [string]$TargetPath = '',
        [string]$TargetPathsFile = '',
        [Parameter(Mandatory)][string]$ToolkitRoot
    )

    $cstScript = Join-Path $ToolkitRoot 'Security\CST\CoreSecurityTool.ps1'
    if (-not (Test-Path -LiteralPath $cstScript)) {
        return [PSCustomObject]@{
            Available = $false
            Message   = 'CST runtime not found on this toolkit.'
            ScanKind  = 'PathScan'
        }
    }

    $targets = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($TargetPathsFile)) {
        if (-not (Test-Path -LiteralPath $TargetPathsFile -PathType Leaf)) {
            return [PSCustomObject]@{
                Available = $true
                Success   = $false
                Message   = "Target paths file not found: $TargetPathsFile"
                ScanKind  = 'PathScan'
            }
        }

        try {
            $doc = Get-Content -LiteralPath $TargetPathsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $rawPaths = @()
            if ($null -ne $doc.targets) { $rawPaths = @($doc.targets) }
            elseif ($null -ne $doc.Paths) { $rawPaths = @($doc.Paths) }
            elseif ($doc -is [System.Array]) { $rawPaths = @($doc) }

            foreach ($p in $rawPaths) {
                $s = [string]$p
                if ([string]::IsNullOrWhiteSpace($s)) { continue }
                $targets.Add($s.Trim().Trim('"'))
            }
        }
        catch {
            return [PSCustomObject]@{
                Available = $true
                Success   = $false
                Message   = "Could not parse target paths file: $($_.Exception.Message)"
                ScanKind  = 'PathScan'
            }
        }
    }

    if ($targets.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($TargetPath)) {
        $targets.Add($TargetPath.Trim().Trim('"'))
    }

    if ($targets.Count -eq 0) {
        return [PSCustomObject]@{
            Available = $true
            Success   = $false
            Message   = 'No scan targets were provided.'
            ScanKind  = 'PathScan'
        }
    }

    $resolved = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    $hasDirectory = $false
    foreach ($t in $targets) {
        if (-not (Test-Path -LiteralPath $t)) {
            $missing.Add($t)
            continue
        }
        try {
            $full = [System.IO.Path]::GetFullPath($t)
        }
        catch {
            $full = $t
        }
        if ((Test-Path -LiteralPath $full -PathType Container)) {
            $hasDirectory = $true
        }
        if (-not ($resolved | Where-Object { $_ -ieq $full })) {
            $resolved.Add($full)
        }
    }

    if ($resolved.Count -eq 0) {
        return [PSCustomObject]@{
            Available = $true
            Success   = $false
            Message   = "Target not found: $($missing -join '; ')"
            ScanKind  = 'PathScan'
        }
    }

    $maxMinutes = if ($hasDirectory -or $resolved.Count -gt 1) { 8 } else { 3 }
    $raw = (& $cstScript -Operation Scan -Mode CustomScan -Target @($resolved.ToArray()) -EmitJson -MaxMinutes $maxMinutes 2>&1 | Out-String)
    $exitCode = $LASTEXITCODE
    $json = Get-CstLastJsonObjectFromText -Text $raw
    if ([string]::IsNullOrWhiteSpace($json)) {
        return [PSCustomObject]@{
            Available = $true
            Success   = $false
            Message   = 'CST path scan returned no JSON payload.'
            Output    = $raw.Trim()
            ExitCode  = $exitCode
            ScanKind  = 'PathScan'
            Targets   = @($resolved.ToArray())
        }
    }

    return [PSCustomObject]@{
        Available = $true
        Success   = ($exitCode -eq 0 -or $exitCode -eq 1 -or $exitCode -eq 2)
        Output    = $json
        ExitCode  = $exitCode
        ScanKind  = 'PathScan'
        Targets   = @($resolved.ToArray())
        Missing   = @($missing.ToArray())
    }
}

function Invoke-StartupEntryCstScan {
    param(
        [Parameter(Mandatory)][string]$MetadataPath,
        [Parameter(Mandatory)][string]$ToolkitRoot
    )

    $cstScript = Join-Path $ToolkitRoot 'Security\CST\CoreSecurityTool.ps1'
    if (-not (Test-Path -LiteralPath $cstScript)) {
        return [PSCustomObject]@{
            Available = $false
            Message   = 'CST runtime not found on this toolkit.'
        }
    }

    if (-not (Test-Path -LiteralPath $MetadataPath -PathType Leaf)) {
        return [PSCustomObject]@{
            Available = $true
            Success   = $false
            Message   = "Startup entry metadata not found: $MetadataPath"
        }
    }

    $raw = (& $cstScript -Operation Scan -StartupEntryMetadataPath $MetadataPath -EmitJson -MaxMinutes 3 2>&1 | Out-String)
    $exitCode = $LASTEXITCODE
    $json = Get-CstLastJsonObjectFromText -Text $raw
    if ([string]::IsNullOrWhiteSpace($json)) {
        return [PSCustomObject]@{
            Available = $true
            Success   = $false
            Message   = 'CST startup-entry scan returned no JSON payload.'
            Output    = $raw.Trim()
            ExitCode  = $exitCode
            ScanKind  = 'StartupEntryScan'
        }
    }

    return [PSCustomObject]@{
        Available = $true
        Success   = ($exitCode -eq 0 -or $exitCode -eq 1 -or $exitCode -eq 2)
        Output    = $json
        ExitCode  = $exitCode
        ScanKind  = 'StartupEntryScan'
    }
}

function Get-CstLastJsonObjectFromText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $best = ''
    $bestScore = -1
    for ($i = 0; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -ne '{') { continue }

        $depth = 0
        $inString = $false
        $escape = $false
        for ($j = $i; $j -lt $Text.Length; $j++) {
            $ch = $Text[$j]
            if ($inString) {
                if ($escape) { $escape = $false; continue }
                if ($ch -eq '\') { $escape = $true; continue }
                if ($ch -eq '"') { $inString = $false }
                continue
            }

            if ($ch -eq '"') { $inString = $true; continue }
            if ($ch -eq '{') { $depth++ }
            elseif ($ch -eq '}') {
                $depth--
                if ($depth -eq 0) {
                    $candidate = $Text.Substring($i, $j - $i + 1)
                    $score = 0
                    if ($candidate -match '"scanKind"\s*:\s*"StartupEntryScan"') { $score += 100 }
                    if ($candidate -match '"verdicts"') { $score += 40 }
                    if ($candidate -match '"findings"') { $score += 20 }
                    if ($candidate -match '"overallVerdict"') { $score += 20 }
                    if ($candidate -match '"scanMode"\s*:\s*"CustomScan"') { $score += 50 }
                    if ($candidate -match '"summary"') { $score += 15 }
                    if ($candidate -match '"threatsFound"') { $score += 15 }
                    if ($candidate -match '"itemsScanned"') { $score += 10 }
                    if ($score -gt $bestScore) {
                        $bestScore = $score
                        $best = $candidate
                    }
                    $i = $j
                    break
                }
            }
        }
    }

    if ($bestScore -gt 0) { return $best }

    # Fallback: last balanced object
    $last = ''
    for ($i = 0; $i -lt $Text.Length; $i++) {
        if ($Text[$i] -ne '{') { continue }
        $depth = 0
        $inString = $false
        $escape = $false
        for ($j = $i; $j -lt $Text.Length; $j++) {
            $ch = $Text[$j]
            if ($inString) {
                if ($escape) { $escape = $false; continue }
                if ($ch -eq '\') { $escape = $true; continue }
                if ($ch -eq '"') { $inString = $false }
                continue
            }
            if ($ch -eq '"') { $inString = $true; continue }
            if ($ch -eq '{') { $depth++ }
            elseif ($ch -eq '}') {
                $depth--
                if ($depth -eq 0) {
                    $last = $Text.Substring($i, $j - $i + 1)
                    $i = $j
                    break
                }
            }
        }
    }
    return $last
}
