using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using ToolkitGUI.Models;
using ToolkitGUI.ViewModels;
using ToolkitGUI.Views;

namespace ToolkitGUI.Services
{
    internal static class CstRemediationService
    {
        public static async Task<bool> ExecuteRemediationAsync(
            string artifactPath,
            string action,
            IEnumerable<string> selectedFindingIds,
            Window? owner = null)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(artifactPath) || !File.Exists(artifactPath))
                {
                    MessageBox.Show(
                        "CST result artifact is missing. Re-run the scan before remediating.",
                        "Core Security Tool",
                        MessageBoxButton.OK,
                        MessageBoxImage.Warning);
                    return false;
                }

                var selectedIds = selectedFindingIds
                    .Where(id => !string.IsNullOrWhiteSpace(id))
                    .Distinct(StringComparer.OrdinalIgnoreCase)
                    .ToArray();
                if (selectedIds.Length == 0)
                {
                    MessageBox.Show(
                        "Select at least one finding before running a remediation action.",
                        "Core Security Tool",
                        MessageBoxButton.OK,
                        MessageBoxImage.Information);
                    return false;
                }

                var cstScriptPath = ResolveCoreSecurityToolPath();
                if (string.IsNullOrWhiteSpace(cstScriptPath) || !File.Exists(cstScriptPath))
                {
                    MessageBox.Show(
                        "Core Security Tool remediation script was not found.",
                        "Core Security Tool",
                        MessageBoxButton.OK,
                        MessageBoxImage.Warning);
                    return false;
                }

                var remediationCommand = new StringBuilder();
                remediationCommand.Append("$result = & ");
                remediationCommand.Append(QuoteForPowerShell(cstScriptPath));
                remediationCommand.Append(" -Operation Remediate -FindingsInputPath ");
                remediationCommand.Append(QuoteForPowerShell(artifactPath));
                remediationCommand.Append(" -RemediationAction ");
                remediationCommand.Append(action);
                remediationCommand.Append(" -SelectedFindingId ");
                remediationCommand.Append(BuildPowerShellArray(selectedIds));
                remediationCommand.Append(" -AutoElevate -RequireElevation -EmitJson; $result");

                var (output, error) = await PowerShellService.QueryAsync(remediationCommand.ToString());
                if (!string.IsNullOrWhiteSpace(error))
                {
                    MessageBox.Show(
                        $"Remediation reported errors:\n{error}",
                        "Core Security Tool",
                        MessageBoxButton.OK,
                        MessageBoxImage.Warning);
                    return false;
                }

                var jsonText = ExtractJsonBlock(output);
                if (string.IsNullOrWhiteSpace(jsonText))
                {
                    MessageBox.Show(
                        "Remediation completed but returned no JSON payload.",
                        "Core Security Tool",
                        MessageBoxButton.OK,
                        MessageBoxImage.Information);
                    return false;
                }

                var opts = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
                var remediation = JsonSerializer.Deserialize<CstRemediationResult>(jsonText, opts);
                if (remediation is null)
                {
                    MessageBox.Show(
                        "Remediation completed but the result payload could not be parsed.",
                        "Core Security Tool",
                        MessageBoxButton.OK,
                        MessageBoxImage.Warning);
                    return false;
                }

