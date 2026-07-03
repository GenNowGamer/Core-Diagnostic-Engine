using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using ToolkitGUI;
using System.Runtime.InteropServices;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json;
using System.Text.Json;
using ToolkitGUI.Services;

namespace ToolkitGUI.ViewModels
{
    public sealed class PowerShellExecutionResult
    {
        public bool Success { get; init; }
        public string Output { get; init; } = string.Empty;
        public string Error { get; init; } = string.Empty;
        public string ExceptionMessage { get; init; } = string.Empty;
    }

    /// <summary>
    /// Result of running a workflow script via powershell.exe. The non-zero
    /// <see cref="ExitCode"/> is an automation backstop; callers should still load
    /// the structured JSON report rather than treating it as a hard failure.
    /// </summary>
    public sealed record WorkflowProcessResult(string Stdout, string Stderr, int ExitCode);

    public class SystemInfo
    {
        public string MachineName { get; set; } = Environment.MachineName;
        public string OsVersion { get; set; } = string.Empty;
        public double CpuUsage { get; set; }
        public double RamUsage { get; set; }
        public string SmartSummary { get; set; } = "Unknown";
        public string EnvironmentMode { get; set; } = "Windows Mode";
        public string Uptime { get; set; } = string.Empty;
    }

    public static class PowerShellService
    {
        private static string ScriptsRoot => ToolkitPaths.GetScriptsRoot();

        [StructLayout(LayoutKind.Sequential)]
        private struct MEMORYSTATUSEX
        {
            public uint dwLength;
            public uint dwMemoryLoad;
            public ulong ullTotalPhys;
            public ulong ullAvailPhys;
            public ulong ullTotalPageFile;
            public ulong ullAvailPageFile;
            public ulong ullTotalVirtual;
            public ulong ullAvailVirtual;
            public ulong ullAvailExtendedVirtual;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);

        private static double GetCpuUsage()
        {
            try
            {
                using var cpuCounter = new PerformanceCounter("Processor", "% Processor Time", "_Total", true);
                _ = cpuCounter.NextValue();
                Thread.Sleep(250);
                var value = cpuCounter.NextValue();
                if (double.IsNaN(value) || double.IsInfinity(value))
                    return 0;
                return Math.Clamp(value, 0, 100);
            }
            catch
            {
                return 0;
            }
        }

        private static double GetRamUsage()
        {
            try
            {
                var mem = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf<MEMORYSTATUSEX>() };
                if (!GlobalMemoryStatusEx(ref mem) || mem.ullTotalPhys == 0)
                    return 0;

                var usedPct = (1.0 - (double)mem.ullAvailPhys / mem.ullTotalPhys) * 100.0;
                if (double.IsNaN(usedPct) || double.IsInfinity(usedPct))
                    return 0;
                return Math.Clamp(Math.Round(usedPct, 1), 0, 100);
            }
            catch
            {
                return 0;
            }
        }

        private static string GetUptime()
        {
            try
            {
                return BootUptimeHelper.GetBannerUptimeDisplay();
            }
            catch
            {
                return string.Empty;
            }
        }

        private static string _smartCache = "Unknown";
        private static DateTime _smartCacheTime = DateTime.MinValue;
        private static readonly object _smartCacheLock = new();

        private static TimeSpan GetWorkflowTimeout()
        {
            try
            {
                var settingsPath = Path.Combine(ToolkitPaths.GetToolkitRoot(), "Config", "settings.json");
                if (File.Exists(settingsPath))
                {
                    using var doc = JsonDocument.Parse(File.ReadAllText(settingsPath));
                    if (doc.RootElement.TryGetProperty("WorkflowTimeoutMinutes", out var minutesProp)
                        && minutesProp.TryGetInt32(out var minutes)
                        && minutes > 0)
                    {
                        return TimeSpan.FromMinutes(minutes);
                    }
                }
            }
            catch
            {
                // ignore
            }

            return TimeSpan.FromMinutes(120);
        }

