#Requires -Version 5.1
<#
.SYNOPSIS
    Correlate Windows event log errors into technician-facing finding clusters.
#>

function Get-EventFindingClustersCatalogPath {
    $coreDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path }
    return (Join-Path (Join-Path $coreDir '..\..') 'Config\EventFindingClusters.json')
}

function Get-EventSuppressorPacksRoot {
    $coreDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path }
    return (Join-Path (Join-Path $coreDir '..\..') 'Config\EventSuppressorPacks')
}

function Get-ActiveEventSuppressorPackIds {
    <#
    .SYNOPSIS
      Auto-detect lab/environment packs. Override with $env:CDE_EVENT_SUPPRESSOR_PACKS=csv.
    #>
    $forced = [string]$env:CDE_EVENT_SUPPRESSOR_PACKS
    if (-not [string]::IsNullOrWhiteSpace($forced)) {
        return @($forced.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    $ids = New-Object System.Collections.Generic.List[string]
    try {
        if ((Get-Command Get-EnvironmentMode -ErrorAction SilentlyContinue) -and (Get-EnvironmentMode) -eq 'WinPE') {
            [void]$ids.Add('winpe')
        }
    } catch { }

    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue | Select-Object -First 1
        $model = if ($cs) { [string]$cs.Model } else { '' }
        $mfr = if ($cs) { [string]$cs.Manufacturer } else { '' }
        if ($model -match '(?i)Virtual Machine|VMware|VirtualBox|KVM|QEMU|Xen|Hyper-V' -or
            $mfr -match '(?i)Microsoft Corporation|VMware|innotek|QEMU|Xen') {
            [void]$ids.Add('hyperv_guest')
        }
    } catch { }

    try {
        $usb = @(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue |
            Where-Object { [string]$_.InterfaceType -eq 'USB' -or [string]$_.PNPDeviceID -match '(?i)USBSTOR' })
        if ($usb.Count -gt 0) {
            [void]$ids.Add('dock_usb')
        }
    } catch { }

    return @($ids | Select-Object -Unique)
}

function Merge-EventSuppressorPacksIntoCatalog {
    param(
        [Parameter(Mandatory)]$Catalog,
        [string[]]$PackIds = @()
    )

    if ($null -eq $Catalog -or $null -eq $Catalog.clusters) { return $Catalog }
    if (-not $PackIds -or $PackIds.Count -eq 0) {
        $PackIds = @(Get-ActiveEventSuppressorPackIds)
    }

    $root = Get-EventSuppressorPacksRoot
    if (-not (Test-Path -LiteralPath $root)) { return $Catalog }

    $applied = New-Object System.Collections.Generic.List[string]
    foreach ($packId in $PackIds) {
        $packPath = Join-Path $root ("{0}.json" -f $packId)
        if (-not (Test-Path -LiteralPath $packPath)) { continue }
        try {
            $pack = Get-Content -LiteralPath $packPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch { continue }

        $map = $pack.clusterSuppressors
        if ($null -eq $map) { continue }

        foreach ($cluster in @($Catalog.clusters)) {
            $cid = [string]$cluster.clusterId
            $extra = $null
            if ($map.PSObject.Properties[$cid]) {
                $extra = @($map.$cid)
            }
            if ($null -eq $extra -or $extra.Count -eq 0) { continue }

            $existing = @()
            if ($cluster.PSObject.Properties['suppressors'] -and $null -ne $cluster.suppressors) {
                $existing = @($cluster.suppressors)
            }
            $cluster.suppressors = @($existing) + @($extra)
        }
        [void]$applied.Add([string]$pack.packId)
    }

    $Catalog | Add-Member -NotePropertyName AppliedSuppressorPacks -NotePropertyValue @($applied) -Force
    return $Catalog
}

function Get-EventFindingClustersCatalog {
    $path = Get-EventFindingClustersCatalogPath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Event finding clusters catalog not found: $path"
    }
    $catalog = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    return Merge-EventSuppressorPacksIntoCatalog -Catalog $catalog
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

function Get-ClusterMatchedEventVolume {
    param(
        [object[]]$Events,
        [object[]]$Specs,
        [datetime]$AnchorTime,
        [int]$WindowMinutes
    )

    $volume = 0
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($spec in @($Specs)) {
        $hits = @(Find-MatchingClusterEvents -Events $Events -Spec $spec -AnchorTime $AnchorTime -WindowMinutes $WindowMinutes)
        foreach ($h in $hits) {
            $key = "{0}|{1}|{2}|{3}" -f $h.Key, $h.EventId, $(if ($null -ne $h.Time) { $h.Time.ToString('o') } else { '' }), $h.Count
            if ($seen.Add($key)) {
                $volume += [math]::Max(1, [int]$h.Count)
            }
        }
    }
    return $volume
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
    $maxUnclassified = if ($catalog.maxUnclassifiedFindings) { [int]$catalog.maxUnclassifiedFindings } else { 5 }

    foreach ($cluster in @($catalog.clusters)) {
        $window = if ($cluster.windowMinutes) { [int]$cluster.windowMinutes } else { $defaultWindow }
        # @($null) has Count 1 in Windows PowerShell — only wrap real arrays.
        $required = @(
            if ($null -ne $cluster.required) { $cluster.required } else { @() }
        ) | Where-Object { $null -ne $_ }
        $requiredAny = @(
            if ($null -ne $cluster.requiredAny) { $cluster.requiredAny } else { @() }
        ) | Where-Object { $null -ne $_ }
        $optional = @(
            if ($null -ne $cluster.optional) { $cluster.optional } else { @() }
        ) | Where-Object { $null -ne $_ }
        $suppressors = @(
            if ($null -ne $cluster.suppressors) { $cluster.suppressors } else { @() }
        ) | Where-Object { $null -ne $_ }
        $minEventCount = if ($cluster.minEventCount) { [int]$cluster.minEventCount } else { 1 }

        $matchedRequired = New-Object System.Collections.Generic.List[object]
        $matchedOptional = New-Object System.Collections.Generic.List[object]
        $score = 0
        $anchor = $null
        $volumeSpecs = @()

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
            $volumeSpecs = $required
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
            $volumeSpecs = $requiredAny
        }
        else {
            continue
        }

        $eventVolume = Get-ClusterMatchedEventVolume `
            -Events $normalized `
            -Specs $volumeSpecs `
            -AnchorTime $(if ($null -ne $anchor) { $anchor } else { [datetime]::MinValue }) `
            -WindowMinutes $(if ($null -ne $anchor) { $window } else { 0 })
        if ($eventVolume -lt $minEventCount) { continue }

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
        if ($eventVolume -gt $repeatCount) {
            $evidence = @($evidence) + @("Matched event volume in window: $eventVolume")
        }
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

        $classification = switch -Regex ([string]$cluster.severityFloor) {
            '^(?i)critical$' { 'ConfirmedFault' }
            '^(?i)high$' {
                if ($confidence -ge 90) { 'CorroboratedSuspect' } else { 'SingleSignal' }
            }
            default { 'SingleSignal' }
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
            -Classification $classification `
            -Evidence $evidence `
            -Recommendations @($cluster.recommendations) `
            -Actions $actionObjs))
    }

    # Residual unmatched significant events (capped; overflow aggregated)
    $residuals = @(
        $normalized |
            Where-Object { -not $_.Consumed -and [int]$_.EventId -gt 0 } |
            Sort-Object @{ Expression = { - [int]$_.Count } }, @{ Expression = { $_.Time }; Descending = $true }
    )
    $shown = @($residuals | Select-Object -First $maxUnclassified)
    $overflow = @($residuals | Select-Object -Skip $maxUnclassified)

    foreach ($evt in $shown) {
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
            -Classification 'Inventory' `
            -Evidence $evidence `
            -Recommendations @('Review the event message in Event Viewer if symptoms persist.') `
            -Actions @([PSCustomObject]@{ type = 'shell'; target = 'eventvwr.msc'; label = 'Event Viewer' })))
    }

    if ($overflow.Count -gt 0) {
        $overflowVolume = ($overflow | Measure-Object -Property Count -Sum).Sum
        $sample = Get-ClusterEvidenceLines -Events @($overflow | Select-Object -First 3)
        $findings.Add((New-HealthFinding `
            -FindingId 'event.unclassified.aggregate' `
            -CheckId $CheckId `
            -Subject 'Additional unclassified errors' `
            -Finding ("{0} additional unclassified event group(s) omitted from detail" -f $overflow.Count) `
            -Impact 'Remaining unmatched errors were aggregated to reduce noise. Expand Event Viewer if symptoms persist.' `
            -Severity 'Low' `
            -Confidence 30 `
            -Status 'Info' `
            -Classification 'Inventory' `
            -Evidence (@("Omitted groups: $($overflow.Count)", "Omitted volume: $overflowVolume") + @($sample)) `
            -Recommendations @('Review System/Application error logs if the customer reports ongoing symptoms.') `
            -Actions @([PSCustomObject]@{ type = 'shell'; target = 'eventvwr.msc'; label = 'Event Viewer' })))
    }

    return @($findings.ToArray())
}
