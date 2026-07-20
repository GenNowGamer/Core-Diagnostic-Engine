#Requires -Version 5.1
<#
.SYNOPSIS
    Post-run corroboration: promote/demote findings using cross-check evidence.
#>

function Get-HealthWorkflowFindingRefs {
    param($WorkflowResult)

    $refs = New-Object System.Collections.Generic.List[object]
    if ($null -eq $WorkflowResult -or $null -eq $WorkflowResult.Steps) { return @() }

    for ($si = 0; $si -lt @($WorkflowResult.Steps).Count; $si++) {
        $step = $WorkflowResult.Steps[$si]
        if ($null -eq $step) { continue }
        $findings = @()
        if ($step.PSObject.Properties.Name -contains 'StructuredFindings' -and $null -ne $step.StructuredFindings) {
            $findings = @($step.StructuredFindings)
        }
        for ($fi = 0; $fi -lt $findings.Count; $fi++) {
            $f = $findings[$fi]
            if ($null -eq $f) { continue }
            $refs.Add([PSCustomObject]@{
                StepIndex    = $si
                FindingIndex = $fi
                Step         = $step
                Finding      = $f
                FindingId    = [string]$f.findingId
                CheckId      = [string]$f.checkId
                Status       = [string]$f.status
                Classification = [string]$f.classification
                Severity     = [string]$f.severity
            })
        }
    }
    return @($refs.ToArray())
}

function Set-HealthFindingCorroboration {
    param(
        $Finding,
        [string]$Classification,
        [string]$Severity = '',
        [int]$ConfidenceBoost = 0,
        [string]$EvidenceNote = ''
    )

    if ($null -eq $Finding) { return }
    $Finding.classification = $Classification
    if (-not [string]::IsNullOrWhiteSpace($Severity)) {
        $Finding.severity = $Severity
    }
    if ($ConfidenceBoost -ne 0 -and $Finding.PSObject.Properties.Name -contains 'confidence') {
        $Finding.confidence = [math]::Min(100, [math]::Max(0, [int]$Finding.confidence + $ConfidenceBoost))
    }
    if (-not [string]::IsNullOrWhiteSpace($EvidenceNote)) {
        $ev = New-Object System.Collections.Generic.List[string]
        foreach ($e in @($Finding.evidence)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$e)) { [void]$ev.Add([string]$e) }
        }
        [void]$ev.Add($EvidenceNote)
        $Finding.evidence = @($ev.ToArray())
    }
}

