using System;
using System.IO;

namespace ToolkitGUI
{
    /// <summary>
    /// WinPE session state under %TOOLKIT_ROOT%\CDE\Runtime (not toolkit root).
    /// </summary>
    internal static class OfflineRuntimePaths
    {
        internal const string RuntimeSubdir = "CDE\\Runtime";
        internal const string EnvFileName = "offline_env.txt";
        internal const string ProgressLogFileName = "offline_progress.log";
        internal const string ActiveWorkOrderFileName = "active_work_order.json";

        internal static string? GetRuntimeDirectory(string? toolkitRoot)
        {
            if (string.IsNullOrWhiteSpace(toolkitRoot))
                return null;

            return Path.Combine(toolkitRoot.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar), RuntimeSubdir);
        }

        internal static string? GetEnvFilePath(string? toolkitRoot)
        {
            var dir = GetRuntimeDirectory(toolkitRoot);
            return dir == null ? null : Path.Combine(dir, EnvFileName);
        }

        internal static string? GetProgressLogPath(string? toolkitRoot)
        {
            var dir = GetRuntimeDirectory(toolkitRoot);
            return dir == null ? null : Path.Combine(dir, ProgressLogFileName);
        }

        internal static string? GetLegacyEnvFilePath(string? toolkitRoot)
        {
            if (string.IsNullOrWhiteSpace(toolkitRoot))
                return null;

            return Path.Combine(toolkitRoot.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar), EnvFileName);
        }

        internal static string? GetLegacyProgressLogPath(string? toolkitRoot)
        {
            if (string.IsNullOrWhiteSpace(toolkitRoot))
                return null;

            return Path.Combine(toolkitRoot.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar), ProgressLogFileName);
        }

        internal static string? ResolveEnvFilePath(string? toolkitRoot)
        {
            var preferred = GetEnvFilePath(toolkitRoot);
            if (!string.IsNullOrEmpty(preferred) && File.Exists(preferred))
                return preferred;

            var legacy = GetLegacyEnvFilePath(toolkitRoot);
            if (!string.IsNullOrEmpty(legacy) && File.Exists(legacy))
                return legacy;

            return preferred;
        }

        internal static void EnsureRuntimeDirectory(string toolkitRoot)
        {
            var dir = GetRuntimeDirectory(toolkitRoot);
            if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
                Directory.CreateDirectory(dir);
        }

        internal static void ClearSessionFiles(string? toolkitRoot)
        {
            if (string.IsNullOrWhiteSpace(toolkitRoot))
                return;

            foreach (var path in new[] { GetLegacyEnvFilePath(toolkitRoot), GetLegacyProgressLogPath(toolkitRoot) })
            {
                if (!string.IsNullOrEmpty(path) && File.Exists(path))
                {
                    try { File.Delete(path); } catch { /* best-effort */ }
                }
            }

            var runtimeDir = GetRuntimeDirectory(toolkitRoot);
            if (string.IsNullOrEmpty(runtimeDir) || !Directory.Exists(runtimeDir))
                return;

            foreach (var sessionFile in new[] { EnvFileName, ProgressLogFileName })
            {
                var path = Path.Combine(runtimeDir, sessionFile);
                if (File.Exists(path))
                {
                    try { File.Delete(path); } catch { /* best-effort */ }
                }
            }
        }

        internal static bool IsOfflineSoftwareHiveLoaded()
        {
            try
            {
                using var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(
                    @"Offline_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon");
                return key != null;
            }
            catch
            {
                return false;
            }
        }

        internal static void SyncOfflineRegistryLoadedEnv()
        {
            var flagged = string.Equals(Environment.GetEnvironmentVariable("OFFLINE_REGISTRY_LOADED"), "1", StringComparison.OrdinalIgnoreCase);
            if (!flagged)
                return;

            if (IsOfflineSoftwareHiveLoaded())
                return;

            Environment.SetEnvironmentVariable("OFFLINE_REGISTRY_LOADED", null, EnvironmentVariableTarget.Process);
        }

        internal static void ClearOfflineProcessEnv()
        {
            Environment.SetEnvironmentVariable("OFFLINE_REGISTRY_LOADED", null, EnvironmentVariableTarget.Process);
            Environment.SetEnvironmentVariable("OFFLINE_WINDOWS_ROOT", null, EnvironmentVariableTarget.Process);
            Environment.SetEnvironmentVariable("OFFLINE_DRIVERS_LOADED", null, EnvironmentVariableTarget.Process);
        }
    }
}
