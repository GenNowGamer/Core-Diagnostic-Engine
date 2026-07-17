using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using ToolkitGUI.ViewModels;
using ToolkitGUI.Views;

namespace ToolkitGUI.Services
{
    internal static class DefenderScanResultService
    {
        private static readonly JsonSerializerOptions JsonOptions = new()
        {
            PropertyNameCaseInsensitive = true
        };

        private static readonly Regex DefenderProgressRegex = new(
            @"^\[DEFENDER:PROGRESS\]\s*(?<json>\{.*\})\s*$",
            RegexOptions.Compiled | RegexOptions.IgnoreCase);

        private static readonly Regex ThreatLineRegex = new(
            @"^(?<name>.+?)\s+—\s+(?<location>.+?)(?:\s+\((?<when>.+)\))?\s*$",
            RegexOptions.Compiled);

        public static void ShowLiveScan(
            Window? owner,
            string scriptPath,
            Action<ProcessAnalyzerCstScanPresentation, string>? onSuccess = null,
            Action? onFinished = null)
        {
            var dialog = new ProcessAnalyzerCstResultDialog(
                displayName: "Windows Defender",
                targetPath: "Quick scan (system)",
                scanSubtitle: "Quick scan • Windows Defender",
                isStartupEntryScan: false,
                showMalwareCleanupButton: false,
                scanKind: SecurityScanDialogKind.Defender)
            {
                Owner = owner ?? Application.Current?.Windows.OfType<Window>().FirstOrDefault(window => window.IsActive)
            };

            dialog.Dispatcher.BeginInvoke(new Action(async () =>
            {
                try
                {
                    await dialog.ExecuteScanAsync(async (progress, cancellationToken) =>
                    {
                        string? reportJsonPath = null;
                        try
                        {
                            var result = await PowerShellService.RunWorkflowAsync(
                                scriptPath,
                                "-ToolName DefenderScan",
                                cancellationToken,
                                line =>
                                {
                                    if (TryParseProgressLine(line, out var update))
                                        progress.Report(update);

                                    if (WorkflowReportExportHelper.TryExtractArtifactPath(
                                            line, "Report saved", ".json", out var jsonPath))
                                    {
                                        reportJsonPath = jsonPath;
                                    }
                                }).ConfigureAwait(true);

                            if (cancellationToken.IsCancellationRequested)
                                return CstScanRunOutcome.Failed("Scan cancelled.");

                            var workflowJson = await ResolveWorkflowJsonAsync(result.Stdout, reportJsonPath)
                                .ConfigureAwait(true);

                            if (string.IsNullOrWhiteSpace(workflowJson))
                            {
                                return CstScanRunOutcome.Failed(
                                    "Defender scan finished but no workflow report was found.");
                            }

                            if (!TryBuildPresentation(workflowJson, out var presentation, out var parseError))
                            {
                                return CstScanRunOutcome.Failed(parseError ?? "Could not parse Defender scan results.");
                            }

                            return new CstScanRunOutcome
                            {
                                Success = true,
                                RawOutput = workflowJson,
                                Presentation = presentation,
                                OnSuccess = onSuccess
                            };
                        }
                        catch (OperationCanceledException)
                        {
                            return CstScanRunOutcome.Failed("Scan cancelled.");
                        }
                        catch (Exception ex)
                        {
                            return CstScanRunOutcome.Failed(ex.Message);
                        }
                    });
                }
                finally
                {
                    try { onFinished?.Invoke(); } catch { }
                }
            }), DispatcherPriority.Loaded);

            dialog.ShowDialog();
        }

