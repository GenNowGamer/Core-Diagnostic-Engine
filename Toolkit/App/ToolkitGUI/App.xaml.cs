using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using ToolkitGUI.Services;
using ToolkitGUI.Views;

namespace ToolkitGUI
{
    public partial class App : Application
    {
        protected override async void OnStartup(StartupEventArgs e)
        {
            DispatcherUnhandledException += OnDispatcherException;
            AppDomain.CurrentDomain.UnhandledException += OnDomainException;

            // Keep the process alive while we hand off from splash to MainWindow.
            // In WinPE offline mode the splash can be the only open window for a moment.
            // Stay on explicit shutdown in WinPE for the whole session — OnMainWindowClose
            // was returning to startnet's recovery menu when the shell failed to stay open.
            ShutdownMode = ShutdownMode.OnExplicitShutdown;

            if (IsWinPeRuntime())
            {
                // Layered/D3D presentation is unreliable in WinPE; force software render early.
                try
                {
                    RenderOptions.ProcessRenderMode = RenderMode.SoftwareOnly;
                }
                catch
                {
                    /* best-effort */
                }

                WinPeStartupLog.Write("OnStartup", "WinPE detected, software render requested");
            }

            LoadRuntimeConfig();

            if (IsWinPeRuntime())
            {
                var toolkitRoot = ResolveToolkitRoot();
                if (!string.IsNullOrWhiteSpace(toolkitRoot))
                    OfflineRuntimePaths.ClearSessionFiles(toolkitRoot);
                OfflineRuntimePaths.ClearOfflineProcessEnv();
                WinPeStartupLog.Write("ToolkitRoot", toolkitRoot ?? "(null)");
            }

            base.OnStartup(e);

            // Windows always shows a brief branded splash. global.ini ShowSplash no longer drives a MessageBox.
            if (!IsWinPeRuntime())
                await ShowStartupSplashAsync();

            // In WinPE the WPF boot menu replaces the startnet.cmd text menu.
            // The user's choice here sets OFFLINE_LOAD_REQUESTED for the flow below.
            if (IsWinPeRuntime())
            {
                WinPeStartupLog.Write("BootMenu", "showing");
                var bootMenu = new WinPEBootMenuWindow();
                bootMenu.Show();
                var choice = await bootMenu.WaitForChoiceAsync();
                WinPeStartupLog.Write("BootMenuChoice", choice.ToString());

                if (choice == WinPELaunchChoice.OfflineCDE)
                    Environment.SetEnvironmentVariable("OFFLINE_LOAD_REQUESTED", "1", EnvironmentVariableTarget.Process);
                else if (choice == WinPELaunchChoice.NormalCDE)
                {
                    Environment.SetEnvironmentVariable("OFFLINE_LOAD_REQUESTED", "0", EnvironmentVariableTarget.Process);
                    var toolkitRoot = ResolveToolkitRoot();
                    if (!string.IsNullOrWhiteSpace(toolkitRoot))
                        OfflineRuntimePaths.ClearSessionFiles(toolkitRoot);
                    OfflineRuntimePaths.ClearOfflineProcessEnv();
                }
                else
                {
                    // User triggered reboot/shutdown from the menu, or closed the window
                    // without selecting a CDE launch option.
                    WinPeStartupLog.Write("Shutdown", "boot menu cancelled");
                    Shutdown(0);
                    return;
                }
            }

            try
            {
                if (ShouldRunOfflineLoadFlow())
                {
                    WinPeStartupLog.Write("OfflineLoad", "starting");
                    await RunOfflineLoadWithSplashAsync();
                    TryApplyOfflineEnvFile();
                    WinPeStartupLog.Write("OfflineLoad", "finished");
                }
                else if (!IsWinPeRuntime())
                {
                    TryApplyOfflineEnvFile();
                }

                OfflineRuntimePaths.SyncOfflineRegistryLoadedEnv();
                WorkOrderService.ApplyActiveCaseToProcess();

                WinPeStartupLog.Write("MainWindow", "constructing");
                var mainWindow = new MainWindow();
                MainWindow = mainWindow;
                mainWindow.Closed += OnMainWindowClosed;

                WinPeStartupLog.Write("MainWindow", "showing");
                mainWindow.Show();
                mainWindow.Activate();
                _ = mainWindow.Focus();
                WinPeStartupLog.Write("MainWindow",
                    $"shown IsVisible={mainWindow.IsVisible} State={mainWindow.WindowState} " +
                    $"Size={mainWindow.ActualWidth}x{mainWindow.ActualHeight} " +
                    $"Pos={mainWindow.Left},{mainWindow.Top}");

                if (!IsWinPeRuntime())
                {
                    // Full Windows: normal lifetime.
                    ShutdownMode = ShutdownMode.OnMainWindowClose;
                }

                // Re-check bounds after layout; WinPE pseudo-maximize and live-Windows centering both
                // depend on a valid HWND and composition target.
                mainWindow.Dispatcher.InvokeAsync(() =>
                {
                    try
                    {
                        BorderlessWindowHelper.EnsureWithinWorkArea(mainWindow);
                        mainWindow.Activate();
                        WinPeStartupLog.Write("MainWindow",
                            $"loaded IsVisible={mainWindow.IsVisible} Size={mainWindow.ActualWidth}x{mainWindow.ActualHeight}");
                    }
                    catch (Exception ex)
                    {
                        WinPeStartupLog.Write("MainWindowLayoutError", ex.ToString());
                    }
                }, DispatcherPriority.Loaded);
            }
            catch (Exception ex)
            {
                // Boot menu already closed; without this, OnExplicitShutdown leaves a blank session.
                WinPeStartupLog.Write("MainWindowStartupFailed", ex.ToString());
                LogCrash("MainWindowStartup", ex);
                var detail = ex.InnerException is { } inner
                    ? $"{ex.Message}\n\n{inner.Message}"
                    : ex.Message;
                MessageBox.Show(
                    $"Failed to open CDE main window:\n\n{detail}\n\nSee CDE\\Runtime\\winpe_startup.log on the USB for details.",
                    "ToolkitGUI Error",
                    MessageBoxButton.OK,
                    MessageBoxImage.Error);
                Shutdown(1);
            }
        }

