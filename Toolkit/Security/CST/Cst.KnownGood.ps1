# Known-good hash store and content-scan skip helpers (CST FP reduction)
$script:CstKnownGoodStore = $null
$script:CstKnownGoodSqliteConnection = $null
$script:CstKnownGoodSqliteCommand = $null
$script:CstKnownGoodSqliteFallbackLogged = $false

function Get-CstRulesDirectory {
    param([Parameter(Mandatory)][string]$RulesPath)
    return [System.IO.Path]::GetDirectoryName((Resolve-Path -LiteralPath $RulesPath).Path)
}

function Import-CstKnownGoodBaselineFile {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        # PS 5.1 rejects Count=0 HashSet without AllowEmptyCollection (breaks first baseline load).
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$HashSet
    )

    if (-not (Test-Path -LiteralPath $FilePath)) { return 0 }
    $added = 0
    try {
        $raw = Get-Content -LiteralPath $FilePath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return 0 }
        $parsed = $raw | ConvertFrom-Json
        $entries = @()
        if ($parsed -is [System.Array]) {
            $entries = @($parsed)
        } elseif ($parsed.PSObject.Properties['hashes']) {
            $entries = @($parsed.hashes)
        } elseif ($parsed.PSObject.Properties['entries']) {
            $entries = @($parsed.entries)
        } else {
            $entries = @($parsed)
        }

        foreach ($entry in $entries) {
            $h = ''
            if ($entry -is [string]) {
                $h = ([string]$entry).Trim().ToUpperInvariant()
            } elseif ($null -ne $entry -and $entry.PSObject.Properties['sha256']) {
                $h = ([string]$entry.sha256).Trim().ToUpperInvariant()
            }
            if ($h -match '^[A-F0-9]{64}$' -and $HashSet.Add($h)) {
                $added++
            }
        }
    } catch {
        Write-Warning ("CST known-good baseline load failed for {0}: {1}" -f $FilePath, $_.Exception.Message)
    }
    return $added
}

