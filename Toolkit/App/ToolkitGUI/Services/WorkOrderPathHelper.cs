using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace ToolkitGUI.Services
{
    /// <summary>
    /// Internal work order JSON lives under CDE/Runtime/WorkOrders.
    /// Operator-facing closed-case PDFs live under Toolkit/WorkOrders.
    /// </summary>
    internal static class WorkOrderPathHelper
    {
        /// <summary>Matches CreateWorkOrder / Get-NextCaseId: PREFIX-yyyyMMdd-#####</summary>
        internal static readonly Regex CaseIdPattern = new(
            @"^[A-Za-z0-9]+-\d{8}-\d{5}$",
            RegexOptions.Compiled | RegexOptions.CultureInvariant);

        internal static string GetToolkitRoot()
        {
            var scriptsRoot = ToolkitPaths.GetScriptsRoot();
            var root = Directory.GetParent(scriptsRoot)?.FullName;
            if (string.IsNullOrWhiteSpace(root))
                throw new InvalidOperationException("Unable to resolve toolkit root.");
            return root;
        }

        internal static string GetRuntimeRoot()
        {
            var root = Path.Combine(GetToolkitRoot(), "CDE", "Runtime");
            Directory.CreateDirectory(root);
            return root;
        }

        internal static string GetInternalWorkOrdersDirectory()
        {
            var root = Path.Combine(GetRuntimeRoot(), "WorkOrders");
            Directory.CreateDirectory(root);
            return root;
        }

        internal static string GetOperatorWorkOrdersDirectory()
        {
            var root = Path.Combine(GetToolkitRoot(), "WorkOrders");
            Directory.CreateDirectory(root);
            return root;
        }

        internal static string GetActivePointerPath()
            => Path.Combine(GetRuntimeRoot(), "active_work_order.json");

        internal static bool IsValidCaseId(string? caseId)
        {
            if (string.IsNullOrWhiteSpace(caseId))
                return false;

            var trimmed = caseId.Trim();
            if (trimmed.IndexOfAny(new[] { '/', '\\' }) >= 0)
                return false;
            if (trimmed.Contains("..", StringComparison.Ordinal))
                return false;
            if (trimmed.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
                return false;

            return CaseIdPattern.IsMatch(trimmed);
        }

        internal static string RequireValidCaseId(string? caseId)
        {
            var trimmed = caseId?.Trim() ?? string.Empty;
            if (!IsValidCaseId(trimmed))
                throw new ArgumentException($"Invalid CaseId format: '{caseId}'.");
            return trimmed;
        }

        /// <summary>
        /// Ensures a resolved path stays under the internal or operator WorkOrders roots.
        /// </summary>
        internal static string AssertUnderWorkOrdersRoot(string path)
        {
            if (string.IsNullOrWhiteSpace(path))
                throw new InvalidOperationException("Work order path is empty.");

            var full = Path.GetFullPath(path);
            foreach (var rootDir in new[] { GetInternalWorkOrdersDirectory(), GetOperatorWorkOrdersDirectory() })
            {
                var rootFull = Path.GetFullPath(rootDir);
                if (IsPathUnderRoot(full, rootFull))
                    return full;
            }

            throw new InvalidOperationException($"Work order path escapes WorkOrders root: {full}");
        }

        internal static bool IsPathUnderRoot(string fullPath, string rootDirectory)
        {
            var full = Path.GetFullPath(fullPath);
            var root = Path.GetFullPath(rootDirectory);
            if (!root.EndsWith(Path.DirectorySeparatorChar) && !root.EndsWith(Path.AltDirectorySeparatorChar))
                root += Path.DirectorySeparatorChar;

            return full.StartsWith(root, StringComparison.OrdinalIgnoreCase)
                || string.Equals(full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                    root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                    StringComparison.OrdinalIgnoreCase);
        }

        internal static string GetInternalJsonPath(string caseId)
        {
            caseId = RequireValidCaseId(caseId);
            return AssertUnderWorkOrdersRoot(
                Path.Combine(GetInternalWorkOrdersDirectory(), $"{caseId}.json"));
        }

        internal static string GetLegacyInternalJsonPath(string caseId)
        {
            caseId = RequireValidCaseId(caseId);
            return AssertUnderWorkOrdersRoot(
                Path.Combine(GetToolkitRoot(), "WorkOrders", $"{caseId}.json"));
        }

        internal static string GetOperatorPdfPath(string caseId)
        {
            caseId = RequireValidCaseId(caseId);
            return AssertUnderWorkOrdersRoot(
                Path.Combine(GetOperatorWorkOrdersDirectory(), $"{caseId}.pdf"));
        }

        /// <summary>
        /// Resolves the work-order JSON path from CaseId under known roots.
        /// Does not trust caller-supplied absolute paths.
        /// </summary>
        internal static string ResolveInternalJsonPath(string caseId)
        {
            if (string.IsNullOrWhiteSpace(caseId))
                return string.Empty;

            caseId = RequireValidCaseId(caseId);

            var runtimePath = GetInternalJsonPath(caseId);
            if (File.Exists(runtimePath))
                return runtimePath;

            var legacyPath = GetLegacyInternalJsonPath(caseId);
            if (File.Exists(legacyPath))
                return legacyPath;

            return runtimePath;
        }

        internal static string ResolveOperatorPdfPath(string caseId, string? storedPdfPath = null)
        {
            // Prefer re-resolved canonical layout over stored absolute paths.
            if (!string.IsNullOrWhiteSpace(caseId) && IsValidCaseId(caseId))
            {
                var canonical = GetOperatorPdfPath(caseId);
                if (File.Exists(canonical))
                    return canonical;

                var dir = GetOperatorWorkOrdersDirectory();
                if (Directory.Exists(dir))
                {
                    var stamped = Directory.GetFiles(dir, $"{caseId}_Final_*.pdf")
                        .OrderByDescending(File.GetLastWriteTimeUtc)
                        .FirstOrDefault();
                    if (!string.IsNullOrWhiteSpace(stamped))
                        return AssertUnderWorkOrdersRoot(stamped);
                }
            }

            if (!string.IsNullOrWhiteSpace(storedPdfPath))
            {
                try
                {
                    var full = Path.GetFullPath(storedPdfPath);
                    if (File.Exists(full) && IsPathUnderRoot(full, GetOperatorWorkOrdersDirectory()))
                        return full;
                }
                catch
                {
                    // ignore untrusted stored path
                }
            }

            return string.Empty;
        }

        internal static bool IsCanonicalWorkOrderFile(string fileName)
        {
            if (!fileName.EndsWith(".json", StringComparison.OrdinalIgnoreCase))
                return false;
            if (fileName.Contains("_Final_", StringComparison.OrdinalIgnoreCase))
                return false;

            var caseId = Path.GetFileNameWithoutExtension(fileName);
            return IsValidCaseId(caseId);
        }

        internal static IEnumerable<string> EnumerateInternalWorkOrderJsonFiles()
        {
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            foreach (var dir in new[] { GetInternalWorkOrdersDirectory(), Path.Combine(GetToolkitRoot(), "WorkOrders") })
            {
                if (!Directory.Exists(dir))
                    continue;

                foreach (var file in Directory.GetFiles(dir, "*.json"))
                {
                    var name = Path.GetFileName(file);
                    if (!IsCanonicalWorkOrderFile(name))
                        continue;

                    var full = Path.GetFullPath(file);
                    if (!IsPathUnderRoot(full, dir))
                        continue;

                    if (seen.Add(full))
                        yield return full;
                }
            }
        }
    }
}
