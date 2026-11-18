using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using ToolkitGUI.Services;
using ToolkitGUI.ViewModels;

namespace ToolkitGUI.Views
{
    public partial class SettingsView : System.Windows.Controls.UserControl
    {
        private bool _isPowerActionInProgress;
        private bool _initializingTheme;

        public SettingsView()
        {
            InitializeComponent();
            AppVersionText.Text = $"Core Diagnostic Engine v{GetAppVersion()}";
            _initializingTheme = true;
            try
            {
                if (ThemeService.CurrentTheme == AppTheme.Dark)
                    DarkThemeRadio.IsChecked = true;
                else
                    LightThemeRadio.IsChecked = true;
            }
            finally
            {
                _initializingTheme = false;
            }
        }

        private void LightTheme_Checked(object sender, RoutedEventArgs e)
        {
            if (_initializingTheme)
                return;
            ThemeService.SetTheme(AppTheme.Light);
        }

        private void DarkTheme_Checked(object sender, RoutedEventArgs e)
        {
            if (_initializingTheme)
                return;
            ThemeService.SetTheme(AppTheme.Dark);
        }

        private void OpenUserGuide_Click(object sender, RoutedEventArgs e)
        {
            var guidePath = ToolkitPaths.GetUserGuidePath();
            if (!File.Exists(guidePath))
            {
                MessageBox.Show(
                    $"User guide not found:\n\n{guidePath}\n\nRe-run toolkit publish or copy the HALP folder to this media.",
                    "Open User Guide",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            try
            {
                ShellFileOpenHelper.OpenWithDefaultApplication(guidePath);
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    $"Could not open user guide:\n\n{ex.Message}",
                    "Open User Guide",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }

        private void ClearResultLogs_Click(object sender, RoutedEventArgs e)
        {
            var targets = ResultLogCleanupService.GetTargetPaths();
            var existing = targets.Where(Directory.Exists).ToList();
            var missing = targets.Where(p => !Directory.Exists(p)).ToList();

            var message = new StringBuilder();
            message.AppendLine("Delete all files in these diagnostic log folders?");
            message.AppendLine();

            if (existing.Count > 0)
            {
                message.AppendLine("Will clear:");
                foreach (var path in existing)
                    message.AppendLine($"  • {path}");
            }
            else
            {
                message.AppendLine("No log folders were found on this system.");
            }

            if (missing.Count > 0)
            {
                message.AppendLine();
                message.AppendLine("Not present (skipped):");
                foreach (var path in missing)
                    message.AppendLine($"  • {path}");
            }

            message.AppendLine();
            message.AppendLine("This cannot be undone.");

            var confirm = MessageBox.Show(
                message.ToString(),
                "Clear Test & Scan Logs",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning,
                MessageBoxResult.No);

            if (confirm != MessageBoxResult.Yes)
                return;

            if (existing.Count == 0)
            {
                MessageBox.Show(
                    "No diagnostic log folders were found to clear.",
                    "Clear Test & Scan Logs",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            var result = ResultLogCleanupService.ClearAll();
            var summary = new StringBuilder();
            summary.AppendLine($"Removed {result.FilesDeleted} file(s) and {result.DirectoriesDeleted} folder(s).");

            if (result.ClearedPaths.Count > 0)
            {
                summary.AppendLine();
                summary.AppendLine("Cleared:");
                foreach (var path in result.ClearedPaths)
                    summary.AppendLine($"  • {path}");
            }

            if (result.Errors.Count > 0)
            {
                summary.AppendLine();
                summary.AppendLine("Some items could not be deleted:");
                foreach (var error in result.Errors.Take(8))
                    summary.AppendLine($"  • {error}");
                if (result.Errors.Count > 8)
                    summary.AppendLine($"  • ... and {result.Errors.Count - 8} more");
            }

            MessageBox.Show(
                summary.ToString(),
                result.Errors.Count > 0 ? "Clear Test & Scan Logs — Partial" : "Clear Test & Scan Logs",
                MessageBoxButton.OK,
                result.Errors.Count > 0 ? MessageBoxImage.Warning : MessageBoxImage.Information);
        }

        private void SetPowerButtonsEnabled(bool enabled)
        {
            UnmountOfflineOsButton.IsEnabled = enabled;
            RebootWindowsButton.IsEnabled = enabled;
        }

        private async void UnmountOfflineOs_Click(object sender, RoutedEventArgs e)
        {
            if (_isPowerActionInProgress)
                return;

            var confirm = MessageBox.Show(
                "Unload offline registry hives now?\n\nThis unloads HKLM\\Offline_* and HKU\\Offline_* without rebooting.",
                "Unmount Offline OS",
                MessageBoxButton.YesNo,
                MessageBoxImage.Question);

            if (confirm != MessageBoxResult.Yes)
                return;

            _isPowerActionInProgress = true;
            SetPowerButtonsEnabled(false);
            try
            {
                var result = await PowerShellService.ExecuteAsync(GetOfflineHiveCleanupScript(throwOnFailure: true));
                if (!result.Success)
                {
                    var detail = !string.IsNullOrWhiteSpace(result.Error)
                        ? result.Error
                        : (!string.IsNullOrWhiteSpace(result.ExceptionMessage) ? result.ExceptionMessage : result.Output);
                    MessageBox.Show(
                        $"Offline hive unload failed:\n\n{detail}",
                        "Unmount Offline OS",
                        MessageBoxButton.OK,
                        MessageBoxImage.Warning);
                    return;
                }

                var summary = string.IsNullOrWhiteSpace(result.Output)
                    ? "Offline hive unload command completed."
                    : result.Output.Trim();
                MessageBox.Show(
                    summary,
                    "Unmount Offline OS",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
            }
            finally
            {
                _isPowerActionInProgress = false;
                SetPowerButtonsEnabled(true);
            }
        }

        private async void RebootWindows_Click(object sender, RoutedEventArgs e)
        {
            if (_isPowerActionInProgress)
                return;

            var confirm = MessageBox.Show(
                "Reboot now and unload offline registry hives first?\n\nThis will run cleanup for HKLM\\Offline_* and HKU\\Offline_* before reboot.",
                "Reboot Windows",
                MessageBoxButton.YesNo,
                MessageBoxImage.Question);

            if (confirm != MessageBoxResult.Yes)
                return;

            _isPowerActionInProgress = true;
            SetPowerButtonsEnabled(false);
            try
            {
                var script = GetOfflineHiveCleanupScript(throwOnFailure: false) + @"

if (Test-Path 'X:\Windows\System32\wpeutil.exe') {
    $out = & 'X:\Windows\System32\wpeutil.exe' reboot 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ""wpeutil reboot failed (exit $LASTEXITCODE): $(($out | Out-String).Trim())""
    }
} else {
    $out = & shutdown.exe /r /t 0 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ""shutdown.exe failed (exit $LASTEXITCODE): $(($out | Out-String).Trim())""
    }
}
";

                var result = await PowerShellService.ExecuteAsync(script);
                if (!result.Success)
                {
                    var detail = !string.IsNullOrWhiteSpace(result.Error)
                        ? result.Error
                        : (!string.IsNullOrWhiteSpace(result.ExceptionMessage) ? result.ExceptionMessage : result.Output);
                    MessageBox.Show(
                        $"Reboot command failed:\n\n{detail}",
                        "Reboot Windows",
                        MessageBoxButton.OK,
                        MessageBoxImage.Warning);
                }
            }
            finally
            {
                _isPowerActionInProgress = false;
                SetPowerButtonsEnabled(true);
            }
        }

        internal static string GetOfflineHiveCleanupScript(bool throwOnFailure = true) => @"
# Force release of any PS registry provider handles before unloading hives.
# reg.exe must run as a child process (Start-Process) so it does not inherit
# the PS runspace's open HKEY handles — inline reg.exe calls fail with
# 'Access is denied' because the Registry provider holds the hive open.
[GC]::Collect()
[GC]::WaitForPendingFinalizers()
[GC]::Collect()

function Invoke-HiveUnload {
    param([string]$HivePath)
    try {
        $p = Start-Process 'reg.exe' -ArgumentList @('unload', $HivePath) `
             -Wait -PassThru -NoNewWindow -ErrorAction SilentlyContinue
        return $p.ExitCode
    } catch {
        return -1
    }
}

$targets = [System.Collections.Generic.List[string]]::new()
foreach ($base in @('HKLM\Offline_SOFTWARE','HKLM\Offline_SYSTEM','HKLM\Offline_SAM','HKLM\Offline_DEFAULT','HKLM\Offline_SECURITY','HKLM\Offline_COMPONENTS')) {
    if (-not $targets.Contains($base)) { $targets.Add($base) }
}

foreach ($root in @(
    @{ Query = 'HKLM'; Prefix = 'HKEY_LOCAL_MACHINE\'; Short = 'HKLM\' },
    @{ Query = 'HKU';  Prefix = 'HKEY_USERS\';         Short = 'HKU\' }
)) {
    $lines = & reg.exe query $root.Query 2>$null
    if ($lines) {
        foreach ($line in $lines) {
            if ($line -match 'Offline_') {
                $leaf = $line.Replace($root.Prefix, '').Trim()
                if ($leaf -and $leaf -like 'Offline_*') {
                    $hive = $root.Short + $leaf
                    if (-not $targets.Contains($hive)) { $targets.Add($hive) }
                }
            }
        }
    }
}

$unloaded = [System.Collections.Generic.List[string]]::new()
$failed = [System.Collections.Generic.List[string]]::new()
foreach ($h in $targets) {
    $ec = Invoke-HiveUnload $h
    if ($ec -eq 0) {
        $unloaded.Add($h)
    } elseif ($ec -ne 2) {
        $failed.Add(""$h (exit $ec)"")
    }
}

if ($failed.Count -gt 0) {
    $msg = ""Failed to unload offline hive(s): $($failed -join ', ')""
    " + (throwOnFailure ? "throw $msg" : "Write-Warning $msg") + @"
}

if ($unloaded.Count -gt 0) {
    Write-Output ""Unloaded $($unloaded.Count) offline hive(s): $($unloaded -join ', ')""
} else {
    Write-Output ""No offline registry hives were loaded.""
}
";

        private static string GetAppVersion()
        {
            var asmVersion = Assembly.GetExecutingAssembly()
                .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
            if (!string.IsNullOrWhiteSpace(asmVersion))
            {
                var plusIndex = asmVersion.IndexOf('+');
                return plusIndex > 0 ? asmVersion[..plusIndex] : asmVersion;
            }

            return Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "1.0.0";
        }
    }
}
