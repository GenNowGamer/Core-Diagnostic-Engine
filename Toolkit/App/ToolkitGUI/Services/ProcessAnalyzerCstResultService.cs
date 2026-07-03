using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Windows;
using ToolkitGUI.Views;

namespace ToolkitGUI.Services
{
    internal static class ProcessAnalyzerCstResultService
    {
        private static readonly JsonSerializerOptions JsonOptions = new()
        {
            PropertyNameCaseInsensitive = true
        };

        public static bool TryShowResults(string rawOutput, string targetPath, string? processName, Window? owner)
        {
            if (!TryBuildPresentation(rawOutput, targetPath, processName, out var presentation, out var errorMessage))
            {
                MessageBox.Show(
                    errorMessage ?? "CST scan finished, but the result could not be parsed.",
                    "CST Scan",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return false;
            }

            var dialog = new ProcessAnalyzerCstResultDialog(presentation)
            {
                Owner = owner ?? Application.Current?.Windows.OfType<Window>().FirstOrDefault(window => window.IsActive)
            };
            dialog.ShowDialog();
            return true;
        }

        public static bool TryBuildPresentation(
            string rawOutput,
            string targetPath,
            string? processName,
            out ProcessAnalyzerCstScanPresentation presentation,
            out string? errorMessage)
        {
            presentation = null!;
            errorMessage = null;

            if (string.IsNullOrWhiteSpace(rawOutput))
            {
                errorMessage = "CST scan finished with no output.";
                return false;
            }

            var wrapperJson = ExtractJsonBlock(rawOutput);
            if (string.IsNullOrWhiteSpace(wrapperJson))
            {
                errorMessage = "CST scan output did not contain JSON.";
                return false;
            }

            ProcessCstScanWrapper? wrapper;
            try
            {
                wrapper = JsonSerializer.Deserialize<ProcessCstScanWrapper>(wrapperJson, JsonOptions);
            }
            catch (Exception ex)
            {
                errorMessage = $"Could not parse CST wrapper response: {ex.Message}";
                return false;
            }

            if (wrapper is null)
            {
                errorMessage = "CST scan response was empty.";
                return false;
            }

            if (!wrapper.Available)
            {
                errorMessage = string.IsNullOrWhiteSpace(wrapper.Message)
                    ? "Core Security Tool is not available on this toolkit."
                    : wrapper.Message;
                return false;
            }

            if (!wrapper.Success)
            {
                errorMessage = string.IsNullOrWhiteSpace(wrapper.Message)
                    ? $"CST scan failed (exit code {wrapper.ExitCode})."
                    : wrapper.Message;
                return false;
            }

            var scanJson = ExtractJsonBlock(wrapper.Output ?? string.Empty) ?? wrapper.Output?.Trim();
            if (string.IsNullOrWhiteSpace(scanJson))
            {
                errorMessage = "CST scan completed but returned no scan payload.";
                return false;
            }

            ProcessCstScanDocument? scan;
            try
            {
                scan = JsonSerializer.Deserialize<ProcessCstScanDocument>(scanJson, JsonOptions);
            }
            catch (Exception ex)
            {
                errorMessage = $"Could not parse CST scan payload: {ex.Message}";
                return false;
            }

            if (scan is null)
            {
                errorMessage = "CST scan payload was empty.";
                return false;
            }

            var findings = BuildFindingRows(scan.Findings, suppressed: false);
            var suppressed = BuildFindingRows(scan.SuppressedAuditFindings, suppressed: true)
                .Where(row => CstStructuredResultsService.ShouldShowSuppressedAuditFinding(row.Detector, row.Confidence))
                .ToList();

            var summary = scan.Summary;
            var threats = summary?.ThreatsFound ?? CountThreatLikeFindings(scan.Findings);
            var warnings = summary?.WarningsFound ?? 0;
            var itemsScanned = ResolveFilesAnalyzed(
                summary?.ItemsScanned ?? 0,
                summary?.ContentScansPerformed ?? 0,
                summary?.EnumeratedCandidates ?? 0,
                targetPath);
            var scanErrors = summary?.ScanErrors ?? scan.ScanErrorDetails?.Count ?? 0;

            var verdict = ResolveVerdict(threats, warnings, findings, suppressed, scanErrors);
            var verdictDetail = BuildVerdictDetail(verdict, threats, warnings, scanErrors, findings.Count, suppressed.Count);

            presentation = new ProcessAnalyzerCstScanPresentation
            {
                TargetPath = targetPath,
                ProcessName = string.IsNullOrWhiteSpace(processName) ? "Selected process" : processName!,
                ScanMode = string.IsNullOrWhiteSpace(scan.ScanMode) ? "CustomScan" : scan.ScanMode!,
                Verdict = verdict,
                VerdictDetail = verdictDetail,
                ItemsScanned = itemsScanned,
                ThreatsFound = threats,
                WarningsFound = warnings,
                ScanErrors = scanErrors,
                ActionSummary = scan.ActionSummary ?? string.Empty,
                CoverageReason = scan.CoverageReason ?? string.Empty,
                Findings = findings,
                SuppressedFindings = suppressed,
                ErrorDetails = scan.ScanErrorDetails ?? new List<string>(),
                CopySummary = BuildCopySummary(
                    targetPath,
                    processName,
                    verdict,
                    verdictDetail,
                    itemsScanned,
                    threats,
                    warnings,
                    scanErrors,
                    findings,
                    suppressed,
                    scan.ActionSummary,
                    scan.CoverageReason,
                    scan.ScanErrorDetails)
            };

            return true;
        }

        private static IReadOnlyList<ProcessAnalyzerCstFindingRow> BuildFindingRows(
            IReadOnlyList<ProcessCstFindingDocument>? findings,
            bool suppressed)
        {
            if (findings is null || findings.Count == 0)
            {
                return Array.Empty<ProcessAnalyzerCstFindingRow>();
            }

            return findings
                .Select(finding => new ProcessAnalyzerCstFindingRow
                {
                    Severity = finding.Severity ?? string.Empty,
                    Type = finding.Type ?? string.Empty,
                    Name = finding.Name ?? string.Empty,
                    Detector = finding.Detector ?? string.Empty,
                    Confidence = finding.Confidence,
                    ConfidenceDisplay = FormatConfidence(finding.Confidence),
                    Location = finding.Location ?? string.Empty,
                    Evidence = TrimEvidence(finding.Evidence),
                    IsSuppressed = suppressed
                })
                .OrderByDescending(row => SeverityRank(row.Severity))
                .ThenByDescending(row => row.Confidence)
                .ThenBy(row => row.Name, StringComparer.OrdinalIgnoreCase)
                .ToList();
        }

        private static int ResolveFilesAnalyzed(
            int itemsScanned,
            int contentScansPerformed,
            int enumeratedCandidates,
            string targetPath)
        {
            if (itemsScanned > 0)
            {
                return itemsScanned;
            }

            if (contentScansPerformed > 0)
            {
                return contentScansPerformed;
            }

            if (enumeratedCandidates > 0)
            {
                return enumeratedCandidates;
            }

            if (!string.IsNullOrWhiteSpace(targetPath) && File.Exists(targetPath))
            {
                return 1;
            }

            return itemsScanned;
        }

        private static string ResolveVerdict(
            int threats,
            int warnings,
            IReadOnlyList<ProcessAnalyzerCstFindingRow> findings,
            IReadOnlyList<ProcessAnalyzerCstFindingRow> suppressed,
            int scanErrors)
        {
            if (threats > 0 || findings.Any(IsThreatLikeFinding))
            {
                return "Threat";
            }

            if (scanErrors > 0)
            {
                return "Incomplete";
            }

            if (warnings > 0
                || findings.Count > 0
                || suppressed.Count > 0)
            {
                return "Review";
            }

            return "Clean";
        }

        private static string BuildVerdictDetail(
            string verdict,
            int threats,
            int warnings,
            int scanErrors,
            int findingCount,
            int suppressedCount)
        {
            return verdict switch
            {
                "Threat" => threats > 0
                    ? $"{threats} threat(s) reported by CST for this file."
                    : $"{findingCount} finding(s) require technician review.",
                "Incomplete" => scanErrors > 0
                    ? $"Scan finished with {scanErrors} error(s). Review details before trusting a clean result."
                    : "Scan coverage was incomplete.",
                "Review" => warnings > 0
                    ? $"{warnings} warning(s) and {findingCount + suppressedCount} finding row(s) to review."
                    : findingCount + suppressedCount > 0
                        ? $"{findingCount + suppressedCount} finding row(s) to review. No confirmed threats."
                        : "Low-risk signals detected. No confirmed threats.",
                _ => "No malware or unwanted-program detections for this file."
            };
        }

        private static bool IsThreatLikeFinding(ProcessAnalyzerCstFindingRow row)
        {
            return CstStructuredResultsService.IsActionableFindingType(row.Type)
                || string.Equals(row.Severity, "Critical", StringComparison.OrdinalIgnoreCase)
                || string.Equals(row.Severity, "High", StringComparison.OrdinalIgnoreCase);
        }

        private static int CountThreatLikeFindings(IReadOnlyList<ProcessCstFindingDocument>? findings)
        {
            if (findings is null || findings.Count == 0)
            {
                return 0;
            }

            return findings.Count(finding =>
                CstStructuredResultsService.IsActionableFindingType(finding.Type)
                || string.Equals(finding.Severity, "Critical", StringComparison.OrdinalIgnoreCase)
                || string.Equals(finding.Severity, "High", StringComparison.OrdinalIgnoreCase));
        }

        private static string BuildCopySummary(
            string targetPath,
            string? processName,
            string verdict,
            string verdictDetail,
            int itemsScanned,
            int threats,
            int warnings,
            int scanErrors,
            IReadOnlyList<ProcessAnalyzerCstFindingRow> findings,
            IReadOnlyList<ProcessAnalyzerCstFindingRow> suppressed,
            string? actionSummary,
            string? coverageReason,
            IReadOnlyList<string>? errorDetails)
        {
            var sb = new StringBuilder();
            sb.AppendLine("CST Custom Scan — Process Analyzer");
            sb.AppendLine($"Process: {processName}");
            sb.AppendLine($"Target: {targetPath}");
            sb.AppendLine($"Verdict: {verdict} — {verdictDetail}");
            sb.AppendLine($"Files analyzed: {itemsScanned}");
            sb.AppendLine($"Threats: {threats}");
            sb.AppendLine($"Warnings: {warnings}");
            sb.AppendLine($"Scan errors: {scanErrors}");

            if (!string.IsNullOrWhiteSpace(actionSummary))
            {
                sb.AppendLine($"Action summary: {actionSummary}");
            }

            if (!string.IsNullOrWhiteSpace(coverageReason))
            {
                sb.AppendLine($"Coverage: {coverageReason}");
            }

            AppendFindingSection(sb, "Findings", findings);
            AppendFindingSection(sb, "Suppressed audit findings", suppressed);

            if (errorDetails is { Count: > 0 })
            {
                sb.AppendLine();
                sb.AppendLine("Scan errors:");
                foreach (var detail in errorDetails)
                {
                    sb.AppendLine($"- {detail}");
                }
            }

            return sb.ToString().TrimEnd();
        }

        private static void AppendFindingSection(
            StringBuilder sb,
            string title,
            IReadOnlyList<ProcessAnalyzerCstFindingRow> rows)
        {
            if (rows.Count == 0)
            {
                return;
            }

            sb.AppendLine();
            sb.AppendLine($"{title}:");
            foreach (var row in rows)
            {
                sb.AppendLine(
                    $"- [{row.Severity}/{row.Type}] {row.Name} ({row.Detector}, {row.ConfidenceDisplay})");
                if (!string.IsNullOrWhiteSpace(row.Location))
                {
                    sb.AppendLine($"  Location: {row.Location}");
                }

                if (!string.IsNullOrWhiteSpace(row.Evidence))
                {
                    sb.AppendLine($"  Evidence: {row.Evidence}");
                }
            }
        }

        private static string FormatConfidence(double confidence)
        {
            if (confidence <= 0)
            {
                return "n/a";
            }

            return $"{Math.Round(confidence * 100)}%";
        }

        private static string TrimEvidence(string? evidence)
        {
            if (string.IsNullOrWhiteSpace(evidence))
            {
                return string.Empty;
            }

            var trimmed = evidence.Trim();
            return trimmed.Length <= 240 ? trimmed : trimmed[..240] + "...";
        }

        private static int SeverityRank(string? severity)
        {
            return (severity ?? string.Empty).Trim().ToUpperInvariant() switch
            {
                "CRITICAL" => 5,
                "HIGH" => 4,
                "MEDIUM" => 3,
                "LOW" => 2,
                _ => 1
            };
        }

        private static string? ExtractJsonBlock(string rawOutput)
        {
            if (string.IsNullOrWhiteSpace(rawOutput))
            {
                return null;
            }

            var start = rawOutput.IndexOf('{');
            var end = rawOutput.LastIndexOf('}');
            if (start < 0 || end <= start)
            {
                return null;
            }

            return rawOutput.Substring(start, end - start + 1);
        }

        private sealed class ProcessCstScanWrapper
        {
            public bool Available { get; set; }
            public bool Success { get; set; }
            public string? Message { get; set; }
            public string? Output { get; set; }
            public int ExitCode { get; set; }
        }

        private sealed class ProcessCstScanDocument
        {
            public string? ScanMode { get; set; }
            public string? ActionSummary { get; set; }
            public string? CoverageReason { get; set; }
            public ProcessCstSummaryDocument? Summary { get; set; }
            public List<ProcessCstFindingDocument> Findings { get; set; } = new();
            public List<ProcessCstFindingDocument> SuppressedAuditFindings { get; set; } = new();
            public List<string> ScanErrorDetails { get; set; } = new();
        }

        private sealed class ProcessCstSummaryDocument
        {
            public int ItemsScanned { get; set; }
            public int ThreatsFound { get; set; }
            public int WarningsFound { get; set; }
            public int ScanErrors { get; set; }
            public int ContentScansPerformed { get; set; }
            public int EnumeratedCandidates { get; set; }
        }

        private sealed class ProcessCstFindingDocument
        {
            public string? Severity { get; set; }
            public string? Type { get; set; }
            public string? Name { get; set; }
            public string? Detector { get; set; }
            public double Confidence { get; set; }
            public string? Location { get; set; }
            public string? Evidence { get; set; }
        }
    }

