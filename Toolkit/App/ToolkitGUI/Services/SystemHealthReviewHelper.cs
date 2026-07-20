using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
using ToolkitGUI.Models;
using ToolkitGUI.ViewModels;

namespace ToolkitGUI.Services
{
    internal static class SystemHealthReviewHelper
    {
        public static string ExtractHeadline(string? detail, string? status)
        {
            if (string.IsNullOrWhiteSpace(detail))
            {
                return IsIssueStatus(status)
                    ? "This check reported an issue."
                    : "This check completed successfully.";
            }

            var overview = WorkflowResultFormatter.BuildOverview(null, detail);
            if (!string.IsNullOrWhiteSpace(overview))
            {
                return overview.Length > 200 ? overview[..200] + "…" : overview;
            }

            var firstLine = detail.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
                .FirstOrDefault()?.Trim() ?? detail.Trim();

            if (firstLine.Length > 200)
                return firstLine[..200] + "…";

            return firstLine;
        }

        public static IReadOnlyList<StructuredResultItemViewModel> BuildAttentionItems(
            string? stepName,
            string? checkId,
            string? detail,
            string? status,
            IReadOnlyList<StructuredResultItemViewModel>? formattedItems = null)
        {
            // Startup Entry Audit already lists review items under "Needs review" in Detailed Results.
            // Skip the parallel Items-to-address list so each entry card appears once.
            if (IsStartupAuditStep(stepName, checkId))
            {
                return Array.Empty<StructuredResultItemViewModel>();
            }

            if (formattedItems != null && formattedItems.Count > 0)
            {
                var actionable = formattedItems
                    .Where(i => i.IsStructuredHealthFinding && IsAttentionWorthyStructuredItem(i))
                    .ToList();
                if (actionable.Count > 0)
                {
                    return actionable;
                }
            }

            if (!IsIssueStatus(status))
                return Array.Empty<StructuredResultItemViewModel>();

            if (IsUsbSmartLimitation(detail))
            {
                // ExpectedLimitation is informational — not an item to remediate.
                return Array.Empty<StructuredResultItemViewModel>();
            }

            var parserStepName = ResolveParserStepName(stepName, checkId);
            var structured = WorkflowViewModelBase.ExtractStructuredResultItems(parserStepName, detail).ToList();
            if (structured.Count > 0)
                return structured;

            return BuildFallbackAttentionItems(detail).ToList();
        }

        public static IReadOnlyList<HealthActionViewModel> BuildActions(
            HealthFindingViewModel finding,
            IEnumerable<HealthCheckRecommendationDto> rules)
        {
            if (!IsIssueStatus(finding.Status))
                return Array.Empty<HealthActionViewModel>();

            if (IsUsbSmartLimitation(finding.Detail))
                return Array.Empty<HealthActionViewModel>();

            var actions = new List<HealthActionViewModel>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            foreach (var rule in rules)
            {
                if (!string.Equals(rule.WhenCheckId, finding.CheckId, StringComparison.OrdinalIgnoreCase))
                    continue;

                if (rule.WhenStatus == null || rule.WhenStatus.Count == 0)
                    continue;

                if (!rule.WhenStatus.Any(s => string.Equals(s, finding.Status, StringComparison.OrdinalIgnoreCase)))
                    continue;

                if (rule.Actions is { Count: > 0 })
                {
                    foreach (var action in rule.Actions)
                    {
                        var vm = CreateAction(action);
                        if (vm != null && seen.Add(vm.Label))
                            actions.Add(vm);
                    }
                }
                else if (!string.IsNullOrWhiteSpace(rule.NavTarget))
                {
                    var label = GetCdeNavLabel(rule.NavTarget);
                    if (seen.Add(label))
                    {
                        var target = rule.NavTarget;
                        actions.Add(new HealthActionViewModel
                        {
                            Label = label,
                            IsExternal = false,
                            Command = new RelayCommand(() =>
                            {
                                NavigationService.Request(target);
                                return Task.CompletedTask;
                            })
                        });
                    }
                }
            }

            return actions;
        }

        public static string BuildGuidance(HealthFindingViewModel finding, bool hasAttentionItems, bool hasActions)
        {
            if (IsUsbSmartLimitation(finding.Detail))
            {
                return "Many USB drive enclosures do not pass SMART commands. This is informational only — use an internal/SATA connection or the vendor tool if you need SMART data for this drive.";
            }

            return finding.Status.ToUpperInvariant() switch
            {
                "PASS" => "This check completed successfully. No further action is recommended.",
                "SKIP" or "N/A" or "NA" => "This check could not be completed in the current environment.",
                _ when hasActions => string.Empty,
                _ when hasAttentionItems => "Review the items above and use the recommended actions when available.",
                _ => "No automated remediation is mapped for this finding. Use the appropriate CDE module or Windows tool manually if needed."
            };
        }

