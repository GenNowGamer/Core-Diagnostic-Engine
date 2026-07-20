#Requires -Version 5.1
<#
.SYNOPSIS
    Per-machine Health/SMART baseline store for cross-run deltas.
#>

function Get-CdeMachineBaselineRoot {
    if (Get-Command Get-ToolkitWorkflowDataRoot -ErrorAction SilentlyContinue) {
        $dataRoot = Get-ToolkitWorkflowDataRoot
        $parent = Split-Path $dataRoot -Parent
        return (Join-Path $parent 'baselines')
    }
    $coreDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path }
    return (Join-Path (Join-Path $coreDir '..\..\CDE\Runtime\Data') 'baselines')
}

function Get-CdeMachineBaselineId {
    $serial = ''
    try {
        $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($bios -and -not [string]::IsNullOrWhiteSpace([string]$bios.SerialNumber)) {
            $serial = ([string]$bios.SerialNumber).Trim()
        }
    } catch { }

    if ([string]::IsNullOrWhiteSpace($serial) -or $serial -match '^(?i)(To be filled|None|Default string|System Serial|0+)$') {
        $serial = $env:COMPUTERNAME
    }

    $safe = ($serial -replace '[^\w\-.]', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'unknown' }
    return $safe.ToLowerInvariant()
}

function Get-CdeMachineBaselinePath {
    param([string]$MachineId = '')

    if ([string]::IsNullOrWhiteSpace($MachineId)) {
        $MachineId = Get-CdeMachineBaselineId
    }
    $root = Get-CdeMachineBaselineRoot
    if (-not (Test-Path -LiteralPath $root)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
    }
    return (Join-Path $root ("{0}.json" -f $MachineId))
}

function Import-CdeMachineBaseline {
    param([string]$MachineId = '')

    $path = Get-CdeMachineBaselinePath -MachineId $MachineId
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Export-CdeMachineBaseline {
    param(
        [Parameter(Mandatory)]$Baseline,
        [string]$MachineId = ''
    )

    $path = Get-CdeMachineBaselinePath -MachineId $MachineId
    $json = $Baseline | ConvertTo-Json -Depth 8 -Compress
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
    return $path
}

function Get-CdeSmartBaselineFingerprint {
    <#
    .SYNOPSIS Extract comparable SMART counters from a SmartAnalyzer / HW step output blob.
    #>
    param([string]$Text)

    $map = @{}
    if ([string]::IsNullOrWhiteSpace($Text)) { return $map }

    # Attr lines: "5 Reallocated ..." or "MediaErrors: N" style from CDE SMART text.
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '(?i)\b(?:attr(?:ibute)?\s*)?(5|10|184|187|196|197|198)\b.*?(\d+)\s*$') {
            $map["ata_$($Matches[1])"] = [int64]$Matches[2]
        }
        elseif ($line -match '(?i)media\s*errors?\s*[:=]\s*(\d+)') {
            $map['nvme_media_errors'] = [int64]$Matches[1]
        }
        elseif ($line -match '(?i)percentage\s*used\s*[:=]\s*(\d+)') {
            $map['nvme_percent_used'] = [int64]$Matches[1]
        }
    }
    return $map
}