    public sealed class ProcessAnalyzerCstScanPresentation
    {
        public string TargetPath { get; init; } = string.Empty;
        public string ProcessName { get; init; } = string.Empty;
        public string ScanMode { get; init; } = string.Empty;
        public string Verdict { get; init; } = "Clean";
        public string VerdictDetail { get; init; } = string.Empty;
        public int ItemsScanned { get; init; }
        public int ThreatsFound { get; init; }
        public int WarningsFound { get; init; }
        public int ScanErrors { get; init; }
        public string ActionSummary { get; init; } = string.Empty;
        public string CoverageReason { get; init; } = string.Empty;
        public IReadOnlyList<ProcessAnalyzerCstFindingRow> Findings { get; init; } = Array.Empty<ProcessAnalyzerCstFindingRow>();
        public IReadOnlyList<ProcessAnalyzerCstFindingRow> SuppressedFindings { get; init; } = Array.Empty<ProcessAnalyzerCstFindingRow>();
        public IReadOnlyList<string> ErrorDetails { get; init; } = Array.Empty<string>();
        public string CopySummary { get; init; } = string.Empty;

        public bool HasFindings => Findings.Count > 0;
        public bool HasSuppressedFindings => SuppressedFindings.Count > 0;
        public bool HasErrorDetails => ErrorDetails.Count > 0;
        public bool HasActionSummary => !string.IsNullOrWhiteSpace(ActionSummary);
        public bool HasCoverageReason => !string.IsNullOrWhiteSpace(CoverageReason);
    }

    public sealed class ProcessAnalyzerCstFindingRow
    {
        public string Severity { get; init; } = string.Empty;
        public string Type { get; init; } = string.Empty;
        public string Name { get; init; } = string.Empty;
        public string Detector { get; init; } = string.Empty;
        public double Confidence { get; init; }
        public string ConfidenceDisplay { get; init; } = string.Empty;
        public string Location { get; init; } = string.Empty;
        public string Evidence { get; init; } = string.Empty;
        public bool IsSuppressed { get; init; }
    }
}
