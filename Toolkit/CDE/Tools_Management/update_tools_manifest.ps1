param(
    [switch]$DownloadApprovedNow
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$toolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifestPath = Join-Path $toolsRoot "tools_manifest.json"
$tempRoot = Join-Path $toolsRoot "_download_temp"

function Get-Sha256([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
}

function Ensure-ParentDirectory([string]$path) {
    $parent = Split-Path -Parent $path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

function Try-DownloadOfficial([string]$url, [string]$destination) {
    Ensure-ParentDirectory $destination
    try {
        Invoke-WebRequest -Uri $url -OutFile $destination
        return $true
    }
    catch {
        Write-Warning "Download failed: $url -> $destination : $($_.Exception.Message)"
        return $false
    }
}

function Try-StageEntry([hashtable]$entry, [string]$toolPath) {
    if (-not $DownloadApprovedNow) { return }
    if ([string]::IsNullOrWhiteSpace($entry.downloadDirectUrl)) { return }

    $downloadName = if ($entry.ContainsKey("downloadFileName") -and $entry.downloadFileName) { $entry.downloadFileName } else { [IO.Path]::GetFileName($entry.downloadDirectUrl) }
    $downloadPath = Join-Path $tempRoot $downloadName
    $ok = Try-DownloadOfficial -url $entry.downloadDirectUrl -destination $downloadPath
    if (-not $ok) { return }

    Ensure-ParentDirectory $toolPath
    switch ($entry.downloadType) {
        "file" {
            Copy-Item -LiteralPath $downloadPath -Destination $toolPath -Force
        }
        "zip_member" {
            $extractRoot = Join-Path $tempRoot ([IO.Path]::GetFileNameWithoutExtension($downloadName))
            if (Test-Path -LiteralPath $extractRoot) { Remove-Item -LiteralPath $extractRoot -Recurse -Force }
            Expand-Archive -LiteralPath $downloadPath -DestinationPath $extractRoot -Force
            $memberPath = Join-Path $extractRoot ($entry.memberPath -replace "/", "\")
            if (Test-Path -LiteralPath $memberPath -PathType Leaf) {
                Copy-Item -LiteralPath $memberPath -Destination $toolPath -Force
            }
            else {
                Write-Warning "Archive member not found for $($entry.name): $($entry.memberPath)"
            }
        }
    }
}

$entries = @(
    @{
        name = "Core Hardware Utility (UEFI)"
        relativePath = "Boot/CoreHardwareUtility/CoreDiag.efi"
        executionMode = "boot_efi"
        sourceUrl = ""
        preferredVersion = "CURRENT"
        pinned = $true
        monetizationApproved = $true
        status = "manual_required"
        approvalSource = "OwnerApprovedAllowlist"
        approvedOn = "2026-05-05"
        downloadDirectUrl = $null
        downloadType = "file"
    }
    @{
        name = "Windows Memory Diagnostic (Microsoft memtest.efi)"
        relativePath = "Boot/WinMemoryDiag/memtest.efi"
        executionMode = "boot_efi"
        sourceUrl = "https://learn.microsoft.com/windows-hardware/"
        preferredVersion = "FROM_OS_MEDIA"
        pinned = $true
        monetizationApproved = $true
        status = "manual_required"
        approvalSource = "OwnerApprovedAllowlist"
        approvedOn = "2026-05-04"
        downloadDirectUrl = $null
        downloadType = "file"
    }
)

if ($DownloadApprovedNow -and -not (Test-Path -LiteralPath $tempRoot)) {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
}

$resolvedEntries = foreach ($entry in $entries) {
    $toolPath = Join-Path $toolsRoot ($entry.relativePath -replace "/", "\")
    Try-StageEntry -entry $entry -toolPath $toolPath

    $exists = if ($entry.executionMode -eq "boot_folder") {
        Test-Path -LiteralPath $toolPath -PathType Container
    }
    else {
        Test-Path -LiteralPath $toolPath -PathType Leaf
    }
    $status = if ($exists) { "acquired" } else { $entry.status }
    $sha256 = Get-Sha256 $toolPath
    $sizeBytes = if ($exists -and (Test-Path -LiteralPath $toolPath -PathType Leaf)) { (Get-Item -LiteralPath $toolPath).Length } else { 0 }

    [ordered]@{
        name = $entry.name
        relativePath = $entry.relativePath
        executionMode = $entry.executionMode
        sourceUrl = $entry.sourceUrl
        preferredVersion = $entry.preferredVersion
        pinned = $entry.pinned
        monetizationApproved = $entry.monetizationApproved
        approvalSource = $entry.approvalSource
        approvedOn = $entry.approvedOn
        status = $status
        sha256 = $sha256
        sizeBytes = $sizeBytes
    }
}

$manifest = [ordered]@{
    manifestVersion = 2
    manifestSchemaVersion = "2.0.0"
    generatedUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    generatedBy = "CDE Tools Onboarding Pipeline"
    checksumAlgorithm = "SHA256"
    sourcePolicy = "official_only"
    notes = "Use official project/vendor sources only. manual_required indicates user-supplied artifact is needed."
    entries = @($resolvedEntries)
}

$manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestPath -Encoding UTF8
Write-Host "Updated tools manifest: $manifestPath"

