using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace ToolkitGUI.Services
{
    /// <summary>Public so PowerShell can load ToolkitGUI.dll and invoke PDF export for script-side closes.</summary>
    public static class WorkOrderReportPdfService
    {
        static WorkOrderReportPdfService()
        {
            QuestPDF.Settings.License = LicenseType.Community;
        }

        public static bool TryGenerateFromJsonFile(string orderJsonPath, string pdfPath, out string? error)
        {
            error = null;
            try
            {
                if (!File.Exists(orderJsonPath))
                {
                    error = $"Work order JSON not found: {orderJsonPath}";
                    return false;
                }

                var root = JsonNode.Parse(File.ReadAllText(orderJsonPath)) as JsonObject;
                if (root == null)
                {
                    error = "Work order JSON is invalid.";
                    return false;
                }

                return TryGenerate(root, pdfPath, out error);
            }
            catch (Exception ex)
            {
                error = ex.Message;
                return false;
            }
        }

        public static bool TryGenerate(JsonObject order, string pdfPath, out string? error)
        {
            error = null;
            try
            {
                var directory = Path.GetDirectoryName(pdfPath);
                if (!string.IsNullOrWhiteSpace(directory))
                    Directory.CreateDirectory(directory);

                Document.Create(container => ComposeDocument(container, order)).GeneratePdf(pdfPath);
                return File.Exists(pdfPath);
            }
            catch (Exception ex)
            {
                error = ex.Message;
                return false;
            }
        }

        private sealed class RunEntry
        {
            public int Index { get; init; }
            public string Label { get; init; } = string.Empty;
            public string CompletedAt { get; init; } = string.Empty;
            public string Health { get; init; } = "Healthy";
            public string Summary { get; init; } = string.Empty;
        }

        private static void ComposeDocument(IDocumentContainer container, JsonObject order)
        {
            var caseId = order["CaseId"]?.GetValue<string>() ?? "Work Order";
            var clientName = order["ClientName"]?.GetValue<string>() ?? string.Empty;
            var clientPhone = order["ClientPhone"]?.GetValue<string>() ?? string.Empty;
            var notes = order["TechnicianNotes"]?.GetValue<string>() ?? string.Empty;
            var createdAt = FormatTimestamp(order["CreatedAt"]?.GetValue<string>());
            var closedAt = FormatTimestamp(order["ClosedAt"]?.GetValue<string>());
            var runs = ParseRuns(order["Runs"] as JsonArray);

            container.Page(page =>
            {
                page.Size(PageSizes.A4);
                page.Margin(36);
                page.DefaultTextStyle(x => x.FontSize(10).FontColor(Colors.Grey.Darken3));

                page.Header().Column(column =>
                {
                    column.Item().Text("CDE Work Order").FontSize(20).Bold().FontColor(Colors.Blue.Darken2);
                    column.Item().PaddingTop(4).Text(caseId).FontSize(12).SemiBold();
                });

                page.Footer().AlignCenter().Text(text =>
                {
                    text.Span("Core Diagnostic Engine · Page ");
                    text.CurrentPageNumber();
                    text.Span(" of ");
                    text.TotalPages();
                });

                page.Content().PaddingTop(12).Column(column =>
                {
                    column.Spacing(10);
                    column.Item().Text($"Client: {clientName}    Phone: {clientPhone}");
                    column.Item().Text($"Opened: {createdAt}    Closed: {closedAt}");
                    column.Item().PaddingTop(6).Text("Technician notes").SemiBold();
                    column.Item().Text(string.IsNullOrWhiteSpace(notes) ? "(none)" : notes);

                    column.Item().PaddingTop(10).Text($"Recorded runs ({runs.Count})").FontSize(12).SemiBold();
                    column.Item().Element(c => ComposeRunsTable(c, runs));

                    column.Item().PaddingTop(16).Text("Run summaries").FontSize(12).SemiBold();
                    if (runs.Count == 0)
                    {
                        column.Item().PaddingTop(6).Text("No workflow runs were recorded for this work order.").Italic();
                        return;
                    }

                    foreach (var run in runs)
                    {
                        column.Item().PaddingTop(10).Element(c => ComposeRunSummarySection(c, run, runs.Count));
                    }
                });
            });
        }

        private static List<RunEntry> ParseRuns(JsonArray? runs)
        {
            var list = new List<RunEntry>();
            if (runs == null)
                return list;

            var index = 0;
            foreach (var node in runs)
            {
                if (node is not JsonObject run)
                    continue;

                index++;
                var label = run["DisplayLabel"]?.GetValue<string>();
                if (string.IsNullOrWhiteSpace(label))
                    label = run["WorkflowName"]?.GetValue<string>() ?? "Workflow";

                list.Add(new RunEntry
                {
                    Index = index,
                    Label = label,
                    CompletedAt = FormatTimestamp(run["CompletedAt"]?.GetValue<string>()),
                    Health = run["OverallHealth"]?.GetValue<string>() ?? "Healthy",
                    Summary = BuildSummaryText(run)
                });
            }

            return list;
        }

        private static string BuildSummaryText(JsonObject run)
        {
            var summary = run["Summary"]?.GetValue<string>()?.Trim();
            if (!string.IsNullOrWhiteSpace(summary))
                return summary;

            if (run["KeyFindings"] is not JsonArray findings || findings.Count == 0)
                return "(No summary recorded.)";

            var lines = new List<string>();
            foreach (var node in findings)
            {
                if (node is not JsonObject finding)
                    continue;

                var step = finding["Step"]?.GetValue<string>() ?? "Finding";
                var status = finding["Status"]?.GetValue<string>() ?? string.Empty;
                var detail = finding["Detail"]?.GetValue<string>() ?? string.Empty;
                lines.Add(string.IsNullOrWhiteSpace(status)
                    ? $"{step}: {detail}"
                    : $"{step} ({status}): {detail}");
            }

            return lines.Count == 0 ? "(No summary recorded.)" : string.Join(Environment.NewLine, lines);
        }

        private static void ComposeRunsTable(IContainer container, IReadOnlyList<RunEntry> runs)
        {
            container.Table(table =>
            {
                table.ColumnsDefinition(columns =>
                {
                    columns.RelativeColumn(2);
                    columns.RelativeColumn(4);
                    columns.ConstantColumn(72);
                });

                table.Header(header =>
                {
                    header.Cell().Background(Colors.Grey.Lighten3).Padding(6).Text("Time").SemiBold();
                    header.Cell().Background(Colors.Grey.Lighten3).Padding(6).Text("Tool / scan").SemiBold();
                    header.Cell().Background(Colors.Grey.Lighten3).Padding(6).AlignCenter().Text("Health").SemiBold();
                });

                if (runs.Count == 0)
                {
                    table.Cell().ColumnSpan(3).Padding(6)
                        .Text("No workflow runs were recorded for this work order.");
                    return;
                }

                foreach (var run in runs)
                {
                    table.Cell().Padding(6).Text(run.CompletedAt);
                    table.Cell().Padding(6).Text(run.Label);
                    table.Cell().Padding(6).AlignCenter()
                        .Text(run.Health).FontColor(HealthColor(run.Health)).SemiBold();
                }
            });
        }

        private static void ComposeRunSummarySection(IContainer container, RunEntry run, int totalRuns)
        {
            container.Border(1).BorderColor("#D8DEE6").Background("#F8FAFD").Padding(12).Column(column =>
            {
                column.Spacing(4);
                column.Item().Row(row =>
                {
                    row.RelativeItem().Text($"Run {run.Index} of {totalRuns}: {run.Label}")
                        .FontSize(11).SemiBold().FontColor("#1B2B40");
                    row.ConstantItem(88).AlignRight().Text(run.Health)
                        .FontSize(10).SemiBold().FontColor(HealthColor(run.Health));
                });
                column.Item().Text($"Completed: {run.CompletedAt}").FontSize(9).FontColor("#5A6B80");
                column.Item().PaddingTop(6).LineHorizontal(1).LineColor("#E1E6EF");
                column.Item().PaddingTop(8).Text(FormatSummaryBody(run.Summary))
                    .FontSize(9).LineHeight(1.35f).FontColor("#1B2B40");
            });
        }

        private static string FormatSummaryBody(string summary)
        {
            if (string.IsNullOrWhiteSpace(summary))
                return "(No summary recorded.)";

            var normalized = summary
                .Replace("\r\n", "\n")
                .Replace(" | ", "\n");

            return normalized;
        }

        private static string FormatTimestamp(string? raw) =>
            WorkOrderTimestampFormatter.Format(raw);

        private static string HealthColor(string health)
        {
            if (health.Equals("Critical", StringComparison.OrdinalIgnoreCase) ||
                health.Equals("Fail", StringComparison.OrdinalIgnoreCase))
            {
                return "#C42B1C";
            }

            if (health.Equals("Warning", StringComparison.OrdinalIgnoreCase) ||
                health.Equals("Warn", StringComparison.OrdinalIgnoreCase))
            {
                return "#926800";
            }

            return "#0D7A3E";
        }
    }
}
