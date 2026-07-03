using System;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Input;

namespace ToolkitGUI.Views
{
    public enum WinPELaunchChoice { NormalCDE, OfflineCDE, Cancelled }

    public partial class WinPEBootMenuWindow : Window
    {
        private readonly TaskCompletionSource<WinPELaunchChoice> _tcs = new();
        private readonly string _toolkitRoot;

        public WinPEBootMenuWindow()
        {
            InitializeComponent();

            _toolkitRoot = Environment.GetEnvironmentVariable("TOOLKIT_ROOT") ?? string.Empty;

            if (!string.IsNullOrEmpty(_toolkitRoot))
                MediaPathText.Text = $"Media: {_toolkitRoot}";
            else
                MediaPathText.Text = "Media: (TOOLKIT_ROOT not set)";
        }

        public Task<WinPELaunchChoice> WaitForChoiceAsync() => _tcs.Task;

        protected override void OnClosed(EventArgs e)
        {
            base.OnClosed(e);
            // Fires for any close reason; TrySetResult is a no-op if already resolved.
            _tcs.TrySetResult(WinPELaunchChoice.Cancelled);
        }

        // ----------------------------------------------------------------
        // Keyboard shortcuts: 1-7 map directly to menu options
        // ----------------------------------------------------------------
        private void Window_KeyDown(object sender, KeyEventArgs e)
        {
            switch (e.Key)
            {
                case Key.D1: case Key.NumPad1: LaunchNormalCDE(); break;
                case Key.D2: case Key.NumPad2: LaunchOfflineCDE(); break;
                case Key.D3: case Key.NumPad3: OpenCmdPrompt(); break;
                case Key.D4: case Key.NumPad4: OpenPowerShell(); break;
                case Key.D5: case Key.NumPad5: RunNetConfig(); break;
                case Key.D6: case Key.NumPad6: ConfirmReboot(); break;
                case Key.D7: case Key.NumPad7: ConfirmShutdown(); break;
            }
        }

        // ----------------------------------------------------------------
        // Click handlers — delegate to action methods
        // ----------------------------------------------------------------
        private void OnNormalCDE_Click(object sender, RoutedEventArgs e) => LaunchNormalCDE();
        private void OnOfflineCDE_Click(object sender, RoutedEventArgs e) => LaunchOfflineCDE();
        private void OnCmdPrompt_Click(object sender, RoutedEventArgs e) => OpenCmdPrompt();
        private void OnPowerShell_Click(object sender, RoutedEventArgs e) => OpenPowerShell();
        private void OnNetConfig_Click(object sender, RoutedEventArgs e) => RunNetConfig();
        private void OnReboot_Click(object sender, RoutedEventArgs e) => ConfirmReboot();
        private void OnShutdown_Click(object sender, RoutedEventArgs e) => ConfirmShutdown();

        // ----------------------------------------------------------------
        // Action methods
        // ----------------------------------------------------------------
        private void LaunchNormalCDE()
        {
            _tcs.TrySetResult(WinPELaunchChoice.NormalCDE);
            Close();
        }

        private void LaunchOfflineCDE()
        {
            _tcs.TrySetResult(WinPELaunchChoice.OfflineCDE);
            Close();
        }

        private void OpenCmdPrompt()
        {
            LaunchProcess("cmd.exe",
                @"/k ""prompt CDE-PE $P$G && echo CDE WinPE Shell  -  press EXIT to return""",
                useShellExecute: true);
        }

        private void OpenPowerShell()
        {
            var psExe = @"X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe";
            if (!File.Exists(psExe)) psExe = "powershell.exe";
            LaunchProcess(psExe, "-NoProfile -NoLogo", useShellExecute: false, createNoWindow: false);
        }

        private void RunNetConfig()
        {
            LaunchProcess("wpeinit", "", useShellExecute: false, createNoWindow: true, waitForExit: true);
            MessageBox.Show("Network initialization complete (wpeinit finished).",
                "Network Setup", MessageBoxButton.OK, MessageBoxImage.Information);
        }

        private void ConfirmReboot()
        {
            var r = MessageBox.Show("Reboot the system?", "Reboot",
                MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No);
            if (r == MessageBoxResult.Yes)
                LaunchProcess("wpeutil", "Reboot");
        }

        private void ConfirmShutdown()
        {
            var r = MessageBox.Show("Shut down the system?", "Shutdown",
                MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No);
            if (r == MessageBoxResult.Yes)
                LaunchProcess("wpeutil", "Shutdown");
        }

        // ----------------------------------------------------------------
        // Helpers
        // ----------------------------------------------------------------
        private static void LaunchProcess(string fileName, string args,
            bool useShellExecute = false, bool createNoWindow = true, bool waitForExit = false)
        {
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = fileName,
                    Arguments = args,
                    UseShellExecute = useShellExecute,
                    CreateNoWindow = !useShellExecute && createNoWindow,
                    WindowStyle = (!useShellExecute && createNoWindow)
                        ? ProcessWindowStyle.Hidden
                        : ProcessWindowStyle.Normal
                };
                var p = Process.Start(psi);
                if (waitForExit) p?.WaitForExit();
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Failed to launch: {fileName}\n\n{ex.Message}",
                    "Launch Error", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }
    }
}