function Resolve-CstKnownGoodHashSet {
    param(
        [Parameter(Mandatory)]$Rules,
        [Parameter(Mandatory)][string]$RulesPath,
        [Parameter(Mandatory)]$Context
    )

    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $matchedProfiles = New-Object System.Collections.Generic.List[string]
    if (-not $Rules.knownGoodPolicy -or -not [bool]$Rules.knownGoodPolicy.enabled) {
        return [PSCustomObject]@{
            hashSet = $set
            matchedProfiles = @()
            context = $Context
            inlineCount = 0
            fileCount = 0
        }
    }

    $rulesDir = Get-CstRulesDirectory -RulesPath $RulesPath
    foreach ($entry in @($Rules.knownGoodPolicy.hashAllowlist)) {
        if ($entry -is [string]) {
            $h = ([string]$entry).Trim().ToUpperInvariant()
            if ($h -match '^[A-F0-9]{64}$') { [void]$set.Add($h) }
        } elseif ($null -ne $entry -and $entry.PSObject.Properties['sha256']) {
            $h = ([string]$entry.sha256).Trim().ToUpperInvariant()
            if ($h -match '^[A-F0-9]{64}$') { [void]$set.Add($h) }
        }
    }

    foreach ($profile in @($Rules.knownGoodPolicy.hashAllowlistProfiles)) {
        if ($null -eq $profile) { continue }
        $profileName = if ($profile.PSObject.Properties['name']) { [string]$profile.name } else { 'UnnamedProfile' }
        $buildRegex = if ($profile.PSObject.Properties['osBuildRegex']) { [string]$profile.osBuildRegex } else { '' }
        $productRegex = if ($profile.PSObject.Properties['productRegex']) { [string]$profile.productRegex } else { '' }

        $buildMatch = $true
        if (-not [string]::IsNullOrWhiteSpace($buildRegex)) {
            $buildMatch = ([string]$Context.buildNumber -match $buildRegex)
        }
        $productMatch = $true
        if (-not [string]::IsNullOrWhiteSpace($productRegex)) {
            $productMatch = ([string]$Context.productName -match $productRegex)
        }
        if (-not ($buildMatch -and $productMatch)) { continue }

        if (-not $matchedProfiles.Contains($profileName)) {
            $matchedProfiles.Add($profileName)
        }

        foreach ($hEntry in @($profile.hashes)) {
            if ($hEntry -is [string]) {
                $h = ([string]$hEntry).Trim().ToUpperInvariant()
                if ($h -match '^[A-F0-9]{64}$') { [void]$set.Add($h) }
            } elseif ($null -ne $hEntry -and $hEntry.PSObject.Properties['sha256']) {
                $h = ([string]$hEntry.sha256).Trim().ToUpperInvariant()
                if ($h -match '^[A-F0-9]{64}$') { [void]$set.Add($h) }
            }
        }

        if ($profile.PSObject.Properties['files']) {
            $profileFiles = @($profile.files)
            $fileIndex = 0
            foreach ($relPath in $profileFiles) {
                $fileIndex++
                $rel = ([string]$relPath).Trim().TrimStart('\', '/')
                if ([string]::IsNullOrWhiteSpace($rel)) { continue }
                $fullPath = Join-Path $rulesDir $rel
                if (Get-Command Write-CstLiveProgress -ErrorAction SilentlyContinue) {
                    $phasePct = [math]::Min(95.0, [math]::Round(($fileIndex / [math]::Max(1, $profileFiles.Count)) * 100.0, 1))
                    Write-CstLiveProgress -Scanned 0 -ProgressTotal 1 -CurrentPath $fullPath -ElapsedSec 0 -Phase 'TargetPrep' -PhasePercent $phasePct -OverallPercent ([math]::Round(10.5 + ($phasePct * 0.004), 1)) -Detail ("Loading known-good baseline {0}/{1}: {2}" -f $fileIndex, $profileFiles.Count, [System.IO.Path]::GetFileName($rel))
                }
                Import-CstKnownGoodBaselineFile -FilePath $fullPath -HashSet $set | Out-Null
            }
        }
    }

    return [PSCustomObject]@{
        hashSet = $set
        matchedProfiles = @($matchedProfiles.ToArray())
        context = $Context
        count = $set.Count
    }
}

function Test-CstKnownGoodSqliteAvailable {
    param([string]$SqliteDllPath = '')

    if (-not [string]::IsNullOrWhiteSpace($SqliteDllPath) -and (Test-Path -LiteralPath $SqliteDllPath)) {
        try {
            Add-Type -Path $SqliteDllPath -ErrorAction Stop | Out-Null
            return $true
        } catch {}
    }

    $bundledLib = Join-Path $PSScriptRoot 'lib'
    $bundledDll = Join-Path $bundledLib 'Microsoft.Data.Sqlite.dll'
    if (Test-Path -LiteralPath $bundledDll) {
        try {
            foreach ($dep in @('SQLitePCLRaw.core.dll', 'SQLitePCLRaw.batteries_v2.dll', 'Microsoft.Data.Sqlite.dll')) {
                $depPath = Join-Path $bundledLib $dep
                if (Test-Path -LiteralPath $depPath) {
                    Add-Type -Path $depPath -ErrorAction Stop | Out-Null
                }
            }
            return $true
        } catch {}
    }

    foreach ($assemblyName in @('Microsoft.Data.Sqlite', 'System.Data.SQLite')) {
        try {
            Add-Type -AssemblyName $assemblyName -ErrorAction Stop | Out-Null
            return $true
        } catch {}
    }

    return $false
}

function Initialize-CstKnownGoodStore {
    param(
        [Parameter(Mandatory)]$Rules,
        [Parameter(Mandatory)][string]$RulesPath,
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][hashtable]$MalwareIocIndex
    )

    Dispose-CstKnownGoodStore
    $policy = $Rules.knownGoodPolicy
    if (-not $policy -or -not [bool]$policy.enabled) {
        $script:CstKnownGoodStore = [PSCustomObject]@{
            enabled = $false
            storageMode = 'Memory'
            memorySet = (New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase))
            sqliteActive = $false
            matchedProfiles = @()
            malwareIocCount = $MalwareIocIndex.Count
        }
        return $script:CstKnownGoodStore
    }

    $storageMode = if ($policy.PSObject.Properties['storageMode']) { [string]$policy.storageMode } else { 'Memory' }
    if (Get-Command Write-CstLiveProgress -ErrorAction SilentlyContinue) {
        Write-CstLiveProgress -Scanned 0 -ProgressTotal 1 -CurrentPath '' -ElapsedSec 0 -Phase 'TargetPrep' -PhasePercent 30.0 -OverallPercent 10.6 -Detail ("Resolving known-good hash allowlists ({0})..." -f $storageMode)
    }
    $resolved = Resolve-CstKnownGoodHashSet -Rules $Rules -RulesPath $RulesPath -Context $Context
    $memorySet = $resolved.hashSet

    $sqliteActive = $false
    $sqlitePath = ''
    $sqliteWarning = ''
    if ($storageMode -eq 'Sqlite') {
        if (Get-Command Write-CstLiveProgress -ErrorAction SilentlyContinue) {
            Write-CstLiveProgress -Scanned 0 -ProgressTotal 1 -CurrentPath '' -ElapsedSec 0 -Phase 'TargetPrep' -PhasePercent 55.0 -OverallPercent 10.8 -Detail 'Opening known-good SQLite goodware database...'
        }
        $rulesDir = Get-CstRulesDirectory -RulesPath $RulesPath
        $sqliteRel = if ($policy.PSObject.Properties['sqlitePath'] -and -not [string]::IsNullOrWhiteSpace([string]$policy.sqlitePath)) {
            [string]$policy.sqlitePath
        } else {
            'rules\goodware.db'
        }
        $sqlitePath = if ([System.IO.Path]::IsPathRooted($sqliteRel)) { $sqliteRel } else { Join-Path $rulesDir $sqliteRel }
        $dllPath = Join-Path (Join-Path $PSScriptRoot 'lib') 'Microsoft.Data.Sqlite.dll'

        if (-not (Test-Path -LiteralPath $sqlitePath)) {
            $sqliteWarning = "SQLite goodware database not found: $sqlitePath"
        } elseif (-not (Test-CstKnownGoodSqliteAvailable -SqliteDllPath $dllPath)) {
            $sqliteWarning = 'Microsoft.Data.Sqlite assembly unavailable; using in-memory known-good set only.'
        } else {
            try {
                $connType = [Microsoft.Data.Sqlite.SqliteConnection]
                $script:CstKnownGoodSqliteConnection = $connType::new(("Data Source={0};Mode=ReadOnly" -f $sqlitePath))
                $script:CstKnownGoodSqliteConnection.Open()
                $script:CstKnownGoodSqliteCommand = $script:CstKnownGoodSqliteConnection.CreateCommand()
                $script:CstKnownGoodSqliteCommand.CommandText = 'SELECT 1 FROM goodware WHERE sha256 = @hash LIMIT 1'
                $null = $script:CstKnownGoodSqliteCommand.Parameters.AddWithValue('@hash', '')
                $sqliteActive = $true
            } catch {
                $sqliteWarning = "SQLite known-good open failed: $($_.Exception.Message)"
                Dispose-CstKnownGoodStore
            }
        }

        if (-not $sqliteActive -and -not [string]::IsNullOrWhiteSpace($sqliteWarning) -and -not $script:CstKnownGoodSqliteFallbackLogged) {
            Write-Warning $sqliteWarning
            $script:CstKnownGoodSqliteFallbackLogged = $true
        }
    }

    $script:CstKnownGoodStore = [PSCustomObject]@{
        enabled = $true
        storageMode = if ($sqliteActive) { 'Sqlite' } else { 'Memory' }
        memorySet = $memorySet
        sqliteActive = $sqliteActive
        sqlitePath = $sqlitePath
        matchedProfiles = @($resolved.matchedProfiles)
        malwareIocIndex = $MalwareIocIndex
        skipContentScan = if ($policy.PSObject.Properties['skipContentScan']) { [bool]$policy.skipContentScan } else { $true }
        trustedSignerEarlyExit = $policy.trustedSignerEarlyExit
    }
    return $script:CstKnownGoodStore
}