        private static async Task<T> RunWithTimeoutAsync<T>(
            Func<CancellationToken, T> work,
            CancellationToken cancellationToken)
        {
            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeoutCts.CancelAfter(GetWorkflowTimeout());

            var task = Task.Run(() => work(timeoutCts.Token), timeoutCts.Token);
            try
            {
                return await task.ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                throw new TimeoutException(
                    $"PowerShell operation exceeded {GetWorkflowTimeout().TotalMinutes:0} minute workflow timeout.");
            }
        }

        private static string GetSmartSummary()
        {
            lock (_smartCacheLock)
            {
                if ((DateTime.UtcNow - _smartCacheTime).TotalSeconds < 60)
                    return _smartCache;
            }

            try
            {
                var scriptPath = ToolkitPaths.GetWorkflowScriptPath("SmartAnalyzer.ps1");

                // Use the same proven runspace path as the dedicated SMART Analyzer
                // (QueryAsync sets execution policy bypass and opens an explicit runspace).
                var (json, _) = QueryAsync($"& '{scriptPath}' -Mode Query")
                    .GetAwaiter().GetResult();

                if (!string.IsNullOrWhiteSpace(json))
                {
                    using var doc = JsonDocument.Parse(json);
                    if (doc.RootElement.TryGetProperty("Drives", out var drives))
                    {
                        bool anyFail = false, anyWarn = false, anySupported = false, anyDrive = false;
                        string? ioctlHint = null;
                        foreach (var d in drives.EnumerateArray())
                        {
                            anyDrive = true;
                            if (d.TryGetProperty("Overall", out var overall))
                            {
                                var s = overall.GetString() ?? string.Empty;
                                if (s.Equals("Fail", StringComparison.OrdinalIgnoreCase)) anyFail = true;
                                else if (s.Equals("Warn", StringComparison.OrdinalIgnoreCase)) anyWarn = true;
                            }
                            if (d.TryGetProperty("Supported", out var sup) && sup.GetBoolean())
                                anySupported = true;
                            else if (ioctlHint == null && d.TryGetProperty("Detail", out var detailProp))
                                ioctlHint = detailProp.GetString();
                        }

                        var summary = anyFail ? "Critical"
                            : anyWarn ? "Warning"
                            : anySupported ? "Healthy"
                            : anyDrive
                                ? "Unavailable (SMART IOCTL blocked — try internal SATA or vendor tool)"
                                : "Unavailable (no drives reported)";
                        lock (_smartCacheLock)
                        {
                            _smartCache = summary;
                            _smartCacheTime = DateTime.UtcNow;
                        }
                        return summary;
                    }
                }
            }
            catch
            {
                // Best-effort only.
            }

            return "Unknown";
        }

        public static async Task<SystemInfo> GetSystemInfoAsync()
        {
            return await Task.Run(() =>
            {
                return new SystemInfo
                {
                    MachineName = Environment.MachineName,
                    OsVersion = Environment.OSVersion.VersionString,
                    CpuUsage = GetCpuUsage(),
                    RamUsage = GetRamUsage(),
                    SmartSummary = GetSmartSummary(),
                    EnvironmentMode = TestIsWinPe() ? "WinPE Mode" : "Windows Mode",
                    Uptime = GetUptime()
                };
            });
        }

        private static bool TestIsWinPe()
        {
            try
            {
                return Environment.GetEnvironmentVariable("SystemDrive")?.Equals("X:", StringComparison.OrdinalIgnoreCase) == true
                    || Environment.GetEnvironmentVariable("WINPE") == "1"
                    || Environment.GetEnvironmentVariable("PEINSTALL") == "1";
            }
            catch
            {
                return false;
            }
        }

