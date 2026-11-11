using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Threading;
using ToolkitGUI.ViewModels;
using ToolkitGUI.Views;

namespace ToolkitGUI.Services
{
    internal static class ProcessAnalyzerCstResultService
    {
        private static readonly JsonSerializerOptions JsonOptions = new()
        {
            PropertyNameCaseInsensitive = true
        };

        private static readonly Regex CstProgressRegex = new(
            @"^\[CST:PROGRESS\]\s*(?<json>\{.*\})$",
            RegexOptions.Compiled | RegexOptions.IgnoreCase);

        public static void ShowLiveScan(
            Window? owner,
            string displayName,
            string targetPath,
            string scanSubtitle,
            bool isStartupEntryScan,
            string scriptPath,
            string scriptParameters,
            Action<ProcessAnalyzerCstScanPresentation, string>? onSuccess = null,
            Action? onFinished = null,
            bool showMalwareCleanupButton = true)
        {
            var dialog = new ProcessAnalyzerCstResultDialog(
                displayName,
                targetPath,
                scanSubtitle,
                isStartupEntryScan,
                showMalwareCleanupButton)
            {
                Owner = owner ?? Application.Current?.Windows.OfType<Window>().FirstOrDefault(window => window.IsActive)
            };

            dialog.Dispatcher.BeginInvoke(new Action(async () =>
            {
                try
                {
                    await dialog.ExecuteScanAsync(async (progress, cancellationToken) =>
                    {
                        try
                        {
                            var result = await PowerShellService.RunWorkflowAsync(
                                scriptPath,
                                scriptParameters,
                                cancellationToken,
                                line =>
                                {
                                    if (TryParseProgressLine(line, out var update))
                                        progress.Report(update);
                                }).ConfigureAwait(true);

                            if (cancellationToken.IsCancellationRequested)
                                return CstScanRunOutcome.Failed("Scan cancelled.");

                            if (string.IsNullOrWhiteSpace(result.Stdout)
                                && !string.IsNullOrWhiteSpace(result.Stderr)
                                && result.ExitCode != 0
                                && result.ExitCode != 1
                                && result.ExitCode != 2)
                            {
                                return CstScanRunOutcome.Failed(
                                    string.IsNullOrWhiteSpace(result.Stderr)
                                        ? $"CST scan failed (exit code {result.ExitCode})."
                                        : result.Stderr.Trim());
                            }

                            return CstScanRunOutcome.FromOutput(result.Stdout, onSuccess);
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

        /// <summary>
        /// Writes structured scan JSON under Runtime/Data/scans and an operator PDF under Logs.
        /// </summary>
        public static bool TryEnsureOperatorPdf(
            ProcessAnalyzerCstScanPresentation presentation,
            out string pdfPath,
            out string? error)
        {
            pdfPath = string.Empty;
            error = null;
            if (presentation is null)
            {
                error = "Presentation is null.";
                return false;
            }

            try
            {
                var document = BuildTabularReportDocument(presentation);
                var paths = TabularScanReportService.EnsureReports(document);
                if (!TabularScanReportService.TryGeneratePdf(document, paths.PdfPath, out error))
                    return false;

                pdfPath = paths.PdfPath;
                presentation.ReportPdfPath = pdfPath;
                return File.Exists(pdfPath);
            }
            catch (Exception ex)
            {
                error = ex.Message;
                return false;
            }
        }

        private static TabularScanReportDocument BuildTabularReportDocument(
            ProcessAnalyzerCstScanPresentation presentation)
        {
            var headers = new[]
            {
                "Severity", "Type", "Name", "Detector", "Warning", "Confidence", "Location", "Evidence", "Note"
            };

            var rows = new List<IReadOnlyList<string>>();
            foreach (var f in presentation.Findings)
            {
                rows.Add(new[]
                {
                    f.Severity,
                    f.Type,
                    f.Name,
                    f.Detector,
                    f.WarningBadge,
                    f.ConfidenceDisplay,
                    f.Location,
                    f.Evidence,
                    f.SelectionNote
                });
            }

            foreach (var f in presentation.SuppressedFindings)
            {
                rows.Add(new[]
                {
                    f.Severity,
                    f.Type,
                    f.Name,
                    f.Detector,
                    string.IsNullOrWhiteSpace(f.WarningBadge) ? "Suppressed" : f.WarningBadge,
                    f.ConfidenceDisplay,
                    f.Location,
                    f.Evidence,
                    "Suppressed (outside strict scope)"
                });
            }

            var overall = presentation.Verdict switch
            {
                "Threat" => "Critical",
                "Incomplete" => "Warning",
                "Review" => "Warning",
                "Suspicious" => "Warning",
                _ => "Healthy"
            };

            var title = presentation.IsStartupEntryScan
                ? "CST Startup Entry Scan"
                : string.IsNullOrWhiteSpace(presentation.ScanMode)
                    ? "CST Scan Report"
                    : $"CST {presentation.ScanMode} Report";

            var summaryParts = new List<string>();
            if (!string.IsNullOrWhiteSpace(presentation.ProcessName))
                summaryParts.Add(presentation.ProcessName);
            if (!string.IsNullOrWhiteSpace(presentation.TargetPath))
                summaryParts.Add(presentation.TargetPath);
            if (!string.IsNullOrWhiteSpace(presentation.VerdictDetail))
                summaryParts.Add(presentation.VerdictDetail);
            if (!string.IsNullOrWhiteSpace(presentation.ActionSummary))
                summaryParts.Add(presentation.ActionSummary);
            if (!string.IsNullOrWhiteSpace(presentation.CoverageReason))
                summaryParts.Add($"Coverage: {presentation.CoverageReason}");

            return new TabularScanReportDocument
            {
                WorkflowName = "CST_Scan",
                Title = title,
                Summary = string.Join(" — ", summaryParts),
                OverallHealth = overall,
                GeneratedAt = DateTime.Now,
                ColumnHeaders = headers,
                Rows = rows,
                Metrics = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                {
                    ["FilesAnalyzed"] = presentation.ItemsScanned.ToString(),
                    ["Threats"] = presentation.ThreatsFound.ToString(),
                    ["Warnings"] = presentation.WarningsFound.ToString(),
                    ["ScanErrors"] = presentation.ScanErrors.ToString(),
                    ["Findings"] = presentation.Findings.Count.ToString(),
                    ["Suppressed"] = presentation.SuppressedFindings.Count.ToString(),
                    ["Verdict"] = presentation.Verdict
                }
            };
        }

        private static bool TryParseProgressLine(string line, out CstScanProgressUpdate update)
        {
            update = null!;
            if (string.IsNullOrWhiteSpace(line))
                return false;

            var match = CstProgressRegex.Match(line.Trim());
            if (!match.Success)
                return false;

            try
            {
                var progress = JsonSerializer.Deserialize<CstProgressEvent>(match.Groups["json"].Value, JsonOptions);
                if (progress is null)
                    return false;

                var percent = Math.Max(0.0, Math.Min(100.0, CstScanProgressHelper.ResolveDisplayPercent(
                    progress.Phase,
                    progress.Scanned,
                    progress.ProgressTotal,
                    progress.OverallPercent,
                    progress.Percent)));
                var phasePercent = progress.PhasePercent ?? -1;
                var phase = (progress.Phase ?? string.Empty).Trim();
                var phaseUpper = phase.ToUpperInvariant();
                var detail = progress.Detail ?? string.Empty;
                var currentPath = progress.CurrentPath ?? string.Empty;
                var elapsedSec = progress.ElapsedSec;

                string phaseText;
                string caption;
                if (phaseUpper == "TARGETPREP")
                {
                    phaseText = string.IsNullOrWhiteSpace(detail) ? "Pre-scan checks..." : detail;
                    caption = elapsedSec > 0
                        ? $"Preparing targets, known-good baselines, and scan policy • {FormatElapsed(elapsedSec)}"
                        : "Preparing targets, known-good baselines, and scan policy...";
                    if (phasePercent >= 0)
                        percent = Math.Max(percent, Math.Min(12.0, 1.0 + (phasePercent * 0.11)));
                }
                else if (phaseUpper == "ENUMERATING")
                {
                    phaseText = string.IsNullOrWhiteSpace(detail)
                        ? "Discovering scan locations..."
                        : detail;
                    caption = progress.TargetCount > 0
                        ? $"Path discovery: {progress.EnumeratedCandidates:N0} candidates • target {Math.Max(0, progress.TargetIndex):N0}/{progress.TargetCount:N0}"
                        : $"Path discovery: {progress.EnumeratedCandidates:N0} candidates";
                    if (elapsedSec > 0)
                        caption += $" • {FormatElapsed(elapsedSec)}";
                    if (phasePercent >= 0)
                        percent = Math.Max(percent, Math.Min(35.0, 10.0 + (phasePercent * 0.25)));
                }
                else if (phaseUpper == "COMPLETED")
                {
                    phaseText = string.IsNullOrWhiteSpace(detail) ? "Finalizing results..." : detail;
                    caption = $"{progress.Scanned:N0} files analyzed • finalizing report";
                }
                else if (progress.Scanned <= 0 && progress.EnumeratedCandidates > 0)
                {
                    phaseText = string.IsNullOrWhiteSpace(detail)
                        ? (string.IsNullOrWhiteSpace(currentPath) ? "Discovering scan locations..." : $"Discovering: {Path.GetFileName(currentPath)}")
                        : detail;
                    caption = string.IsNullOrWhiteSpace(detail)
                        ? $"Walking {progress.EnumeratedCandidates:N0} paths"
                        : detail;
                    if (phasePercent >= 0)
                        percent = Math.Max(percent, Math.Min(35.0, 10.0 + (phasePercent * 0.25)));
                }
                else
                {
                    phaseText = string.IsNullOrWhiteSpace(currentPath)
                        ? "Scanning..."
                        : $"Scanning: {Path.GetFileName(currentPath)}";
                    var etaText = progress.EtaSec > 0
                        ? TimeSpan.FromSeconds(progress.EtaSec).ToString(progress.EtaSec >= 3600 ? @"h\:mm\:ss" : @"m\:ss")
                        : "calculating";
                    caption = progress.ProgressTotal > 0
                        ? $"{progress.Scanned:N0} / {progress.ProgressTotal:N0} files scanned • ETA {etaText}"
                        : (string.IsNullOrWhiteSpace(detail) ? $"{progress.Scanned:N0} files scanned" : detail);
                }

                update = new CstScanProgressUpdate
                {
                    Percent = percent,
                    Phase = phase,
                    PhaseText = phaseText,
                    Detail = caption,
                    CurrentPath = currentPath,
                    VerdictDetail = string.IsNullOrWhiteSpace(detail) ? caption : detail,
                    IsPreScanPhase = phaseUpper is "TARGETPREP" or "ENUMERATING"
                        || (progress.Scanned <= 0 && progress.EnumeratedCandidates > 0)
                };
                return true;
            }
            catch
            {
                return false;
            }
        }

        private static string FormatElapsed(double elapsedSec)
        {
            var span = TimeSpan.FromSeconds(Math.Max(0, elapsedSec));
            return span.TotalHours >= 1
                ? span.ToString(@"h\:mm\:ss")
                : span.ToString(@"m\:ss");
        }

        private sealed class CstProgressEvent
        {
            public int Scanned { get; set; }
            public int ProgressTotal { get; set; }
            public double Percent { get; set; }
            public string? Phase { get; set; }
            public double? PhasePercent { get; set; }
            public double? OverallPercent { get; set; }
            public int TargetIndex { get; set; }
            public int TargetCount { get; set; }
            public int EnumeratedCandidates { get; set; }
            public string? Detail { get; set; }
            public string? CurrentPath { get; set; }
            public double EtaSec { get; set; }
            public double ElapsedSec { get; set; }
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

            // Path A: ProcessAnalyzer / PathCstScan / StartupEntryCstScan wrapper.
            var wrapperJson = ExtractPreferredWrapperJson(rawOutput)
                ?? ExtractJsonBlock(StripCstTaggedLines(rawOutput));
            if (!string.IsNullOrWhiteSpace(wrapperJson)
                && TryBuildPresentationFromWrapper(
                    wrapperJson,
                    rawOutput,
                    targetPath,
                    processName,
                    out presentation,
                    out errorMessage))
            {
                AttachArtifactPath(presentation, rawOutput);
                return true;
            }

            // Path B: Malware Cleanup / MalwareSweep workflow output → CST result artifact.
            if (TryBuildPresentationFromArtifactOrDirectScan(
                    rawOutput, targetPath, processName, out presentation, out errorMessage))
            {
                AttachArtifactPath(presentation, rawOutput);
                return true;
            }

            errorMessage ??= "CST scan output did not contain a recognizable scan result.";
            return false;
        }

        private static bool TryBuildPresentationFromWrapper(
            string wrapperJson,
            string rawOutput,
            string targetPath,
            string? processName,
            out ProcessAnalyzerCstScanPresentation presentation,
            out string? errorMessage)
        {
            presentation = null!;
            errorMessage = null;

            ProcessCstScanWrapper? wrapper;
            try
            {
                wrapper = JsonSerializer.Deserialize<ProcessCstScanWrapper>(wrapperJson, JsonOptions);
            }
            catch
            {
                return false;
            }

            if (wrapper is null)
                return false;

            // Progress crumbs can look like JSON objects; require wrapper shape.
            if (!wrapperJson.Contains("\"Available\"", StringComparison.OrdinalIgnoreCase)
                && !wrapperJson.Contains("\"ScanKind\"", StringComparison.OrdinalIgnoreCase))
            {
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
                // Still try artifact fallback for partial workflow success.
                if (TryBuildPresentationFromArtifactOrDirectScan(
                        rawOutput, targetPath, processName, out presentation, out var artifactError))
                {
                    return true;
                }

                errorMessage = string.IsNullOrWhiteSpace(wrapper.Message)
                    ? $"CST scan failed (exit code {wrapper.ExitCode})."
                    : wrapper.Message;
                if (!string.IsNullOrWhiteSpace(artifactError))
                    errorMessage = artifactError;
                return false;
            }

            var scanJson = ExtractPreferredScanJson(wrapper.Output ?? string.Empty)
                ?? ExtractJsonBlock(wrapper.Output ?? string.Empty)
                ?? wrapper.Output?.Trim();
            if (string.IsNullOrWhiteSpace(scanJson))
            {
                if (TryBuildPresentationFromArtifactOrDirectScan(
                        rawOutput, targetPath, processName, out presentation, out errorMessage))
                {
                    return true;
                }

                errorMessage = "CST scan completed but returned no scan payload.";
                return false;
            }

            return TryBuildPresentationFromScanJson(
                scanJson, targetPath, processName, out presentation, out errorMessage);
        }

        private static bool TryBuildPresentationFromArtifactOrDirectScan(
            string rawOutput,
            string targetPath,
            string? processName,
            out ProcessAnalyzerCstScanPresentation presentation,
            out string? errorMessage)
        {
            presentation = null!;
            errorMessage = null;

            var artifactPath = CstStructuredResultsService.ResolveArtifactPathFromStepOutput(rawOutput);
            if (!string.IsNullOrWhiteSpace(artifactPath) && File.Exists(artifactPath))
            {
                try
                {
                    var artifactJson = File.ReadAllText(artifactPath);
                    if (TryBuildPresentationFromScanJson(
                            artifactJson, targetPath, processName, out presentation, out errorMessage))
                    {
                        presentation.ArtifactPath = artifactPath;
                        return true;
                    }
                }
                catch (Exception ex)
                {
                    errorMessage = $"Could not read CST result artifact: {ex.Message}";
                }
            }

            var directJson = ExtractPreferredScanJson(StripCstTaggedLines(rawOutput))
                ?? ExtractPreferredScanJson(rawOutput);
            if (!string.IsNullOrWhiteSpace(directJson)
                && TryBuildPresentationFromScanJson(
                    directJson, targetPath, processName, out presentation, out errorMessage))
            {
                return true;
            }

            if (string.IsNullOrWhiteSpace(errorMessage))
            {
                errorMessage = string.IsNullOrWhiteSpace(artifactPath)
                    ? "CST scan completed but no result artifact was found."
                    : $"CST result artifact was missing or unreadable: {artifactPath}";
            }

            return false;
        }

        private static bool TryBuildPresentationFromScanJson(
            string scanJson,
            string targetPath,
            string? processName,
            out ProcessAnalyzerCstScanPresentation presentation,
            out string? errorMessage)
        {
            presentation = null!;
            errorMessage = null;

            // Prefer a direct StartupEntryScan envelope if the wrapper Output was double-encoded
            // or mixed with progress lines.
            if (TryDeserializeScanDocument(scanJson, out var directScan)
                && IsStartupEntryScanDocument(directScan))
            {
                return TryBuildStartupEntryPresentation(
                    directScan!, targetPath, processName, out presentation, out errorMessage);
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

            // Startup-entry scan envelope (File / CommandLine / Persistence verdicts).
            if (IsStartupEntryScanDocument(scan))
            {
                return TryBuildStartupEntryPresentation(
                    scan, targetPath, processName, out presentation, out errorMessage);
            }

            // Require scan-shaped payload (avoid treating progress crumbs as results).
            if (string.IsNullOrWhiteSpace(scan.ScanMode)
                && scan.Summary is null
                && (scan.Findings is null || scan.Findings.Count == 0)
                && string.IsNullOrWhiteSpace(scan.ScanKind))
            {
                errorMessage = "CST scan payload was incomplete.";
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
            var scanMode = string.IsNullOrWhiteSpace(scan.ScanMode) ? "CustomScan" : scan.ScanMode!;
            var coverageReason = scan.CoverageReason ?? string.Empty;
            var verdictDetail = BuildVerdictDetail(
                verdict,
                threats,
                warnings,
                scanErrors,
                findings.Count,
                suppressed.Count,
                scanMode,
                coverageReason);

            presentation = new ProcessAnalyzerCstScanPresentation
            {
                TargetPath = targetPath,
                ProcessName = string.IsNullOrWhiteSpace(processName) ? "Selected process" : processName!,
                ScanMode = scanMode,
                Verdict = verdict,
                VerdictDetail = verdictDetail,
                ItemsScanned = itemsScanned,
                ThreatsFound = threats,
                WarningsFound = warnings,
                ScanErrors = scanErrors,
                ActionSummary = scan.ActionSummary ?? string.Empty,
                CoverageReason = coverageReason,
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
                .Select(finding =>
                {
                    var location = finding.Location ?? string.Empty;
                    var objectType = string.IsNullOrWhiteSpace(finding.ObjectType) ? "File" : finding.ObjectType!;
                    var parentArchivePath = TryGetArchiveParentPath(location);
                    var isArchiveEntry = string.Equals(objectType, "ArchiveEntry", StringComparison.OrdinalIgnoreCase)
                        || !string.IsNullOrWhiteSpace(parentArchivePath);
                    var fileExists = !string.IsNullOrWhiteSpace(location) && File.Exists(location);
                    var parentExists = !string.IsNullOrWhiteSpace(parentArchivePath) && File.Exists(parentArchivePath);
                    var canRemediate = string.Equals(objectType, "File", StringComparison.OrdinalIgnoreCase) && fileExists;
                    var warningBadge = ResolveWarningBadge(finding.Detector, finding.Confidence, suppressed);
                    string selectionNote;
                    if (canRemediate)
                    {
                        selectionNote = suppressed
                            ? "Outside selected scope; operator override allowed"
                            : (string.Equals(finding.Detector, "ArchiveInspector", StringComparison.OrdinalIgnoreCase)
                                ? "Selectable — quarantine/remove this archive"
                                : "Selectable for remediation");
                    }
                    else if (isArchiveEntry)
                    {
                        selectionNote = parentExists
                            ? "Review only — select the parent archive row to quarantine/remove"
                            : "Review only (archive entry; parent archive not found)";
                    }
                    else
                    {
                        selectionNote = fileExists ? $"Review only ({objectType})" : "File not found";
                    }

                    return new ProcessAnalyzerCstFindingRow
                    {
                        Id = finding.Id ?? string.Empty,
                        Severity = finding.Severity ?? string.Empty,
                        Type = finding.Type ?? string.Empty,
                        Name = finding.Name ?? string.Empty,
                        Detector = finding.Detector ?? string.Empty,
                        Confidence = finding.Confidence,
                        ConfidenceDisplay = FormatConfidence(finding.Confidence),
                        Location = location,
                        Evidence = TrimEvidence(finding.Evidence),
                        ObjectType = objectType,
                        WarningBadge = warningBadge,
                        SelectionNote = selectionNote,
                        CanRemediate = canRemediate,
                        IsSuppressed = suppressed
                    };
                })
                .OrderByDescending(row => SeverityRank(row.Severity))
                .ThenByDescending(row => row.Confidence)
                .ThenBy(row => row.Name, StringComparer.OrdinalIgnoreCase)
                .ToList();
        }

        private static string? TryGetArchiveParentPath(string? location)
        {
            if (string.IsNullOrWhiteSpace(location))
                return null;

            var separator = location.IndexOf("::", StringComparison.Ordinal);
            if (separator <= 0)
                return null;

            var parent = location[..separator];
            return string.IsNullOrWhiteSpace(parent) ? null : parent;
        }

        private static string ResolveWarningBadge(string? detector, double confidence, bool suppressed)
        {
            if (suppressed)
                return "Scope override";
            if (string.Equals(detector, "PathHeuristic", StringComparison.OrdinalIgnoreCase))
                return "Weak heuristic";
            if (string.Equals(detector, "SignerTrust", StringComparison.OrdinalIgnoreCase) && confidence < 0.7)
                return "Low-confidence trust";
            return string.Empty;
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

            if (warnings > 0 || findings.Count > 0)
            {
                return "Review";
            }

            if (suppressed.Count > 0)
            {
                return "HealthyWithNotes";
            }

            return "Clean";
        }

        private static string BuildVerdictDetail(
            string verdict,
            int threats,
            int warnings,
            int scanErrors,
            int findingCount,
            int suppressedCount,
            string? scanMode = null,
            string? coverageReason = null)
        {
            var modePrefix = FormatScanModeLabel(scanMode);
            var core = verdict switch
            {
                "Threat" => threats > 0
                    ? $"{threats} threat(s) reported by CST for this target."
                    : $"{findingCount} finding(s) require technician review.",
                "Incomplete" => scanErrors > 0
                    ? $"Scan finished with {scanErrors} error(s). Review details before trusting a clean result."
                    : "Scan coverage was incomplete.",
                "Review" => warnings > 0
                    ? (suppressedCount > 0
                        ? $"{warnings} warning(s) and {findingCount} finding row(s) to review ({suppressedCount} audit trace(s) suppressed)."
                        : $"{warnings} warning(s) and {findingCount} finding row(s) to review.")
                    : findingCount > 0
                        ? (suppressedCount > 0
                            ? $"{findingCount} finding row(s) to review ({suppressedCount} audit trace(s) suppressed). No confirmed threats."
                            : $"{findingCount} finding row(s) to review. No confirmed threats.")
                        : "Low-risk signals detected. No confirmed threats.",
                "HealthyWithNotes" => suppressedCount > 0
                    ? $"No confirmed threats ({suppressedCount} low-confidence audit trace(s) suppressed below)."
                    : "No malware or unwanted-program detections for this target.",
                _ => string.Equals(scanMode, "ThreatScan", StringComparison.OrdinalIgnoreCase)
                    ? "No malware or unwanted-program detections in high-risk paths."
                    : "No malware or unwanted-program detections for this target."
            };

            if (!string.IsNullOrWhiteSpace(coverageReason) &&
                (string.Equals(verdict, "Incomplete", StringComparison.OrdinalIgnoreCase)
                 || coverageReason.Contains("Partial", StringComparison.OrdinalIgnoreCase)
                 || coverageReason.Contains("limited", StringComparison.OrdinalIgnoreCase)
                 || coverageReason.Contains("ThreatScan covers", StringComparison.OrdinalIgnoreCase)))
            {
                // Coverage detail belongs in Copy summary / PDF — keep the on-screen verdict short.
                if (string.Equals(verdict, "Incomplete", StringComparison.OrdinalIgnoreCase)
                    && !core.Contains("incomplete", StringComparison.OrdinalIgnoreCase))
                {
                    core = $"{core} Coverage was incomplete.";
                }
            }

            return string.IsNullOrWhiteSpace(modePrefix) ? core : $"{modePrefix} — {core}";
        }

        private static string FormatScanModeLabel(string? scanMode)
        {
            if (string.IsNullOrWhiteSpace(scanMode))
                return string.Empty;

            return scanMode switch
            {
                "ThreatScan" => "ThreatScan (quick high-risk paths)",
                "FullScan" => "FullScan (broad system coverage)",
                "CustomScan" => "CustomScan (selected targets)",
                "StartupEntryScan" => "Startup entry scan",
                _ => scanMode
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

        private static bool TryBuildStartupEntryPresentation(
            ProcessCstScanDocument scan,
            string targetPath,
            string? processName,
            out ProcessAnalyzerCstScanPresentation presentation,
            out string? errorMessage)
        {
            presentation = null!;
            errorMessage = null;

            var sourceFindings = ResolveStartupEntryFindings(scan);
            var findings = BuildFindingRows(sourceFindings, suppressed: false);
            var suppressed = BuildFindingRows(scan.SuppressedAuditFindings, suppressed: true)
                .Where(row => CstStructuredResultsService.ShouldShowSuppressedAuditFinding(row.Detector, row.Confidence))
                .ToList();

            // If JSON depth/truncation dropped finding rows but verdicts still name detectors,
            // synthesize visible rows so the grid is never blank when axes are non-Clean.
            if (findings.Count == 0)
            {
                findings = BuildFindingsFromVerdicts(scan.Verdicts);
            }

            var summary = scan.Summary ?? scan.CustomScan?.Summary;
            var threats = summary?.ThreatsFound ?? CountThreatLikeFindings(sourceFindings);
            if (threats == 0)
                threats = findings.Count(IsThreatLikeFinding);
            var warnings = summary?.WarningsFound ?? 0;
            if (warnings == 0)
                warnings = findings.Count(row => !IsThreatLikeFinding(row));
            var itemsScanned = ResolveFilesAnalyzed(
                summary?.ItemsScanned ?? scan.TargetsScanned?.Count ?? 0,
                summary?.ContentScansPerformed ?? 0,
                summary?.EnumeratedCandidates ?? 0,
                targetPath);
            var scanErrors = summary?.ScanErrors ?? scan.ScanErrorDetails?.Count ?? 0;

            var fileV = scan.Verdicts?.File;
            var cmdV = scan.Verdicts?.CommandLine;
            var persistV = scan.Verdicts?.Persistence;

            var overall = string.IsNullOrWhiteSpace(scan.OverallVerdict)
                ? ResolveVerdict(threats, warnings, findings, suppressed, scanErrors)
                : scan.OverallVerdict!;

            var verdictDetail = BuildStartupEntryVerdictDetail(overall, fileV, cmdV, persistV);

            var displayPath = targetPath;
            if (scan.StartupEntry is not null && !string.IsNullOrWhiteSpace(scan.StartupEntry.CommandLine))
            {
                displayPath = scan.StartupEntry.CommandLine!;
            }

            presentation = new ProcessAnalyzerCstScanPresentation
            {
                TargetPath = displayPath,
                ProcessName = string.IsNullOrWhiteSpace(processName) ? "Startup entry" : processName!,
                ScanMode = "StartupEntryScan",
                Verdict = overall,
                VerdictDetail = verdictDetail,
                ItemsScanned = itemsScanned,
                ThreatsFound = threats,
                WarningsFound = warnings,
                ScanErrors = scanErrors,
                ActionSummary = scan.ActionSummary ?? scan.CustomScan?.ActionSummary ?? string.Empty,
                CoverageReason = scan.CoverageReason ?? scan.CustomScan?.CoverageReason ?? string.Empty,
                Findings = findings,
                SuppressedFindings = suppressed,
                ErrorDetails = scan.ScanErrorDetails ?? new List<string>(),
                IsStartupEntryScan = true,
                FileVerdict = fileV?.Verdict ?? "Clean",
                FileVerdictDetail = fileV?.Detail ?? string.Empty,
                CommandLineVerdict = cmdV?.Verdict ?? "Clean",
                CommandLineVerdictDetail = cmdV?.Detail ?? string.Empty,
                PersistenceVerdict = persistV?.Verdict ?? "Clean",
                PersistenceVerdictDetail = persistV?.Detail ?? string.Empty,
                CopySummary = BuildStartupEntryCopySummary(
                    displayPath,
                    processName,
                    overall,
                    verdictDetail,
                    fileV,
                    cmdV,
                    persistV,
                    itemsScanned,
                    threats,
                    warnings,
                    scanErrors,
                    findings,
                    suppressed)
            };

            return true;
        }

        private static bool IsStartupEntryScanDocument(ProcessCstScanDocument? scan)
        {
            if (scan is null)
                return false;

            return string.Equals(scan.ScanKind, "StartupEntryScan", StringComparison.OrdinalIgnoreCase)
                || string.Equals(scan.ScanMode, "StartupEntryScan", StringComparison.OrdinalIgnoreCase)
                || scan.Verdicts is not null;
        }

        private static bool TryDeserializeScanDocument(string json, out ProcessCstScanDocument? scan)
        {
            scan = null;
            try
            {
                scan = JsonSerializer.Deserialize<ProcessCstScanDocument>(json, JsonOptions);
                return scan is not null;
            }
            catch
            {
                return false;
            }
        }

        private static List<ProcessCstFindingDocument> ResolveStartupEntryFindings(ProcessCstScanDocument scan)
        {
            var merged = new List<ProcessCstFindingDocument>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            void AddRange(IEnumerable<ProcessCstFindingDocument>? items)
            {
                if (items is null)
                    return;

                foreach (var finding in items)
                {
                    var key = string.Join('|',
                        finding.Id ?? string.Empty,
                        finding.Detector ?? string.Empty,
                        finding.Name ?? string.Empty,
                        finding.Location ?? string.Empty);
                    if (seen.Add(key))
                        merged.Add(finding);
                }
            }

            AddRange(scan.Findings);
            AddRange(scan.CustomScan?.Findings);
            return merged;
        }

        private static IReadOnlyList<ProcessAnalyzerCstFindingRow> BuildFindingsFromVerdicts(
            ProcessCstVerdictsDocument? verdicts)
        {
            if (verdicts is null)
                return Array.Empty<ProcessAnalyzerCstFindingRow>();

            var rows = new List<ProcessAnalyzerCstFindingRow>();
            void AddAxis(string axis, ProcessCstAxisVerdictDocument? axisVerdict)
            {
                if (axisVerdict is null)
                    return;
                if (string.Equals(axisVerdict.Verdict, "Clean", StringComparison.OrdinalIgnoreCase)
                    || string.IsNullOrWhiteSpace(axisVerdict.Verdict))
                    return;

                var names = ExtractFindingNamesFromDetail(axisVerdict.Detail);
                if (names.Count == 0)
                    names.Add(axisVerdict.Verdict);

                foreach (var name in names)
                {
                    rows.Add(new ProcessAnalyzerCstFindingRow
                    {
                        Severity = string.Equals(axisVerdict.Verdict, "Threat", StringComparison.OrdinalIgnoreCase)
                            ? "High"
                            : "Medium",
                        Type = string.Equals(axisVerdict.Verdict, "Threat", StringComparison.OrdinalIgnoreCase)
                            ? "Malware"
                            : "Suspicious",
                        Name = name,
                        Detector = axis switch
                        {
                            "File" => "FileScan",
                            "Command line" => "StartupCommandLine",
                            "Persistence" => "StartupEntryContext",
                            _ => "StartupEntryScan"
                        },
                        Confidence = 0.7,
                        ConfidenceDisplay = "70%",
                        Location = axis,
                        Evidence = string.IsNullOrWhiteSpace(axisVerdict.Detail)
                            ? $"{axis} verdict: {axisVerdict.Verdict}"
                            : axisVerdict.Detail!,
                        IsSuppressed = false
                    });
                }
            }

            AddAxis("File", verdicts.File);
            AddAxis("Command line", verdicts.CommandLine);
            AddAxis("Persistence", verdicts.Persistence);

            return rows
                .GroupBy(row => $"{row.Detector}|{row.Name}", StringComparer.OrdinalIgnoreCase)
                .Select(group => group.First())
                .ToList();
        }

        private static List<string> ExtractFindingNamesFromDetail(string? detail)
        {
            var names = new List<string>();
            if (string.IsNullOrWhiteSpace(detail))
                return names;

            // Examples: "Suspicious: 1 finding(s) (HiddenWindow_Bypass)"
            //           "Threat: 2 finding(s) (PS_EncodedCommand, LOLBin_Mshta_Remote)"
            var open = detail.LastIndexOf('(');
            var close = detail.LastIndexOf(')');
            if (open < 0 || close <= open)
                return names;

            var inner = detail.Substring(open + 1, close - open - 1);
            foreach (var part in inner.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                if (!string.IsNullOrWhiteSpace(part))
                    names.Add(part);
            }

            return names;
        }

        private static void AttachArtifactPath(ProcessAnalyzerCstScanPresentation presentation, string rawOutput)
        {
            if (!string.IsNullOrWhiteSpace(presentation.ArtifactPath) && File.Exists(presentation.ArtifactPath))
                return;

            var fromOutput = CstStructuredResultsService.ResolveArtifactPathFromStepOutput(rawOutput);
            if (string.IsNullOrWhiteSpace(fromOutput) || !File.Exists(fromOutput))
            {
                var workflowJson = WorkflowReportExportHelper.TryExtractWorkflowJson(rawOutput);
                if (!string.IsNullOrWhiteSpace(workflowJson))
                {
                    try
                    {
                        using var doc = JsonDocument.Parse(workflowJson);
                        if (doc.RootElement.TryGetProperty("steps", out var steps)
                            || doc.RootElement.TryGetProperty("Steps", out steps))
                        {
                            foreach (var step in steps.EnumerateArray())
                            {
                                var name = step.TryGetProperty("name", out var n) ? n.GetString()
                                    : step.TryGetProperty("Name", out n) ? n.GetString() : null;
                                if (!string.Equals(name, "CoreSecurityTool", StringComparison.OrdinalIgnoreCase))
                                    continue;
                                var output = step.TryGetProperty("output", out var o) ? o.GetString()
                                    : step.TryGetProperty("Output", out o) ? o.GetString() : null;
                                fromOutput = CstStructuredResultsService.ResolveArtifactPathFromStepOutput(output);
                                if (!string.IsNullOrWhiteSpace(fromOutput) && File.Exists(fromOutput))
                                    break;
                            }
                        }
                    }
                    catch
                    {
                        // Best-effort workflow parse.
                    }
                }
            }

            if (!string.IsNullOrWhiteSpace(fromOutput) && File.Exists(fromOutput))
            {
                presentation.ArtifactPath = fromOutput!;
                return;
            }

            // Path/Startup scans may only return JSON in-memory — persist a temp artifact for remediation.
            try
            {
                var scanJson = ExtractPreferredScanJson(rawOutput)
                    ?? ExtractPreferredScanJson(StripCstTaggedLines(rawOutput));
                if (string.IsNullOrWhiteSpace(scanJson))
                    return;

                var cstDir = ReportPathHelper.GetCstDataRoot();
                Directory.CreateDirectory(cstDir);
                var path = Path.Combine(cstDir, $"CST_Result_UI_{DateTime.UtcNow:yyyyMMdd_HHmmss_fff}.json");
                File.WriteAllText(path, scanJson);
                presentation.ArtifactPath = path;
            }
            catch
            {
                // Remediation stays disabled if we cannot persist an artifact.
            }
        }

        private static string? ExtractPreferredScanJson(string rawOutput)
        {
            if (string.IsNullOrWhiteSpace(rawOutput))
                return null;

            string? best = null;
            var bestScore = -1;
            foreach (var candidate in EnumerateJsonObjects(rawOutput))
            {
                var score = ScoreScanPayload(candidate);
                if (score > bestScore)
                {
                    bestScore = score;
                    best = candidate;
                }
            }

            return bestScore > 0 ? best : null;
        }

        private static string? ExtractPreferredWrapperJson(string rawOutput)
        {
            if (string.IsNullOrWhiteSpace(rawOutput))
                return null;

            // Live scans stream [CST:PROGRESS]/[CST:FINDING] lines before the wrapper JSON.
            // Prefer the ProcessAnalyzer wrapper object; never use first-{ to last-} spanning.
            string? best = null;
            var bestScore = -1;
            foreach (var candidate in EnumerateJsonObjects(rawOutput))
            {
                var score = ScoreWrapperPayload(candidate);
                if (score > bestScore)
                {
                    bestScore = score;
                    best = candidate;
                }
            }

            return bestScore > 0 ? best : null;
        }

        private static int ScoreWrapperPayload(string candidate)
        {
            var score = 0;
            if (candidate.IndexOf("\"Available\"", StringComparison.OrdinalIgnoreCase) >= 0)
                score += 50;
            if (candidate.IndexOf("\"Success\"", StringComparison.OrdinalIgnoreCase) >= 0)
                score += 40;
            if (candidate.IndexOf("\"Output\"", StringComparison.OrdinalIgnoreCase) >= 0)
                score += 30;
            if (candidate.IndexOf("\"ScanKind\"", StringComparison.OrdinalIgnoreCase) >= 0)
                score += 25;
            if (candidate.IndexOf("\"ExitCode\"", StringComparison.OrdinalIgnoreCase) >= 0)
                score += 15;
            if (candidate.IndexOf("PathScan", StringComparison.OrdinalIgnoreCase) >= 0)
                score += 10;
            if (candidate.IndexOf("StartupEntryScan", StringComparison.OrdinalIgnoreCase) >= 0)
                score += 10;

            // Demote live progress crumbs that also start with '{'.
            if (candidate.IndexOf("\"overallPercent\"", StringComparison.OrdinalIgnoreCase) >= 0
                && candidate.IndexOf("\"phase\"", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                score -= 80;
            }

            if (candidate.IndexOf("\"enumeratedCandidates\"", StringComparison.OrdinalIgnoreCase) >= 0
                && candidate.IndexOf("\"Available\"", StringComparison.OrdinalIgnoreCase) < 0)
            {
                score -= 40;
            }

            score += Math.Min(candidate.Length / 2000, 10);
            return score;
        }

        private static int ScoreScanPayload(string candidate)
        {
            var score = 0;
            if (candidate.IndexOf("\"scanKind\"", StringComparison.OrdinalIgnoreCase) >= 0
                && candidate.IndexOf("StartupEntryScan", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                score += 100;
            }

            if (candidate.IndexOf("\"verdicts\"", StringComparison.OrdinalIgnoreCase) >= 0)
                score += 40;
            if (candidate.IndexOf("\"findings\"", StringComparison.OrdinalIgnoreCase) >= 0)
                score += 20;
            if (candidate.IndexOf("\"overallVerdict\"", StringComparison.OrdinalIgnoreCase) >= 0)
                score += 20;
            if (candidate.IndexOf("\"scanMode\"", StringComparison.OrdinalIgnoreCase) >= 0)
                score += 15;
            if (candidate.IndexOf("CustomScan", StringComparison.OrdinalIgnoreCase) >= 0)
                score += 20;
            if (candidate.IndexOf("\"summary\"", StringComparison.OrdinalIgnoreCase) >= 0)
                score += 15;
            if (candidate.IndexOf("\"threatsFound\"", StringComparison.OrdinalIgnoreCase) >= 0)
                score += 10;

            if (candidate.IndexOf("\"overallPercent\"", StringComparison.OrdinalIgnoreCase) >= 0
                && candidate.IndexOf("\"phase\"", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                score -= 80;
            }

            // Prefer larger payloads when scores tie (full report vs progress crumbs).
            score += Math.Min(candidate.Length / 1000, 15);
            return score;
        }

        private static string StripCstTaggedLines(string rawOutput)
        {
            if (string.IsNullOrWhiteSpace(rawOutput))
                return string.Empty;

            var sb = new StringBuilder(Math.Min(rawOutput.Length, 4096));
            using var reader = new StringReader(rawOutput);
            string? line;
            while ((line = reader.ReadLine()) != null)
            {
                var trimmed = line.TrimStart();
                if (trimmed.StartsWith("[CST:", StringComparison.OrdinalIgnoreCase))
                    continue;
                sb.AppendLine(line);
            }

            return sb.ToString().Trim();
        }

        private static IEnumerable<string> EnumerateJsonObjects(string rawOutput)
        {
            for (var i = 0; i < rawOutput.Length; i++)
            {
                if (rawOutput[i] != '{')
                    continue;

                var depth = 0;
                var inString = false;
                var escape = false;
                for (var j = i; j < rawOutput.Length; j++)
                {
                    var ch = rawOutput[j];
                    if (inString)
                    {
                        if (escape)
                        {
                            escape = false;
                            continue;
                        }

                        if (ch == '\\')
                        {
                            escape = true;
                            continue;
                        }

                        if (ch == '"')
                            inString = false;
                        continue;
                    }

                    if (ch == '"')
                    {
                        inString = true;
                        continue;
                    }

                    if (ch == '{')
                        depth++;
                    else if (ch == '}')
                    {
                        depth--;
                        if (depth == 0)
                        {
                            yield return rawOutput.Substring(i, j - i + 1);
                            i = j;
                            break;
                        }
                    }
                }
            }
        }

        private static string BuildStartupEntryVerdictDetail(
            string overall,
            ProcessCstAxisVerdictDocument? fileV,
            ProcessCstAxisVerdictDocument? cmdV,
            ProcessCstAxisVerdictDocument? persistV)
        {
            return
                $"Overall: {overall}. " +
                $"File: {fileV?.Verdict ?? "Clean"} — {fileV?.Detail ?? "n/a"}. " +
                $"Command line: {cmdV?.Verdict ?? "Clean"} — {cmdV?.Detail ?? "n/a"}. " +
                $"Persistence: {persistV?.Verdict ?? "Clean"} — {persistV?.Detail ?? "n/a"}.";
        }

        private static string BuildStartupEntryCopySummary(
            string targetPath,
            string? processName,
            string overall,
            string verdictDetail,
            ProcessCstAxisVerdictDocument? fileV,
            ProcessCstAxisVerdictDocument? cmdV,
            ProcessCstAxisVerdictDocument? persistV,
            int itemsScanned,
            int threats,
            int warnings,
            int scanErrors,
            IReadOnlyList<ProcessAnalyzerCstFindingRow> findings,
            IReadOnlyList<ProcessAnalyzerCstFindingRow> suppressed)
        {
            var sb = new StringBuilder();
            sb.AppendLine("CST Startup Entry Scan — Startup Manager");
            sb.AppendLine($"Entry: {processName}");
            sb.AppendLine($"Command line: {targetPath}");
            sb.AppendLine($"Overall: {overall}");
            sb.AppendLine(verdictDetail);
            sb.AppendLine($"File: {fileV?.Verdict} — {fileV?.Detail}");
            sb.AppendLine($"Command line: {cmdV?.Verdict} — {cmdV?.Detail}");
            sb.AppendLine($"Persistence: {persistV?.Verdict} — {persistV?.Detail}");
            sb.AppendLine($"Files analyzed: {itemsScanned}");
            sb.AppendLine($"Threats: {threats}; Warnings: {warnings}; Scan errors: {scanErrors}");
            AppendFindingSection(sb, "Findings", findings);
            AppendFindingSection(sb, "Suppressed", suppressed);
            return sb.ToString();
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

            // Prefer a single brace-balanced object (never first '{' through last '}').
            foreach (var candidate in EnumerateJsonObjects(rawOutput))
            {
                if (ScoreWrapperPayload(candidate) > 0)
                    return candidate;
            }

            using var enumerator = EnumerateJsonObjects(rawOutput).GetEnumerator();
            string? last = null;
            while (enumerator.MoveNext())
                last = enumerator.Current;
            return last;
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
            public string? ScanKind { get; set; }
            public string? ScanMode { get; set; }
            public string? OverallVerdict { get; set; }
            public string? ActionSummary { get; set; }
            public string? CoverageReason { get; set; }
            public ProcessCstSummaryDocument? Summary { get; set; }
            public ProcessCstStartupEntryDocument? StartupEntry { get; set; }
            public ProcessCstVerdictsDocument? Verdicts { get; set; }
            public ProcessCstScanDocument? CustomScan { get; set; }
            public List<string>? TargetsScanned { get; set; }
            public List<ProcessCstFindingDocument> Findings { get; set; } = new();
            public List<ProcessCstFindingDocument> SuppressedAuditFindings { get; set; } = new();
            public List<string> ScanErrorDetails { get; set; } = new();
        }

        private sealed class ProcessCstStartupEntryDocument
        {
            public string? Name { get; set; }
            public string? CommandLine { get; set; }
        }

        private sealed class ProcessCstVerdictsDocument
        {
            public ProcessCstAxisVerdictDocument? File { get; set; }
            public ProcessCstAxisVerdictDocument? CommandLine { get; set; }
            public ProcessCstAxisVerdictDocument? Persistence { get; set; }
        }

        private sealed class ProcessCstAxisVerdictDocument
        {
            public string? Verdict { get; set; }
            public string? Detail { get; set; }
            public List<string>? FindingIds { get; set; }
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
            public string? Id { get; set; }
            public string? Severity { get; set; }
            public string? Type { get; set; }
            public string? Name { get; set; }
            public string? Detector { get; set; }
            public double Confidence { get; set; }
            public string? Location { get; set; }
            public string? Evidence { get; set; }
            public string? ObjectType { get; set; }
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
        public string PrimaryMetricLabel { get; init; } = "FILES ANALYZED";
        public string PrimaryMetricValue { get; init; } = string.Empty;
        public string PrimaryMetricDisplay => !string.IsNullOrWhiteSpace(PrimaryMetricValue)
            ? PrimaryMetricValue
            : ItemsScanned.ToString("N0");
        public int ThreatsFound { get; init; }
        public int WarningsFound { get; init; }
        public int ScanErrors { get; init; }
        public string ActionSummary { get; init; } = string.Empty;
        public string CoverageReason { get; init; } = string.Empty;
        public string ArtifactPath { get; set; } = string.Empty;
        /// <summary>Operator-facing PDF under Logs, generated when results are shown.</summary>
        public string ReportPdfPath { get; set; } = string.Empty;
        public IReadOnlyList<ProcessAnalyzerCstFindingRow> Findings { get; init; } = Array.Empty<ProcessAnalyzerCstFindingRow>();
        public IReadOnlyList<ProcessAnalyzerCstFindingRow> SuppressedFindings { get; init; } = Array.Empty<ProcessAnalyzerCstFindingRow>();
        public IReadOnlyList<string> ErrorDetails { get; init; } = Array.Empty<string>();
        public string CopySummary { get; init; } = string.Empty;
        public bool IsStartupEntryScan { get; init; }
        public string FileVerdict { get; init; } = string.Empty;
        public string FileVerdictDetail { get; init; } = string.Empty;
        public string CommandLineVerdict { get; init; } = string.Empty;
        public string CommandLineVerdictDetail { get; init; } = string.Empty;
        public string PersistenceVerdict { get; init; } = string.Empty;
        public string PersistenceVerdictDetail { get; init; } = string.Empty;

        public bool HasFindings => Findings.Count > 0;
        public bool HasSuppressedFindings => SuppressedFindings.Count > 0;
        public bool HasErrorDetails => ErrorDetails.Count > 0;
        public bool HasActionSummary => !string.IsNullOrWhiteSpace(ActionSummary);
        public bool HasCoverageReason => !string.IsNullOrWhiteSpace(CoverageReason);
        public bool CanRemediate => !string.IsNullOrWhiteSpace(ArtifactPath) && File.Exists(ArtifactPath);
    }

    public sealed class ProcessAnalyzerCstFindingRow : System.ComponentModel.INotifyPropertyChanged
    {
        private bool _isSelected;

        public string Id { get; init; } = string.Empty;
        public string Severity { get; init; } = string.Empty;
        public string Type { get; init; } = string.Empty;
        public string Name { get; init; } = string.Empty;
        public string Detector { get; init; } = string.Empty;
        public double Confidence { get; init; }
        public string ConfidenceDisplay { get; init; } = string.Empty;
        public string Location { get; init; } = string.Empty;
        public string Evidence { get; init; } = string.Empty;
        public string ObjectType { get; init; } = "File";
        public string WarningBadge { get; init; } = string.Empty;
        public string SelectionNote { get; init; } = string.Empty;
        public bool CanRemediate { get; init; }
        public bool IsSuppressed { get; init; }

        public bool IsSelected
        {
            get => _isSelected;
            set
            {
                if (value && !CanRemediate)
                    return;
                if (_isSelected == value)
                    return;
                _isSelected = value;
                PropertyChanged?.Invoke(this, new System.ComponentModel.PropertyChangedEventArgs(nameof(IsSelected)));
            }
        }

        public event System.ComponentModel.PropertyChangedEventHandler? PropertyChanged;
    }
}
