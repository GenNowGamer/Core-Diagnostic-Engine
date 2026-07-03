using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;
using ToolkitGUI.Models;

namespace ToolkitGUI.Services
{
    internal static class WorkflowReportPdfService
    {
        private const int MaxOutputChars = 12000;
        private static string? _currentPdfPath;

        static WorkflowReportPdfService()
        {
            QuestPDF.Settings.License = LicenseType.Community;
        }

        public static string GetPdfPathForJsonReport(string jsonPath)
        {
            return Path.ChangeExtension(jsonPath, ".pdf");
        }

        public static bool TryGeneratePdf(WorkflowExecutionReport report, string pdfPath, out string? error)
        {
            error = null;
            if (report == null)
            {
                error = "Report is null.";
                return false;
            }

            try
            {
                _currentPdfPath = pdfPath;
                var directory = Path.GetDirectoryName(pdfPath);
                if (!string.IsNullOrWhiteSpace(directory))
                {
                    Directory.CreateDirectory(directory);
                }

                Document.Create(container => ComposeDocument(container, report)).GeneratePdf(pdfPath);
                return File.Exists(pdfPath);
            }
            catch (Exception ex)
            {
                error = ex.Message;
                return false;
            }
            finally
            {
                _currentPdfPath = null;
            }
        }

        private static void ComposeDocument(IDocumentContainer container, WorkflowExecutionReport report)
        {
            var steps = report.Steps ?? new List<WorkflowExecutionStep>();
            var counts = CountSteps(steps);
            var health = ResolveHealth(report, counts);
            var machine = ResolveReportMachineName();
            var activeCase = WorkOrderService.GetActiveWorkOrder();

            container.Page(page =>
            {
                page.Size(PageSizes.A4);
                page.Margin(36);
                page.DefaultTextStyle(x => x.FontSize(10).FontColor(Colors.Grey.Darken3));

                page.Header().Element(c => ComposeHeader(c, report, health, machine));
                page.Footer().AlignCenter().Text(text =>
                {
                    text.Span("Core Diagnostic Engine · Page ");
                    text.CurrentPageNumber();
                    text.Span(" of ");
                    text.TotalPages();
                });

                page.Content().PaddingTop(12).Column(column =>
                {
                    column.Spacing(14);
                    column.Item().Element(c => ComposeSummaryCards(c, report, counts, health, Environment.UserName, activeCase));
                    column.Item().Element(c => ComposeStatusChart(c, counts));
                    column.Item().Element(c => ComposeStepsSection(c, steps, report.WorkflowName));
                    column.Item().Element(c => ComposeErrorsSection(c, report.Errors));
                });
            });
        }

        private static void ComposeHeader(IContainer container, WorkflowExecutionReport report, string health, string machine)
        {
            container.Column(column =>
            {
                column.Item().Background("#0078D4").Padding(16).Row(row =>
                {
                    row.RelativeItem().Column(inner =>
                    {
                        inner.Item().Text("Core Diagnostic Engine").FontSize(11).FontColor(Colors.White);
                        inner.Item().Text(FormatWorkflowTitle(report.WorkflowName))
                            .FontSize(20).Bold().FontColor(Colors.White);
                        inner.Item().Text($"Machine: {machine} · Generated {DateTime.Now:yyyy-MM-dd HH:mm}")
                            .FontSize(9).FontColor("#D6ECFF");
                    });
                    row.ConstantItem(90).AlignRight().AlignMiddle()
                        .Background(HealthBadgeColor(health)).Padding(8)
                        .Text(health).FontSize(11).Bold().FontColor(Colors.White);
                });
            });
        }

