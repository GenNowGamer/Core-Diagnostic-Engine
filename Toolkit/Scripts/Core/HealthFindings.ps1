#Requires -Version 5.1
<#
.SYNOPSIS
    Shared structured finding helpers for System Health Check.

.NOTES
    Evidence-quality Classification follows NIST SP 800-61 triage practice
    (validate / confirm before treating a signal as an incident) and keeps
    Incomplete distinct from Fail per common test-result pass/fail/incomplete
    outcomes (ISO/IEC/IEEE 29119 pass/fail criteria; incomplete when the check
    cannot complete).
#>

function Resolve-HealthFindingClassification {
    param(
        [string]$Classification = '',
        [string]$Status = 'Info',
        [string]$Severity = 'Info',
        [int]$Confidence = 80
    )

    $explicit = ([string]$Classification).Trim()
    if ($explicit -match '^(?i)(ConfirmedFault|CorroboratedSuspect|SingleSignal|Inventory|ExpectedLimitation|Incomplete)$') {
        switch -Regex ($explicit) {
            '^(?i)ConfirmedFault$' { return 'ConfirmedFault' }
            '^(?i)CorroboratedSuspect$' { return 'CorroboratedSuspect' }
            '^(?i)SingleSignal$' { return 'SingleSignal' }
            '^(?i)Inventory$' { return 'Inventory' }
            '^(?i)ExpectedLimitation$' { return 'ExpectedLimitation' }
            '^(?i)Incomplete$' { return 'Incomplete' }
        }
    }

    $statusNorm = ([string]$Status).Trim()
    $severityNorm = ([string]$Severity).Trim()

    if ($statusNorm -match '^(?i)fail$') { return 'ConfirmedFault' }
    if ($statusNorm -match '^(?i)n/?a$' -or $statusNorm -match '^(?i)skip$') { return 'Incomplete' }
    if ($statusNorm -match '^(?i)pass$' -or $statusNorm -match '^(?i)info$') { return 'Inventory' }

    if ($statusNorm -match '^(?i)warn$') {
        if ($severityNorm -match '^(?i)critical$') { return 'ConfirmedFault' }
        if ($severityNorm -match '^(?i)high$' -and $Confidence -ge 90) { return 'CorroboratedSuspect' }
        return 'SingleSignal'
    }

    return 'SingleSignal'
}

function Test-HealthFindingRequiresAttention {
    param(
        [string]$Classification = '',
        [string]$Status = 'Info',
        [string]$Severity = 'Info',
        [int]$Confidence = 80
    )

    $resolved = Resolve-HealthFindingClassification `
        -Classification $Classification `
        -Status $Status `
        -Severity $Severity `
        -Confidence $Confidence

    switch -Regex ($resolved) {
        '^(?i)ConfirmedFault$' { return $true }
        '^(?i)CorroboratedSuspect$' { return $true }
        '^(?i)SingleSignal$' {
            return ([string]$Status).Trim() -match '^(?i)(fail|warn)$'
        }
        default { return $false }
    }
}

function Get-HealthFindingClassificationDisplay {
    param([string]$Classification)

    switch -Regex (([string]$Classification).Trim()) {
        '^(?i)ConfirmedFault$' { return 'Confirmed fault' }
        '^(?i)CorroboratedSuspect$' { return 'Corroborated suspect' }
        '^(?i)SingleSignal$' { return 'Single signal' }
        '^(?i)Inventory$' { return 'Inventory' }
        '^(?i)ExpectedLimitation$' { return 'Expected limitation' }
        '^(?i)Incomplete$' { return 'Incomplete' }
        default { return ([string]$Classification).Trim() }
    }
}