function New-CdeMachineBaselineFromWorkflow {
    param([Parameter(Mandatory)]$WorkflowResult)

    $findings = @()
    $smart = @{}
    $vitals = @{}

    foreach ($step in @($WorkflowResult.Steps)) {
        if ($null -eq $step) { continue }
        $checkId = if ($step.PSObject.Properties['CheckId']) { [string]$step.CheckId } else { '' }
        if ($checkId -eq 'cpu_load' -and $step.PSObject.Properties['Value']) {
            $vitals['cpu_load'] = [double]$step.Value
        }
        if ($checkId -eq 'ram' -and $step.PSObject.Properties['UsedPct']) {
            $vitals['ram_used_pct'] = [double]$step.UsedPct
        }
        if ($checkId -eq 'battery_health') {
            foreach ($f in @($step.StructuredFindings)) {
                if ($f.findingId -match 'battery' -and $f.evidence) {
                    $vitals['battery_evidence'] = [string](@($f.evidence)[0])
                }
            }
        }

        $name = [string]$step.Name
        $out = if ($step.PSObject.Properties['Output']) { [string]$step.Output } else { '' }
        if ($name -match '(?i)smart|storage|drive' -or $out -match '(?i)Reallocated|MediaErrors|Percentage Used') {
            $fp = Get-CdeSmartBaselineFingerprint -Text $out
            foreach ($k in $fp.Keys) { $smart[$k] = $fp[$k] }
        }

        # Prefer structured SMART Data from SmartAnalyzer steps.
        if ($step.PSObject.Properties['Data'] -and $null -ne $step.Data) {
            $d = $step.Data
            $prefix = 'd{0}_' -f $(if ($d.PSObject.Properties['Index']) { [int]$d.Index } else { 0 })
            if ($d.PSObject.Properties['Attributes']) {
                foreach ($a in @($d.Attributes)) {
                    $id = if ($a.PSObject.Properties['Id']) { [int]$a.Id } else { 0 }
                    if ($id -in @(5, 10, 184, 187, 196, 197, 198, 199)) {
                        $raw = 0
                        if ($a.PSObject.Properties['Raw']) { $raw = [int64]$a.Raw }
                        elseif ($a.PSObject.Properties['RawValue']) { $raw = [int64]$a.RawValue }
                        $smart["${prefix}ata_$id"] = $raw
                    }
                }
            }
            if ($d.PSObject.Properties['MediaErrors'] -and $null -ne $d.MediaErrors) {
                $smart["${prefix}nvme_media_errors"] = [int64]$d.MediaErrors
            }
            if ($d.PSObject.Properties['PercentageUsed'] -and $null -ne $d.PercentageUsed) {
                $smart["${prefix}nvme_percent_used"] = [int64]$d.PercentageUsed
            }
        }

        foreach ($f in @($step.StructuredFindings)) {
            if ($null -eq $f) { continue }
            $findings += [PSCustomObject]@{
                findingId      = [string]$f.findingId
                classification = [string]$f.classification
                severity       = [string]$f.severity
                status         = [string]$f.status
                confidence     = [int]$f.confidence
            }
        }
    }

    return [PSCustomObject]@{
        schemaVersion  = 1
        machineId      = Get-CdeMachineBaselineId
        computerName   = $env:COMPUTERNAME
        capturedUtc    = [datetime]::UtcNow.ToString('o')
        overallHealth  = if ($WorkflowResult.PSObject.Properties['OverallHealth']) { [string]$WorkflowResult.OverallHealth } else { '' }
        workflowName   = if ($WorkflowResult.PSObject.Properties['WorkflowName']) { [string]$WorkflowResult.WorkflowName } else { '' }
        vitals         = $vitals
        smart          = $smart
        findings       = @($findings)
    }
}

function Compare-CdeSmartBaselineDelta {
    param(
        $PriorSmart,
        $CurrentSmart
    )

    $deltas = New-Object System.Collections.Generic.List[object]
    if ($null -eq $PriorSmart -or $null -eq $CurrentSmart) { return @() }

    $keys = @($PriorSmart.PSObject.Properties.Name)
    if ($PriorSmart -is [hashtable]) { $keys = @($PriorSmart.Keys) }

    foreach ($key in $keys) {
        $prev = if ($PriorSmart -is [hashtable]) { [int64]$PriorSmart[$key] } else { [int64]$PriorSmart.$key }
        $curr = $null
        if ($CurrentSmart -is [hashtable]) {
            if ($CurrentSmart.ContainsKey($key)) { $curr = [int64]$CurrentSmart[$key] }
        }
        elseif ($CurrentSmart.PSObject.Properties[$key]) {
            $curr = [int64]$CurrentSmart.$key
        }
        if ($null -eq $curr) { continue }
        if ($curr -gt $prev) {
            $deltas.Add([PSCustomObject]@{
                Key      = $key
                Previous = $prev
                Current  = $curr
                Delta    = ($curr - $prev)
            }) | Out-Null
        }
    }
    return , @($deltas.ToArray())
}

