#Requires -Version 5.1
<#
.SYNOPSIS
    Task Manager StartupApproved registry parity for Run keys and startup folders.
#>

function Get-StartupApprovedRegistryRoot {
    return 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
}

function Get-StartupApprovedCategoryForSource {
    param(
        [string]$SourceGroup,
        [string]$RowType
    )

    if ($RowType -eq 'FileStartupItem') {
        return 'StartupFolder'
    }

    if ($SourceGroup -match 'WOW6432Node') {
        return 'Run32'
    }

    return 'Run'
}

function Get-StartupApprovedEntryName {
    param(
        [string]$RowType,
        [string]$ValueName,
        [string]$Name,
        [string]$FilePath
    )

    if ($RowType -eq 'FileStartupItem') {
        if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
            return [System.IO.Path]::GetFileName($FilePath)
        }
        return $Name
    }

    if (-not [string]::IsNullOrWhiteSpace($ValueName)) {
        return $ValueName
    }

    return $Name
}

function Test-StartupApprovedEntryEnabled {
    param(
        [string]$Category,
        [string]$EntryName
    )

    if ([string]::IsNullOrWhiteSpace($Category) -or [string]::IsNullOrWhiteSpace($EntryName)) {
        return $true
    }

    $approvedPath = Join-Path (Get-StartupApprovedRegistryRoot) $Category
    if (-not (Test-Path -LiteralPath $approvedPath)) {
        return $true
    }

    try {
        $bytes = (Get-ItemProperty -LiteralPath $approvedPath -Name $EntryName -ErrorAction Stop).$EntryName
        if ($bytes -is [byte[]] -and $bytes.Length -gt 0) {
            return ($bytes[0] -eq 0x02)
        }
    } catch {
        return $true
    }

    return $true
}

function Set-StartupApprovedEntryEnabled {
    param(
        [string]$Category,
        [string]$EntryName,
        [bool]$Enable
    )

    if ([string]::IsNullOrWhiteSpace($Category) -or [string]::IsNullOrWhiteSpace($EntryName)) {
        throw 'Category and EntryName are required for StartupApproved updates.'
    }

    if ($env:OFFLINE_WINDOWS_ROOT) {
        throw 'PROTECTED_OR_UNSUPPORTED: StartupApproved is not supported in offline registry mode.'
    }

    $approvedPath = Join-Path (Get-StartupApprovedRegistryRoot) $Category
    if (-not (Test-Path -LiteralPath $approvedPath)) {
        New-Item -Path $approvedPath -Force | Out-Null
    }

    $bytes = New-Object byte[] 12
    $bytes[0] = if ($Enable) { [byte]0x02 } else { [byte]0x03 }
    Set-ItemProperty -LiteralPath $approvedPath -Name $EntryName -Value $bytes -Type Binary -Force
}

function Remove-StartupApprovedEntry {
    param(
        [string]$Category,
        [string]$EntryName
    )

    if ([string]::IsNullOrWhiteSpace($Category) -or [string]::IsNullOrWhiteSpace($EntryName)) {
        return
    }

    $approvedPath = Join-Path (Get-StartupApprovedRegistryRoot) $Category
    if (-not (Test-Path -LiteralPath $approvedPath)) {
        return
    }

    try {
        Remove-ItemProperty -LiteralPath $approvedPath -Name $EntryName -ErrorAction Stop
    } catch { }
}

function Get-StartupApprovedEnabledState {
    param(
        [string]$SourceGroup,
        [string]$RowType,
        [string]$ValueName,
        [string]$Name,
        [string]$FilePath,
        [bool]$IsInActiveLocation
    )

    if (-not $IsInActiveLocation) {
        return $false
    }

    $category = Get-StartupApprovedCategoryForSource -SourceGroup $SourceGroup -RowType $RowType
    $entryName = Get-StartupApprovedEntryName -RowType $RowType -ValueName $ValueName -Name $Name -FilePath $FilePath
    return (Test-StartupApprovedEntryEnabled -Category $category -EntryName $entryName)
}