function Dispose-CstKnownGoodStore {
    if ($null -ne $script:CstKnownGoodSqliteCommand) {
        try { $script:CstKnownGoodSqliteCommand.Dispose() } catch {}
        $script:CstKnownGoodSqliteCommand = $null
    }
    if ($null -ne $script:CstKnownGoodSqliteConnection) {
        try { $script:CstKnownGoodSqliteConnection.Dispose() } catch {}
        $script:CstKnownGoodSqliteConnection = $null
    }
    $script:CstKnownGoodStore = $null
}

function Test-CstKnownGoodHash {
    param(
        [AllowEmptyString()][string]$Sha256 = '',
        [hashtable]$MalwareIocIndex = $null
    )

    if ([string]::IsNullOrWhiteSpace($Sha256)) { return $false }

    $hash = $Sha256.Trim().ToUpperInvariant()
    if ($hash -notmatch '^[A-F0-9]{64}$') { return $false }
    if ($null -eq $script:CstKnownGoodStore -or -not [bool]$script:CstKnownGoodStore.enabled) { return $false }

    $iocIndex = if ($null -ne $MalwareIocIndex) { $MalwareIocIndex } else { $script:CstKnownGoodStore.malwareIocIndex }
    if ($null -ne $iocIndex -and $iocIndex.ContainsKey($hash)) {
        return $false
    }

    if ([bool]$script:CstKnownGoodStore.sqliteActive -and $null -ne $script:CstKnownGoodSqliteCommand) {
        try {
            $script:CstKnownGoodSqliteCommand.Parameters['@hash'].Value = $hash
            $result = $script:CstKnownGoodSqliteCommand.ExecuteScalar()
            if ($null -ne $result) { return $true }
        } catch {}
    }

    return $script:CstKnownGoodStore.memorySet.Contains($hash)
}