                MessageBox.Show(
                    BuildRemediationSummary(remediation),
                    "Core Security Tool",
                    MessageBoxButton.OK,
                    remediation.Failed > 0 ? MessageBoxImage.Warning : MessageBoxImage.Information);
                return remediation.Failed == 0;
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    $"Remediation failed: {ex.Message}",
                    "Core Security Tool",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return false;
            }
        }

        public static Task ExecuteRollbackFromManifestAsync(string rollbackManifestPath)
            => ExecuteCstRollbackAsync(rollbackManifestPath);

        public static async Task TryOpenFindingsOperatorDialogAsync(string? reportJsonPath)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(reportJsonPath) || !File.Exists(reportJsonPath))
                    return;

                var opts = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
                var report = JsonSerializer.Deserialize<WorkflowExecutionReport>(
                    await File.ReadAllTextAsync(reportJsonPath), opts);
                var cstStep = report?.Steps?.FirstOrDefault(step =>
                    string.Equals(step.Name, "CoreSecurityTool", StringComparison.OrdinalIgnoreCase));
                if (cstStep is null || string.IsNullOrWhiteSpace(cstStep.Output))
                    return;

                await TryOpenFindingsOperatorDialogFromScanOutputAsync(cstStep.Output);
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    $"Unable to open CST findings selection: {ex.Message}",
                    "Core Security Tool",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }

        public static async Task TryOpenFindingsOperatorDialogFromScanOutputAsync(string? scanOutput)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(scanOutput))
                    return;

                var artifactPath = CstStructuredResultsService.ResolveArtifactPathFromStepOutput(scanOutput);
                if (string.IsNullOrWhiteSpace(artifactPath) || !File.Exists(artifactPath))
                {
                    // Workflow JSON may be embedded in live-scan stdout.
                    var workflowJson = WorkflowReportExportHelper.TryExtractWorkflowJson(scanOutput);
                    if (!string.IsNullOrWhiteSpace(workflowJson))
                    {
                        var opts = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
                        var report = JsonSerializer.Deserialize<WorkflowExecutionReport>(workflowJson, opts);
                        var cstStep = report?.Steps?.FirstOrDefault(step =>
                            string.Equals(step.Name, "CoreSecurityTool", StringComparison.OrdinalIgnoreCase));
                        if (cstStep is not null && !string.IsNullOrWhiteSpace(cstStep.Output))
                        {
                            artifactPath = CstStructuredResultsService.ResolveArtifactPathFromStepOutput(cstStep.Output);
                        }
                    }
                }

                if (string.IsNullOrWhiteSpace(artifactPath) || !File.Exists(artifactPath))
                    return;

                await OpenFindingsOperatorDialogFromArtifactAsync(artifactPath);
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    $"Unable to open CST findings selection: {ex.Message}",
                    "Core Security Tool",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }

        private static async Task OpenFindingsOperatorDialogFromArtifactAsync(string artifactPath)
        {
            try
            {
                var opts = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
                var scanArtifact = JsonSerializer.Deserialize<CstScanArtifact>(
                    await File.ReadAllTextAsync(artifactPath), opts);

                var findings = new List<CstFindingSelectionItem>();
                foreach (var finding in scanArtifact?.Findings ?? new List<CstScanFinding>())
                {
                    findings.Add(BuildCstFindingSelectionItem(finding, false));
                }

                foreach (var finding in scanArtifact?.SuppressedAuditFindings ?? new List<CstScanFinding>())
                {
                    if (!CstStructuredResultsService.ShouldShowSuppressedAuditFinding(finding.Detector, finding.Confidence))
                    {
                        continue;
                    }

                    if (findings.Any(existing =>
                            string.Equals(existing.Id, finding.Id ?? string.Empty, StringComparison.OrdinalIgnoreCase)))
                    {
                        continue;
                    }

                    findings.Add(BuildCstFindingSelectionItem(finding, true));
                }

                if (findings.Count == 0)
                {
                    MessageBox.Show(
                        "CST scan completed, but no findings were available for post-scan selection or review.",
                        "Core Security Tool",
                        MessageBoxButton.OK,
                        MessageBoxImage.Information);
                    return;
                }

                var dialog = new CstFindingsOperatorDialog(findings)
                {
                    Owner = Application.Current?.Windows.OfType<Window>().FirstOrDefault(window => window.IsActive)
                };

                if (dialog.ShowDialog() != true || string.IsNullOrWhiteSpace(dialog.RequestedAction))
                    return;

                if (string.Equals(dialog.RequestedAction, "Rollback", StringComparison.OrdinalIgnoreCase))
                {
                    if (string.IsNullOrWhiteSpace(dialog.RollbackManifestPath))
                    {
                        MessageBox.Show(
                            "Rollback was requested, but no rollback manifest path was selected.",
                            "Core Security Tool",
                            MessageBoxButton.OK,
                            MessageBoxImage.Warning);
                        return;
                    }

                    await ExecuteCstRollbackAsync(dialog.RollbackManifestPath);
                    return;
                }

                var selectedIds = dialog.Findings
                    .Where(f => f.IsSelected)
                    .Select(f => f.Id)
                    .Where(id => !string.IsNullOrWhiteSpace(id))
                    .ToArray();
                if (selectedIds.Length == 0)
                    return;

                var cstScriptPath = ResolveCoreSecurityToolPath();
                if (string.IsNullOrWhiteSpace(cstScriptPath) || !File.Exists(cstScriptPath))
                {
                    MessageBox.Show(
                        "Core Security Tool remediation script was not found.",
                        "Core Security Tool",
                        MessageBoxButton.OK,
                        MessageBoxImage.Warning);
                    return;
                }

                var remediationCommand = new StringBuilder();
                remediationCommand.Append("$result = & ");
                remediationCommand.Append(QuoteForPowerShell(cstScriptPath));
                remediationCommand.Append(" -Operation Remediate -FindingsInputPath ");
                remediationCommand.Append(QuoteForPowerShell(artifactPath));
                remediationCommand.Append(" -RemediationAction ");
                remediationCommand.Append(dialog.RequestedAction);
                remediationCommand.Append(" -SelectedFindingId ");
                remediationCommand.Append(BuildPowerShellArray(selectedIds));
                remediationCommand.Append(" -AutoElevate -RequireElevation -EmitJson; $result");

                var (output, error) = await PowerShellService.QueryAsync(remediationCommand.ToString());
                if (!string.IsNullOrWhiteSpace(error))
                {
                    MessageBox.Show(
                        $"Remediation reported errors:\n{error}",
                        "Core Security Tool",
                        MessageBoxButton.OK,
                        MessageBoxImage.Warning);
                    return;
                }

                var jsonText = ExtractJsonBlock(output);
                if (string.IsNullOrWhiteSpace(jsonText))
                {
                    MessageBox.Show(
                        "Remediation completed but returned no JSON payload.",
                        "Core Security Tool",
                        MessageBoxButton.OK,
                        MessageBoxImage.Information);
                    return;
                }

                var remediation = JsonSerializer.Deserialize<CstRemediationResult>(jsonText, opts);
                if (remediation is null)
                {
                    MessageBox.Show(
                        "Remediation completed but the result payload could not be parsed.",
                        "Core Security Tool",
                        MessageBoxButton.OK,
                        MessageBoxImage.Warning);
                    return;
                }

                MessageBox.Show(
                    BuildRemediationSummary(remediation),
                    "Core Security Tool",
                    MessageBoxButton.OK,
                    remediation.Failed > 0 ? MessageBoxImage.Warning : MessageBoxImage.Information);
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    $"Unable to open CST findings operator: {ex.Message}",
                    "Core Security Tool",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }

        private static async Task ExecuteCstRollbackAsync(string rollbackManifestPath)
        {
            var cstScriptPath = ResolveCoreSecurityToolPath();
            if (string.IsNullOrWhiteSpace(cstScriptPath) || !File.Exists(cstScriptPath))
            {
                MessageBox.Show(
                    "Core Security Tool rollback script was not found.",
                    "Core Security Tool",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return;
            }

            var command = new StringBuilder();
            command.Append("$result = & ");
            command.Append(QuoteForPowerShell(cstScriptPath));
            command.Append(" -Operation Rollback -RollbackManifestPath ");
            command.Append(QuoteForPowerShell(rollbackManifestPath));
            command.Append(" -AutoElevate -RequireElevation -EmitJson; $result");

            var (output, error) = await PowerShellService.QueryAsync(command.ToString());
            if (!string.IsNullOrWhiteSpace(error))
            {
                MessageBox.Show(
                    $"Rollback reported errors:\n{error}",
                    "Core Security Tool",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return;
            }

            var jsonText = ExtractJsonBlock(output);
            if (string.IsNullOrWhiteSpace(jsonText))
            {
                MessageBox.Show(
                    "Rollback completed but returned no JSON payload.",
                    "Core Security Tool",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            var opts = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
            var rollback = JsonSerializer.Deserialize<CstRollbackResult>(jsonText, opts);
            if (rollback is null)
            {
                MessageBox.Show(
                    "Rollback completed but the result payload could not be parsed.",
                    "Core Security Tool",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return;
            }

            MessageBox.Show(
                $"Rollback complete.\n\nRestored: {rollback.Restored}\nFailed: {rollback.Failed}\nSkipped: {rollback.Skipped}\nManifest: {rollback.RollbackManifestPath}",
                "Core Security Tool",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
        }

        private static string BuildRemediationSummary(CstRemediationResult remediation)
        {
            var builder = new StringBuilder();
            builder.AppendLine("Remediation complete.");
            builder.AppendLine();
            builder.AppendLine($"Action: {remediation.Action}");
            builder.AppendLine($"Succeeded: {remediation.Succeeded}");
            builder.AppendLine($"Failed: {remediation.Failed}");
            builder.AppendLine($"Skipped: {remediation.Skipped}");
            if (!string.IsNullOrWhiteSpace(remediation.RollbackManifestPath))
            {
                builder.AppendLine($"Rollback Manifest: {remediation.RollbackManifestPath}");
            }

            if (remediation.Errors.Count > 0)
            {
                builder.AppendLine();
                builder.AppendLine("Errors:");
                foreach (var error in remediation.Errors.Take(5))
                {
                    builder.AppendLine($"- {error}");
                }

                if (remediation.Errors.Count > 5)
                {
                    builder.AppendLine($"- ... and {remediation.Errors.Count - 5} more");
                }
            }
            else if (remediation.Failed > 0)
            {
                builder.AppendLine();
                builder.AppendLine("Some items could not be removed or quarantined. Common causes: file in use, access denied, or path no longer exists.");
            }

            return builder.ToString().TrimEnd();
        }

        private static string? ResolveCstArtifactPath(string output)
            => CstStructuredResultsService.ResolveArtifactPathFromStepOutput(output);

        private static string? ResolveCoreSecurityToolPath()
        {
            var candidates = new List<string>();

            var toolkitRootFromEnv = Environment.GetEnvironmentVariable("TOOLKIT_ROOT");
            if (!string.IsNullOrWhiteSpace(toolkitRootFromEnv))
            {
                candidates.Add(Path.Combine(toolkitRootFromEnv.TrimEnd('\\', '/'), "Security", "CST", "CoreSecurityTool.ps1"));
            }

            var toolkitRoot = ToolkitPaths.GetToolkitRoot();
            if (!string.IsNullOrWhiteSpace(toolkitRoot))
            {
                candidates.Add(Path.Combine(toolkitRoot, "Security", "CST", "CoreSecurityTool.ps1"));

                TryAddDevSiblingCstCandidate(candidates, toolkitRoot);
            }

            return candidates.FirstOrDefault(File.Exists);
        }

        private static void TryAddDevSiblingCstCandidate(List<string> candidates, string toolkitRoot)
        {
            try
            {
                var toolkitParent = Directory.GetParent(toolkitRoot);
                if (toolkitParent is null)
                    return;

                var appBuildsRoot = Directory.GetParent(toolkitParent.FullName);
                if (appBuildsRoot is null)
                    return;

                candidates.Add(Path.Combine(appBuildsRoot.FullName, "Core Security Tool", "CST", "CoreSecurityTool.ps1"));
            }
            catch
            {
                // Dev-machine fallback only; USB / customer layouts use Security\CST under toolkit root.
            }
        }

        private static string BuildPowerShellArray(IEnumerable<string> values)
        {
            var quoted = values.Select(QuoteForPowerShell);
            return "@(" + string.Join(", ", quoted) + ")";
        }

        private static string QuoteForPowerShell(string value)
            => PowerShellArgumentHelper.QuoteForScriptParameter(value);

        private static string? ExtractJsonBlock(string rawOutput)
        {
            if (string.IsNullOrWhiteSpace(rawOutput))
                return null;

            var start = rawOutput.IndexOf('{');
            var end = rawOutput.LastIndexOf('}');
            if (start < 0 || end <= start)
                return null;

            return rawOutput.Substring(start, end - start + 1);
        }

        private static CstFindingSelectionItem BuildCstFindingSelectionItem(CstScanFinding finding, bool isSuppressedByScope)
        {
            var location = finding.Location ?? string.Empty;
            var fileExists = !string.IsNullOrWhiteSpace(location) && File.Exists(location);
            var objectType = string.IsNullOrWhiteSpace(finding.ObjectType) ? "File" : finding.ObjectType!;
            var isArchiveEntry = string.Equals(objectType, "ArchiveEntry", StringComparison.OrdinalIgnoreCase)
                || location.Contains("::", StringComparison.Ordinal);
            var isConcreteFileTrace = string.Equals(objectType, "File", StringComparison.OrdinalIgnoreCase) && fileExists;
            var canRemediate = isConcreteFileTrace;

            var selectionNote = canRemediate
                ? isSuppressedByScope
                    ? "Outside selected scope; operator override allowed"
                    : (string.Equals(finding.Detector, "ArchiveInspector", StringComparison.OrdinalIgnoreCase)
                        ? "Selectable — quarantine/remove this archive"
                        : "Selectable for remediation")
                : isArchiveEntry
                    ? "Review only — select the parent archive row to quarantine/remove"
                    : fileExists
                        ? $"Review only ({objectType})"
                        : "File not found";

            var warningBadge = GetCstWarningBadge(finding, isSuppressedByScope);

            return new CstFindingSelectionItem
            {
                Id = finding.Id ?? string.Empty,
                Type = finding.Type ?? string.Empty,
                Severity = finding.Severity ?? string.Empty,
                Name = finding.Name ?? string.Empty,
                Location = location,
                Evidence = finding.Evidence ?? string.Empty,
                CanRemediate = canRemediate,
                IsSuppressedByScope = isSuppressedByScope,
                SelectionNote = selectionNote,
                WarningBadge = warningBadge,
                Detector = finding.Detector ?? string.Empty,
                Confidence = finding.Confidence,
                ObjectType = objectType,
                RemediationState = string.IsNullOrWhiteSpace(finding.RemediationState) ? "None" : finding.RemediationState!
            };
        }

        private static string GetCstWarningBadge(CstScanFinding finding, bool isSuppressedByScope)
        {
            if (isSuppressedByScope)
            {
                return "Scope override";
            }

            var detector = finding.Detector ?? string.Empty;
            if (string.Equals(detector, "PathHeuristic", StringComparison.OrdinalIgnoreCase))
            {
                return "Weak heuristic";
            }

            if (string.Equals(detector, "SignerTrust", StringComparison.OrdinalIgnoreCase) && finding.Confidence < 0.7)
            {
                return "Low-confidence trust";
            }

            return string.Empty;
        }

        private sealed class CstScanArtifact
        {
            public List<CstScanFinding> Findings { get; set; } = new();
            public List<CstScanFinding> SuppressedAuditFindings { get; set; } = new();
        }

        private sealed class CstScanFinding
        {
            public string? Id { get; set; }
            public string? Type { get; set; }
            public string? Severity { get; set; }
            public string? Name { get; set; }
            public string? Location { get; set; }
            public string? Evidence { get; set; }
            public string? Detector { get; set; }
            public double Confidence { get; set; }
            public string? ObjectType { get; set; }
            public bool CanRemediate { get; set; }
            public string? RemediationState { get; set; }
        }

        private sealed class CstRemediationResult
        {
            public string Action { get; set; } = string.Empty;
            public int Succeeded { get; set; }
            public int Failed { get; set; }
            public int Skipped { get; set; }
            public string RollbackManifestPath { get; set; } = string.Empty;
            public List<string> Errors { get; set; } = new();
        }

        private sealed class CstRollbackResult
        {
            public int Restored { get; set; }
            public int Failed { get; set; }
            public int Skipped { get; set; }
            public string RollbackManifestPath { get; set; } = string.Empty;
        }
    }
}
