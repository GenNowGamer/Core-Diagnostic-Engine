using System;
using System.IO;

namespace ToolkitGUI.Services
{
    /// <summary>
    /// Operator-facing PDFs live under Logs. Structured JSON for app plumbing lives under CDE/Runtime/Data.
    /// </summary>
    internal static class ReportPathHelper
    {
        internal static string GetInternalDataRoot()
        {
            var root = Path.Combine(ToolkitPaths.GetToolkitRoot(), "CDE", "Runtime", "Data");
            Directory.CreateDirectory(root);
            return root;
        }

        internal static string GetWorkflowDataRoot()
        {
            var root = Path.Combine(GetInternalDataRoot(), "workflows");
            Directory.CreateDirectory(root);
            return root;
        }

        internal static string GetScanDataRoot()
        {
            var root = Path.Combine(GetInternalDataRoot(), "scans");
            Directory.CreateDirectory(root);
            return root;
        }

        internal static string GetCstDataRoot()
        {
            var root = Path.Combine(GetInternalDataRoot(), "cst");
            Directory.CreateDirectory(root);
            return root;
        }

        internal static string GetSessionsDataRoot()
        {
            var root = Path.Combine(GetInternalDataRoot(), "sessions");
            Directory.CreateDirectory(root);
            return root;
        }

        /// <summary>Operator-facing deliverables only (PDF). Session logs and JSON live under CDE/Runtime/Data.</summary>
        internal static string GetOperatorLogsRoot() => ToolkitPaths.GetLogsRoot();

        internal static string GetOperatorPdfPath(string baseName)
        {
            foreach (var c in Path.GetInvalidFileNameChars())
            {
                baseName = baseName.Replace(c, '_');
            }

            return Path.Combine(GetOperatorLogsRoot(), $"{baseName}.pdf");
        }

        internal static string GetOperatorPdfPathForInternalJson(string? internalJsonPath)
        {
            if (string.IsNullOrWhiteSpace(internalJsonPath))
                return string.Empty;

            return GetOperatorPdfPath(Path.GetFileNameWithoutExtension(internalJsonPath));
        }

        internal static string ResolveOperatorPdf(string? reportPdf, string? reportJson, string? reportHtml)
        {
            if (!string.IsNullOrWhiteSpace(reportPdf) && File.Exists(reportPdf))
                return reportPdf;

            foreach (var sourcePath in new[] { reportJson, reportHtml })
            {
                if (string.IsNullOrWhiteSpace(sourcePath))
                    continue;

                var pdf = GetOperatorPdfPath(Path.GetFileNameWithoutExtension(sourcePath));
                if (File.Exists(pdf))
                    return pdf;
            }

            return string.Empty;
        }
    }
}
