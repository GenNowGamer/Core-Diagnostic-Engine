using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using ToolkitGUI.Models;

namespace ToolkitGUI.Services
{
    internal sealed class ActiveWorkOrderInfo
    {
        public string CaseId { get; init; } = string.Empty;
        public string WorkOrderPath { get; init; } = string.Empty;
        public string Status { get; init; } = string.Empty;
        public int RunCount { get; init; }
        public string ClientName { get; init; } = string.Empty;
        public string ClientPhone { get; init; } = string.Empty;
        public string TechnicianNotes { get; init; } = string.Empty;
    }

    internal static class WorkOrderService
    {
        public static event Action? ActiveWorkOrderChanged;

        /// <summary>Last TryRecord* failure message (case id + detail) for operator/debug visibility.</summary>
        public static string? LastWorkOrderAttachError { get; private set; }

        private static string GetToolkitRoot() => WorkOrderPathHelper.GetToolkitRoot();

        private static string GetWorkOrdersDirectory() => WorkOrderPathHelper.GetOperatorWorkOrdersDirectory();

        private static string GetActivePointerPath() => WorkOrderPathHelper.GetActivePointerPath();

        private static string GetWorkOrderPath(string caseId) => WorkOrderPathHelper.ResolveInternalJsonPath(caseId);

        private static bool IsCanonicalWorkOrderFile(string fileName) => WorkOrderPathHelper.IsCanonicalWorkOrderFile(fileName);

        public static ActiveWorkOrderInfo? GetActiveWorkOrder()
        {
            try
            {
                // Pointer file is source of truth. Env is only accepted when it matches the pointer
                // and the work order Status is Open (checked in TryLoadActiveSummary).
                string? pointerCaseId = null;
                var pointerPath = GetActivePointerPath();
                if (File.Exists(pointerPath))
                {
                    var ptr = JsonNode.Parse(File.ReadAllText(pointerPath)) as JsonObject;
                    pointerCaseId = ptr?["CaseId"]?.GetValue<string>()?.Trim();
                    if (!string.IsNullOrWhiteSpace(pointerCaseId) && WorkOrderPathHelper.IsValidCaseId(pointerCaseId))
                    {
                        // Re-resolve from CaseId; do not trust ptr.WorkOrderPath.
                        var fromPointer = TryLoadActiveSummary(pointerCaseId);
                        if (fromPointer != null)
                        {
                            Environment.SetEnvironmentVariable("CDE_ACTIVE_CASE_ID", fromPointer.CaseId, EnvironmentVariableTarget.Process);
                            return fromPointer;
                        }
                    }
                }

                var envCase = Environment.GetEnvironmentVariable("CDE_ACTIVE_CASE_ID")?.Trim();
                if (!string.IsNullOrWhiteSpace(envCase) &&
                    !string.IsNullOrWhiteSpace(pointerCaseId) &&
                    string.Equals(envCase, pointerCaseId, StringComparison.OrdinalIgnoreCase) &&
                    WorkOrderPathHelper.IsValidCaseId(envCase))
                {
                    return TryLoadActiveSummary(envCase);
                }

                return null;
            }
            catch
            {
                // WinPE / read-only media must not block MainWindow construction.
                return null;
            }
        }

        private static ActiveWorkOrderInfo? TryLoadActiveSummary(string caseId)
        {
            if (!WorkOrderPathHelper.IsValidCaseId(caseId))
                return null;

            var path = GetWorkOrderPath(caseId);
            if (!File.Exists(path))
                return null;

            try
            {
                var root = JsonNode.Parse(File.ReadAllText(path)) as JsonObject;
                if (root == null)
                    return null;

                var status = root["Status"]?.GetValue<string>() ?? "Open";
                if (!string.Equals(status, "Open", StringComparison.OrdinalIgnoreCase))
                    return null;

                var runs = root["Runs"] as JsonArray;
                return MapActiveSummary(caseId, path, status, root, runs?.Count ?? 0);
            }
            catch
            {
                return null;
            }
        }

        private static ActiveWorkOrderInfo MapActiveSummary(string caseId, string path, string status, JsonObject root, int runCount)
        {
            return new ActiveWorkOrderInfo
            {
                CaseId = caseId,
                WorkOrderPath = path,
                Status = status,
                RunCount = runCount,
                ClientName = root["ClientName"]?.GetValue<string>() ?? string.Empty,
                ClientPhone = root["ClientPhone"]?.GetValue<string>() ?? string.Empty,
                TechnicianNotes = root["TechnicianNotes"]?.GetValue<string>() ?? string.Empty
            };
        }

        public static IReadOnlyList<WorkOrderListItem> GetRecentWorkOrders(int count = 5)
        {
            var items = new List<WorkOrderListItem>();
            IEnumerable<string> files;
            try
            {
                files = WorkOrderPathHelper.EnumerateInternalWorkOrderJsonFiles();
            }
            catch
            {
                return items;
            }

            foreach (var file in files)
            {
                var name = Path.GetFileName(file);
                if (!IsCanonicalWorkOrderFile(name))
                    continue;

                try
                {
                    var root = JsonNode.Parse(File.ReadAllText(file)) as JsonObject;
                    if (root == null)
                        continue;

                    var caseId = root["CaseId"]?.GetValue<string>() ?? Path.GetFileNameWithoutExtension(name);
                    var clientName = root["ClientName"]?.GetValue<string>() ?? string.Empty;
                    var status = root["Status"]?.GetValue<string>() ?? "Unknown";
                    var sortTime = ParseSortTime(root, file);

                    var label = string.IsNullOrWhiteSpace(clientName)
                        ? $"{caseId} ({status})"
                        : $"{caseId} - {clientName} ({status})";

                    items.Add(new WorkOrderListItem
                    {
                        CaseId = caseId,
                        ClientName = clientName,
                        Status = status,
                        SortTime = sortTime,
                        DisplayLabel = label,
                        FilePath = file
                    });
                }
                catch
                {
                    /* skip corrupt */
                }
            }

            return items
                .OrderByDescending(i => i.SortTime)
                .Take(count)
                .ToList();
        }