function New-HealthFinding {
    param(
        [Parameter(Mandatory)][string]$FindingId,
        [Parameter(Mandatory)][string]$CheckId,
        [Parameter(Mandatory)][string]$Finding,
        [string]$Subject = '',
        [string]$Impact = '',
        [ValidateSet('Critical', 'High', 'Medium', 'Low', 'Info')]
        [string]$Severity = 'Info',
        [ValidateRange(0, 100)]
        [int]$Confidence = 80,
        [ValidateSet('Fail', 'Warn', 'Pass', 'Info', 'N/A', 'Skip')]
        [string]$Status = 'Info',
        [ValidateSet('', 'ConfirmedFault', 'CorroboratedSuspect', 'SingleSignal', 'Inventory', 'ExpectedLimitation', 'Incomplete')]
        [string]$Classification = '',
        [string[]]$Evidence,
        [string[]]$Recommendations,
        [object[]]$Actions
    )

    if ($null -eq $Evidence) { $Evidence = @() }
    if ($null -eq $Recommendations) { $Recommendations = @() }
    if ($null -eq $Actions) { $Actions = @() }

    $actionList = New-Object System.Collections.Generic.List[object]
    foreach ($a in @($Actions)) {
        if ($null -eq $a) { continue }
        $actionList.Add([PSCustomObject]@{
            type  = [string]$a.type
            target = [string]$a.target
            label = [string]$a.label
        })
    }

    $evidenceOut = New-Object System.Collections.Generic.List[string]
    foreach ($e in @($Evidence)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$e)) { [void]$evidenceOut.Add([string]$e) }
    }
    $recOut = New-Object System.Collections.Generic.List[string]
    foreach ($rec in @($Recommendations)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$rec)) { [void]$recOut.Add([string]$rec) }
    }

    $resolvedClassification = Resolve-HealthFindingClassification `
        -Classification $Classification `
        -Status $Status `
        -Severity $Severity `
        -Confidence $Confidence

    return [PSCustomObject]@{
        findingId       = [string]$FindingId
        checkId         = [string]$CheckId
        subject         = [string]$Subject
        finding         = [string]$Finding
        impact          = [string]$Impact
        severity        = [string]$Severity
        confidence      = [int]$Confidence
        status          = [string]$Status
        classification  = [string]$resolvedClassification
        evidence        = @($evidenceOut.ToArray())
        recommendations = @($recOut.ToArray())
        actions         = @($actionList.ToArray())
    }
}
function Get-HealthFindingSeverityRank {
    param([string]$Severity)
    switch -Regex ($Severity) {
        '^(?i)critical$' { return 5 }
        '^(?i)high$'     { return 4 }
        '^(?i)medium$'   { return 3 }
        '^(?i)low$'      { return 2 }
        default          { return 1 }
    }
}

function Get-HealthFindingStatusRank {
    param([string]$Status)
    switch -Regex ($Status) {
        '^(?i)fail$'  { return 5 }
        '^(?i)warn$'  { return 4 }
        '^(?i)pass$'  { return 3 }
        '^(?i)info$'  { return 2 }
        '^(?i)n/?a$'  { return 1 }
        '^(?i)skip$'  { return 1 }
        default       { return 0 }
    }
}

function Get-HealthStepStatusFromFindings {
    param([object[]]$Findings)

    if (-not $Findings -or $Findings.Count -eq 0) { return 'Pass' }

    $best = 0
    $bestStatus = 'Pass'
    foreach ($f in $Findings) {
        $rank = Get-HealthFindingStatusRank -Status ([string]$f.status)
        if ($rank -gt $best) {
            $best = $rank
            $bestStatus = [string]$f.status
        }
    }

    if ($bestStatus -eq 'Info') { return 'Pass' }
    return $bestStatus
}

function Get-HealthFindingClassificationRank {
    param([string]$Classification)
    switch -Regex (([string]$Classification).Trim()) {
        '^(?i)ConfirmedFault$' { return 6 }
        '^(?i)CorroboratedSuspect$' { return 5 }
        '^(?i)SingleSignal$' { return 4 }
        '^(?i)Incomplete$' { return 3 }
        '^(?i)ExpectedLimitation$' { return 2 }
        '^(?i)Inventory$' { return 1 }
        default { return 0 }
    }
}

