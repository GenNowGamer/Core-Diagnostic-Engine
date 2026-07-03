using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Text.Json;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace ToolkitGUI.Services
{
    internal sealed class TabularScanReportDocument
    {
        public string WorkflowName { get; init; } = "ScanReport";
        public string Title { get; init; } = "Scan Report";
        public string Summary { get; init; } = string.Empty;
        public string OverallHealth { get; init; } = "Info";
        public DateTime GeneratedAt { get; init; } = DateTime.Now;
        public IReadOnlyList<string> ColumnHeaders { get; init; } = Array.Empty<string>();
        public IReadOnlyList<IReadOnlyList<string>> Rows { get; init; } = Array.Empty<IReadOnlyList<string>>();
        public IReadOnlyDictionary<string, string> Metrics { get; init; } =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    }

    internal sealed class TabularScanReportPaths
    {
        public string BaseName { get; init; } = string.Empty;
        public string JsonPath { get; init; } = string.Empty;
        public string PdfPath { get; init; } = string.Empty;
    }

    internal static class TabularScanReportService
    {
        static TabularScanReportService()
        {
            QuestPDF.Settings.License = LicenseType.Community;
        }

        public static TabularScanReportPaths EnsureReports(
            TabularScanReportDocument document,
            string? existingBaseName = null)
        {
            var dataDir = ReportPathHelper.GetScanDataRoot();
            var logsDir = ReportPathHelper.GetOperatorLogsRoot();
            Directory.CreateDirectory(dataDir);
            Directory.CreateDirectory(logsDir);

            var safeWorkflow = SanitizeFileName(document.WorkflowName);
            var baseName = string.IsNullOrWhiteSpace(existingBaseName)
                ? $"{safeWorkflow}_{document.GeneratedAt:yyyyMMdd_HHmmss}"
                : SanitizeFileName(existingBaseName);

            var jsonPath = Path.Combine(dataDir, $"{baseName}.json");
            var pdfPath = Path.Combine(logsDir, $"{baseName}.pdf");

            WriteJson(jsonPath, document);

            return new TabularScanReportPaths
            {
                BaseName = baseName,
                JsonPath = jsonPath,
                PdfPath = pdfPath
            };
        }

        public static bool TryGeneratePdf(TabularScanReportDocument document, string pdfPath, out string? error)
        {
            error = null;
            try
            {
                var directory = Path.GetDirectoryName(pdfPath);
                if (!string.IsNullOrWhiteSpace(directory))
                {
                    Directory.CreateDirectory(directory);
                }

                Document.Create(container => ComposePdf(container, document)).GeneratePdf(pdfPath);
                return File.Exists(pdfPath);
            }
            catch (Exception ex)
            {
                error = ex.Message;
                return false;
            }
        }

        public static void CopyReport(string sourcePath, string destinationPath)
        {
            var directory = Path.GetDirectoryName(destinationPath);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            File.Copy(sourcePath, destinationPath, overwrite: true);
        }

        private static void WriteJson(string path, TabularScanReportDocument document)
        {
            var payload = new
            {
                workflowName = document.WorkflowName,
                title = document.Title,
                summary = document.Summary,
                overallHealth = document.OverallHealth,
                generatedAt = document.GeneratedAt.ToString("o"),
                metrics = document.Metrics,
                columns = document.ColumnHeaders,
                rows = document.Rows
            };

            var json = JsonSerializer.Serialize(payload, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(path, json, Encoding.UTF8);
        }

        private static void ComposePdf(IDocumentContainer container, TabularScanReportDocument document)
        {
            container.Page(page =>
            {
                page.Size(PageSizes.A4.Landscape());
                page.Margin(28);
                page.DefaultTextStyle(x => x.FontSize(9).FontColor(Colors.Grey.Darken3));

                page.Header().Column(column =>
                {
                    column.Item().Background("#0078D4").Padding(12).Row(row =>
                    {
                        row.RelativeItem().Column(inner =>
                        {
                            inner.Item().Text("Core Diagnostic Engine").FontSize(9).FontColor(Colors.White);
                            inner.Item().Text(document.Title).FontSize(16).Bold().FontColor(Colors.White);
                            inner.Item().Text($"{Environment.MachineName} · {document.GeneratedAt:yyyy-MM-dd HH:mm}")
                                .FontSize(8).FontColor("#D6ECFF");
                        });
                        row.ConstantItem(80).AlignRight().AlignMiddle()
                            .Background(HealthBadgeColor(document.OverallHealth)).Padding(6)
                            .Text(document.OverallHealth).FontSize(9).Bold().FontColor(Colors.White);
                    });
                    if (!string.IsNullOrWhiteSpace(document.Summary))
                    {
                        column.Item().PaddingTop(8).Text(document.Summary).FontSize(9);
                    }
                });

                page.Content().PaddingTop(10).Table(table =>
                {
                    table.ColumnsDefinition(columns =>
                    {
                        foreach (var _ in document.ColumnHeaders)
                        {
                            columns.RelativeColumn();
                        }
                    });

                    table.Header(header =>
                    {
                        foreach (var columnHeader in document.ColumnHeaders)
                        {
                            header.Cell().Background("#F3F6FA").Padding(6)
                                .Text(columnHeader).SemiBold().FontSize(8);
                        }
                    });

                    if (document.Rows.Count == 0)
                    {
                        table.Cell().ColumnSpan((uint)Math.Max(document.ColumnHeaders.Count, 1))
                            .Padding(8).Text("No rows recorded.").Italic();
                        return;
                    }

                    foreach (var row in document.Rows)
                    {
                        for (var i = 0; i < document.ColumnHeaders.Count; i++)
                        {
                            var value = i < row.Count ? row[i] : string.Empty;
                            table.Cell().BorderBottom(1).BorderColor("#E8EDF3").Padding(6)
                                .Text(TrimCell(value)).FontSize(8);
                        }
                    }
                });

                page.Footer().AlignCenter().Text(text =>
                {
                    text.Span("Page ");
                    text.CurrentPageNumber();
                    text.Span(" of ");
                    text.TotalPages();
                });
            });
        }

        private static string Encode(string? value) =>
            WebUtility.HtmlEncode(value ?? string.Empty);

        private static string TrimCell(string? value)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return string.Empty;
            }

            const int max = 500;
            var trimmed = value.Trim();
            return trimmed.Length <= max ? trimmed : trimmed[..max] + "...";
        }

        private static string SanitizeFileName(string value)
        {
            var text = string.IsNullOrWhiteSpace(value) ? "ScanReport" : value;
            foreach (var c in Path.GetInvalidFileNameChars())
            {
                text = text.Replace(c, '_');
            }

            return text;
        }

        private static string HealthBadgeColor(string health) => health.ToUpperInvariant() switch
        {
            "CRITICAL" or "HIJACKED" => "#C42B1C",
            "WARNING" or "SUSPICIOUS" => "#926800",
            "HEALTHY" or "PASS" => "#0D7A3E",
            _ => "#0078D4"
        };
    }
}
