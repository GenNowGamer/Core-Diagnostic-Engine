using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using ToolkitGUI.Models;

namespace ToolkitGUI.Services
{
    internal static class WorkflowStepLabelHelper
    {
        private static readonly object CatalogLock = new();
        private static Dictionary<string, string>? _catalogLabels;
        private static bool _catalogLoadAttempted;

        public static string ResolveDisplayTitle(WorkflowExecutionStep step, string? workflowName = null)
        {
            if (step == null)
            {
                return "Step";
            }

            var catalogLabel = TryGetCatalogLabel(step.CheckId);
            if (!string.IsNullOrWhiteSpace(catalogLabel))
            {
                return catalogLabel;
            }

            if (!string.IsNullOrWhiteSpace(step.Name))
            {
                var fromWorkflow = TryExtractTitleFromWorkflowName(workflowName, step.Name);
                if (!string.IsNullOrWhiteSpace(fromWorkflow))
                {
                    return fromWorkflow;
                }

                return FormatStepName(step.Name);
            }

            return "Step";
        }

        public static bool ShouldRepeatTestLabelOnItems(string? workflowName)
            => string.Equals(workflowName, "SystemHealthCheck", StringComparison.OrdinalIgnoreCase);

        private static string? TryGetCatalogLabel(string? checkId)
        {
            if (string.IsNullOrWhiteSpace(checkId))
            {
                return null;
            }

            EnsureCatalogLoaded();
            if (_catalogLabels != null
                && _catalogLabels.TryGetValue(checkId.Trim(), out var label)
                && !string.IsNullOrWhiteSpace(label))
            {
                return label;
            }

            return null;
        }

        private static void EnsureCatalogLoaded()
        {
            lock (CatalogLock)
            {
                if (_catalogLoadAttempted)
                {
                    return;
                }

                _catalogLoadAttempted = true;
                _catalogLabels = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

                try
                {
                    var path = ToolkitPaths.GetHealthCheckCatalogPath();
                    if (!File.Exists(path))
                    {
                        return;
                    }

                    using var doc = JsonDocument.Parse(File.ReadAllText(path));
                    if (!doc.RootElement.TryGetProperty("categories", out var categories)
                        || categories.ValueKind != JsonValueKind.Array)
                    {
                        return;
                    }

                    foreach (var category in categories.EnumerateArray())
                    {
                        if (!category.TryGetProperty("checks", out var checks)
                            || checks.ValueKind != JsonValueKind.Array)
                        {
                            continue;
                        }

                        foreach (var check in checks.EnumerateArray())
                        {
                            var id = check.TryGetProperty("id", out var idEl) ? idEl.GetString() : null;
                            var label = check.TryGetProperty("label", out var labelEl) ? labelEl.GetString() : null;
                            if (!string.IsNullOrWhiteSpace(id) && !string.IsNullOrWhiteSpace(label))
                            {
                                _catalogLabels[id] = label;
                            }
                        }
                    }
                }
                catch
                {
                    _catalogLabels = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                }
            }
        }

        private static string? TryExtractTitleFromWorkflowName(string? workflowName, string stepName)
        {
            if (string.IsNullOrWhiteSpace(workflowName))
            {
                return null;
            }

            if (!workflowName.StartsWith("SystemAudit_", StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }

            var suffix = workflowName["SystemAudit_".Length..];
            if (string.Equals(suffix, stepName, StringComparison.OrdinalIgnoreCase)
                || string.Equals(suffix, "All", StringComparison.OrdinalIgnoreCase))
            {
                return FormatStepName(stepName);
            }

            return FormatStepName(suffix);
        }

        private static string FormatStepName(string? value)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return string.Empty;
            }

            var trimmed = value.Trim().Replace('_', ' ');
            return Regex.Replace(trimmed, "([a-z])([A-Z])", "$1 $2");
        }
    }
}
