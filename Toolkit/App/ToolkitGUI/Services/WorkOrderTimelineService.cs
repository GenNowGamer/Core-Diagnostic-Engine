using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using ToolkitGUI.Models;

namespace ToolkitGUI.Services
{
    internal static class WorkOrderTimelineService
    {
        public static IReadOnlyList<WorkOrderTimelineEntry> LoadTimelineForCase(string caseId)
        {
            var path = WorkOrderPathHelper.ResolveInternalJsonPath(caseId);
            if (!File.Exists(path))
                return Array.Empty<WorkOrderTimelineEntry>();

            try
            {
                var root = JsonNode.Parse(File.ReadAllText(path)) as JsonObject;
                if (root?["Runs"] is not JsonArray runs)
                    return Array.Empty<WorkOrderTimelineEntry>();

                return runs
                    .OfType<JsonObject>()
                    .Select(MapTimelineEntry)
                    .OrderByDescending(e => ParseTime(e.CompletedAt))
                    .ToList();
            }
            catch
            {
                return Array.Empty<WorkOrderTimelineEntry>();
            }
        }

        public static IReadOnlyList<WorkOrderTimelineEntry> LoadActiveTimeline()
        {
            var active = WorkOrderService.GetActiveWorkOrder();
            if (active == null)
                return Array.Empty<WorkOrderTimelineEntry>();

            return LoadTimelineForCase(active.CaseId);
        }

        public static WorkOrderGuidanceContext? LoadGuidanceContext(string caseId)
        {
            var path = WorkOrderPathHelper.ResolveInternalJsonPath(caseId);
            if (!File.Exists(path))
                return null;

            try
            {
                var root = JsonNode.Parse(File.ReadAllText(path)) as JsonObject;
                var ctx = root?["GuidanceContext"] as JsonObject;
                if (ctx == null)
                    return null;

                return new WorkOrderGuidanceContext
                {
                    LastSymptomId = ctx["LastSymptomId"]?.GetValue<string>() ?? string.Empty,
                    LastHealthPreset = ctx["LastHealthPreset"]?.GetValue<string>() ?? string.Empty,
                    UpdatedAt = ctx["UpdatedAt"]?.GetValue<string>() ?? string.Empty
                };
            }
            catch
            {
                return null;
            }
        }

        private static WorkOrderTimelineEntry MapTimelineEntry(JsonObject runObj) => new()
        {
            CompletedAt = WorkOrderTimestampFormatter.Format(runObj["CompletedAt"]?.GetValue<string>()),
            DisplayLabel = runObj["DisplayLabel"]?.GetValue<string>() ?? string.Empty,
            WorkflowName = runObj["WorkflowName"]?.GetValue<string>() ?? "Workflow",
            EventKind = runObj["EventKind"]?.GetValue<string>() ?? "Workflow",
            OverallHealth = runObj["OverallHealth"]?.GetValue<string>() ?? string.Empty,
            ReportJson = runObj["ReportJson"]?.GetValue<string>() ?? string.Empty,
            ReportHtml = runObj["ReportHtml"]?.GetValue<string>() ?? string.Empty,
            ReportPdf = ReportPathHelper.ResolveOperatorPdf(
                runObj["ReportPdf"]?.GetValue<string>(),
                runObj["ReportJson"]?.GetValue<string>(),
                runObj["ReportHtml"]?.GetValue<string>()),
            SourceArtifact = runObj["SourceArtifact"]?.GetValue<string>() ?? string.Empty
        };

        private static DateTime ParseTime(string? raw) =>
            DateTime.TryParse(raw, out var parsed) ? parsed : DateTime.MinValue;
    }
}
