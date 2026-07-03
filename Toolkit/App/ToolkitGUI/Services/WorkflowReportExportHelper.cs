using System;
using System.IO;
using System.Text.Json;
using ToolkitGUI.Models;

namespace ToolkitGUI.Services
{
    internal static class WorkflowReportExportHelper
    {
        public static bool TryExtractArtifactPath(string line, string marker, string extension, out string path)
        {
            path = string.Empty;
            if (string.IsNullOrWhiteSpace(line) || string.IsNullOrWhiteSpace(marker))
            {
                return false;
            }

            var idx = line.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
            if (idx < 0)
            {
                return false;
            }

            var candidate = line[(idx + marker.Length)..].Trim();
            if (candidate.StartsWith(':'))
            {
                candidate = candidate[1..].Trim();
            }

            if (!candidate.EndsWith(extension, StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            path = candidate.Trim().TrimEnd('\r');
            return !string.IsNullOrWhiteSpace(path);
        }

        public static string? TryExtractWorkflowJson(string? text)
        {
            if (string.IsNullOrWhiteSpace(text))
            {
                return null;
            }

            var trimmed = text.Trim();
            if (trimmed.StartsWith('{') && TryDeserializeReport(trimmed))
            {
                return trimmed;
            }

            var markerIdx = text.LastIndexOf("\"WorkflowName\"", StringComparison.Ordinal);
            if (markerIdx < 0)
            {
                return null;
            }

            var start = text.LastIndexOf('{', markerIdx);
            if (start < 0)
            {
                return null;
            }

            var depth = 0;
            for (var i = start; i < text.Length; i++)
            {
                switch (text[i])
                {
                    case '{':
                        depth++;
                        break;
                    case '}':
                        depth--;
                        if (depth == 0)
                        {
                            var slice = text.Substring(start, i - start + 1);
                            return TryDeserializeReport(slice) ? slice : null;
                        }
                        break;
                }
            }

            return null;
        }

        public static string GetLogsDirectory() => ReportPathHelper.GetOperatorLogsRoot();

        public static string BuildReportBaseName(WorkflowExecutionReport report)
        {
            var workflow = string.IsNullOrWhiteSpace(report.WorkflowName) ? "Workflow" : report.WorkflowName;
            foreach (var c in Path.GetInvalidFileNameChars())
            {
                workflow = workflow.Replace(c, '_');
            }

            var stamp = report.EndTime != default
                ? report.EndTime.ToLocalTime().ToString("yyyyMMdd_HHmmss")
                : DateTime.Now.ToString("yyyyMMdd_HHmmss");

            return $"{workflow}_{stamp}";
        }

        private static bool TryDeserializeReport(string json)
        {
            try
            {
                using var doc = JsonDocument.Parse(json);
                return doc.RootElement.ValueKind == JsonValueKind.Object
                    && doc.RootElement.TryGetProperty("WorkflowName", out _);
            }
            catch
            {
                return false;
            }
        }
    }
}