function ConvertTo-HealthFindingMarkerLine {
    param([Parameter(Mandatory)]$Finding)

    $classification = if ($Finding.PSObject.Properties.Name -contains 'classification' -and
        -not [string]::IsNullOrWhiteSpace([string]$Finding.classification)) {
        [string]$Finding.classification
    }
    else {
        Resolve-HealthFindingClassification `
            -Status ([string]$Finding.status) `
            -Severity ([string]$Finding.severity) `
            -Confidence ([int]$Finding.confidence)
    }

    $payload = @{
        findingId       = [string]$Finding.findingId
        checkId         = [string]$Finding.checkId
        subject         = [string]$Finding.subject
        finding         = [string]$Finding.finding
        impact          = [string]$Finding.impact
        severity        = [string]$Finding.severity
        confidence      = [int]$Finding.confidence
        status          = [string]$Finding.status
        classification  = [string]$classification
        evidence        = @($Finding.evidence)
        recommendations = @($Finding.recommendations)
        actions         = @($Finding.actions)
    } | ConvertTo-Json -Compress -Depth 6

    return "[HEALTH:FINDING] $payload"
}

function Add-HealthFindingsToStep {
    param(
        [Parameter(Mandatory)][hashtable]$Step,
        [Parameter(Mandatory)][object[]]$Findings,
        [string]$SummaryText = ''
    )

    $ordered = @(
        $Findings |
            Sort-Object `
                @{ Expression = { - (Get-HealthFindingClassificationRank -Classification $_.classification) } }, `
                @{ Expression = { - (Get-HealthFindingSeverityRank -Severity $_.severity) } }, `
                @{ Expression = { - [int]$_.confidence } }, `
                @{ Expression = { [string]$_.finding } }
    )

    $Step['StructuredFindings'] = $ordered
    $Step['Status'] = Get-HealthStepStatusFromFindings -Findings $ordered

    # Preserve the full formatted step Output (rich detail text) as the body.
    # SummaryText is only a fallback body and a Detail candidate, so structured
    # findings stay additive rather than replacing the informational output.
    $lines = New-Object System.Collections.Generic.List[string]
    $existingOutput = [string]$Step.Output
    if (-not [string]::IsNullOrWhiteSpace($existingOutput)) {
        $lines.Add($existingOutput.TrimEnd())
        $lines.Add('')
    }
    elseif (-not [string]::IsNullOrWhiteSpace($SummaryText)) {
        $lines.Add($SummaryText.TrimEnd())
        $lines.Add('')
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$Step.Detail)) {
        $lines.Add([string]$Step.Detail)
        $lines.Add('')
    }

    foreach ($f in $ordered) {
        $lines.Add((ConvertTo-HealthFindingMarkerLine -Finding $f))
    }

    $Step['Output'] = ($lines -join "`n").TrimEnd()
    if ([string]::IsNullOrWhiteSpace([string]$Step.Detail) -and -not [string]::IsNullOrWhiteSpace($SummaryText)) {
        $Step['Detail'] = $SummaryText
    }
}

function Convert-IssueListToHealthFindings {
    param(
        [Parameter(Mandatory)][string]$CheckId,
        [Parameter(Mandatory)][string]$FindingIdPrefix,
        [Parameter(Mandatory)][string]$FindingTitle,
        [string]$Impact = '',
        [string]$Severity = 'Medium',
        [string]$Status = 'Warn',
        [ValidateSet('', 'ConfirmedFault', 'CorroboratedSuspect', 'SingleSignal', 'Inventory', 'ExpectedLimitation', 'Incomplete')]
        [string]$Classification = '',
        [string[]]$Issues = @(),
        [string[]]$Recommendations = @(),
        [object[]]$Actions = @(),
        [string]$PassFinding = 'No issues detected',
        [string]$PassImpact = 'No actionable issues were detected for this check.',
        [string[]]$PassEvidence = @()
    )

    $list = New-Object System.Collections.Generic.List[object]
    $issueArr = @($Issues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($issueArr.Count -eq 0) {
        $evidence = @($PassEvidence | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($evidence.Count -eq 0) { $evidence = @('Issue count: 0') }
        $list.Add((New-HealthFinding `
            -FindingId ("{0}.clean" -f $FindingIdPrefix) `
            -CheckId $CheckId `
            -Finding $PassFinding `
            -Impact $PassImpact `
            -Severity 'Info' `
            -Confidence 85 `
            -Status 'Pass' `
            -Classification 'Inventory' `
            -Evidence $evidence))
        return @($list.ToArray())
    }

    $i = 0
    foreach ($issue in $issueArr) {
        $i++
        $list.Add((New-HealthFinding `
            -FindingId ("{0}.issue_{1}" -f $FindingIdPrefix, $i) `
            -CheckId $CheckId `
            -Subject $FindingTitle `
            -Finding $FindingTitle `
            -Impact $Impact `
            -Severity $Severity `
            -Confidence 80 `
            -Status $Status `
            -Classification $Classification `
            -Evidence @([string]$issue) `
            -Recommendations $Recommendations `
            -Actions $Actions))
    }
    return @($list.ToArray())
}

function New-InventoryHealthFinding {
    param(
        [Parameter(Mandatory)][string]$CheckId,
        [Parameter(Mandatory)][string]$Finding,
        [string]$Subject = '',
        [string]$Impact = 'Informational inventory result; no remediation required unless a risky condition is noted.',
        [string[]]$Evidence,
        [string[]]$Recommendations,
        [object[]]$Actions,
        [int]$Confidence = 90
    )

    return New-HealthFinding `
        -FindingId ("inventory.{0}" -f $CheckId) `
        -CheckId $CheckId `
        -Subject $Subject `
        -Finding $Finding `
        -Impact $Impact `
        -Severity 'Info' `
        -Confidence $Confidence `
        -Status 'Info' `
        -Classification 'Inventory' `
        -Evidence $Evidence `
        -Recommendations $Recommendations `
        -Actions $Actions
}

function Get-CalibratedHealthFindingConfidence {
    <#
    .SYNOPSIS
      Apply floors/caps after classification + corroboration settle.

    .NOTES
      Formula (documented in OUTPUT_CONTRACT.md):
        calibrated = clamp(0, 100, base + corroboration_bonus − noise_penalty)
      Corroboration bonus is applied earlier (Invoke-HealthFindingCorroboration).
      This pass enforces floors/caps so technicians can compare scores across checks.
    #>
    param(
        [string]$Classification = '',
        [int]$Confidence = 80,
        [string]$Status = 'Info'
    )

    $cls = Resolve-HealthFindingClassification `
        -Classification $Classification `
        -Status $Status `
        -Severity 'Info' `
        -Confidence $Confidence

    $c = [math]::Min(100, [math]::Max(0, [int]$Confidence))
    $statusNorm = ([string]$Status).Trim()

    switch -Regex ($cls) {
        '^(?i)ConfirmedFault$' {
            return [math]::Max($c, 90)
        }
        '^(?i)CorroboratedSuspect$' {
            # Floor only — bonus already applied during corroboration.
            return [math]::Max($c, 75)
        }
        '^(?i)SingleSignal$' {
            return $c
        }
        '^(?i)Inventory$' {
            # Noise demotion for residual/inventory Info rows only — Pass "clean" stays as authored.
            if ($statusNorm -match '^(?i)info$') {
                return [math]::Min($c, 40)
            }
            if ($statusNorm -match '^(?i)warn$') {
                return [math]::Min($c, 55)
            }
            return $c
        }
        '^(?i)ExpectedLimitation$' {
            # High certainty that this is a known limitation (not a drive fault).
            return [math]::Max([math]::Min($c, 95), 85)
        }
        '^(?i)Incomplete$' {
            return [math]::Max($c, 90)
        }
        default {
            return $c
        }
    }
}

