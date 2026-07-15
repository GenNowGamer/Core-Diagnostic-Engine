#Requires -Version 5.1
<#
.SYNOPSIS
    Correlate startup rows that likely belong to the same application across mechanisms.
#>

. (Join-Path $PSScriptRoot 'StartupRisk.ps1')

function Get-StartupCorrelationTokens {
    param($Entry)

    $tokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if ($null -eq $Entry) {
        return @()
    }

    $name = [string]$Entry.Name
    if (-not [string]::IsNullOrWhiteSpace($name)) {
        [void]$tokens.Add($name.Trim())
        $shortName = ($name -replace '\s*\([^)]*\)\s*$', '').Trim()
        if (-not [string]::IsNullOrWhiteSpace($shortName)) {
            [void]$tokens.Add($shortName)
        }
    }

    $publisher = [string]$Entry.Publisher
    if (-not [string]::IsNullOrWhiteSpace($publisher) -and $publisher -ne 'Unknown') {
        $publisherKey = $publisher.Trim()
        # Broad vendor names (esp. Microsoft) create noisy false-positive correlation groups.
        $genericPublishers = @(
            'Microsoft',
            'Microsoft Corporation',
            'Microsoft Windows',
            'Google LLC',
            'Google Inc.',
            'Mozilla Corporation',
            'Adobe Inc.',
            'Adobe Systems Incorporated',
            'Intel Corporation',
            'NVIDIA Corporation',
            'Advanced Micro Devices, Inc.',
            'Unknown'
        )
        $isGeneric = $false
        foreach ($generic in $genericPublishers) {
            if ($publisherKey.Equals($generic, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isGeneric = $true
                break
            }
        }
        if (-not $isGeneric) {
            [void]$tokens.Add($publisherKey)
        }
    }

    $pathCandidates = @(
        [string]$Entry.FilePath,
        [string]$Entry.AnalysisFilePath
    )

    foreach ($candidate in $pathCandidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $target = Resolve-StartupTarget -Command $candidate
        if ($target.Exists -and -not [string]::IsNullOrWhiteSpace($target.ResolvedPath)) {
            $leaf = [System.IO.Path]::GetFileNameWithoutExtension($target.ResolvedPath)
            if (-not [string]::IsNullOrWhiteSpace($leaf)) {
                [void]$tokens.Add($leaf)
            }
            [void]$tokens.Add($target.ResolvedPath)
        } else {
            $bareLeaf = [System.IO.Path]::GetFileNameWithoutExtension($candidate)
            if (-not [string]::IsNullOrWhiteSpace($bareLeaf)) {
                [void]$tokens.Add($bareLeaf)
            }
        }
    }

    $family = [string]$Entry.ServiceName
    if ($family -match '^(.+)_8wekyb3d8bbwe$') {
        [void]$tokens.Add($matches[1])
    }

    return @($tokens | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-StartupCorrelationSourceLabel {
    param($Entry)

    switch ([string]$Entry.RowType) {
        'MsixStartupTask' { return 'MSIX startup task' }
        'ScheduledTask' { return 'scheduled task' }
        'RegistryValue' {
            if ([string]$Entry.SourceGroup -match 'Policies\\Explorer\\Run') {
                return 'GPO Run key'
            }
            return 'Run key'
        }
        'FileStartupItem' { return 'startup folder' }
        default { return [string]$Entry.SourceGroup }
    }
}

function Add-StartupEntryCorrelations {
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[object]]$Entries
    )

    if ($Entries.Count -lt 2) {
        foreach ($entry in $Entries) {
            if ($null -eq $entry.PSObject.Properties['CorrelationGroupId']) {
                $entry | Add-Member -NotePropertyName CorrelationGroupId -NotePropertyValue '' -Force
            }
            if ($null -eq $entry.PSObject.Properties['CorrelationSummary']) {
                $entry | Add-Member -NotePropertyName CorrelationSummary -NotePropertyValue '' -Force
            }
        }
        return
    }

    $tokenToIndexes = @{}
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        foreach ($token in @(Get-StartupCorrelationTokens -Entry $Entries[$i])) {
            $normalized = $token.ToLowerInvariant()
            if ($normalized.Length -lt 4) { continue }
            if (-not $tokenToIndexes.ContainsKey($normalized)) {
                $tokenToIndexes[$normalized] = [System.Collections.Generic.List[int]]::new()
            }
            if (-not $tokenToIndexes[$normalized].Contains($i)) {
                $tokenToIndexes[$normalized].Add($i) | Out-Null
            }
        }
    }

    $parent = New-Object int[] $Entries.Count
    for ($i = 0; $i -lt $parent.Length; $i++) { $parent[$i] = $i }

    function Find-SetRoot([int]$x) {
        while ($parent[$x] -ne $x) {
            $parent[$x] = $parent[$parent[$x]]
            $x = $parent[$x]
        }
        return $x
    }

    function Union-Set([int]$a, [int]$b) {
        $ra = Find-SetRoot $a
        $rb = Find-SetRoot $b
        if ($ra -ne $rb) {
            $parent[$rb] = $ra
        }
    }

    foreach ($indexes in $tokenToIndexes.Values) {
        if ($indexes.Count -lt 2) { continue }
        for ($j = 1; $j -lt $indexes.Count; $j++) {
            Union-Set -a $indexes[0] -b $indexes[$j]
        }
    }

    $groups = @{}
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        $root = Find-SetRoot $i
        if (-not $groups.ContainsKey($root)) {
            $groups[$root] = [System.Collections.Generic.List[int]]::new()
        }
        $groups[$root].Add($i) | Out-Null
    }

    foreach ($groupIndexes in $groups.Values) {
        if ($groupIndexes.Count -lt 2) {
            $idx = $groupIndexes[0]
            $Entries[$idx] | Add-Member -NotePropertyName CorrelationGroupId -NotePropertyValue '' -Force
            $Entries[$idx] | Add-Member -NotePropertyName CorrelationSummary -NotePropertyValue '' -Force
            continue
        }

        $groupId = [Guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant()
        foreach ($idx in $groupIndexes) {
            $entry = $Entries[$idx]
            $labels = [System.Collections.Generic.List[string]]::new()
            foreach ($otherIdx in $groupIndexes) {
                if ($otherIdx -eq $idx) { continue }
                $label = Get-StartupCorrelationSourceLabel -Entry $Entries[$otherIdx]
                if (-not $labels.Contains($label)) {
                    $labels.Add($label) | Out-Null
                }
            }

            $summary = if ($labels.Count -gt 0) {
                'Also persists via: ' + ($labels -join ', ')
            } else {
                ''
            }

            $entry | Add-Member -NotePropertyName CorrelationGroupId -NotePropertyValue $groupId -Force
            $entry | Add-Member -NotePropertyName CorrelationSummary -NotePropertyValue $summary -Force

            if (-not [string]::IsNullOrWhiteSpace($summary)) {
                if ([string]$entry.AnalysisDetail) {
                    $entry.AnalysisDetail = "$summary`n$([string]$entry.AnalysisDetail)"
                } else {
                    $entry.AnalysisDetail = $summary
                }
                $entry.HasAnalysisWarning = $true
                if ([string]$entry.AnalysisLevel -eq 'OK') {
                    $entry.AnalysisLevel = 'Caution'
                }
            }
        }
    }
}
