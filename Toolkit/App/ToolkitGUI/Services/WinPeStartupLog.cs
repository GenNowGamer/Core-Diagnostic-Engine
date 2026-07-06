using System;
using System.Collections.Generic;
using System.IO;

namespace ToolkitGUI.Services
{
    /// <summary>
    /// Breadcrumb log for WinPE boot-menu → MainWindow handoff. Survives silent process exit
    /// so field failures can be diagnosed from the USB (CDE\Runtime\winpe_startup.log).
    /// </summary>
    internal static class WinPeStartupLog
    {
        public static void Write(string step, string? detail = null)
        {
            var line = string.IsNullOrWhiteSpace(detail)
                ? $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] {step}"
                : $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] {step} | {detail}";

            foreach (var path in GetLogPaths())
            {
                try
                {
                    var dir = Path.GetDirectoryName(path);
                    if (!string.IsNullOrEmpty(dir))
                        Directory.CreateDirectory(dir);
                    File.AppendAllText(path, line + Environment.NewLine);
                }
                catch
                {
                    /* best-effort */
                }
            }
        }

        private static IEnumerable<string> GetLogPaths()
        {
            var paths = new List<string> { @"X:\winpe_startup.log" };

            try
            {
                var toolkitRoot = Environment.GetEnvironmentVariable("TOOLKIT_ROOT");
                if (!string.IsNullOrWhiteSpace(toolkitRoot))
                    paths.Add(Path.Combine(toolkitRoot.TrimEnd('\\'), "CDE", "Runtime", "winpe_startup.log"));
            }
            catch
            {
                /* ignore */
            }

            try
            {
                var dir = new DirectoryInfo(AppDomain.CurrentDomain.BaseDirectory);
                while (dir != null)
                {
                    if (Directory.Exists(Path.Combine(dir.FullName, "Scripts")) &&
                        Directory.Exists(Path.Combine(dir.FullName, "Config")))
                    {
                        paths.Add(Path.Combine(dir.FullName, "CDE", "Runtime", "winpe_startup.log"));
                        break;
                    }
                    dir = dir.Parent;
                }
            }
            catch
            {
                /* ignore */
            }

            return paths;
        }
    }
}