function Test-CstTrustedSignerEarlyExit {
    param(
        [Parameter(Mandatory)][string]$Extension,
        [Parameter(Mandatory)][string]$SignerStatus,
        [string]$Publisher = '',
        [Parameter(Mandatory)]$Rules,
        [Parameter(Mandatory)]$EnvironmentMode,
        [hashtable]$SignatureCache = $null,
        [int]$SignatureTimeoutMs = 500
    )

    $policy = $Rules.knownGoodPolicy
    if (-not $policy -or -not [bool]$policy.enabled) { return $false }
    $early = $policy.trustedSignerEarlyExit
    if (-not $early -or -not [bool]$early.enabled) { return $false }

    $ext = $Extension.ToLowerInvariant()
    $allowedExt = @('.exe', '.dll', '.sys')
    if ($early.PSObject.Properties['extensions']) {
        $allowedExt = @($early.extensions | ForEach-Object { ([string]$_).ToLowerInvariant() })
    }
    if ($allowedExt -notcontains $ext) { return $false }

    $requireValid = $true
    if ($early.PSObject.Properties['requireValidSignature']) {
        $requireValid = [bool]$early.requireValidSignature
    }
    if ($requireValid -and [string]$SignerStatus -ne 'Valid') { return $false }

    # Prefer a narrow early-exit publisher allowlist (Microsoft family by default).
    # Broader signerPolicies.allowPublishers still soft-suppress weak content findings.
    if ($early.PSObject.Properties['publisherAllowlist'] -and @($early.publisherAllowlist).Count -gt 0) {
        $pubLower = [string]$Publisher.ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($pubLower)) { return $false }
        foreach ($allowed in @($early.publisherAllowlist)) {
            $allowedText = [string]$allowed
            if ([string]::IsNullOrWhiteSpace($allowedText)) { continue }
            if ($pubLower.Contains($allowedText.ToLowerInvariant())) {
                return $true
            }
        }
        return $false
    }

    return (Test-CstPublisherIsTrustedVendor -Publisher $Publisher)
}

function Test-CstShouldSkipContentScan {
    param(
        [bool]$KnownGoodHash,
        [bool]$TrustedSignerSkip,
        [Parameter(Mandatory)]$Rules
    )

    if (-not $Rules.knownGoodPolicy -or -not [bool]$Rules.knownGoodPolicy.enabled) { return $false }
    if (-not [bool]$Rules.knownGoodPolicy.skipContentScan) { return $false }
    return ($KnownGoodHash -or $TrustedSignerSkip)
}