function Invoke-HealthFindingCorroboration {
    param([Parameter(Mandatory)]$WorkflowResult)

    $refs = @(Get-HealthWorkflowFindingRefs -WorkflowResult $WorkflowResult)
    if ($refs.Count -eq 0) { return 0 }

    $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $refs) { [void]$ids.Add($r.FindingId) }

    $hasCrash = $ids.Contains('event.system_crash')
    $hasDisk = $ids.Contains('event.disk_instability') -or $ids.Contains('event.ntfs_corruption')
    $hasWheaHard = $ids.Contains('event.whea_uncorrected_error')
    $hasWheaSoft = $ids.Contains('event.whea_corrected_error')
    $hasCpuHigh = $ids.Contains('health.cpu.high_load')
    $hasRamHigh = $ids.Contains('health.memory.high_usage')
    $hasShutdown = $ids.Contains('event.unexpected_shutdown')

    $changed = 0

    foreach ($ref in $refs) {
        $f = $ref.Finding
        $fid = $ref.FindingId

        if ($fid -eq 'event.disk_instability' -and ($hasWheaHard -or $hasCrash)) {
            Set-HealthFindingCorroboration -Finding $f `
                -Classification 'CorroboratedSuspect' -Severity 'High' -ConfidenceBoost 8 `
                -EvidenceNote 'Corroborated by WHEA uncorrected and/or bugcheck findings in this run.'
            $changed++
            continue
        }

        if ($fid -eq 'event.unexpected_shutdown' -and $hasCrash) {
            Set-HealthFindingCorroboration -Finding $f `
                -Classification 'CorroboratedSuspect' -ConfidenceBoost 5 `
                -EvidenceNote 'Corroborated by nearby system crash / bugcheck finding.'
            $changed++
            continue
        }

        if ($fid -eq 'event.whea_corrected_error' -and ($hasCpuHigh -or $hasRamHigh -or $hasWheaHard)) {
            Set-HealthFindingCorroboration -Finding $f `
                -Classification 'CorroboratedSuspect' -ConfidenceBoost 5 `
                -EvidenceNote 'Corroborated by sustained resource pressure and/or uncorrected WHEA in this run.'
            $changed++
            continue
        }

        if ($fid -eq 'event.application_crash' -and -not $hasCrash -and -not $hasDisk -and -not $hasWheaHard) {
            # Isolated app crashes remain SingleSignal (already default); note demotion clarity.
            if ([string]$f.classification -ne 'SingleSignal') {
                Set-HealthFindingCorroboration -Finding $f -Classification 'SingleSignal' `
                    -EvidenceNote 'No corroborating crash/disk/WHEA fault in this run.'
                $changed++
            }
            continue
        }

        if ($fid -eq 'event.whea_uncorrected_error' -and ($hasCrash -or $hasDisk)) {
            Set-HealthFindingCorroboration -Finding $f `
                -Classification 'ConfirmedFault' -Severity 'Critical' -ConfidenceBoost 5 `
                -EvidenceNote 'Promoted: uncorrected WHEA co-occurs with crash or storage instability.'
            $f.status = 'Fail'
            $changed++
            continue
        }
    }

    # Refresh step status + marker output for mutated steps
    $touched = @($refs | Select-Object -ExpandProperty StepIndex -Unique)
    foreach ($si in $touched) {
        $step = $WorkflowResult.Steps[$si]
        if ($null -eq $step -or -not ($step.PSObject.Properties.Name -contains 'StructuredFindings')) { continue }
        $findings = @($step.StructuredFindings)
        if ($findings.Count -eq 0) { continue }

        # Rebuild via hashtable path when possible
        $ht = @{
            Name    = [string]$step.Name
            Status  = [string]$step.Status
            Detail  = if ($step.PSObject.Properties.Name -contains 'Detail') { [string]$step.Detail } else { '' }
            Output  = ''
            CheckId = if ($step.PSObject.Properties.Name -contains 'CheckId') { [string]$step.CheckId } else { '' }
        }
        # Preserve non-finding output by stripping prior markers then re-adding
        $rawOut = if ($step.PSObject.Properties.Name -contains 'Output') { [string]$step.Output } else { '' }
        $body = @(
            $rawOut -split "`r?`n" |
                Where-Object { $_ -notmatch '^\[HEALTH:FINDING\]' }
        ) -join "`n"
        $ht.Output = $body.TrimEnd()
        Add-HealthFindingsToStep -Step $ht -Findings $findings -SummaryText $ht.Detail

        $step.Status = $ht.Status
        $step.Output = $ht.Output
        $step.StructuredFindings = $ht.StructuredFindings
    }

    return $changed
}

function Update-HealthWorkflowStructuredFindingsOutput {
    param([Parameter(Mandatory)]$WorkflowResult, [int[]]$StepIndexes)

    foreach ($si in @($StepIndexes | Select-Object -Unique)) {
        $step = $WorkflowResult.Steps[$si]
        if ($null -eq $step -or -not ($step.PSObject.Properties.Name -contains 'StructuredFindings')) { continue }
        $findings = @($step.StructuredFindings)
        if ($findings.Count -eq 0) { continue }

        $ht = @{
            Name    = [string]$step.Name
            Status  = [string]$step.Status
            Detail  = if ($step.PSObject.Properties.Name -contains 'Detail') { [string]$step.Detail } else { '' }
            Output  = ''
            CheckId = if ($step.PSObject.Properties.Name -contains 'CheckId') { [string]$step.CheckId } else { '' }
        }
        $rawOut = if ($step.PSObject.Properties.Name -contains 'Output') { [string]$step.Output } else { '' }
        $body = @(
            $rawOut -split "`r?`n" |
                Where-Object { $_ -notmatch '^\[HEALTH:FINDING\]' }
        ) -join "`n"
        $ht.Output = $body.TrimEnd()
        Add-HealthFindingsToStep -Step $ht -Findings $findings -SummaryText $ht.Detail

        $step.Status = $ht.Status
        $step.Output = $ht.Output
        $step.StructuredFindings = $ht.StructuredFindings
    }
}

function Invoke-HealthFindingConfidenceCalibration {
    <#
    .SYNOPSIS
      Post-corroboration confidence floors/caps (noise demotion + fault floors).
    #>
    param([Parameter(Mandatory)]$WorkflowResult)

    $refs = @(Get-HealthWorkflowFindingRefs -WorkflowResult $WorkflowResult)
    if ($refs.Count -eq 0) { return 0 }

    $changed = 0
    $touched = New-Object System.Collections.Generic.List[int]
    foreach ($ref in $refs) {
        $f = $ref.Finding
        if ($null -eq $f -or -not ($f.PSObject.Properties.Name -contains 'confidence')) { continue }

        $before = [int]$f.confidence
        $after = Get-CalibratedHealthFindingConfidence `
            -Classification ([string]$f.classification) `
            -Confidence $before `
            -Status ([string]$f.status)

        if ($after -ne $before) {
            $f.confidence = $after
            $changed++
            if (-not $touched.Contains([int]$ref.StepIndex)) {
                [void]$touched.Add([int]$ref.StepIndex)
            }
        }
    }

    if ($touched.Count -gt 0) {
        Update-HealthWorkflowStructuredFindingsOutput -WorkflowResult $WorkflowResult -StepIndexes @($touched)
    }

    return $changed
}