        private static HealthActionViewModel? CreateAction(HealthCheckActionDto action)
        {
            var type = (action.Type ?? string.Empty).Trim().ToLowerInvariant();
            var target = (action.Target ?? string.Empty).Trim();
            if (string.IsNullOrWhiteSpace(target))
                return null;

            if (type == "shell")
            {
                var label = string.IsNullOrWhiteSpace(action.Label) ? target : action.Label.Trim();
                return new HealthActionViewModel
                {
                    Label = label,
                    IsExternal = true,
                    Command = new RelayCommand(() =>
                    {
                        Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
                        return Task.CompletedTask;
                    })
                };
            }

            var cdeLabel = string.IsNullOrWhiteSpace(action.Label)
                ? GetCdeNavLabel(target)
                : action.Label.Trim();

            return new HealthActionViewModel
            {
                Label = cdeLabel,
                IsExternal = false,
                Command = new RelayCommand(() =>
                {
                    NavigationService.Request(target);
                    return Task.CompletedTask;
                })
            };
        }

        private static IEnumerable<StructuredResultItemViewModel> BuildFallbackAttentionItems(string? detail)
        {
            if (string.IsNullOrWhiteSpace(detail))
                yield break;

            var lines = detail.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
            var emitted = 0;

            foreach (var raw in lines)
            {
                var line = raw.Trim();
                if (line.Length == 0)
                    continue;

                if (line.StartsWith("[OK]", StringComparison.OrdinalIgnoreCase))
                    continue;

                if (line.StartsWith("[POSTOP:STARTUP]", StringComparison.OrdinalIgnoreCase))
                    continue;

                if (line.StartsWith("[AUDIT:EVENT]", StringComparison.OrdinalIgnoreCase))
                    continue;

                if (TryGetStartupReviewTagLine(line, out var reviewLine))
                {
                    yield return BuildStartupReviewFallbackItem(reviewLine);
                    emitted++;
                    continue;
                }

                if (line.StartsWith("Warn:", StringComparison.OrdinalIgnoreCase)
                    || line.StartsWith("Fail:", StringComparison.OrdinalIgnoreCase)
                    || line.StartsWith("Stopped:", StringComparison.OrdinalIgnoreCase)
                    || line.StartsWith("Unsigned:", StringComparison.OrdinalIgnoreCase))
                {
                    yield return StructuredResultItemViewModel.CreatePlain(line);
                    emitted++;
                }
            }

            if (emitted == 0)
            {
                var summary = ExtractHeadline(detail, "Warn");
                if (!string.IsNullOrWhiteSpace(summary))
                    yield return StructuredResultItemViewModel.CreatePlain(summary);
            }
        }

        private static string ResolveParserStepName(string? stepName, string? checkId)
        {
            if (!string.IsNullOrWhiteSpace(stepName))
            {
                if (stepName.StartsWith("Drive ", StringComparison.OrdinalIgnoreCase))
                    return stepName;

                return stepName;
            }

            return (checkId ?? string.Empty).ToLowerInvariant() switch
            {
                "audit_startup" => "StartupAudit",
                "audit_event_logs" => "EventLogs",
                "sec_cst" => "CoreSecurityTool",
                _ => checkId ?? string.Empty
            };
        }

