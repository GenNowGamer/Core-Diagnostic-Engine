#Requires -Version 5.1
<#
.SYNOPSIS
    Correlate Windows event log errors into technician-facing finding clusters.
#>

function Get-EventFindingClustersCatalogPath {
    $coreDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path }
    return (Join-Path (Join-Path $coreDir '..\..') 'Config\EventFindingClusters.json')
}

function Get-EventFindingClustersCatalog {
    $path = Get-EventFindingClustersCatalogPath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Event finding clusters catalog not found: $path"
    }
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function ConvertTo-NormalizedClusterEvent {
    param($Event, [string]$LogName = '')

    $source = ''
    if ($Event.PSObject.Properties.Name -contains 'Source' -and -not [string]::IsNullOrWhiteSpace([string]$Event.Source)) {
        $source = [string]$Event.Source
    }
    elseif ($Event.PSObject.Properties.Name -contains 'ProviderName' -and -not [string]::IsNullOrWhiteSpace([string]$Event.ProviderName)) {
        $source = [string]$Event.ProviderName
    }
    else {
        $source = 'Unknown'
    }

    $eventId = 0
    if ($Event.PSObject.Properties.Name -contains 'EventID' -and $null -ne $Event.EventID) {
        $eventId = [int]$Event.EventID
    }
    elseif ($Event.PSObject.Properties.Name -contains 'EventId' -and $null -ne $Event.EventId) {
        $eventId = [int]$Event.EventId
    }
    elseif ($Event.PSObject.Properties.Name -contains 'Id' -and $null -ne $Event.Id) {
        $eventId = [int]$Event.Id
    }

    $time = $null
    if ($Event.PSObject.Properties.Name -contains 'TimeGenerated') { $time = $Event.TimeGenerated }
    elseif ($Event.PSObject.Properties.Name -contains 'TimeCreated') { $time = $Event.TimeCreated }
    elseif ($Event.PSObject.Properties.Name -contains 'LastTime') { $time = $Event.LastTime }

    $message = ''
    if ($Event.PSObject.Properties.Name -contains 'Message') {
        $message = ([string]$Event.Message -replace '\s+', ' ').Trim()
        if ($message.Length -gt 180) { $message = $message.Substring(0, 180) + '...' }
    }

    $resolvedLog = $LogName
    if ([string]::IsNullOrWhiteSpace($resolvedLog) -and $Event.PSObject.Properties.Name -contains 'LogName') {
        $resolvedLog = [string]$Event.LogName
    }

    $count = 1
    if ($Event.PSObject.Properties.Name -contains 'Count' -and $null -ne $Event.Count) {
        $count = [math]::Max(1, [int]$Event.Count)
    }

    return [PSCustomObject]@{
        LogName   = $resolvedLog
        Source    = $source
        EventId   = $eventId
        Time      = $time
        Message   = $message
        Count     = $count
        Consumed  = $false
        Key       = ("{0}|{1}|{2}" -f $resolvedLog, $source, $eventId)
    }
}

function Test-EventMatchesClusterSpec {
    param($Event, $Spec)

    if ($null -eq $Event -or $null -eq $Spec) { return $false }
    $provider = [string]$Spec.providerContains
    if (-not [string]::IsNullOrWhiteSpace($provider)) {
        if ([string]$Event.Source -notlike ("*{0}*" -f $provider)) { return $false }
    }
    if ($null -ne $Spec.eventId -and [int]$Spec.eventId -ne 0) {
        if ([int]$Event.EventId -ne [int]$Spec.eventId) { return $false }
    }
    return $true
}

function Find-MatchingClusterEvents {
    param(
        [object[]]$Events,
        $Spec,
        [datetime]$AnchorTime,
        [int]$WindowMinutes
    )

    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($evt in $Events) {
        if (-not (Test-EventMatchesClusterSpec -Event $evt -Spec $Spec)) { continue }
        if ($null -ne $evt.Time -and $null -ne $AnchorTime -and $WindowMinutes -gt 0) {
            $delta = [math]::Abs(($evt.Time - $AnchorTime).TotalMinutes)
            if ($delta -gt $WindowMinutes) { continue }
        }
        $matches.Add($evt)
    }
    return @($matches.ToArray())
}