        public static async Task<WorkflowProcessResult> RunWorkflowAsync(
            string scriptPath,
            string? parameters,
            CancellationToken cancellationToken,
            Action<string>? onOutput)
        {
            var sb = new StringBuilder();
            var errSb = new StringBuilder();

            // Use powershell.exe (Windows PowerShell 5.1) so all built-in modules
            // (CimCmdlets, NetTCPIP, etc.) are available without module-path issues
            // that affect the PS7 SDK in a self-contained publish.
            WorkOrderService.ApplyActiveCaseToProcess();

            string args = $"-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{scriptPath}\"";
            if (!string.IsNullOrEmpty(parameters))
                args += $" {parameters}";

            var psi = new System.Diagnostics.ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = args,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
                StandardOutputEncoding = System.Text.Encoding.UTF8,
                StandardErrorEncoding = System.Text.Encoding.UTF8
            };

            foreach (var envName in new[] { "TOOLKIT_ROOT", "OFFLINE_WINDOWS_ROOT", "OFFLINE_REGISTRY_LOADED", "OFFLINE_DRIVERS_LOADED" })
            {
                var value = Environment.GetEnvironmentVariable(envName);
                if (!string.IsNullOrWhiteSpace(value))
                    psi.Environment[envName] = value;
            }

            psi.Environment["TOOLKIT_ROOT"] = ToolkitPaths.GetToolkitRoot();

            using var process = new System.Diagnostics.Process { StartInfo = psi, EnableRaisingEvents = true };
            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeoutCts.CancelAfter(GetWorkflowTimeout());
            var effectiveToken = timeoutCts.Token;

            using var cancellationRegistration = effectiveToken.Register(() =>
            {
                try
                {
                    if (!process.HasExited)
                    {
                        process.Kill(entireProcessTree: true);
                    }
                }
                catch
                {
                    // Best-effort kill on cancellation.
                }
            });

            process.OutputDataReceived += (s, e) =>
            {
                if (e.Data == null) return;
                onOutput?.Invoke(e.Data);
                sb.AppendLine(e.Data);
            };
            process.ErrorDataReceived += (s, e) =>
            {
                if (e.Data == null) return;
                // Suppress the noisy PS unapproved-verbs warning that is cosmetic only
                if (e.Data.Contains("unapproved verbs")) return;
                onOutput?.Invoke($"[WARN] {e.Data}");
                errSb.AppendLine(e.Data);
            };

            process.Start();
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            try
            {
                await process.WaitForExitAsync(effectiveToken);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                try
                {
                    if (!process.HasExited)
                    {
                        process.Kill(entireProcessTree: true);
                    }
                }
                catch
                {
                    // Best-effort kill on timeout.
                }

                return new WorkflowProcessResult(
                    sb.ToString().Trim(),
                    $"Workflow timed out after {GetWorkflowTimeout().TotalMinutes:0} minutes.",
                    -2);
            }
            catch (OperationCanceledException)
            {
                try
                {
                    if (!process.HasExited)
                    {
                        process.Kill(entireProcessTree: true);
                    }
                }
                catch
                {
                    // Best-effort kill on cancellation.
                }
                throw;
            }

            if (process.ExitCode != 0)
            {
                var err = errSb.ToString().Trim();
                if (string.IsNullOrWhiteSpace(err))
                {
                    err = $"Workflow exited with code {process.ExitCode}.";
                }

                // Do NOT throw on a non-zero exit. The exit code is an automation
                // backstop; the structured JSON report (and any stderr) is the
                // authoritative result. Returning it lets the caller still load and
                // render the report instead of discarding stdout.
                return new WorkflowProcessResult(sb.ToString().Trim(), err, process.ExitCode);
            }