        private static bool IsStartupAuditStep(string? stepName, string? checkId)
        {
            if (string.Equals(stepName, "StartupAudit", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            return string.Equals(checkId, "audit_startup", StringComparison.OrdinalIgnoreCase);
        }

        private static bool IsUsbSmartLimitation(string? detail)
        {
            return IsUsbSmartLimitationDetail(detail);
        }

        public static bool IsUsbSmartLimitationDetail(string? detail)
        {
            return !string.IsNullOrWhiteSpace(detail)
                && detail.IndexOf("USB bridge does not pass ATA commands", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private static bool IsAttentionWorthyStructuredItem(StructuredResultItemViewModel item)
        {
            // Prefer explicit evidence-quality labels when present; fall back to status/severity
            // for older payloads that predate Classification.
            var classificationToken = TryMapDisplayLabelToToken(item.Classification);
            if (!string.IsNullOrWhiteSpace(classificationToken))
            {
                return HealthFindingClassification.RequiresAttention(
                    classificationToken,
                    item.StatusLabelText,
                    item.Severity,
                    0);
            }

            return HealthFindingClassification.RequiresAttention(
                null,
                item.StatusLabelText,
                item.Severity,
                0);
        }

        private static string? TryMapDisplayLabelToToken(string? displayOrToken)
        {
            if (string.IsNullOrWhiteSpace(displayOrToken))
                return null;

            var value = displayOrToken.Trim();
            if (value.Equals(HealthFindingClassification.ConfirmedFault, StringComparison.OrdinalIgnoreCase)
                || value.Equals("Confirmed fault", StringComparison.OrdinalIgnoreCase))
            {
                return HealthFindingClassification.ConfirmedFault;
            }

            if (value.Equals(HealthFindingClassification.CorroboratedSuspect, StringComparison.OrdinalIgnoreCase)
                || value.Equals("Corroborated suspect", StringComparison.OrdinalIgnoreCase))
            {
                return HealthFindingClassification.CorroboratedSuspect;
            }

            if (value.Equals(HealthFindingClassification.SingleSignal, StringComparison.OrdinalIgnoreCase)
                || value.Equals("Single signal", StringComparison.OrdinalIgnoreCase))
            {
                return HealthFindingClassification.SingleSignal;
            }

            if (value.Equals(HealthFindingClassification.Inventory, StringComparison.OrdinalIgnoreCase)
                || value.Equals("Inventory", StringComparison.OrdinalIgnoreCase))
            {
                return HealthFindingClassification.Inventory;
            }

            if (value.Equals(HealthFindingClassification.ExpectedLimitation, StringComparison.OrdinalIgnoreCase)
                || value.Equals("Expected limitation", StringComparison.OrdinalIgnoreCase)
                || value.StartsWith("Expected limitation", StringComparison.OrdinalIgnoreCase))
            {
                return HealthFindingClassification.ExpectedLimitation;
            }

            if (value.Equals(HealthFindingClassification.Incomplete, StringComparison.OrdinalIgnoreCase)
                || value.Equals("Incomplete", StringComparison.OrdinalIgnoreCase))
            {
                return HealthFindingClassification.Incomplete;
            }

            return null;
        }

        private static bool IsIssueStatus(string? status)
        {
            if (string.IsNullOrWhiteSpace(status))
                return false;

            return status.Equals("Warn", StringComparison.OrdinalIgnoreCase)
                || status.Equals("Fail", StringComparison.OrdinalIgnoreCase);
        }

        private static bool TryGetStartupReviewTagLine(string line, out string reviewLine)
        {
            reviewLine = string.Empty;
            if (line.StartsWith("[REVIEW]", StringComparison.OrdinalIgnoreCase))
            {
                reviewLine = line["[REVIEW]".Length..].Trim();
                return reviewLine.Length > 0;
            }

            if (line.StartsWith("[SUSPICIOUS]", StringComparison.OrdinalIgnoreCase))
            {
                reviewLine = line["[SUSPICIOUS]".Length..].Trim();
                return reviewLine.Length > 0;
            }

            return false;
        }

        private static StructuredResultItemViewModel BuildStartupReviewFallbackItem(string reviewLine)
        {
            var match = System.Text.RegularExpressions.Regex.Match(
                reviewLine,
                @"^\[(?<loc>[^\]]+)\]\s+(?<name>.+?)\s+—\s+(?<band>Safe|Caution|Warning)(?:\s+\((?<reasons>[^)]+)\))?\s+—\s+(?<path>.+)$",
                System.Text.RegularExpressions.RegexOptions.IgnoreCase);
            if (match.Success)
            {
                return StructuredResultItemViewModel.FromStartupAudit(
                    match.Groups["name"].Value.Trim(),
                    match.Groups["loc"].Value.Trim(),
                    match.Groups["band"].Value.Trim(),
                    match.Groups["reasons"].Success ? match.Groups["reasons"].Value.Trim() : null,
                    match.Groups["path"].Success ? match.Groups["path"].Value.Trim() : null);
            }

            return new StructuredResultItemViewModel
            {
                Name = reviewLine,
                IsStartupReviewItem = true,
                ReviewReason = "Needs review",
                StartupLocation = "Startup entry",
                RiskBand = string.Empty,
                Severity = string.Empty,
                Classification = "Startup entry",
                SeverityBrush = new System.Windows.Media.SolidColorBrush(
                    System.Windows.Media.Color.FromRgb(0x92, 0x68, 0x00)),
                RiskBandBrush = new System.Windows.Media.SolidColorBrush(
                    System.Windows.Media.Color.FromRgb(0x60, 0x67, 0x6E)),
                ClassificationBrush = new System.Windows.Media.SolidColorBrush(
                    System.Windows.Media.Color.FromRgb(0x37, 0x47, 0x5F))
            };
        }

        private static string GetCdeNavLabel(string navTarget)
        {
            var section = navTarget.Contains(':') ? navTarget.Split(':')[0] : navTarget;
            return section switch
            {
                "TempFileCleaner" => "Temp File Cleaner",
                "SmartAnalyzer" => "S.M.A.R.T. Analyzer",
                "StartupManager" => "Startup Manager",
                "SystemHealth" => "System Health Check",
                "SystemAudit" => "System Health Check",
                "MalwareCleanup" => "Malware Cleanup",
                "DiagAndRepair" => "Diag & Repair",
                "HardwareDiagnostics" => "Diag & Repair",
                "FastFixes" => "Fast Fixes",
                "ProcessAnalyzer" => "Process Analyzer",
                _ => string.IsNullOrWhiteSpace(section) ? "Open in CDE" : section
            };
        }
    }
}