        private void OnMainWindowClosed(object? sender, EventArgs e)
        {
            WinPeStartupLog.Write("MainWindowClosed", "shutting down application");
            if (ShutdownMode == ShutdownMode.OnExplicitShutdown)
                Shutdown(0);
        }

        private static bool ShouldRunOfflineLoadFlow()
        {
            if (!IsWinPeRuntime())
                return false;

            var requested = Environment.GetEnvironmentVariable("OFFLINE_LOAD_REQUESTED");
            return string.Equals(requested, "1", StringComparison.OrdinalIgnoreCase) ||
                   string.Equals(requested, "Y", StringComparison.OrdinalIgnoreCase) ||
                   string.Equals(requested, "YES", StringComparison.OrdinalIgnoreCase) ||
                   string.Equals(requested, "TRUE", StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsWinPeRuntime() =>
            Directory.Exists(@"X:\Windows\System32");

        private static async Task ShowStartupSplashAsync()
        {
            var splash = new StartupSplashWindow();
            splash.Show();

            var closed = new TaskCompletionSource();
            splash.Closed += (_, _) => closed.TrySetResult();

            var delay = Task.Delay(2100);
            await Task.WhenAny(closed.Task, delay);

            if (splash.IsVisible)
                splash.Close();
        }

        private static async Task RunOfflineLoadWithSplashAsync()
        {
            var splash = new OfflineLoadProgressWindow();
            splash.UpdateProgress(3);
            splash.UpdateStep("Preparing offline Windows loader...");
            splash.Show();

            try
            {
                string? toolkitRoot = Environment.GetEnvironmentVariable("TOOLKIT_ROOT");
                if (string.IsNullOrWhiteSpace(toolkitRoot))
                {
                    toolkitRoot = TryFindToolkitRootFromBaseDirectory();
                }

                if (string.IsNullOrWhiteSpace(toolkitRoot))
                {
                    splash.UpdateStep("Toolkit root not found. Continuing without offline load.");
                    splash.UpdateProgress(100);
                    await Task.Delay(800);
                    return;
                }

                var scriptPath = Path.Combine(toolkitRoot, "Scripts", "Core", "WinPE_OfflineStartup.ps1");
                if (!File.Exists(scriptPath))
                {
                    splash.UpdateStep("Offline loader script missing. Continuing...");
                    splash.UpdateProgress(100);
                    await Task.Delay(700);
                    return;
                }

                OfflineRuntimePaths.EnsureRuntimeDirectory(toolkitRoot);
                var progressFile = OfflineRuntimePaths.GetProgressLogPath(toolkitRoot);
                if (!string.IsNullOrEmpty(progressFile) && File.Exists(progressFile))
                    File.Delete(progressFile);

                var psExe = @"X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe";
                if (!File.Exists(psExe))
                {
                    psExe = "powershell.exe";
                }

                var progressArg = string.IsNullOrEmpty(progressFile) ? string.Empty : $" -ProgressFile \"{progressFile}\"";
                var args =
                    $"-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"{scriptPath}\" -AutoSelect -AutoLoad -Quiet{progressArg}";

                var psi = new ProcessStartInfo
                {
                    FileName = psExe,
                    Arguments = args,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden
                };

                using var proc = Process.Start(psi);
                if (proc == null)
                {
                    splash.UpdateStep("Unable to start offline loader. Continuing...");
                    splash.UpdateProgress(100);
                    await Task.Delay(700);
                    return;
                }

                var consumedLines = 0;
                while (!proc.HasExited)
                {
                    if (!string.IsNullOrEmpty(progressFile))
                        ConsumeProgressFile(progressFile, ref consumedLines, splash);
                    await Task.Delay(120);
                }

                if (!string.IsNullOrEmpty(progressFile))
                    ConsumeProgressFile(progressFile, ref consumedLines, splash);

                if (proc.ExitCode != 0)
                {
                    splash.UpdateStep("Offline load reported errors. Continuing to CDE...");
                    splash.UpdateProgress(100);
                    await Task.Delay(1100);
                }
                else
                {
                    splash.UpdateStep("Offline load complete. Launching CDE...");
                    splash.UpdateProgress(100);
                    await Task.Delay(450);
                }
            }
            catch
            {
                splash.UpdateStep("Offline load failed. Continuing to CDE...");
                splash.UpdateProgress(100);
                await Task.Delay(1000);
            }
            finally
            {
                splash.Close();
            }
        }

        private static void ConsumeProgressFile(string progressFile, ref int consumedLines, OfflineLoadProgressWindow splash)
        {
            if (!File.Exists(progressFile))
                return;

            string[] lines;
            try
            {
                lines = File.ReadAllLines(progressFile);
            }
            catch
            {
                return;
            }

            for (int i = consumedLines; i < lines.Length; i++)
            {
                var line = lines[i];
                if (string.IsNullOrWhiteSpace(line))
                    continue;

                var sep = line.IndexOf('|');
                if (sep <= 0)
                    continue;

                var pctText = line.Substring(0, sep).Trim();
                var msg = line.Substring(sep + 1).Trim();

                if (int.TryParse(pctText, out var pct))
                {
                    splash.UpdateProgress(pct);
                }

                if (!string.IsNullOrWhiteSpace(msg))
                {
                    splash.UpdateStep(msg);
                }
            }

            consumedLines = lines.Length;
        }

        private static void OnDispatcherException(object sender, DispatcherUnhandledExceptionEventArgs e)
        {
            WinPeStartupLog.Write("DispatcherUnhandledException", e.Exception.ToString());
            LogCrash("DispatcherUnhandledException", e.Exception);
            e.Handled = true;
            var detail = e.Exception.InnerException is { } inner
                ? $"{e.Exception.Message}\n\n{inner.Message}"
                : e.Exception.Message;
            MessageBox.Show($"Unhandled error:\n\n{detail}\n\nSee toolkit_crash.log on Desktop for details.",
                "ToolkitGUI Error", MessageBoxButton.OK, MessageBoxImage.Error);
        }

        private static void OnDomainException(object sender, UnhandledExceptionEventArgs e)
        {
            WinPeStartupLog.Write("AppDomainUnhandledException", e.ExceptionObject?.ToString());
            LogCrash("AppDomainUnhandledException", e.ExceptionObject as Exception);
        }

        private static void LogCrash(string source, Exception? ex)
        {
            var line = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {source}: {ex}\n\n";
            foreach (var path in GetCrashLogPaths())
            {
                try
                {
                    var dir = Path.GetDirectoryName(path);
                    if (!string.IsNullOrEmpty(dir))
                        Directory.CreateDirectory(dir);
                    File.AppendAllText(path, line);
                }
                catch
                {
                    /* best-effort */
                }
            }
        }

        private static IEnumerable<string> GetCrashLogPaths()
        {
            var paths = new List<string>();

            try
            {
                var desktop = Environment.GetFolderPath(Environment.SpecialFolder.Desktop);
                if (!string.IsNullOrWhiteSpace(desktop))
                    paths.Add(Path.Combine(desktop, "toolkit_crash.log"));
            }
            catch { /* ignore */ }

            try
            {
                var toolkitRoot = ResolveToolkitRoot();
                if (!string.IsNullOrWhiteSpace(toolkitRoot))
                    paths.Add(Path.Combine(toolkitRoot, "CDE", "Runtime", "toolkit_crash.log"));
            }
            catch { /* ignore */ }

            paths.Add(@"X:\toolkit_crash.log");
            return paths;
        }

        private static string? ResolveToolkitRoot()
        {
            var toolkitRoot = Environment.GetEnvironmentVariable("TOOLKIT_ROOT");
            if (!string.IsNullOrWhiteSpace(toolkitRoot))
                return toolkitRoot;

            return TryFindToolkitRootFromBaseDirectory();
        }

        /// <summary>
        /// Loads CDE\Runtime\offline_env.txt (same keys WinPE_OfflineStartup.ps1 writes).
        /// </summary>
        private static string? NormalizeOfflineWindowsRoot(string? root)
        {
            if (string.IsNullOrWhiteSpace(root))
                return null;

            var trimmed = root.Trim();
            if (trimmed.Length == 2 && trimmed[1] == ':')
                trimmed += @"\";
            else if (trimmed.Length >= 2 && trimmed[1] == ':' && !trimmed.EndsWith(@"\", StringComparison.Ordinal))
                trimmed += @"\";

            return Directory.Exists(Path.Combine(trimmed, "Windows")) ? trimmed : null;
        }

        private static void TryApplyOfflineEnvFile()
        {
            var toolkitRoot = ResolveToolkitRoot();
            if (string.IsNullOrEmpty(toolkitRoot))
                return;

            var envFile = OfflineRuntimePaths.ResolveEnvFilePath(toolkitRoot);
            if (string.IsNullOrEmpty(envFile) || !File.Exists(envFile))
                return;

            try
            {
                foreach (var line in File.ReadAllLines(envFile))
                {
                    if (string.IsNullOrWhiteSpace(line) || line.TrimStart().StartsWith("#", StringComparison.Ordinal))
                        continue;
                    var idx = line.IndexOf('=');
                    if (idx <= 0)
                        continue;
                    var key = line[..idx].Trim();
                    var val = line[(idx + 1)..].Trim();
                    if (key.Length == 0)
                        continue;

                    if (key.Equals("OFFLINE_WINDOWS_ROOT", StringComparison.OrdinalIgnoreCase))
                        val = NormalizeOfflineWindowsRoot(val) ?? val;

                    Environment.SetEnvironmentVariable(key, val, EnvironmentVariableTarget.Process);
                }
            }
            catch
            {
                /* non-fatal */
            }

            OfflineRuntimePaths.SyncOfflineRegistryLoadedEnv();
        }

        private static void LoadRuntimeConfig()
        {
            string? toolkitRoot = Environment.GetEnvironmentVariable("TOOLKIT_ROOT");
            if (string.IsNullOrWhiteSpace(toolkitRoot))
            {
                toolkitRoot = TryFindToolkitRootFromBaseDirectory();
            }

            RuntimeConfigContext.Load(toolkitRoot);
            Environment.SetEnvironmentVariable("CDE_RUNTIME_SKIN", RuntimeConfigContext.Current.Skin, EnvironmentVariableTarget.Process);
            Environment.SetEnvironmentVariable("CDE_RUNTIME_LANGUAGE", RuntimeConfigContext.Current.Language, EnvironmentVariableTarget.Process);
        }

        private static string? TryFindToolkitRootFromBaseDirectory()
        {
            var dir = new DirectoryInfo(AppDomain.CurrentDomain.BaseDirectory);
            while (dir != null)
            {
                if (Directory.Exists(Path.Combine(dir.FullName, "Scripts")) &&
                    Directory.Exists(Path.Combine(dir.FullName, "Config")))
                {
                    return dir.FullName;
                }
                dir = dir.Parent;
            }
            return null;
        }
    }
}

