using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace ToolkitGUI.Services
{
    internal sealed class ResultLogCleanupResult
    {
        public IReadOnlyList<string> ClearedPaths { get; init; } = Array.Empty<string>();
        public IReadOnlyList<string> MissingPaths { get; init; } = Array.Empty<string>();
        public int FilesDeleted { get; init; }
        public int DirectoriesDeleted { get; init; }
        public IReadOnlyList<string> Errors { get; init; } = Array.Empty<string>();
    }

    /// <summary>
    /// Clears operator PDFs (Logs), internal CDE/Runtime/Data (JSON, session logs), and CHU UEFI folders.
    /// Work order case JSON under CDE/Runtime/WorkOrders is cleared from the Dashboard (Clear Recent).
    /// </summary>
    internal static class ResultLogCleanupService
    {
        internal static IReadOnlyList<string> GetTargetPaths()
        {
            var paths = new List<string>();
            paths.AddRange(FindCoreDiagDirectories("Logs"));
            paths.AddRange(FindCoreDiagDirectories("Results"));
            paths.Add(ToolkitPaths.GetLogsRoot());
            paths.Add(ReportPathHelper.GetInternalDataRoot());
            return paths
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .OrderBy(p => p, StringComparer.OrdinalIgnoreCase)
                .ToList();
        }

        internal static ResultLogCleanupResult ClearAll()
        {
            var cleared = new List<string>();
            var missing = new List<string>();
            var errors = new List<string>();
            var filesDeleted = 0;
            var dirsDeleted = 0;

            foreach (var path in GetTargetPaths())
            {
                if (!Directory.Exists(path))
                {
                    missing.Add(path);
                    continue;
                }

                var (files, dirs, pathErrors) = ClearDirectoryContents(path);
                cleared.Add(path);
                filesDeleted += files;
                dirsDeleted += dirs;
                errors.AddRange(pathErrors);
            }

            return new ResultLogCleanupResult
            {
                ClearedPaths = cleared,
                MissingPaths = missing,
                FilesDeleted = filesDeleted,
                DirectoriesDeleted = dirsDeleted,
                Errors = errors
            };
        }

        private static IEnumerable<string> FindCoreDiagDirectories(string subFolder)
        {
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            foreach (var drive in DriveInfo.GetDrives())
            {
                string root;
                try
                {
                    if (!drive.IsReady)
                        continue;
                    root = drive.RootDirectory.FullName;
                }
                catch
                {
                    continue;
                }

                var path = Path.Combine(root, "EFI", "CoreDiag", subFolder);
                if (Directory.Exists(path) && seen.Add(path))
                    yield return path;
            }

            var toolkitPath = Path.Combine(ToolkitPaths.GetToolkitRoot(), "EFI", "CoreDiag", subFolder);
            if (Directory.Exists(toolkitPath) && seen.Add(toolkitPath))
                yield return toolkitPath;
        }

        private static (int FilesDeleted, int DirectoriesDeleted, List<string> Errors) ClearDirectoryContents(string directoryPath)
        {
            var filesDeleted = 0;
            var dirsDeleted = 0;
            var errors = new List<string>();

            foreach (var file in Directory.EnumerateFiles(directoryPath))
            {
                try
                {
                    File.SetAttributes(file, FileAttributes.Normal);
                    File.Delete(file);
                    filesDeleted++;
                }
                catch (Exception ex)
                {
                    errors.Add($"{file}: {ex.Message}");
                }
            }

            foreach (var dir in Directory.EnumerateDirectories(directoryPath))
            {
                try
                {
                    Directory.Delete(dir, recursive: true);
                    dirsDeleted++;
                }
                catch (Exception ex)
                {
                    errors.Add($"{dir}: {ex.Message}");
                }
            }

            return (filesDeleted, dirsDeleted, errors);
        }
    }
}