        public static WorkOrderDetail LoadWorkOrderDetail(string caseId)
        {
            var path = GetWorkOrderPath(caseId);
            if (!File.Exists(path))
                throw new FileNotFoundException($"Work order not found: {caseId}", path);

            var root = JsonNode.Parse(File.ReadAllText(path)) as JsonObject
                ?? throw new InvalidOperationException("Work order file is invalid.");

            var runs = new List<WorkOrderRunDetail>();
            if (root["Runs"] is JsonArray runArray)
            {
                foreach (var node in runArray)
                {
                    if (node is not JsonObject runObj)
                        continue;
                    runs.Add(MapRunDetail(runObj));
                }
            }

            return new WorkOrderDetail
            {
                CaseId = root["CaseId"]?.GetValue<string>() ?? caseId,
                Status = root["Status"]?.GetValue<string>() ?? string.Empty,
                ClientName = root["ClientName"]?.GetValue<string>() ?? string.Empty,
                ClientPhone = root["ClientPhone"]?.GetValue<string>() ?? string.Empty,
                TechnicianNotes = root["TechnicianNotes"]?.GetValue<string>() ?? string.Empty,
                CreatedAt = WorkOrderTimestampFormatter.Format(root["CreatedAt"]?.GetValue<string>()),
                ClosedAt = WorkOrderTimestampFormatter.Format(
                    root["ClosedAt"]?.GetValue<string>(),
                    emptyDisplay: string.Equals(root["Status"]?.GetValue<string>(), "Open", StringComparison.OrdinalIgnoreCase)
                        ? "(still open)"
                        : string.Empty),
                FinalReportPdf = WorkOrderPathHelper.ResolveOperatorPdfPath(
                    caseId,
                    root["FinalReportPdf"]?.GetValue<string>()),
                GuidanceContext = MapGuidanceContext(root),
                Runs = runs
            };
        }