function Invoke-HealthBaselineDelta {
    <#
    .SYNOPSIS
      Compare current workflow findings/SMART fingerprint to the last saved baseline.
      Returns finding objects to attach; does not mutate steps by itself.
    #>
    param([Parameter(Mandatory)]$WorkflowResult)

    $prior = Import-CdeMachineBaseline
    if ($null -eq $prior) { return @() }

    $current = New-CdeMachineBaselineFromWorkflow -WorkflowResult $WorkflowResult
    $out = New-Object System.Collections.Generic.List[object]

    $smartDeltas = @(Compare-CdeSmartBaselineDelta -PriorSmart $prior.smart -CurrentSmart $current.smart)
    foreach ($d in $smartDeltas) {
        $mediaKeys = @('ata_5', 'ata_196', 'ata_197', 'ata_198', 'nvme_media_errors')
        $isMedia = $mediaKeys -contains $d.Key
        $sev = if ($isMedia) { 'High' } else { 'Medium' }
        $cls = if ($isMedia) { 'CorroboratedSuspect' } else { 'SingleSignal' }
        $out.Add((New-HealthFinding -FindingId ("baseline.smart.delta_{0}" -f $d.Key) -CheckId 'critical_events_7d' `
            -Finding ("SMART counter increased: {0}" -f $d.Key) `
            -Impact 'Growing media/error counters since the last CDE baseline often indicate progressive drive wear.' `
            -Severity $sev -Confidence 85 -Status 'Warn' -Classification $cls `
            -Evidence @(
                ("Previous={0}" -f $d.Previous),
                ("Current={0}" -f $d.Current),
                ("Delta=+{0}" -f $d.Delta),
                ("PriorBaselineUtc={0}" -f $prior.capturedUtc)
            ) `
            -Recommendations @('Run Diag & Repair storage tests.', 'Back up important data if media counters are rising.') `
            -Actions @(@{ type = 'cde'; target = 'HardwareDiagnostics'; label = 'Diag & Repair' })
        )) | Out-Null
    }

    $priorIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($f in @($prior.findings)) {
        if ($f.classification -match '(?i)ConfirmedFault' -or $f.status -match '(?i)fail') {
            [void]$priorIds.Add([string]$f.findingId)
        }
    }
    foreach ($f in @($current.findings)) {
        if ($f.classification -match '(?i)ConfirmedFault' -and -not $priorIds.Contains([string]$f.findingId)) {
            $out.Add((New-HealthFinding -FindingId 'baseline.new_confirmed_fault' -CheckId 'critical_events_7d' `
                -Finding 'New confirmed fault since last baseline' `
                -Impact 'A ConfirmedFault appeared that was not present on the prior saved run for this machine.' `
                -Severity 'High' -Confidence 80 -Status 'Warn' -Classification 'CorroboratedSuspect' `
                -Evidence @(
                    ("FindingId={0}" -f $f.findingId),
                    ("PriorBaselineUtc={0}" -f $prior.capturedUtc)
                ) `
                -Recommendations @('Treat as higher priority than an isolated SingleSignal.')
            )) | Out-Null
            break
        }
    }

    return @($out.ToArray())
}

function Save-CdeMachineBaselineFromWorkflow {
    param([Parameter(Mandatory)]$WorkflowResult)

    $baseline = New-CdeMachineBaselineFromWorkflow -WorkflowResult $WorkflowResult
    return Export-CdeMachineBaseline -Baseline $baseline -MachineId $baseline.machineId
}

function Add-HealthBaselineDeltaFindings {
    param([Parameter(Mandatory)]$WorkflowResult)

    if (-not (Get-Command New-HealthFinding -ErrorAction SilentlyContinue)) { return 0 }
    $deltas = @(Invoke-HealthBaselineDelta -WorkflowResult $WorkflowResult)
    if ($deltas.Count -eq 0) { return 0 }

    # Attach to CriticalEvents step when present; otherwise create a BaselineDelta step.
    $target = $null
    foreach ($step in @($WorkflowResult.Steps)) {
        if ($step.PSObject.Properties['CheckId'] -and [string]$step.CheckId -eq 'critical_events_7d') {
            $target = $step
            break
        }
    }

    if ($null -ne $target) {
        $existing = @()
        if ($target.PSObject.Properties['StructuredFindings'] -and $null -ne $target.StructuredFindings) {
            $existing = @($target.StructuredFindings)
        }
        $merged = @($existing) + @($deltas)
        $ht = @{
            Name    = [string]$target.Name
            Status  = [string]$target.Status
            Detail  = if ($target.PSObject.Properties['Detail']) { [string]$target.Detail } else { '' }
            Output  = ''
            CheckId = 'critical_events_7d'
        }
        $rawOut = if ($target.PSObject.Properties['Output']) { [string]$target.Output } else { '' }
        $body = @(
            $rawOut -split "`r?`n" |
                Where-Object { $_ -notmatch '^\[HEALTH:FINDING\]' }
        ) -join "`n"
        $ht.Output = $body.TrimEnd()
        Add-HealthFindingsToStep -Step $ht -Findings $merged -SummaryText $ht.Detail
        $target.Status = $ht.Status
        $target.Output = $ht.Output
        $target.StructuredFindings = $ht.StructuredFindings
    }
    else {
        $step = @{
            Name    = 'BaselineDelta'
            Status  = 'Warn'
            Detail  = ("{0} baseline delta finding(s)" -f $deltas.Count)
            Output  = 'Compared against prior per-machine baseline.'
            CheckId = 'critical_events_7d'
        }
        Add-HealthFindingsToStep -Step $step -Findings $deltas -SummaryText $step.Detail
        $WorkflowResult.Steps.Add([PSCustomObject]$step)
    }

    return $deltas.Count
}