function Initialize-CstGoodwareDatabase {
    param(
        [string]$DatabasePath,
        [switch]$Force
    )

    if ([string]::IsNullOrWhiteSpace($DatabasePath)) {
        $DatabasePath = Join-Path $PSScriptRoot 'rules\goodware.db'
    }
    if ((Test-Path -LiteralPath $DatabasePath) -and -not $Force) {
        Write-Host "Database already exists: $DatabasePath"
        return $DatabasePath
    }

    $dir = Split-Path -Parent $DatabasePath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if (-not (Test-CstKnownGoodSqliteAvailable)) {
        throw 'Microsoft.Data.Sqlite is required to create goodware.db. Install the package or place Microsoft.Data.Sqlite.dll under CST\lib.'
    }

    if (Test-Path -LiteralPath $DatabasePath) {
        Remove-Item -LiteralPath $DatabasePath -Force
    }

    $conn = [Microsoft.Data.Sqlite.SqliteConnection]::new(("Data Source={0}" -f $DatabasePath))
    $conn.Open()
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = @'
CREATE TABLE goodware (
  sha256 TEXT NOT NULL PRIMARY KEY
);
CREATE INDEX IF NOT EXISTS ix_goodware_sha256 ON goodware(sha256);
'@
        $cmd.ExecuteNonQuery() | Out-Null
        $cmd.CommandText = 'PRAGMA journal_mode=WAL;'
        $cmd.ExecuteNonQuery() | Out-Null
    } finally {
        $conn.Close()
        $conn.Dispose()
    }

    Write-Host "Created goodware database: $DatabasePath"
    return $DatabasePath
}

function Import-CstNsrlToGoodwareDb {
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [string]$DatabasePath,
        [int]$BatchSize = 5000
    )

    if ([string]::IsNullOrWhiteSpace($DatabasePath)) {
        $DatabasePath = Join-Path $PSScriptRoot 'rules\goodware.db'
    }
    if (-not (Test-Path -LiteralPath $DatabasePath)) {
        Initialize-CstGoodwareDatabase -DatabasePath $DatabasePath -Force
    }
    if (-not (Test-CstKnownGoodSqliteAvailable)) {
        throw 'Microsoft.Data.Sqlite is required for NSRL import.'
    }

    $conn = [Microsoft.Data.Sqlite.SqliteConnection]::new(("Data Source={0}" -f $DatabasePath))
    $conn.Open()
    $script:nsrlInserted = 0
    try {
        $tx = $conn.BeginTransaction()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = 'INSERT OR IGNORE INTO goodware (sha256) VALUES (@h)'
        $null = $cmd.Parameters.AddWithValue('@h', '')
        $cmd.Transaction = $tx

        $pending = New-Object System.Collections.Generic.List[string]
        $flushPending = {
            foreach ($h in $pending) {
                $cmd.Parameters['@h'].Value = $h
                $r = $cmd.ExecuteNonQuery()
                if ($r -gt 0) { $script:nsrlInserted += $r }
            }
            $pending.Clear()
        }

        $enqueue = {
            param([string]$line)
            $h = $line.Trim().ToUpperInvariant()
            if ($h -match '^[A-F0-9]{64}$') {
                [void]$pending.Add($h)
                if ($pending.Count -ge $BatchSize) {
                    & $flushPending
                }
            }
        }

        if ($InputPath.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase)) {
            $parsed = Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json
            $items = if ($parsed -is [System.Array]) { @($parsed) } elseif ($parsed.hashes) { @($parsed.hashes) } else { @($parsed) }
            foreach ($item in $items) {
                if ($item -is [string]) { & $enqueue $item }
                elseif ($item.sha256) { & $enqueue ([string]$item.sha256) }
            }
        } else {
            Get-Content -LiteralPath $InputPath | ForEach-Object { & $enqueue $_ }
        }

        if ($pending.Count -gt 0) { & $flushPending }
        $tx.Commit()
    } finally {
        $conn.Close()
        $conn.Dispose()
    }

    Write-Host "Imported $script:nsrlInserted SHA-256 rows into $DatabasePath"
    return $script:nsrlInserted
}