        private static void ComposeSummaryCards(
            IContainer container,
            WorkflowExecutionReport report,
            StepCounts counts,
            string health,
            string user,
            ActiveWorkOrderInfo? activeCase)
        {
            container.Row(row =>
            {
                row.Spacing(8);
                row.RelativeItem().Element(c => SummaryCard(c, "Duration", $"{report.DurationSec:0.0}s"));
                row.RelativeItem().Element(c => SummaryCard(c, "Environment", string.IsNullOrWhiteSpace(report.EnvironmentMode) ? "—" : report.EnvironmentMode));
                row.RelativeItem().Element(c => SummaryCard(c, "Workflow status", string.IsNullOrWhiteSpace(report.Status) ? "—" : report.Status));
                row.RelativeItem().Element(c => SummaryCard(c, "Steps", counts.Total.ToString()));
                row.RelativeItem().Element(c => SummaryCard(c, "Operator", user));
            });

            if (activeCase != null)
            {
                container.PaddingTop(8).Row(row =>
                {
                    row.Spacing(8);
                    row.RelativeItem().Element(c => SummaryCard(c, "Case ID", activeCase.CaseId));
                    row.RelativeItem().Element(c => SummaryCard(c, "Client", string.IsNullOrWhiteSpace(activeCase.ClientName) ? "—" : activeCase.ClientName));
                });
            }
        }

        private static void SummaryCard(IContainer container, string label, string value)
        {
            container.Border(1).BorderColor("#E1E6EF").Background("#F8FAFD").Padding(10).Column(col =>
            {
                col.Item().Text(label).FontSize(8).SemiBold().FontColor("#5A6B80");
                col.Item().PaddingTop(4).Text(value).FontSize(12).Bold().FontColor("#1B2B40");
            });
        }

        private static void ComposeStatusChart(IContainer container, StepCounts counts)
        {
            container.Column(column =>
            {
                column.Item().Text("Step status overview").FontSize(12).Bold().FontColor("#1B2B40");
                column.Item().PaddingTop(8).Element(c => DrawStackedBar(c, counts));
                column.Item().PaddingTop(8).Row(row =>
                {
                    row.Spacing(12);
                    LegendChip(row, "Pass", counts.Pass, "#0D7A3E");
                    LegendChip(row, "Warn", counts.Warn, "#926800");
                    LegendChip(row, "Fail", counts.Fail, "#C42B1C");
                    LegendChip(row, "Skip / Other", counts.Skip + counts.Other, "#6B7280");
                });
            });
        }

        private static void LegendChip(RowDescriptor row, string label, int value, string color)
        {
            row.AutoItem().Row(inner =>
            {
                inner.ConstantItem(10).Height(10).Background(color);
                inner.AutoItem().PaddingLeft(4).Text($"{label}: {value}").FontSize(9);
            });
        }

        private static void DrawStackedBar(IContainer container, StepCounts counts)
        {
            var total = Math.Max(counts.Total, 1);
            var barHeight = 18f;

            container.Height(barHeight).Row(row =>
            {
                void AddSegment(int count, string color)
                {
                    if (count <= 0) return;
                    row.RelativeItem(count).Height(barHeight).Background(color);
                }

                AddSegment(counts.Pass, "#0D7A3E");
                AddSegment(counts.Warn, "#D29922");
                AddSegment(counts.Fail, "#C42B1C");
                AddSegment(counts.Skip + counts.Other, "#9CA3AF");
            });
        }

        private static void ComposeStepsSection(IContainer container, List<WorkflowExecutionStep> steps, string? workflowName)
        {
            container.Column(column =>
            {
                column.Item().Text("Detailed results").FontSize(12).Bold().FontColor("#1B2B40");
                if (steps.Count == 0)
                {
                    column.Item().PaddingTop(6).Text("No steps were recorded.").Italic();
                    return;
                }

                foreach (var step in steps)
                {
                    column.Item().PaddingTop(8).Element(c => ComposeStepCard(c, step, workflowName));
                }
            });
        }

