using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace ToolkitGUI.Services
{
    /// <summary>
    /// Internal work order JSON lives under CDE/Runtime/WorkOrders.
    /// Operator-facing closed-case PDFs live under Toolkit/WorkOrders.
    /// </summary>
    internal static class WorkOrderPathHelper
    {
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

        internal static string GetInternalJsonPath(string caseId)
            => Path.Combine(GetInternalWorkOrdersDirectory(), $"{caseId}.json");

        internal static string GetLegacyInternalJsonPath(string caseId)
            => Path.Combine(GetToolkitRoot(), "WorkOrders", $"{caseId}.json");

        internal static string GetOperatorPdfPath(string caseId)
            => Path.Combine(GetOperatorWorkOrdersDirectory(), $"{caseId}.pdf");

        internal static string ResolveInternalJsonPath(string caseId)
        {
            if (string.IsNullOrWhiteSpace(caseId))
                return string.Empty;

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
            if (!string.IsNullOrWhiteSpace(storedPdfPath) && File.Exists(storedPdfPath))
                return storedPdfPath;

            if (string.IsNullOrWhiteSpace(caseId))
                return string.Empty;

            var canonical = GetOperatorPdfPath(caseId);
            if (File.Exists(canonical))
                return canonical;

            var dir = GetOperatorWorkOrdersDirectory();
            if (!Directory.Exists(dir))
                return string.Empty;

            var stamped = Directory.GetFiles(dir, $"{caseId}_Final_*.pdf")
                .OrderByDescending(File.GetLastWriteTimeUtc)
                .FirstOrDefault();
            return stamped ?? string.Empty;
        }

        internal static bool IsCanonicalWorkOrderFile(string fileName)
        {
            if (!fileName.EndsWith(".json", StringComparison.OrdinalIgnoreCase))
                return false;
            if (fileName.Contains("_Final_", StringComparison.OrdinalIgnoreCase))
                return false;
            return fileName.Count(c => c == '-') >= 2;
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

                    if (seen.Add(file))
                        yield return file;
                }
            }
        }
    }
}