        public static bool TryParseProgressLine(string line, out CstScanProgressUpdate update)
        {
            update = null!;
            if (string.IsNullOrWhiteSpace(line))
                return false;

            var match = DefenderProgressRegex.Match(line.Trim());
            if (!match.Success)
                return false;

            try
            {
                var progress = JsonSerializer.Deserialize<DefenderProgressEvent>(match.Groups["json"].Value, JsonOptions);
                if (progress is null)
                    return false;

                var phase = (progress.Phase ?? string.Empty).Trim();
                var phaseUpper = phase.ToUpperInvariant();
                var detail = progress.Detail ?? string.Empty;
                var percent = Math.Max(0.0, Math.Min(100.0, progress.Percent));

                string phaseText = phaseUpper switch
                {
                    "STATUS" => "Checking Windows Defender status...",
                    "STARTING" => "Starting Windows Defender quick scan...",
                    "SCANNING" => string.IsNullOrWhiteSpace(detail)
                        ? "Windows Defender quick scan in progress"
                        : detail,
                    "COMPLETING" => "Collecting Defender threat results...",
                    "COMPLETED" => "Windows Defender scan complete",
                    "BLOCKED" => "Defender scan unavailable",
                    "FAILED" => "Defender scan failed",
                    _ => string.IsNullOrWhiteSpace(detail) ? "Windows Defender scan" : detail
                };

                string caption;
                if (!string.IsNullOrWhiteSpace(detail))
                {
                    caption = detail;
                }
                else if (progress.ElapsedSec > 0)
                {
                    var elapsed = FormatElapsed(progress.ElapsedSec);
                    var etaPart = progress.EtaSec > 0
                        ? $" • ETA ~{FormatElapsed(progress.EtaSec)} (estimated)"
                        : string.Empty;
                    caption = $"Elapsed {elapsed}{etaPart}";
                }
                else
                {
                    caption = "Windows Defender quick scan";
                }

                if (!string.IsNullOrWhiteSpace(progress.EngineVersion)
                    && phaseUpper is "STATUS" or "STARTING" or "SCANNING"
                    && !caption.Contains("Engine", StringComparison.OrdinalIgnoreCase))
                {
                    caption = $"{caption} • Engine {progress.EngineVersion}";
                }

                update = new CstScanProgressUpdate
                {
                    Percent = percent,
                    Phase = phase,
                    PhaseText = phaseText,
                    Detail = caption,
                    CurrentPath = string.Empty,
                    VerdictDetail = string.IsNullOrWhiteSpace(detail) ? caption : detail,
                    IsPreScanPhase = phaseUpper is "STATUS" or "STARTING",
                    IsEstimated = progress.Estimated
                };
                return true;
            }
            catch
            {
                return false;
            }
        }

        public static bool TryBuildPresentation(
            string workflowJson,
            out ProcessAnalyzerCstScanPresentation presentation,
            out string? errorMessage)
        {
            presentation = null!;
            errorMessage = null;

            if (string.IsNullOrWhiteSpace(workflowJson))
            {
                errorMessage = "Defender scan finished with no report.";
                return false;
            }

            DefenderWorkflowReport? report;
            try
            {
                report = JsonSerializer.Deserialize<DefenderWorkflowReport>(workflowJson, JsonOptions);
            }
            catch (Exception ex)
            {
                errorMessage = $"Could not read Defender workflow report: {ex.Message}";
                return false;
            }

            if (report?.Steps is null || report.Steps.Count == 0)
            {
                errorMessage = "Defender workflow report contained no steps.";
                return false;
            }

            var defenderScan = report.Steps.FirstOrDefault(step =>
                string.Equals(step.Name, "DefenderScan", StringComparison.OrdinalIgnoreCase));
            var defenderStatus = report.Steps.FirstOrDefault(step =>
                string.Equals(step.Name, "DefenderStatus", StringComparison.OrdinalIgnoreCase));
            var externalScanners = report.Steps.FirstOrDefault(step =>
                string.Equals(step.Name, "ExternalScanners", StringComparison.OrdinalIgnoreCase));

            if (defenderScan is null && externalScanners is null)
            {
                errorMessage = "Defender scan step was not found in the workflow report.";
                return false;
            }

            if (defenderScan is null && externalScanners is not null)
            {
                var winPeDetail = externalScanners.Output ?? "Windows Defender is not available in WinPE.";
                presentation = BuildPresentationCore(
                    verdict: "Incomplete",
                    verdictDetail: winPeDetail,
                    elapsedDisplay: FormatDuration(report.DurationSec),
                    threatsFound: 0,
                    warningsFound: CountWarnings(report.Steps),
                    scanErrors: report.Errors?.Count ?? 0,
                    findings: Array.Empty<ProcessAnalyzerCstFindingRow>(),
                    errorDetails: report.Errors ?? new List<string>(),
                    copySummary: winPeDetail);
                return true;
            }

            var scanOutput = defenderScan!.Output ?? string.Empty;
            var findings = ParseThreatFindings(scanOutput);
            var threatCount = findings.Count;
            var warnings = CountWarnings(report.Steps);
            var scanErrors = (report.Errors?.Count ?? 0)
                + (string.Equals(defenderScan.Status, "Fail", StringComparison.OrdinalIgnoreCase) ? 1 : 0);

            var verdict = threatCount > 0
                ? "Threat"
                : string.Equals(defenderScan.Status, "Warn", StringComparison.OrdinalIgnoreCase)
                    || warnings > 0
                    ? "Review"
                    : "Clean";

            var firstLine = scanOutput.Split(new[] { "\r\n", "\n" }, StringSplitOptions.None)
                .FirstOrDefault(line => !string.IsNullOrWhiteSpace(line))
                ?.Trim() ?? "Windows Defender quick scan finished.";

            var verdictDetail = firstLine;
            if (defenderStatus is not null
                && string.Equals(defenderStatus.Status, "Warn", StringComparison.OrdinalIgnoreCase)
                && !string.IsNullOrWhiteSpace(defenderStatus.Output))
            {
                verdictDetail = $"{firstLine} Defender status: {defenderStatus.Output.Split('\n').FirstOrDefault()?.Trim()}";
            }

            presentation = BuildPresentationCore(
                verdict: verdict,
                verdictDetail: verdictDetail,
                elapsedDisplay: FormatDuration(report.DurationSec),
                threatsFound: threatCount,
                warningsFound: warnings,
                scanErrors: scanErrors,
                findings: findings,
                errorDetails: report.Errors ?? new List<string>(),
                copySummary: BuildCopySummary(report, findings, verdict, verdictDetail));

            return true;
        }