        private static void ComposeStepCard(IContainer container, WorkflowExecutionStep step, string? workflowName)
        {
            var status = string.IsNullOrWhiteSpace(step.Status) ? "Unknown" : step.Status;
            var rawOutput = !string.IsNullOrWhiteSpace(step.Output) ? step.Output : step.Detail;
            var formatted = WorkflowResultFormatter.Format(step.Name, rawOutput);
            var displayTitle = WorkflowStepLabelHelper.ResolveDisplayTitle(step, workflowName);
            var repeatTestLabel = WorkflowStepLabelHelper.ShouldRepeatTestLabelOnItems(workflowName);

            container.Border(1).BorderColor("#E1E6EF").Column(col =>
            {
                col.Item().ShowEntire().Background("#F3F6FA").Padding(10).Row(row =>
                {
                    row.RelativeItem().Text(displayTitle).FontSize(13).Bold().FontColor("#1B2B40");
                    row.ConstantItem(70).AlignRight()
                        .Background(StatusBadgeColor(status)).Padding(4)
                        .Text(status).FontSize(9).Bold().FontColor(Colors.White);
                });

                if (!string.IsNullOrWhiteSpace(formatted.Overview))
                {
                    col.Item().PaddingHorizontal(10).PaddingTop(8)
                        .Text(formatted.Overview).FontSize(9.5f).LineHeight(1.3f).FontColor("#1B2B40");
                }

                if (formatted.Sections.Count > 0)
                {
                    col.Item().Padding(10).Element(c =>
                        ComposeFormattedSections(c, formatted, displayTitle, repeatTestLabel, step.Name));
                }
                else if (ShouldUseHtmlStyleFallback(formatted, rawOutput))
                {
                    col.Item().Padding(10).Element(c => ComposeMonospaceBlock(c, TrimOutput(rawOutput)));
                }
                else if (!string.IsNullOrWhiteSpace(rawOutput))
                {
                    col.Item().Padding(10).Text(TrimOutput(rawOutput)).FontSize(9).LineHeight(1.25f);
                }
                else
                {
                    col.Item().Padding(10).Text("No additional output.").Italic().FontColor("#6B7280");
                }
            });
        }

        private static void ComposeFormattedSections(
            IContainer container,
            FormattedWorkflowOutput formatted,
            string displayTitle,
            bool repeatTestLabel,
            string? stepName)
        {
            container.Column(column =>
            {
                column.Spacing(8);
                foreach (var section in formatted.Sections)
                {
                    column.Item().Element(c =>
                        ComposeFormattedSection(c, section, displayTitle, repeatTestLabel, stepName));
                }
            });
        }

        private static void ComposeFormattedSection(
            IContainer container,
            FormattedResultSection section,
            string displayTitle,
            bool repeatTestLabel,
            string? stepName)
        {
            if (WorkflowResultFormatter.UsesDeviceGroupedSections(stepName)
                && section.Lines.Count > 0
                && section.Items.Count == 0)
            {
                container.Border(1).BorderColor("#E8EDF3").Background("#FBFCFE").Padding(8).Column(column =>
                {
                    if (!string.IsNullOrWhiteSpace(section.Title))
                    {
                        column.Item().Text(section.Title).FontSize(10).Bold().FontColor("#1B2B40");
                    }

                    column.Item().PaddingTop(4).Column(linesColumn =>
                    {
                        foreach (var line in section.Lines)
                        {
                            linesColumn.Item().PaddingBottom(2).Element(c =>
                                ComposeDevicePropertyLine(c, line));
                        }
                    });
                });
                return;
            }

            container.Column(column =>
            {
                if (!string.IsNullOrWhiteSpace(section.Title))
                {
                    column.Item().Text(BuildSectionTitle(displayTitle, section.Title))
                        .FontSize(10).Bold().FontColor("#37475F");
                }
                else if (repeatTestLabel)
                {
                    column.Item().Text(displayTitle).FontSize(10).Bold().FontColor("#37475F");
                }

                if (section.Lines.Count > 0)
                {
                    column.Item().PaddingTop(6).Element(c =>
                        ComposeMonospaceBlock(c, string.Join(Environment.NewLine, section.Lines)));
                }

                foreach (var item in section.Items)
                {
                    column.Item().PaddingTop(6).Border(1).BorderColor("#E8EDF3").Background("#FBFCFE")
                        .Padding(8).Element(c => ComposeFormattedItem(c, item, displayTitle, repeatTestLabel));
                }
            });
        }

        private static string BuildSectionTitle(string displayTitle, string sectionTitle)
        {
            if (string.IsNullOrWhiteSpace(sectionTitle))
            {
                return displayTitle;
            }

            return $"{displayTitle} · {sectionTitle}";
        }