        public static void TryUpdateGuidanceContext(string symptomId, string healthPreset)
        {
            var active = GetActiveWorkOrder();
            if (active == null || string.IsNullOrWhiteSpace(symptomId))
                return;

            try
            {
                var root = JsonNode.Parse(File.ReadAllText(active.WorkOrderPath)) as JsonObject;
                if (root == null || !string.Equals(root["Status"]?.GetValue<string>(), "Open", StringComparison.OrdinalIgnoreCase))
                    return;

                root["GuidanceContext"] = new JsonObject
                {
                    ["LastSymptomId"] = symptomId,
                    ["LastHealthPreset"] = string.IsNullOrWhiteSpace(healthPreset) ? symptomId : healthPreset,
                    ["UpdatedAt"] = DateTime.Now.ToString("o")
                };
                File.WriteAllText(active.WorkOrderPath, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            }
            catch
            {
                /* best-effort */
            }
        }

        public static string GetVerifyHealthPreset()
        {
            var active = GetActiveWorkOrder();
            if (active == null)
                return "quick_vitals";

            var ctx = WorkOrderTimelineService.LoadGuidanceContext(active.CaseId);
            if (!string.IsNullOrWhiteSpace(ctx?.LastHealthPreset))
                return ctx.LastHealthPreset;

            return "quick_vitals";
        }

        public static void TryRecordCaseEvent(
            string eventKind,
            string displayLabel,
            string? sourceArtifact,
            string overallHealth,
            string summary,
            string workflowName = "")
        {
            var active = GetActiveWorkOrder();
            if (active == null)
                return;

            try
            {
                var root = JsonNode.Parse(File.ReadAllText(active.WorkOrderPath)) as JsonObject;
                if (root == null || !string.Equals(root["Status"]?.GetValue<string>(), "Open", StringComparison.OrdinalIgnoreCase))
                    return;

                var runs = root["Runs"] as JsonArray ?? new JsonArray();
                if (!string.IsNullOrWhiteSpace(sourceArtifact) &&
                    runs.Any(n => string.Equals(n?["SourceArtifact"]?.GetValue<string>(), sourceArtifact, StringComparison.OrdinalIgnoreCase)))
                {
                    return;
                }

                var wfName = string.IsNullOrWhiteSpace(workflowName) ? eventKind : workflowName;
                var run = new JsonObject
                {
                    ["WorkflowName"] = wfName,
                    ["CompletedAt"] = DateTime.Now.ToString("o"),
                    ["Status"] = "Completed",
                    ["OverallHealth"] = overallHealth,
                    ["Pass"] = 0,
                    ["Warn"] = 0,
                    ["Fail"] = 0,
                    ["Summary"] = summary,
                    ["KeyFindings"] = new JsonArray(),
                    ["ReportJson"] = string.Empty,
                    ["ReportHtml"] = string.Empty,
                    ["Environment"] = Directory.Exists(@"X:\Windows\System32") ? "WinPE" : "Windows",
                    ["EventKind"] = eventKind,
                    ["DisplayLabel"] = displayLabel,
                    ["SourceArtifact"] = sourceArtifact ?? string.Empty
                };

                runs.Add(run);
                root["Runs"] = runs;
                File.WriteAllText(active.WorkOrderPath, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
                NotifyChanged();
            }
            catch (Exception ex)
            {
                RecordTryAttachFailure(active.CaseId, ex);
            }
        }

        public static void TryRecordChuPreBootRun(string jsonPath, int passCount, int warnCount, int failCount)
        {
            var health = failCount > 0 ? "Critical" : warnCount > 0 ? "Warning" : "Healthy";
            var summary = $"CHU pre-boot: {passCount} pass, {warnCount} warn, {failCount} fail";
            TryRecordCaseEvent("ChuPreBoot", "CHU pre-boot", jsonPath, health, summary, "CHU_PreBoot");
        }

        public static void TryRecordCstScanRun(
            string? artifactPath,
            string targetPath,
            string verdict,
            string? reportPdfPath = null)
        {
            var fileName = string.IsNullOrWhiteSpace(targetPath)
                ? "selected file"
                : Path.GetFileName(targetPath);
            var label = $"CST scan: {fileName}";
            var health = verdict.Equals("Threat", StringComparison.OrdinalIgnoreCase) ? "Critical"
                : verdict.Equals("Review", StringComparison.OrdinalIgnoreCase)
                    || verdict.Equals("Suspicious", StringComparison.OrdinalIgnoreCase)
                    || verdict.Equals("Incomplete", StringComparison.OrdinalIgnoreCase) ? "Warning"
                : "Healthy";
            var summary = $"CST verdict: {verdict}";
            var artifactOrPdf = !string.IsNullOrWhiteSpace(reportPdfPath) && File.Exists(reportPdfPath)
                ? reportPdfPath
                : artifactPath;
            TryRecordCaseEvent("CstScan", label, artifactOrPdf, health, summary, "ProcessAnalyzer_CST");
        }

        private static WorkOrderGuidanceContext? MapGuidanceContext(JsonObject root)
        {
            if (root["GuidanceContext"] is not JsonObject ctx)
                return null;

            return new WorkOrderGuidanceContext
            {
                LastSymptomId = ctx["LastSymptomId"]?.GetValue<string>() ?? string.Empty,
                LastHealthPreset = ctx["LastHealthPreset"]?.GetValue<string>() ?? string.Empty,
                UpdatedAt = ctx["UpdatedAt"]?.GetValue<string>() ?? string.Empty
            };
        }

        public static ActiveWorkOrderInfo CreateWorkOrder(WorkOrderFormData form)
        {
            var existing = GetActiveWorkOrder();
            if (existing != null)
                throw new InvalidOperationException($"Work order already active: {existing.CaseId}. Close it before starting a new one.");

            form ??= new WorkOrderFormData();
            var toolkitRoot = GetToolkitRoot();
            var caseId = AllocateNextCaseId(toolkitRoot);
            Directory.CreateDirectory(WorkOrderPathHelper.GetInternalWorkOrdersDirectory());
            Directory.CreateDirectory(Path.GetDirectoryName(GetActivePointerPath())!);

            var workPath = WorkOrderPathHelper.GetInternalJsonPath(caseId);
            var order = new JsonObject
            {
                ["CaseId"] = caseId,
                ["Sequence"] = ParseSequence(caseId),
                ["Status"] = "Open",
                ["CreatedAt"] = DateTime.Now.ToString("o"),
                ["ClosedAt"] = null,
                ["MachineName"] = Environment.MachineName,
                ["UserName"] = Environment.UserName,
                ["ClientName"] = form.ClientName ?? string.Empty,
                ["ClientPhone"] = form.ClientPhone ?? string.Empty,
                ["TechnicianNotes"] = form.TechnicianNotes ?? string.Empty,
                ["EnvironmentHistory"] = new JsonArray(Environment.GetEnvironmentVariable("CDE_WINPE") == "1" ? "WinPE" : "Windows"),
                ["Runs"] = new JsonArray()
            };

            File.WriteAllText(workPath, order.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            WriteActivePointer(caseId, workPath);
            NotifyChanged();
            return GetActiveWorkOrder() ?? throw new InvalidOperationException("Work order was created but could not be loaded.");
        }

        public static void UpdateActiveWorkOrder(WorkOrderFormData form)
        {
            var active = GetActiveWorkOrder() ?? throw new InvalidOperationException("No active work order.");
            ApplyFormToWorkOrder(active.WorkOrderPath, form, onlyIfActive: true);
            NotifyChanged();
        }

        public static string CloseActiveWorkOrder(WorkOrderFormData? form)
        {
            var active = GetActiveWorkOrder() ?? throw new InvalidOperationException("No active work order to close.");
            if (form != null)
                ApplyFormToWorkOrder(active.WorkOrderPath, form, onlyIfActive: true);

            var root = JsonNode.Parse(File.ReadAllText(active.WorkOrderPath)) as JsonObject
                ?? throw new InvalidOperationException("Work order file is invalid.");

            // Export PDF first. On failure the on-disk Status stays Open and the pointer remains.
            var pdfPath = ExportFinalReport(root, active.CaseId);
            root["Status"] = "Closed";
            root["ClosedAt"] = DateTime.Now.ToString("o");
            root["FinalReportPdf"] = pdfPath;
            File.WriteAllText(active.WorkOrderPath, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));

            ClearActivePointer();
            NotifyChanged();
            return pdfPath;
        }

        private static void ApplyFormToWorkOrder(string workOrderPath, WorkOrderFormData form, bool onlyIfActive)
        {
            var root = JsonNode.Parse(File.ReadAllText(workOrderPath)) as JsonObject
                ?? throw new InvalidOperationException("Work order file is invalid.");

            if (onlyIfActive && !string.Equals(root["Status"]?.GetValue<string>(), "Open", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Work order is not open.");

            root["ClientName"] = form.ClientName ?? string.Empty;
            root["ClientPhone"] = form.ClientPhone ?? string.Empty;
            root["TechnicianNotes"] = form.TechnicianNotes ?? string.Empty;
            File.WriteAllText(workOrderPath, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        }

        public static void TryRecordWorkflowReport(
            WorkflowExecutionReport report,
            string? reportJsonPath,
            string? reportHtmlPath = null,
            string? reportPdfPath = null)
        {
            if (report == null || string.IsNullOrWhiteSpace(report.WorkflowName))
                return;

            var active = GetActiveWorkOrder();
            if (active == null)
                return;

            try
            {
                var root = JsonNode.Parse(File.ReadAllText(active.WorkOrderPath)) as JsonObject;
                if (root == null || !string.Equals(root["Status"]?.GetValue<string>(), "Open", StringComparison.OrdinalIgnoreCase))
                    return;

                var runs = root["Runs"] as JsonArray ?? new JsonArray();
                if (!string.IsNullOrWhiteSpace(reportJsonPath) &&
                    runs.Any(n => string.Equals(n?["ReportJson"]?.GetValue<string>(), reportJsonPath, StringComparison.OrdinalIgnoreCase)))
                {
                    return;
                }

                var steps = report.Steps ?? new List<WorkflowExecutionStep>();
                var warn = steps.Count(s => string.Equals(s.Status, "Warn", StringComparison.OrdinalIgnoreCase));
                var fail = steps.Count(s => string.Equals(s.Status, "Fail", StringComparison.OrdinalIgnoreCase));
                var pass = steps.Count(s => string.Equals(s.Status, "Pass", StringComparison.OrdinalIgnoreCase));
                var health = !string.IsNullOrWhiteSpace(report.OverallHealth)
                    ? report.OverallHealth
                    : fail > 0 ? "Critical" : warn > 0 ? "Warning" : "Healthy";

                var summary = BuildSummary(steps, health, pass, warn, fail);
                var keyFindings = BuildKeyFindingsJson(steps, health);
                var displayLabel = report.WorkflowName ?? "Workflow";
                if (string.Equals(report.WorkflowName, "FastFixes", StringComparison.OrdinalIgnoreCase))
                {
                    var firstStep = steps.FirstOrDefault();
                    if (firstStep != null && !string.IsNullOrWhiteSpace(firstStep.Name))
                        displayLabel = $"Fast Fix: {firstStep.Name}";
                }

                var pdfPath = ReportPathHelper.ResolveOperatorPdf(reportPdfPath, reportJsonPath, reportHtmlPath);

                var run = new JsonObject
                {
                    ["WorkflowName"] = report.WorkflowName,
                    ["CompletedAt"] = (report.EndTime == default ? DateTime.Now : report.EndTime).ToString("o"),
                    ["Status"] = report.Status ?? "Completed",
                    ["OverallHealth"] = health,
                    ["Pass"] = pass,
                    ["Warn"] = warn,
                    ["Fail"] = fail,
                    ["Summary"] = summary,
                    ["KeyFindings"] = keyFindings,
                    ["ReportJson"] = reportJsonPath ?? string.Empty,
                    ["ReportHtml"] = string.Empty,
                    ["ReportPdf"] = pdfPath,
                    ["Environment"] = report.EnvironmentMode ?? string.Empty,
                    ["EventKind"] = "Workflow",
                    ["DisplayLabel"] = displayLabel,
                    ["SourceArtifact"] = string.Empty
                };

                runs.Add(run);
                root["Runs"] = runs;
                AppendEnvironment(root, report.EnvironmentMode);
                File.WriteAllText(active.WorkOrderPath, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
                NotifyChanged();
            }
            catch (Exception ex)
            {
                RecordTryAttachFailure(active.CaseId, ex);
            }
        }

        private static void RecordTryAttachFailure(string caseId, Exception ex)
        {
            LastWorkOrderAttachError = $"{caseId}: {ex.Message}";
            Debug.WriteLine($"WorkOrder TryRecord failed [{caseId}]: {ex.Message}");
        }

        public static void ApplyActiveCaseToProcess()
        {
            try
            {
                var active = GetActiveWorkOrder();
                if (active == null)
                {
                    Environment.SetEnvironmentVariable("CDE_ACTIVE_CASE_ID", null, EnvironmentVariableTarget.Process);
                    return;
                }

                Environment.SetEnvironmentVariable("CDE_ACTIVE_CASE_ID", active.CaseId, EnvironmentVariableTarget.Process);
            }
            catch
            {
                // Non-fatal: shell must still open in WinPE.
            }
        }

        private static JsonArray BuildKeyFindingsJson(IEnumerable<WorkflowExecutionStep> steps, string health)
        {
            var array = new JsonArray();
            foreach (var finding in ExtractKeyFindings(steps, health))
            {
                array.Add(new JsonObject
                {
                    ["Step"] = finding.Step,
                    ["Status"] = finding.Status,
                    ["Detail"] = finding.Detail
                });
            }
            return array;
        }

        internal static IReadOnlyList<WorkOrderKeyFinding> ExtractKeyFindings(IEnumerable<WorkflowExecutionStep> steps, string? overallHealth)
        {
            var findings = new List<WorkOrderKeyFinding>();
            foreach (var step in steps ?? Enumerable.Empty<WorkflowExecutionStep>())
            {
                if (!string.Equals(step.Status, "Warn", StringComparison.OrdinalIgnoreCase) &&
                    !string.Equals(step.Status, "Fail", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                var detail = !string.IsNullOrWhiteSpace(step.Output) ? step.Output : step.Detail ?? string.Empty;
                detail = Truncate(detail, 280);
                findings.Add(new WorkOrderKeyFinding
                {
                    Step = string.IsNullOrWhiteSpace(step.Name) ? "Step" : step.Name,
                    Status = step.Status,
                    Detail = detail
                });

                if (findings.Count >= 8)
                    break;
            }

            if (findings.Count == 0)
            {
                findings.Add(new WorkOrderKeyFinding
                {
                    Step = "Overall",
                    Status = "Pass",
                    Detail = $"No warnings or failures recorded. Health: {overallHealth ?? "Healthy"}."
                });
            }

            return findings;
        }

        private static WorkOrderRunDetail MapRunDetail(JsonObject runObj)
        {
            var findings = new List<WorkOrderKeyFinding>();
            if (runObj["KeyFindings"] is JsonArray storedFindings && storedFindings.Count > 0)
            {
                foreach (var node in storedFindings)
                {
                    if (node is not JsonObject f)
                        continue;
                    findings.Add(new WorkOrderKeyFinding
                    {
                        Step = f["Step"]?.GetValue<string>() ?? string.Empty,
                        Status = f["Status"]?.GetValue<string>() ?? string.Empty,
                        Detail = f["Detail"]?.GetValue<string>() ?? string.Empty
                    });
                }
            }
            else
            {
                var reportPath = runObj["ReportJson"]?.GetValue<string>();
                if (!string.IsNullOrWhiteSpace(reportPath) && File.Exists(reportPath))
                {
                    try
                    {
                        var report = JsonSerializer.Deserialize<WorkflowExecutionReport>(
                            File.ReadAllText(reportPath),
                            new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
                        if (report?.Steps != null)
                        {
                            findings.AddRange(ExtractKeyFindings(report.Steps, runObj["OverallHealth"]?.GetValue<string>()));
                        }
                    }
                    catch
                    {
                        /* fallback below */
                    }
                }

                if (findings.Count == 0 && !string.IsNullOrWhiteSpace(runObj["Summary"]?.GetValue<string>()))
                {
                    findings.Add(new WorkOrderKeyFinding
                    {
                        Step = "Summary",
                        Status = runObj["OverallHealth"]?.GetValue<string>() ?? "Info",
                        Detail = runObj["Summary"]?.GetValue<string>() ?? string.Empty
                    });
                }
            }

            return new WorkOrderRunDetail
            {
                WorkflowName = runObj["WorkflowName"]?.GetValue<string>() ?? "Workflow",
                CompletedAt = WorkOrderTimestampFormatter.Format(runObj["CompletedAt"]?.GetValue<string>()),
                OverallHealth = runObj["OverallHealth"]?.GetValue<string>() ?? string.Empty,
                Status = runObj["Status"]?.GetValue<string>() ?? string.Empty,
                Summary = runObj["Summary"]?.GetValue<string>() ?? string.Empty,
                EventKind = runObj["EventKind"]?.GetValue<string>() ?? "Workflow",
                DisplayLabel = runObj["DisplayLabel"]?.GetValue<string>() ?? string.Empty,
                ReportJson = runObj["ReportJson"]?.GetValue<string>() ?? string.Empty,
                ReportHtml = runObj["ReportHtml"]?.GetValue<string>() ?? string.Empty,
                ReportPdf = ResolveStoredReportPdf(runObj),
                SourceArtifact = runObj["SourceArtifact"]?.GetValue<string>() ?? string.Empty,
                KeyFindings = findings
            };
        }

        private static string ResolveStoredReportPdf(JsonObject runObj)
        {
            var storedPdf = runObj["ReportPdf"]?.GetValue<string>();
            var reportJson = runObj["ReportJson"]?.GetValue<string>();
            var reportHtml = runObj["ReportHtml"]?.GetValue<string>();
            return ReportPathHelper.ResolveOperatorPdf(storedPdf, reportJson, reportHtml);
        }

        private static string BuildSummary(IEnumerable<WorkflowExecutionStep> steps, string health, int pass, int warn, int fail)
        {
            var issues = steps
                .Where(s => string.Equals(s.Status, "Warn", StringComparison.OrdinalIgnoreCase) ||
                            string.Equals(s.Status, "Fail", StringComparison.OrdinalIgnoreCase))
                .Take(3)
                .Select(s =>
                {
                    var detail = !string.IsNullOrWhiteSpace(s.Output) ? s.Output : s.Detail ?? string.Empty;
                    return $"{s.Name}: {s.Status} - {Truncate(detail, 180)}";
                })
                .ToList();

            return issues.Count > 0
                ? string.Join(" | ", issues)
                : $"Completed - {health} ({pass} pass, {warn} warn, {fail} fail)";
        }

        private static string Truncate(string value, int max)
        {
            if (string.IsNullOrEmpty(value) || value.Length <= max)
                return value;
            return value[..max] + "...";
        }

        private static DateTime ParseSortTime(JsonObject root, string filePath)
        {
            foreach (var key in new[] { "ClosedAt", "CreatedAt" })
            {
                var raw = root[key]?.GetValue<string>();
                if (!string.IsNullOrWhiteSpace(raw) && DateTime.TryParse(raw, out var parsed))
                    return parsed;
            }

            return File.GetLastWriteTime(filePath);
        }

        private static void AppendEnvironment(JsonObject root, string? environmentMode)
        {
            if (string.IsNullOrWhiteSpace(environmentMode))
                return;

            var history = root["EnvironmentHistory"] as JsonArray ?? new JsonArray();
            if (history.Any(n => string.Equals(n?.GetValue<string>(), environmentMode, StringComparison.OrdinalIgnoreCase)))
                return;

            history.Add(environmentMode);
            root["EnvironmentHistory"] = history;
        }

        private static string ExportFinalReport(JsonObject order, string caseId)
        {
            var pdfPath = WorkOrderPathHelper.GetOperatorPdfPath(caseId);
            if (!WorkOrderReportPdfService.TryGenerate(order, pdfPath, out var error))
                throw new InvalidOperationException($"Unable to generate work order PDF: {error}");

            return pdfPath;
        }

        private static string AllocateNextCaseId(string toolkitRoot)
        {
            var counterPath = Path.Combine(toolkitRoot, "Config", "case_counter.json");
            var lockPath = counterPath + ".lock";
            Directory.CreateDirectory(Path.GetDirectoryName(counterPath)!);

            using var lockStream = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            var prefix = "CDE";
            var lastSequence = 0;

            if (File.Exists(counterPath))
            {
                try
                {
                    var node = JsonNode.Parse(File.ReadAllText(counterPath)) as JsonObject;
                    prefix = node?["Prefix"]?.GetValue<string>() ?? "CDE";
                    lastSequence = node?["LastSequence"]?.GetValue<int>() ?? 0;
                }
                catch { /* defaults */ }
            }

            lastSequence++;
            var payload = new JsonObject
            {
                ["Prefix"] = prefix,
                ["LastSequence"] = lastSequence
            };
            File.WriteAllText(counterPath, payload.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));

            return $"{prefix}-{DateTime.Now:yyyyMMdd}-{lastSequence:D5}";
        }

        private static int ParseSequence(string caseId)
        {
            var parts = caseId.Split('-');
            if (parts.Length >= 3 && int.TryParse(parts[^1], out var seq))
                return seq;
            return 0;
        }

        private static void WriteActivePointer(string caseId, string workOrderPath)
        {
            caseId = WorkOrderPathHelper.RequireValidCaseId(caseId);
            // Re-resolve under known roots; do not trust caller-supplied absolute paths.
            var resolvedPath = WorkOrderPathHelper.ResolveInternalJsonPath(caseId);
            if (string.IsNullOrWhiteSpace(resolvedPath))
                resolvedPath = workOrderPath;

            var pointer = new JsonObject
            {
                ["CaseId"] = caseId,
                ["WorkOrderPath"] = resolvedPath,
                ["ActivatedAt"] = DateTime.Now.ToString("o")
            };
            var pointerPath = GetActivePointerPath();
            Directory.CreateDirectory(Path.GetDirectoryName(pointerPath)!);
            File.WriteAllText(pointerPath, pointer.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            Environment.SetEnvironmentVariable("CDE_ACTIVE_CASE_ID", caseId, EnvironmentVariableTarget.Process);
        }

        private static void ClearActivePointer()
        {
            var pointerPath = GetActivePointerPath();
            if (File.Exists(pointerPath))
            {
                try { File.Delete(pointerPath); } catch { /* best-effort */ }
            }
            Environment.SetEnvironmentVariable("CDE_ACTIVE_CASE_ID", null, EnvironmentVariableTarget.Process);
        }

        internal sealed class WorkOrderRecordCleanupResult
        {
            public int FilesDeleted { get; init; }
            public IReadOnlyList<string> Errors { get; init; } = Array.Empty<string>();
            public bool ActiveWorkOrderCleared { get; init; }
        }

        /// <summary>
        /// Packages case-scoped workflow/CST artifacts, timeline, and latest publish verify log for field support.
        /// No cloud upload — local zip only. Does not include ClientPhone or entire workflows/cst trees.
        /// </summary>
        public static string ExportFieldFeedbackBundle(string? caseId = null)
        {
            var toolkitRoot = GetToolkitRoot();
            var active = GetActiveWorkOrder();
            var resolvedCaseId = string.IsNullOrWhiteSpace(caseId)
                ? active?.CaseId
                : caseId.Trim();
            if (string.IsNullOrWhiteSpace(resolvedCaseId))
                throw new InvalidOperationException("Open a work order or supply a case ID before exporting feedback.");

            resolvedCaseId = WorkOrderPathHelper.RequireValidCaseId(resolvedCaseId);

            var stamp = DateTime.Now.ToString("yyyyMMdd_HHmmss");
            var exportDir = Path.Combine(toolkitRoot, "CDE", "Runtime", "Data", "exports");
            Directory.CreateDirectory(exportDir);
            var zipPath = Path.Combine(exportDir, $"cde_feedback_{resolvedCaseId}_{stamp}.zip");

            if (File.Exists(zipPath))
                File.Delete(zipPath);

            var tempRoot = Path.Combine(Path.GetTempPath(), $"cde_feedback_{Guid.NewGuid():N}");
            Directory.CreateDirectory(tempRoot);

            try
            {
                var allowedRoots = new[]
                {
                    Path.Combine(toolkitRoot, "CDE", "Runtime", "Data"),
                    WorkOrderPathHelper.GetInternalWorkOrdersDirectory(),
                    WorkOrderPathHelper.GetOperatorWorkOrdersDirectory(),
                    Path.Combine(toolkitRoot, "Logs")
                };

                var workOrderPath = GetWorkOrderPath(resolvedCaseId);
                JsonObject? orderRoot = null;
                if (File.Exists(workOrderPath))
                {
                    orderRoot = JsonNode.Parse(File.ReadAllText(workOrderPath)) as JsonObject;
                    WriteScrubbedWorkOrderCopy(orderRoot, workOrderPath, Path.Combine(tempRoot, "workorders", Path.GetFileName(workOrderPath)), toolkitRoot);
                }

                var artifactPaths = CollectCaseArtifactPaths(orderRoot);
                foreach (var sourcePath in artifactPaths)
                {
                    TryCopyCaseArtifact(sourcePath, tempRoot, toolkitRoot, allowedRoots);
                }

                // Also pick up any workflow/cst JSON that explicitly belongs to this CaseId
                // (without copying entire session trees).
                CopyCaseIdTaggedJson(
                    Path.Combine(toolkitRoot, "CDE", "Runtime", "Data", "workflows"),
                    "workflows",
                    resolvedCaseId,
                    tempRoot,
                    toolkitRoot,
                    artifactPaths);
                CopyCaseIdTaggedJson(
                    Path.Combine(toolkitRoot, "CDE", "Runtime", "Data", "cst"),
                    "cst",
                    resolvedCaseId,
                    tempRoot,
                    toolkitRoot,
                    artifactPaths);

                var timeline = WorkOrderTimelineService.LoadTimelineForCase(resolvedCaseId);
                var timelineJson = RedactFeedbackText(
                    JsonSerializer.Serialize(timeline, new JsonSerializerOptions { WriteIndented = true }),
                    toolkitRoot);
                File.WriteAllText(Path.Combine(tempRoot, "timeline.json"), timelineJson);

                var verifyRoot = Path.Combine(toolkitRoot, "CDE", "Runtime", "Data");
                if (Directory.Exists(verifyRoot))
                {
                    var latestVerify = Directory.GetFiles(verifyRoot, "publish_verify_*.json")
                        .OrderByDescending(File.GetLastWriteTimeUtc)
                        .FirstOrDefault();
                    if (!string.IsNullOrWhiteSpace(latestVerify))
                        TryCopyCaseArtifact(latestVerify, tempRoot, toolkitRoot, allowedRoots, forceRelativeDest: $"verify/{Path.GetFileName(latestVerify)}");
                }

                var manifest = new JsonObject
                {
                    ["CaseId"] = resolvedCaseId,
                    ["ExportedAt"] = DateTime.Now.ToString("o"),
                    ["ToolkitRoot"] = "<redacted>"
                };
                File.WriteAllText(
                    Path.Combine(tempRoot, "manifest.json"),
                    manifest.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));

                System.IO.Compression.ZipFile.CreateFromDirectory(tempRoot, zipPath);
                return zipPath;
            }
            finally
            {
                try
                {
                    if (Directory.Exists(tempRoot))
                        Directory.Delete(tempRoot, recursive: true);
                }
                catch
                {
                    // best-effort cleanup
                }
            }
        }

        private static readonly Regex FeedbackSecretRegex = new(
            @"\b(password|pwd|token|apikey|api_key|secret)\s*=\s*[^\s,;""']+",
            RegexOptions.Compiled | RegexOptions.IgnoreCase);

        private static HashSet<string> CollectCaseArtifactPaths(JsonObject? orderRoot)
        {
            var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (orderRoot == null)
                return paths;

            void Add(string? path)
            {
                if (!string.IsNullOrWhiteSpace(path))
                    paths.Add(path.Trim());
            }

            Add(orderRoot["FinalReportPdf"]?.GetValue<string>());

            if (orderRoot["Runs"] is JsonArray runs)
            {
                foreach (var node in runs)
                {
                    if (node is not JsonObject run)
                        continue;
                    Add(run["ReportJson"]?.GetValue<string>());
                    Add(run["ReportHtml"]?.GetValue<string>());
                    Add(run["ReportPdf"]?.GetValue<string>());
                    Add(run["SourceArtifact"]?.GetValue<string>());
                }
            }

            return paths;
        }

        private static void WriteScrubbedWorkOrderCopy(JsonObject? root, string sourcePath, string destPath, string toolkitRoot)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(destPath)!);
            if (root == null)
            {
                File.Copy(sourcePath, destPath, overwrite: true);
                return;
            }

            var clone = JsonNode.Parse(root.ToJsonString()) as JsonObject ?? new JsonObject();
            // Exclude client phone from share zip (not opted-in).
            clone.Remove("ClientPhone");

            RedactJsonAbsolutePaths(clone, toolkitRoot);
            var text = RedactFeedbackText(
                clone.ToJsonString(new JsonSerializerOptions { WriteIndented = true }),
                toolkitRoot);
            File.WriteAllText(destPath, text);
        }

        private static void RedactJsonAbsolutePaths(JsonNode? node, string toolkitRoot)
        {
            if (node is JsonObject obj)
            {
                foreach (var prop in obj.ToList())
                {
                    if (prop.Value is JsonValue value && value.TryGetValue<string>(out var s) && LooksLikeAbsolutePath(s))
                    {
                        obj[prop.Key] = ToFeedbackRelativePath(s, toolkitRoot);
                    }
                    else
                    {
                        RedactJsonAbsolutePaths(prop.Value, toolkitRoot);
                    }
                }
            }
            else if (node is JsonArray arr)
            {
                for (var i = 0; i < arr.Count; i++)
                    RedactJsonAbsolutePaths(arr[i], toolkitRoot);
            }
        }

        private static bool LooksLikeAbsolutePath(string value)
        {
            if (string.IsNullOrWhiteSpace(value) || value.Length < 3)
                return false;
            return Path.IsPathRooted(value) || value.Contains(":\\", StringComparison.Ordinal) || value.StartsWith("\\\\", StringComparison.Ordinal);
        }

        private static string ToFeedbackRelativePath(string path, string toolkitRoot)
        {
            try
            {
                var full = Path.GetFullPath(path);
                var root = Path.GetFullPath(toolkitRoot)
                    .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                if (full.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
                    full.StartsWith(root + Path.AltDirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(full, root, StringComparison.OrdinalIgnoreCase))
                {
                    return "<toolkit>/" + full[root.Length..].TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
                        .Replace('\\', '/');
                }

                return "<redacted-path>/" + Path.GetFileName(path);
            }
            catch
            {
                return "<redacted-path>";
            }
        }

        private static string RedactFeedbackText(string text, string toolkitRoot)
        {
            if (string.IsNullOrEmpty(text))
                return text;

            var result = FeedbackSecretRegex.Replace(text, match =>
            {
                var eq = match.Value.IndexOf('=');
                if (eq < 0)
                    return match.Value;
                return match.Value[..(eq + 1)] + "***";
            });

            try
            {
                var root = Path.GetFullPath(toolkitRoot)
                    .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                if (!string.IsNullOrWhiteSpace(root))
                {
                    result = Regex.Replace(
                        result,
                        Regex.Escape(root).Replace("\\\\", @"[\\/]"),
                        "<toolkit>",
                        RegexOptions.IgnoreCase);
                }
            }
            catch
            {
                // best-effort
            }

            return result;
        }

        private static void TryCopyCaseArtifact(
            string sourcePath,
            string tempRoot,
            string toolkitRoot,
            IEnumerable<string> allowedRoots,
            string? forceRelativeDest = null)
        {
            if (string.IsNullOrWhiteSpace(sourcePath) || !File.Exists(sourcePath))
                return;

            string full;
            try
            {
                full = Path.GetFullPath(sourcePath);
            }
            catch
            {
                return;
            }

            if (!allowedRoots.Any(root => WorkOrderPathHelper.IsPathUnderRoot(full, root)))
                return;

            var relative = forceRelativeDest;
            if (string.IsNullOrWhiteSpace(relative))
            {
                var dataRoot = Path.Combine(toolkitRoot, "CDE", "Runtime", "Data");
                if (WorkOrderPathHelper.IsPathUnderRoot(full, dataRoot))
                {
                    var dataFull = Path.GetFullPath(dataRoot)
                        .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                    relative = full[dataFull.Length..].TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                }
                else
                {
                    relative = Path.Combine("artifacts", Path.GetFileName(full));
                }
            }

            var dest = Path.Combine(tempRoot, relative.Replace('/', Path.DirectorySeparatorChar));
            Directory.CreateDirectory(Path.GetDirectoryName(dest)!);

            var ext = Path.GetExtension(full);
            if (string.Equals(ext, ".json", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(ext, ".txt", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(ext, ".log", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(ext, ".html", StringComparison.OrdinalIgnoreCase))
            {
                var text = RedactFeedbackText(File.ReadAllText(full), toolkitRoot);
                File.WriteAllText(dest, text);
            }
            else
            {
                File.Copy(full, dest, overwrite: true);
            }
        }

        private static void CopyCaseIdTaggedJson(
            string sourceDir,
            string relativeDest,
            string caseId,
            string tempRoot,
            string toolkitRoot,
            HashSet<string> alreadyCopied)
        {
            if (!Directory.Exists(sourceDir))
                return;

            foreach (var file in Directory.GetFiles(sourceDir, "*.json"))
            {
                var full = Path.GetFullPath(file);
                if (alreadyCopied.Contains(full) || alreadyCopied.Contains(file))
                    continue;

                try
                {
                    var node = JsonNode.Parse(File.ReadAllText(file));
                    var fileCase = node?["CaseId"]?.GetValue<string>()?.Trim();
                    if (!string.Equals(fileCase, caseId, StringComparison.OrdinalIgnoreCase))
                        continue;
                }
                catch
                {
                    continue;
                }

                alreadyCopied.Add(full);
                var dest = Path.Combine(tempRoot, relativeDest, Path.GetFileName(file));
                Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                var text = RedactFeedbackText(File.ReadAllText(file), toolkitRoot);
                File.WriteAllText(dest, text);
            }
        }

        public static WorkOrderRecordCleanupResult ClearRecentInternalWorkOrderRecords()
        {
            var dir = WorkOrderPathHelper.GetInternalWorkOrdersDirectory();
            var errors = new List<string>();
            var filesDeleted = 0;
            var active = GetActiveWorkOrder();
            var activePath = active?.WorkOrderPath ?? string.Empty;
            var activeWasInRuntime = !string.IsNullOrWhiteSpace(activePath) &&
                activePath.StartsWith(dir, StringComparison.OrdinalIgnoreCase);

            if (Directory.Exists(dir))
            {
                foreach (var file in Directory.GetFiles(dir, "*.json"))
                {
                    var name = Path.GetFileName(file);
                    if (!WorkOrderPathHelper.IsCanonicalWorkOrderFile(name))
                        continue;

                    try
                    {
                        File.SetAttributes(file, FileAttributes.Normal);
                        File.Delete(file);
                        filesDeleted++;
                    }
                    catch (Exception ex)
                    {
                        errors.Add($"{file}: {ex.Message}");
                    }
                }
            }

            var activeCleared = false;
            if (activeWasInRuntime && (active == null || !File.Exists(activePath)))
            {
                ClearActivePointer();
                NotifyChanged();
                activeCleared = true;
            }

            return new WorkOrderRecordCleanupResult
            {
                FilesDeleted = filesDeleted,
                Errors = errors,
                ActiveWorkOrderCleared = activeCleared
            };
        }

        private static void NotifyChanged() => ActiveWorkOrderChanged?.Invoke();
    }
}