        private static ProcessAnalyzerCstScanPresentation BuildPresentationCore(
            string verdict,
            string verdictDetail,
            string elapsedDisplay,
            int threatsFound,
            int warningsFound,
            int scanErrors,
            IReadOnlyList<ProcessAnalyzerCstFindingRow> findings,
            IReadOnlyList<string> errorDetails,
            string copySummary)
        {
            return new ProcessAnalyzerCstScanPresentation
            {
                ProcessName = "Windows Defender",
                TargetPath = "Quick scan (system)",
                ScanMode = "QuickScan",
                Verdict = verdict,
                VerdictDetail = verdictDetail,
                PrimaryMetricLabel = "ELAPSED",
                PrimaryMetricValue = elapsedDisplay,
                ItemsScanned = 0,
                ThreatsFound = threatsFound,
                WarningsFound = warningsFound,
                ScanErrors = scanErrors,
                Findings = findings,
                SuppressedFindings = Array.Empty<ProcessAnalyzerCstFindingRow>(),
                ErrorDetails = errorDetails,
                CopySummary = copySummary,
                ActionSummary = "Remediate threats in Windows Security (Defender UI). CDE does not quarantine via Defender from this dialog.",
                CoverageReason = "Windows Defender does not expose per-file scan progress to third-party apps; elapsed/ETA during scan are estimated."
            };
        }

        private static async Task<string?> ResolveWorkflowJsonAsync(string stdout, string? reportJsonPath)
        {
            if (!string.IsNullOrWhiteSpace(reportJsonPath) && File.Exists(reportJsonPath))
            {
                try
                {
                    return await File.ReadAllTextAsync(reportJsonPath).ConfigureAwait(false);
                }
                catch
                {
                    // Fall through to stdout extraction.
                }
            }

            return WorkflowReportExportHelper.TryExtractWorkflowJson(stdout);
        }