        private static void ComposeFormattedItem(
            IContainer container,
            FormattedResultItem item,
            string displayTitle,
            bool repeatTestLabel)
        {
            container.Column(column =>
            {
                column.Spacing(4);
                if (repeatTestLabel)
                {
                    column.Item().Text(displayTitle).FontSize(8).SemiBold().FontColor("#0078D4");
                }

                column.Item().Row(row =>
                {
                    row.AutoItem().Background(FormattedStatusColor(item.Status)).PaddingHorizontal(6).PaddingVertical(2)
                        .Text(item.StatusLabel).FontSize(8).Bold().FontColor(Colors.White);
                    row.RelativeItem().PaddingLeft(8).Text(item.Title).FontSize(9.5f).Bold().FontColor("#1B2B40");
                });

                if (!string.IsNullOrWhiteSpace(item.Location))
                {
                    column.Item().Text(text =>
                    {
                        text.Span("Location: ").SemiBold().FontSize(8.5f).FontColor("#5A6B80");
                        text.Span(item.Location).FontSize(8.5f).FontColor("#1B2B40");
                    });
                }

                if (!string.IsNullOrWhiteSpace(item.Subtitle))
                {
                    column.Item().Text(item.Subtitle).FontSize(8.5f).FontColor("#37475F");
                }

                if (!string.IsNullOrWhiteSpace(item.Path))
                {
                    column.Item().Text(text =>
                    {
                        text.Span("Path: ").SemiBold().FontSize(8.5f).FontColor("#5A6B80");
                        text.Span(item.Path).FontFamily("Consolas").FontSize(8f).FontColor("#1B2B40");
                    });
                }

                if (!string.IsNullOrWhiteSpace(item.Notes))
                {
                    if (item.Notes.Contains('\n', StringComparison.Ordinal))
                    {
                        column.Item().PaddingTop(4).Element(c =>
                            ComposeMonospaceBlock(c, item.Notes, 8f));
                    }
                    else
                    {
                        column.Item().Text(text =>
                        {
                            text.Span("Notes: ").SemiBold().FontSize(8.5f).FontColor("#5A6B80");
                            text.Span(item.Notes).FontSize(8.5f).FontColor("#37475F");
                        });
                    }
                }
            });
        }

        private static void ComposeDevicePropertyLine(IContainer container, string line)
        {
            var colon = line.IndexOf(':');
            if (colon <= 0)
            {
                container.Text(line).FontSize(8.5f).FontColor("#1B2B40");
                return;
            }

            container.Row(row =>
            {
                row.ConstantItem(112).Text(line[..colon].Trim()).FontSize(8.5f).SemiBold().FontColor("#5A6B80");
                row.RelativeItem().Text(line[(colon + 1)..].Trim()).FontSize(8.5f).FontColor("#1B2B40");
            });
        }

        private static void ComposeMonospaceBlock(IContainer container, string text, float fontSize = 8.5f)
        {
            container.Border(1).BorderColor("#E8EDF3").Background("#FBFCFE").Padding(8)
                .Text(TrimOutput(text))
                .FontFamily("Consolas").FontSize(fontSize).LineHeight(1.25f).FontColor("#1B2B40");
        }

        private static bool ShouldUseHtmlStyleFallback(FormattedWorkflowOutput formatted, string? rawOutput)
        {
            if (string.IsNullOrWhiteSpace(rawOutput))
            {
                return false;
            }

            var items = formatted.AllItems;
            if (items.Count < 6)
            {
                return false;
            }

            var infoCount = items.Count(i => i.Status == FormattedItemStatus.Info);
            return infoCount >= items.Count * 0.8;
        }

        private static string FormattedStatusColor(FormattedItemStatus status) => status switch
        {
            FormattedItemStatus.Ok => "#2E7D32",
            FormattedItemStatus.Review => "#926800",
            FormattedItemStatus.Warning => "#D29922",
            FormattedItemStatus.Fail => "#C42B1C",
            FormattedItemStatus.Info => "#0078D4",
            _ => "#5A6B80"
        };

        private static void ComposeErrorsSection(IContainer container, List<string>? errors)
        {
            var list = errors?.Where(e => !string.IsNullOrWhiteSpace(e)).ToList() ?? new List<string>();
            if (list.Count == 0) return;

            container.Column(column =>
            {
                column.Item().Text("Errors").FontSize(12).Bold().FontColor("#C42B1C");
                foreach (var error in list)
                {
                    column.Item().PaddingTop(6).Border(1).BorderColor("#F2C7C2").Background("#FFF5F4")
                        .Padding(8).Text(error).FontSize(9);
                }
            });
        }

