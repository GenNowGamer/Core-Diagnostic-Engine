#Requires -Version 5.1
<#
.SYNOPSIS
    Shared structured finding helpers for System Health Check.
#>

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

    return [PSCustomObject]@{
        findingId       = [string]$FindingId
        checkId         = [string]$CheckId
        subject         = [string]$Subject
        finding         = [string]$Finding
        impact          = [string]$Impact
        severity        = [string]$Severity
        confidence      = [int]$Confidence
        status          = [string]$Status
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

function ConvertTo-HealthFindingMarkerLine {
    param([Parameter(Mandatory)]$Finding)

    $payload = @{
        findingId       = [string]$Finding.findingId
        checkId         = [string]$Finding.checkId
        subject         = [string]$Finding.subject
        finding         = [string]$Finding.finding
        impact          = [string]$Finding.impact
        severity        = [string]$Finding.severity
        confidence      = [int]$Finding.confidence
        status          = [string]$Finding.status
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
        -Evidence $Evidence `
        -Recommendations $Recommendations `
        -Actions $Actions
}