        private static List<ProcessAnalyzerCstFindingRow> ParseThreatFindings(string scanOutput)
        {
            var findings = new List<ProcessAnalyzerCstFindingRow>();
            if (string.IsNullOrWhiteSpace(scanOutput))
                return findings;

            var blocks = scanOutput.Split(new[] { "\r\n\r\n", "\n\n" }, StringSplitOptions.None);
            if (blocks.Length < 2)
                return findings;

            foreach (var rawLine in blocks.Skip(1).SelectMany(block => block.Split(new[] { "\r\n", "\n" }, StringSplitOptions.None)))
            {
                var line = rawLine.Trim();
                if (string.IsNullOrWhiteSpace(line))
                    continue;

                var match = ThreatLineRegex.Match(line);
                if (!match.Success)
                    continue;

                var name = match.Groups["name"].Value.Trim();
                var location = match.Groups["location"].Value.Trim();
                var when = match.Groups["when"].Success ? match.Groups["when"].Value.Trim() : string.Empty;
                var evidence = string.IsNullOrWhiteSpace(when)
                    ? "Reported by Get-MpThreatDetection during this scan window."
                    : $"Detected at {when}.";

                findings.Add(new ProcessAnalyzerCstFindingRow
                {
                    Id = Guid.NewGuid().ToString("N"),
                    Severity = "High",
                    Type = "Threat",
                    Name = name,
                    Detector = "Windows Defender",
                    Confidence = 1.0,
                    ConfidenceDisplay = "100%",
                    Location = location,
                    Evidence = evidence,
                    ObjectType = "File",
                    WarningBadge = string.Empty,
                    SelectionNote = "Review in Windows Security",
                    CanRemediate = false
                });
            }

            return findings;
        }

        private static int CountWarnings(IReadOnlyList<DefenderWorkflowStep> steps)
            => steps.Count(step => string.Equals(step.Status, "Warn", StringComparison.OrdinalIgnoreCase));

        private static string FormatDuration(double durationSec)
        {
            if (durationSec <= 0)
                return "—";

            var ts = TimeSpan.FromSeconds(durationSec);
            return ts.TotalHours >= 1
                ? ts.ToString(@"h\:mm\:ss")
                : ts.ToString(@"m\:ss");
        }

        private static string FormatElapsed(double elapsedSec)
        {
            if (elapsedSec <= 0)
                return "0:00";

            var ts = TimeSpan.FromSeconds(elapsedSec);
            return ts.TotalHours >= 1
                ? ts.ToString(@"h\:mm\:ss")
                : ts.ToString(@"m\:ss");
        }

        private static string BuildCopySummary(
            DefenderWorkflowReport report,
            IReadOnlyList<ProcessAnalyzerCstFindingRow> findings,
            string verdict,
            string verdictDetail)
        {
            var sb = new StringBuilder();
            sb.AppendLine("Windows Defender quick scan");
            sb.AppendLine($"Verdict: {verdict} — {verdictDetail}");
            sb.AppendLine($"Elapsed: {FormatDuration(report.DurationSec)}");
            sb.AppendLine($"Threats: {findings.Count}");
            sb.AppendLine($"Warnings: {CountWarnings(report.Steps)}");
            if (report.Errors is { Count: > 0 })
            {
                sb.AppendLine();
                sb.AppendLine("Errors:");
                foreach (var error in report.Errors)
                    sb.AppendLine($"- {error}");
            }

            if (findings.Count > 0)
            {
                sb.AppendLine();
                sb.AppendLine("Detections:");
                foreach (var finding in findings)
                {
                    sb.AppendLine($"- {finding.Name} — {finding.Location}");
                }
            }

            sb.AppendLine();
            sb.AppendLine("Remediate in Windows Security. CDE does not run Defender quarantine/remove actions from this dialog.");
            return sb.ToString().TrimEnd();
        }

        private sealed class DefenderWorkflowReport
        {
            public List<DefenderWorkflowStep>? Steps { get; set; }
            public double DurationSec { get; set; }
            public List<string>? Errors { get; set; }
        }

        private sealed class DefenderWorkflowStep
        {
            public string? Name { get; set; }
            public string? Status { get; set; }
            public string? Output { get; set; }
        }

        private sealed class DefenderProgressEvent
        {
            public string? Phase { get; set; }
            public double Percent { get; set; }
            public string? Detail { get; set; }
            public double ElapsedSec { get; set; }
            public double EtaSec { get; set; }
            public string? EngineVersion { get; set; }
            public bool Estimated { get; set; }
        }
    }
}