        private static StepCounts CountSteps(IEnumerable<WorkflowExecutionStep> steps)
        {
            var counts = new StepCounts();
            foreach (var step in steps)
            {
                switch ((step.Status ?? string.Empty).Trim().ToUpperInvariant())
                {
                    case "PASS":
                    case "COMPLETED":
                        counts.Pass++;
                        break;
                    case "WARN":
                        counts.Warn++;
                        break;
                    case "FAIL":
                    case "ERROR":
                        counts.Fail++;
                        break;
                    case "SKIP":
                    case "N/A":
                    case "NA":
                        counts.Skip++;
                        break;
                    default:
                        counts.Other++;
                        break;
                }
            }

            return counts;
        }

        private static string ResolveHealth(WorkflowExecutionReport report, StepCounts counts)
        {
            if (!string.IsNullOrWhiteSpace(report.OverallHealth))
                return report.OverallHealth!;

            if (counts.Fail > 0) return "Critical";
            if (counts.Warn > 0) return "Warning";
            return "Healthy";
        }

        private static string FormatWorkflowTitle(string? workflowName)
        {
            if (string.IsNullOrWhiteSpace(workflowName))
                return "Workflow Report";

            return System.Text.RegularExpressions.Regex.Replace(workflowName, "([a-z])([A-Z])", "$1 $2");
        }

        private static string TrimOutput(string? text)
        {
            if (string.IsNullOrWhiteSpace(text))
                return string.Empty;

            var trimmed = text.Trim();
            if (trimmed.Length <= MaxOutputChars)
                return trimmed;

            var appendixPath = BuildOutputAppendixPath();
            try
            {
                if (!string.IsNullOrWhiteSpace(appendixPath))
                {
                    var directory = Path.GetDirectoryName(appendixPath);
                    if (!string.IsNullOrWhiteSpace(directory))
                        Directory.CreateDirectory(directory);
                    File.WriteAllText(appendixPath, trimmed);
                    return trimmed[..MaxOutputChars] + Environment.NewLine
                        + $"… (output truncated for PDF; full log: {appendixPath})";
                }
            }
            catch
            {
                // Fall back to simple truncation if appendix write fails.
            }

            return trimmed[..MaxOutputChars] + Environment.NewLine + "… (output truncated for PDF)";
        }

        private static string? BuildOutputAppendixPath()
        {
            if (string.IsNullOrWhiteSpace(_currentPdfPath))
                return null;

            var directory = Path.GetDirectoryName(_currentPdfPath);
            var stem = Path.GetFileNameWithoutExtension(_currentPdfPath);
            if (string.IsNullOrWhiteSpace(directory) || string.IsNullOrWhiteSpace(stem))
                return null;

            return Path.Combine(directory, $"{stem}_output_appendix.txt");
        }

        private static string ResolveReportMachineName()
        {
            var offline = Environment.GetEnvironmentVariable("OFFLINE_WINDOWS_ROOT");
            if (!string.IsNullOrWhiteSpace(offline))
            {
                return $"Offline target ({offline.TrimEnd('\\', '/')})";
            }

            return Environment.MachineName;
        }

        private static string HealthBadgeColor(string health) => health.ToUpperInvariant() switch
        {
            "CRITICAL" => "#C42B1C",
            "WARNING" => "#926800",
            "HEALTHY" => "#0D7A3E",
            _ => "#0078D4"
        };

        private static string StatusBadgeColor(string status) => status.ToUpperInvariant() switch
        {
            "PASS" or "COMPLETED" => "#0D7A3E",
            "WARN" => "#926800",
            "FAIL" or "ERROR" => "#C42B1C",
            "SKIP" or "N/A" or "NA" => "#6B7280",
            _ => "#0078D4"
        };

        private sealed class StepCounts
        {
            public int Pass { get; set; }
            public int Warn { get; set; }
            public int Fail { get; set; }
            public int Skip { get; set; }
            public int Other { get; set; }
            public int Total => Pass + Warn + Fail + Skip + Other;
        }
    }
}
