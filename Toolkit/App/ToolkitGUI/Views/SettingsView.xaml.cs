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
        public SettingsView()
        {
            InitializeComponent();
            AppVersionText.Text = $"Core Diagnostic Engine v{GetAppVersion()}";
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

        private async void UnmountOfflineOs_Click(object sender, RoutedEventArgs e)
        {
            var confirm = MessageBox.Show(
                "Unload offline registry hives now?\n\nThis unloads HKLM\\Offline_* and HKU\\Offline_* without rebooting.",
                "Unmount Offline OS",
                MessageBoxButton.YesNo,
                MessageBoxImage.Question);

            if (confirm != MessageBoxResult.Yes)
                return;

            var result = await PowerShellService.ExecuteAsync(GetOfflineHiveCleanupScript());
            if (!result.Success)
            {
                var detail = !string.IsNullOrWhiteSpace(result.Error)
                    ? result.Error
                    : result.ExceptionMessage;
                MessageBox.Show(
                    $"Offline hive unload failed:\n\n{detail}",
                    "Unmount Offline OS",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return;
            }

            MessageBox.Show(
                "Offline hive unload command completed.",
                "Unmount Offline OS",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
        }

        private async void RebootWindows_Click(object sender, RoutedEventArgs e)
        {
            var confirm = MessageBox.Show(
                "Reboot now and unload offline registry hives first?\n\nThis will run cleanup for HKLM\\Offline_* and HKU\\Offline_* before reboot.",
                "Reboot Windows",
                MessageBoxButton.YesNo,
                MessageBoxImage.Question);

            if (confirm != MessageBoxResult.Yes)
                return;

            var script = GetOfflineHiveCleanupScript() + @"
 
if (Test-Path 'X:\Windows\System32\wpeutil.exe') {
    & 'X:\Windows\System32\wpeutil.exe' reboot
} else {
    shutdown.exe /r /t 0
}
";

            var result = await PowerShellService.ExecuteAsync(script);
            if (!result.Success)
            {
                var detail = !string.IsNullOrWhiteSpace(result.Error)
                    ? result.Error
                    : result.ExceptionMessage;
                MessageBox.Show(
                    $"Reboot command failed:\n\n{detail}",
                    "Reboot Windows",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }

        internal static string GetOfflineHiveCleanupScript() => @"
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
        $p = Start-Process 'reg.exe' -ArgumentList ""unload \""$HivePath\"""" `
             -Wait -PassThru -NoNewWindow -ErrorAction SilentlyContinue
        return $p.ExitCode
    } catch {
        return -1
    }
}

foreach ($h in @('HKLM\Offline_SOFTWARE','HKLM\Offline_SYSTEM','HKLM\Offline_SAM')) {
    $ec = Invoke-HiveUnload $h
    if ($ec -notin @(0,2)) {
        Write-Warning ""Hive unload exit $ec for $h""
    }
}

# Query HKU subkeys via reg.exe (avoids PS Registry provider handle acquisition)
$hkuLines = & reg.exe query HKU 2>$null
if ($hkuLines) {
    $hkuLines |
        Where-Object { $_ -match 'Offline_' } |
        ForEach-Object {
            $leaf = ($_ -replace 'HKEY_USERS\\','').Trim()
            if ($leaf -and $leaf -like 'Offline_*') {
                Invoke-HiveUnload ""HKU\$leaf"" | Out-Null
            }
        }
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