function Get-ClusterEvidenceLines {
    param([object[]]$Events)

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($evt in ($Events | Sort-Object Time -Descending)) {
        $when = if ($null -ne $evt.Time) { ([datetime]$evt.Time).ToString('g') } else { 'unknown time' }
        $countSuffix = if ([int]$evt.Count -gt 1) { " (x$($evt.Count))" } else { '' }
        $msg = if ([string]::IsNullOrWhiteSpace($evt.Message)) { '' } else { " - $($evt.Message)" }
        $lines.Add(("{0} {1}{2} - {3}{4}" -f $evt.Source, $evt.EventId, $countSuffix, $when, $msg))
    }
    return @($lines.ToArray())
}

function Invoke-EventFindingClustering {
    param(
        [Parameter(Mandatory)][string]$CheckId,
        [array]$Events,
        [string]$DefaultLogName = 'System'
    )

    $catalog = Get-EventFindingClustersCatalog
    $normalized = New-Object System.Collections.Generic.List[object]
    foreach ($raw in @($Events)) {
        if ($null -eq $raw) { continue }
        $normalized.Add((ConvertTo-NormalizedClusterEvent -Event $raw -LogName $DefaultLogName))
    }

    $findings = New-Object System.Collections.Generic.List[object]
    $defaultWindow = if ($catalog.defaultWindowMinutes) { [int]$catalog.defaultWindowMinutes } else { 10 }

    foreach ($cluster in @($catalog.clusters)) {
        $window = if ($cluster.windowMinutes) { [int]$cluster.windowMinutes } else { $defaultWindow }
        $required = @($cluster.required)
        $requiredAny = @($cluster.requiredAny)
        $optional = @($cluster.optional)
        $suppressors = @($cluster.suppressors)

        $matchedRequired = New-Object System.Collections.Generic.List[object]
        $matchedOptional = New-Object System.Collections.Generic.List[object]
        $score = 0
        $anchor = $null

        if ($required.Count -gt 0) {
            $allRequiredOk = $true
            foreach ($spec in $required) {
                $hits = @(Find-MatchingClusterEvents -Events $normalized -Spec $spec -AnchorTime ([datetime]::MinValue) -WindowMinutes 0)
                if ($hits.Count -eq 0) {
                    $allRequiredOk = $false
                    break
                }
                if ($null -eq $anchor -or ($null -ne $hits[0].Time -and $hits[0].Time -gt $anchor)) {
                    $anchor = $hits[0].Time
                }
            }
            if (-not $allRequiredOk) { continue }

            # Re-match within window around latest required hit
            $latestRequiredTime = $null
            foreach ($spec in $required) {
                $hits = @(Find-MatchingClusterEvents -Events $normalized -Spec $spec -AnchorTime ([datetime]::MinValue) -WindowMinutes 0)
                foreach ($h in $hits) {
                    if ($null -eq $latestRequiredTime -or ($null -ne $h.Time -and $h.Time -gt $latestRequiredTime)) {
                        $latestRequiredTime = $h.Time
                    }
                }
            }
            $anchor = $latestRequiredTime
            foreach ($spec in $required) {
                $hits = @(Find-MatchingClusterEvents -Events $normalized -Spec $spec -AnchorTime $anchor -WindowMinutes $window)
                if ($hits.Count -eq 0) { $allRequiredOk = $false; break }
                $best = $hits | Sort-Object Time -Descending | Select-Object -First 1
                $matchedRequired.Add($best)
                $score += [int]$spec.weight
            }
            if (-not $allRequiredOk) { continue }
        }
        elseif ($requiredAny.Count -gt 0) {
            $minAny = if ($cluster.minRequiredAny) { [int]$cluster.minRequiredAny } else { 1 }
            foreach ($spec in $requiredAny) {
                $hits = @(Find-MatchingClusterEvents -Events $normalized -Spec $spec -AnchorTime ([datetime]::MinValue) -WindowMinutes 0)
                if ($hits.Count -eq 0) { continue }
                $best = $hits | Sort-Object Time -Descending | Select-Object -First 1
                $matchedRequired.Add($best)
                $score += [int]$spec.weight
                if ($null -eq $anchor -or ($null -ne $best.Time -and $best.Time -gt $anchor)) {
                    $anchor = $best.Time
                }
            }
            if ($matchedRequired.Count -lt $minAny) { continue }
        }
        else {
            continue
        }

        $suppressed = $false
        foreach ($spec in $suppressors) {
            $supWindow = if ($spec.windowMinutes) { [int]$spec.windowMinutes } else { $window }
            $hits = @(Find-MatchingClusterEvents -Events $normalized -Spec $spec -AnchorTime $anchor -WindowMinutes $supWindow)
            if ($hits.Count -gt 0) {
                $suppressed = $true
                break
            }
        }
        if ($suppressed) { continue }

        foreach ($spec in $optional) {
            $hits = @(Find-MatchingClusterEvents -Events $normalized -Spec $spec -AnchorTime $anchor -WindowMinutes $window)
            if ($hits.Count -eq 0) { continue }
            $best = $hits | Sort-Object Time -Descending | Select-Object -First 1
            $matchedOptional.Add($best)
            $score += [int]$spec.weight
        }

        $allMatched = @($matchedRequired.ToArray()) + @($matchedOptional.ToArray())
        $repeatCount = ($allMatched | Measure-Object -Property Count -Sum).Sum
        if ($repeatCount -gt 1 -and $cluster.repeatBonus) {
            $score += [int]$cluster.repeatBonus
        }

        $maxConf = if ($cluster.maxConfidence) { [int]$cluster.maxConfidence } else { 95 }
        $confidence = [math]::Min($maxConf, [math]::Max(40, $score))

        foreach ($evt in $allMatched) { $evt.Consumed = $true }

        $evidence = Get-ClusterEvidenceLines -Events $allMatched
        $causes = @($cluster.likelyCauses)
        if ($causes.Count -gt 0) {
            $evidence = @($evidence) + @('Likely causes: ' + ($causes -join '; '))
        }

        $status = switch -Regex ([string]$cluster.severityFloor) {
            '^(?i)critical$' { 'Fail' }
            '^(?i)high$'     { 'Warn' }
            '^(?i)medium$'   { 'Warn' }
            default          { 'Warn' }
        }

        $actionObjs = @()
        foreach ($a in @($cluster.actions)) {
            if ($null -eq $a) { continue }
            $actionObjs += [PSCustomObject]@{
                type = [string]$a.type
                target = [string]$a.target
                label = [string]$a.label
            }
        }

        $findings.Add((New-HealthFinding `
            -FindingId ("event.{0}" -f [string]$cluster.clusterId) `
            -CheckId $CheckId `
            -Subject ([string]$cluster.title) `
            -Finding ([string]$cluster.title) `
            -Impact ([string]$cluster.impact) `
            -Severity ([string]$cluster.severityFloor) `
            -Confidence $confidence `
            -Status $status `
            -Evidence $evidence `
            -Recommendations @($cluster.recommendations) `
            -Actions $actionObjs))
    }

    # Residual unmatched significant events
    foreach ($evt in $normalized) {
        if ($evt.Consumed) { continue }
        if ([int]$evt.EventId -le 0) { continue }

        $evidence = Get-ClusterEvidenceLines -Events @($evt)
        $findings.Add((New-HealthFinding `
            -FindingId ("event.unclassified.{0}.{1}" -f ($evt.Source -replace '[^\w\-]', '_'), $evt.EventId) `
            -CheckId $CheckId `
            -Subject ("{0} {1}" -f $evt.Source, $evt.EventId) `
            -Finding 'Unclassified event error' `
            -Impact 'This error did not match a known correlation cluster. Manual review may be needed.' `
            -Severity 'Low' `
            -Confidence 35 `
            -Status 'Info' `
            -Evidence $evidence `
            -Recommendations @('Review the event message in Event Viewer if symptoms persist.') `
            -Actions @([PSCustomObject]@{ type = 'shell'; target = 'eventvwr.msc'; label = 'Event Viewer' })))
    }

    return @($findings.ToArray())
}
