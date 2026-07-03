#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$testsRoot = Split-Path $MyInvocation.MyCommand.Path
$coreDir = Join-Path $testsRoot '..\Core'
Import-Module (Join-Path $coreDir 'Toolkit.Core.psm1') -Force -DisableNameChecking

Write-Host 'Test-SecurityAuditOutputFormat'

$extensionInventory = @(
    [PSCustomObject]@{
        Kind = 'Store'
        Browser = 'Chrome'
        Profile = 'Default'
        User = 'TestUser'
        Location = 'C:\Users\TestUser\AppData\Local\Google\Chrome\User Data\Default\Extensions'
    },
    [PSCustomObject]@{
        Kind = 'Extension'
        Browser = 'Chrome'
        Profile = 'Default'
        User = 'TestUser'
        ExtensionId = 'abc123'
        ExtensionName = 'uBlock Origin'
        Version = '1.0.0'
        ExtensionPath = 'C:\Users\TestUser\AppData\Local\Google\Chrome\User Data\Default\Extensions\abc123\1.0.0'
        ManifestDescription = 'Block ads'
    }
)

$extensionOutput = Format-BrowserExtensionList -ExtensionInventory $extensionInventory
foreach ($fragment in @('STORE 1 :', 'EXTENSION 1 :', '[Chrome] uBlock Origin', 'Path')) {
    if ($extensionOutput -notmatch [regex]::Escape($fragment)) {
        Write-Error "Format-BrowserExtensionList output missing: $fragment"
        exit 1
    }
}

$customTasks = @(
    [PSCustomObject]@{
        TaskName = 'VendorUpdater'
        TaskPath = '\Vendor\'
        State = 'Ready'
        Actions = [PSCustomObject]@{ Execute = 'C:\Program Files\Vendor\update.exe'; Arguments = '' }
    },
    [PSCustomObject]@{
        TaskName = 'SketchyLauncher'
        TaskPath = '\Startup\'
        State = 'Ready'
        Actions = [PSCustomObject]@{ Execute = 'C:\Users\Public\runme.cmd'; Arguments = '' }
    }
)
$suspicious = @($customTasks[1])

$taskOutput = Format-ScheduledTasksList -CustomTasks $customTasks -SuspiciousTasks $suspicious
foreach ($fragment in @('TASK 1 :', 'TASK 2 :', 'Task Path', 'Action', 'Flagged')) {
    if ($taskOutput -notmatch [regex]::Escape($fragment)) {
        Write-Error "Format-ScheduledTasksList output missing: $fragment"
        exit 1
    }
}

if ($taskOutput -notmatch '\[!\]\s*SketchyLauncher') {
    Write-Error 'Format-ScheduledTasksList should flag suspicious tasks in the title.'
    exit 1
}

Write-Host '  PASS: browser extension and scheduled task grouped output'
Write-Host 'Test-SecurityAuditOutputFormat: PASS'
exit 0
