using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ToolkitGUI.Services
{
    /// <summary>
    /// Loads EnvironmentCapabilityMatrix.json and resolves support for the active environment.
    /// </summary>
    internal static class EnvironmentCapabilityService
    {
        private static readonly object CacheLock = new();
        private static JsonObject? _matrix;
        private static string? _matrixPath;

        private static JsonObject LoadMatrix()
        {
            lock (CacheLock)
            {
                var path = ToolkitPaths.GetEnvironmentCapabilityMatrixPath();
                if (_matrix != null && string.Equals(_matrixPath, path, StringComparison.OrdinalIgnoreCase))
                    return _matrix;

                if (!File.Exists(path))
                    throw new FileNotFoundException("Environment capability matrix not found.", path);

                var root = JsonNode.Parse(File.ReadAllText(path)) as JsonObject
                    ?? throw new InvalidOperationException("Capability matrix root must be an object.");
                _matrix = root;
                _matrixPath = path;
                return _matrix;
            }
        }

        public static string GetActiveColumn()
        {
            if (IsWinPe())
            {
                var offline = Environment.GetEnvironmentVariable("OFFLINE_WINDOWS_ROOT");
                if (!string.IsNullOrWhiteSpace(offline))
                    return "winpe_offline";
                return "winpe_online";
            }

            try
            {
                if (Environment.OSVersion.Version.Build >= 22000)
                    return "live_win11";
            }
            catch
            {
                // ignore
            }

            return "live_win10";
        }

        public static bool IsActionSupported(string workflow, string action = "Run")
        {
            var value = GetCapabilityValue(workflow, action);
            return value switch
            {
                "na" => false,
                "requires_elevation" => IsElevated(),
                "requires_offline_registry" => IsOfflineRegistryLoaded(),
                "offline_registry" => !IsWinPe() || IsOfflineRegistryLoaded(),
                _ => true
            };
        }

        public static string GetUnavailableReason(string workflow, string action = "Run")
        {
            var value = GetCapabilityValue(workflow, action);
            var column = GetActiveColumn();
            return value switch
            {
                "na" => $"{workflow} is not available in {column.Replace('_', ' ')}.",
                "requires_elevation" => $"{workflow} requires administrator elevation.",
                "requires_offline_registry" => $"{workflow} requires offline registry hives to be loaded.",
                "offline_registry" when IsWinPe() && !IsOfflineRegistryLoaded() =>
                    $"{workflow} requires offline registry hives in WinPE.",
                _ => string.Empty
            };
        }

        private static string GetCapabilityValue(string workflow, string action)
        {
            var matrix = LoadMatrix();
            if (matrix["workflows"] is not JsonObject workflows)
                return "supported";

            if (!workflows.TryGetPropertyValue(workflow, out var workflowNode) || workflowNode is not JsonObject workflowObj)
                return "supported";

            if (workflowObj["actions"] is not JsonObject actions)
                return "supported";

            if (!actions.TryGetPropertyValue(action, out var actionNode))
            {
                if (!actions.TryGetPropertyValue("Run", out actionNode))
                    return "supported";
            }

            if (actionNode is not JsonObject actionMap)
                return "supported";

            var column = GetActiveColumn();
            if (actionMap.TryGetPropertyValue(column, out var valueNode))
                return valueNode?.GetValue<string>() ?? "supported";

            return "supported";
        }

        private static bool IsWinPe()
        {
            try
            {
                if (string.Equals(Environment.GetEnvironmentVariable("SystemDrive"), "X:", StringComparison.OrdinalIgnoreCase))
                    return true;
                if (Environment.GetEnvironmentVariable("WINPE") == "1")
                    return true;
            }
            catch
            {
                // ignore
            }

            return false;
        }

        private static bool IsOfflineRegistryLoaded()
            => string.Equals(Environment.GetEnvironmentVariable("OFFLINE_REGISTRY_LOADED"), "1", StringComparison.Ordinal);

        private static bool IsElevated()
        {
            try
            {
                using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
                var principal = new System.Security.Principal.WindowsPrincipal(identity);
                return principal.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
            }
            catch
            {
                return true;
            }
        }
    }
}