            return new WorkflowProcessResult(sb.ToString().Trim(), errSb.ToString().Trim(), process.ExitCode);
        }

        /// <summary>
        /// Run an inline PowerShell script and return the raw output string.
        /// Useful for JSON queries from interactive ViewModels.
        /// </summary>
        /// <summary>
        /// Run an inline PowerShell script and return the raw output string.
        /// Returns "QUERY_ERROR: ..." on failure so callers can surface diagnostics.
        /// </summary>
        public static Task<(string Output, string Error)> QueryAsync(string script)
            => QueryAsync(script, CancellationToken.None);

        public static async Task<(string Output, string Error)> QueryAsync(string script, CancellationToken cancellationToken)
        {
            try
            {
                return await RunWithTimeoutAsync(ct =>
                {
                    ct.ThrowIfCancellationRequested();
                    using var runspace = RunspaceFactory.CreateRunspace(InitialSessionState.CreateDefault());
                    runspace.Open();
                    using var ps = PowerShell.Create();
                    ps.Runspace = runspace;
                    ps.AddScript("Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force; $InformationPreference = 'Continue'").Invoke();
                    ps.Commands.Clear();
                    ps.AddScript(script);
                    var results = ps.Invoke();

                    var errSb = new StringBuilder();
                    foreach (var e in ps.Streams.Error)
                        errSb.AppendLine(e.ToString());

                    var sb = new StringBuilder();
                    foreach (var r in results)
                        if (r?.BaseObject != null) sb.AppendLine(r.ToString());

                    return (sb.ToString().Trim(), errSb.ToString().Trim());
                }, cancellationToken).ConfigureAwait(false);
            }
            catch (TimeoutException ex)
            {
                return (string.Empty, $"TIMEOUT: {ex.Message}");
            }
            catch (OperationCanceledException)
            {
                return (string.Empty, "CANCELLED: Query was cancelled.");
            }
            catch (Exception ex)
            {
                return (string.Empty, $"EXCEPTION: {ex.GetType().Name}: {DescribeException(ex)}");
            }
        }

        private static string DescribeException(Exception ex)
        {
            if (!string.IsNullOrWhiteSpace(ex.Message))
                return ex.Message.Trim();

            if (ex.InnerException != null && !string.IsNullOrWhiteSpace(ex.InnerException.Message))
                return ex.InnerException.Message.Trim();

            return ex.ToString().Trim();
        }

        /// <summary>
        /// Run an inline PowerShell script with no return value (fire-and-forget action).
        /// </summary>
        public static Task<PowerShellExecutionResult> ExecuteAsync(string script)
            => ExecuteAsync(script, CancellationToken.None);

        public static async Task<PowerShellExecutionResult> ExecuteAsync(string script, CancellationToken cancellationToken)
        {
            try
            {
                return await RunWithTimeoutAsync(ct =>
                {
                    ct.ThrowIfCancellationRequested();
                    using var runspace = RunspaceFactory.CreateRunspace(InitialSessionState.CreateDefault());
                    runspace.Open();
                    using var ps = PowerShell.Create();
                    ps.Runspace = runspace;
                    ps.AddScript("Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force; $ErrorActionPreference = 'Stop'").Invoke();
                    ps.Commands.Clear();
                    ps.AddScript(script);
                    var results = ps.Invoke();

                    var outputSb = new StringBuilder();
                    foreach (var r in results)
                        if (r?.BaseObject != null) outputSb.AppendLine(r.ToString());

                    var errSb = new StringBuilder();
                    foreach (var e in ps.Streams.Error)
                        errSb.AppendLine(e.ToString());

                    if (ps.HadErrors)
                    {
                        return new PowerShellExecutionResult
                        {
                            Success = false,
                            Output = outputSb.ToString().Trim(),
                            Error = errSb.ToString().Trim()
                        };
                    }

                    return new PowerShellExecutionResult
                    {
                        Success = true,
                        Output = outputSb.ToString().Trim(),
                        Error = errSb.ToString().Trim()
                    };
                }, cancellationToken).ConfigureAwait(false);
            }
            catch (TimeoutException ex)
            {
                return new PowerShellExecutionResult
                {
                    Success = false,
                    Error = $"TIMEOUT: {ex.Message}"
                };
            }
            catch (OperationCanceledException)
            {
                return new PowerShellExecutionResult
                {
                    Success = false,
                    Error = "CANCELLED: Script execution was cancelled."
                };
            }
            catch (Exception ex)
            {
                return new PowerShellExecutionResult
                {
                    Success = false,
                    ExceptionMessage = $"{ex.GetType().Name}: {ex.Message}"
                };
            }
        }
    }
}
