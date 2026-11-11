using System;
using System.IO;

namespace ToolkitGUI
{
    /// <summary>
    /// Resolves Toolkit layout from TOOLKIT_ROOT, or by walking up from the exe until Scripts\Core is found.
    /// Supports standardized Release layout and TOOLKIT_ROOT deployments.
    /// </summary>
    internal static class ToolkitPaths
    {
        internal static string GetScriptsRoot()
        {
            var fromEnv = TryScriptsRootFromToolkitRoot();
            if (!string.IsNullOrEmpty(fromEnv))
                return fromEnv;

            var ascendant = FindToolkitRootDirectory(AppDomain.CurrentDomain.BaseDirectory);
            if (!string.IsNullOrEmpty(ascendant))
                return Path.Combine(ascendant, "Scripts");

            return Path.GetFullPath(Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory,
                "..", "..", "..", "..", "..", "Scripts"));
        }

        internal static string GetWorkflowScriptPath(string scriptFileName)
            => Path.Combine(GetScriptsRoot(), "Workflows", scriptFileName);

        internal static string GetToolkitRoot()
            => Path.GetFullPath(Path.Combine(GetScriptsRoot(), ".."));

        internal static string GetLogsRoot()
        {
            var logsDir = Path.Combine(GetToolkitRoot(), "Logs");
            Directory.CreateDirectory(logsDir);
            return logsDir;
        }

        internal static string GetUserGuidePath()
        {
            var rootPath = Path.Combine(GetToolkitRoot(), "CDE_User_Guide.pdf");
            if (File.Exists(rootPath))
                return rootPath;

            return Path.Combine(GetToolkitRoot(), "HALP", "CDE_User_Guide.pdf");
        }

        internal static string GetHealthCheckCatalogPath()
            => Path.Combine(GetToolkitRoot(), "Config", "HealthCheckCatalog.json");

        internal static string GetSymptomFlowsPath()
            => Path.Combine(GetToolkitRoot(), "Config", "SymptomFlows.json");

        internal static string GetEnvironmentCapabilityMatrixPath()
            => Path.Combine(GetToolkitRoot(), "Config", "EnvironmentCapabilityMatrix.json");

        internal static string GetVersionManifestPath()
            => Path.Combine(GetToolkitRoot(), "VERSION.json");

        internal static string GetHardwareTestCatalogPath()
            => Path.Combine(GetToolkitRoot(), "Config", "HardwareTestCatalog.json");

        private static string? TryScriptsRootFromToolkitRoot()
        {
            var tr = Environment.GetEnvironmentVariable("TOOLKIT_ROOT");
            if (string.IsNullOrEmpty(tr))
                return null;
            var scripts = Path.Combine(tr.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar), "Scripts");
            return Directory.Exists(scripts) ? scripts : null;
        }

        private static string? FindToolkitRootDirectory(string startDir)
        {
            try
            {
                var probe = new DirectoryInfo(Path.GetFullPath(startDir));
                for (var i = 0; i < 14 && probe != null; i++)
                {
                    var coreMarker = Path.Combine(probe.FullName, "Scripts", "Core", "Toolkit.Core.psm1");
                    if (File.Exists(coreMarker))
                        return probe.FullName;
                    probe = probe.Parent;
                }
            }
            catch
            {
                /* ignore */
            }

            return null;
        }
    }
}
