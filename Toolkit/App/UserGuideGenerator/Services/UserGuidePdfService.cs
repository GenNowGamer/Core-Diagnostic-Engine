using System.Text;
using System.Text.Json;
using Markdig;
using Markdig.Extensions.Tables;
using Markdig.Syntax;
using Markdig.Syntax.Inlines;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace UserGuideGenerator.Services;

public static class UserGuidePdfService
{
    private const string BrandBlue = "#0078D4";
    private const string TextPrimary = "#1B2B40";
    private const string TextSecondary = "#5A6B80";
    private const string BorderColor = "#E1E6EF";
    private const string CardBackground = "#F8FAFD";
    private const string CalloutTip = "#E8F4FD";
    private const string CalloutImportant = "#FFF4E5";
    private const string CalloutWarn = "#FDECEC";

    static UserGuidePdfService()
    {
        QuestPDF.Settings.License = LicenseType.Community;
    }

    public static bool TryGeneratePdf(
        string sourceDirectory,
        string outputPdfPath,
        string? version,
        out string? error)
    {
        error = null;
        try
        {
            var manifestPath = Path.Combine(sourceDirectory, "manifest.json");
            if (!File.Exists(manifestPath))
            {
                error = $"manifest.json not found in {sourceDirectory}";
                return false;
            }

            var manifest = JsonSerializer.Deserialize<UserGuideManifest>(
                File.ReadAllText(manifestPath),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });

            if (manifest?.Chapters == null || manifest.Chapters.Count == 0)
            {
                error = "User guide manifest has no chapters.";
                return false;
            }

            var pipeline = new MarkdownPipelineBuilder()
                .UseAdvancedExtensions()
                .Build();

            var chapters = new List<RenderedChapter>();
            foreach (var entry in manifest.Chapters)
            {
                var chapterPath = Path.Combine(sourceDirectory, entry.File);
                if (!File.Exists(chapterPath))
                {
                    error = $"Chapter file not found: {chapterPath}";
                    return false;
                }

                var markdown = File.ReadAllText(chapterPath);
                var document = Markdown.Parse(markdown, pipeline);
                chapters.Add(new RenderedChapter(entry, document));
            }

            var directory = Path.GetDirectoryName(outputPdfPath);
            if (!string.IsNullOrWhiteSpace(directory))
                Directory.CreateDirectory(directory);

            var displayVersion = string.IsNullOrWhiteSpace(version) ? "1.0" : version.Trim();

            Document.Create(container =>
            {
                container.Page(page =>
                {
                    page.Size(PageSizes.A4);
                    page.Margin(0);
                    ComposeCoverPage(page, manifest, displayVersion);
                });

                container.Page(page =>
                {
                    page.Size(PageSizes.A4);
                    page.Margin(36);
                    page.DefaultTextStyle(x => x.FontSize(10).FontColor(TextPrimary).LineHeight(1.35f));

                    page.Header().Element(c => ComposeRunningHeader(c, manifest.Title));
                    page.Footer().AlignCenter().Text(text =>
                    {
                        text.Span("Core Diagnostic Engine User Guide · Page ");
                        text.CurrentPageNumber();
                        text.Span(" of ");
                        text.TotalPages();
                    });

                    page.Content().Column(column =>
                    {
                        column.Spacing(10);
                        ComposeTableOfContents(column, manifest, chapters);

                        foreach (var chapter in chapters)
                        {
                            if (string.Equals(chapter.Entry.File, "00_Cover.md", StringComparison.OrdinalIgnoreCase))
                                continue;

                            column.Item().PaddingTop(16).Element(c => ComposeChapter(c, chapter));
                        }
                    });
                });
            }).GeneratePdf(outputPdfPath);

            return File.Exists(outputPdfPath);
        }
        catch (Exception ex)
        {
            error = ex.Message;
            return false;
        }
    }

    private static void ComposeCoverPage(PageDescriptor page, UserGuideManifest manifest, string version)
    {
        page.Content().Background(BrandBlue).Padding(48).Column(column =>
        {
            column.Item().PaddingTop(120).Text("Core Diagnostic Engine")
                .FontSize(14).FontColor("#D6ECFF");
            column.Item().PaddingTop(12).Text(manifest.Title ?? "User Guide")
                .FontSize(32).Bold().FontColor(Colors.White);
            column.Item().PaddingTop(8).Text(manifest.Subtitle ?? "Diagnosing and Repairing Windows PCs")
                .FontSize(16).FontColor("#D6ECFF");
            column.Item().PaddingTop(48).Text($"Version {version}")
                .FontSize(11).FontColor("#D6ECFF");
            column.Item().PaddingTop(4).Text($"Generated {DateTime.Now:yyyy-MM-dd}")
                .FontSize(11).FontColor("#D6ECFF");
        });
    }

    private static void ComposeRunningHeader(IContainer container, string? title)
    {
        container.BorderBottom(1).BorderColor(BorderColor).PaddingBottom(6).Row(row =>
        {
            row.RelativeItem().Text(title ?? "Core Diagnostic Engine User Guide")
                .FontSize(9).SemiBold().FontColor(TextSecondary);
            row.ConstantItem(80).AlignRight().Text("CDE User Guide")
                .FontSize(8).FontColor(TextSecondary);
        });
    }

    private static void ComposeTableOfContents(
        ColumnDescriptor column,
        UserGuideManifest manifest,
        IReadOnlyList<RenderedChapter> chapters)
    {
        column.Item().Text("Table of Contents").FontSize(18).Bold().FontColor(TextPrimary);
        column.Item().PaddingTop(8).Column(toc =>
        {
            toc.Spacing(4);
            var index = 1;
            foreach (var chapter in chapters)
            {
                if (!chapter.Entry.IncludeInToc)
                    continue;
                var title = chapter.Entry.Title ?? chapter.Entry.File;
                toc.Item().Text($"{index}. {title}").FontSize(11).FontColor(TextPrimary);
                index++;
            }
        });
        column.Item().PaddingTop(8).LineHorizontal(1).LineColor(BorderColor);
    }

    private static void ComposeChapter(IContainer container, RenderedChapter chapter)
    {
        container.Column(column =>
        {
            column.Spacing(8);
            foreach (var block in chapter.Document)
            {
                column.Item().Element(c => RenderBlock(c, block));
            }
        });
    }

    private static void RenderBlock(IContainer container, Block block)
    {
        switch (block)
        {
            case HeadingBlock heading:
                RenderHeading(container, heading);
                break;
            case ParagraphBlock paragraph:
                RenderParagraph(container, paragraph);
                break;
            case ListBlock list:
                RenderList(container, list);
                break;
            case QuoteBlock quote:
                RenderQuote(container, quote);
                break;
            case FencedCodeBlock code:
                RenderCodeBlock(container, code);
                break;
            case Table table:
                RenderTable(container, table);
                break;
            case ThematicBreakBlock:
                container.PaddingVertical(6).LineHorizontal(1).LineColor(BorderColor);
                break;
            default:
                if (block is LeafBlock leaf && leaf.Inline != null)
                    RenderInlines(container, leaf.Inline);
                break;
        }
    }

    private static void RenderHeading(IContainer container, HeadingBlock heading)
    {
        var text = GetInlineText(heading.Inline);
        if (heading.Level <= 1)
        {
            container.PaddingTop(4).Text(text).FontSize(20).Bold().FontColor(TextPrimary);
        }
        else if (heading.Level == 2)
        {
            container.PaddingTop(10).Text(text).FontSize(14).Bold().FontColor(TextPrimary);
        }
        else
        {
            container.PaddingTop(6).Text(text).FontSize(12).SemiBold().FontColor(TextSecondary);
        }
    }

    private static void RenderParagraph(IContainer container, ParagraphBlock paragraph)
    {
        if (paragraph.Inline == null)
            return;

        container.Text(text => AppendInlines(text, paragraph.Inline));
    }

    private static void RenderList(IContainer container, ListBlock list)
    {
        container.PaddingLeft(8).Column(column =>
        {
            var itemIndex = 1;
            foreach (var item in list)
            {
                if (item is not ListItemBlock listItem)
                    continue;

                var bullet = list.IsOrdered ? $"{itemIndex}." : "•";
                column.Item().PaddingBottom(4).Row(row =>
                {
                    row.ConstantItem(16).Text(bullet).FontSize(10);
                    row.RelativeItem().Column(inner =>
                    {
                        foreach (var child in listItem)
                        {
                            inner.Item().Element(c => RenderBlock(c, child));
                        }
                    });
                });
                itemIndex++;
            }
        });
    }

    private static void RenderQuote(IContainer container, QuoteBlock quote)
    {
        var sb = new StringBuilder();
        foreach (var block in quote)
        {
            if (block is ParagraphBlock p)
                sb.AppendLine(GetInlineText(p.Inline));
        }

        var content = sb.ToString().Trim();
        var background = CalloutTip;
        if (content.Contains("Important", StringComparison.OrdinalIgnoreCase))
            background = CalloutImportant;
        else if (content.Contains("WinPE only", StringComparison.OrdinalIgnoreCase))
            background = CalloutWarn;

        container.Border(1).BorderColor(BorderColor).Background(background).Padding(10)
            .Text(content).FontSize(9.5f).LineHeight(1.3f).FontColor(TextPrimary);
    }

    private static void RenderCodeBlock(IContainer container, FencedCodeBlock code)
    {
        var lines = new StringBuilder();
        foreach (var line in code.Lines.Lines)
        {
            if (line.Slice.Text != null)
                lines.AppendLine(line.Slice.ToString());
        }

        container.Border(1).BorderColor(BorderColor).Background(CardBackground).Padding(8)
            .Text(lines.ToString().TrimEnd())
            .FontFamily("Consolas").FontSize(8.5f).LineHeight(1.25f).FontColor(TextPrimary);
    }

    private static void RenderTable(IContainer container, Table table)
    {
        var rows = GetContentRows(table);
        if (rows.Count == 0)
            return;

        var columnCount = rows.Max(r => r.OfType<TableCell>().Count());
        if (columnCount <= 0)
            return;

        var headerRow = rows.FirstOrDefault(r => r.IsHeader);
        var bodyRows = headerRow == null
            ? rows
            : rows.Where(r => !ReferenceEquals(r, headerRow)).ToList();

        container.Table(tableDescriptor =>
        {
            tableDescriptor.ColumnsDefinition(columns =>
            {
                for (var i = 0; i < columnCount; i++)
                    columns.RelativeColumn();
            });

            if (headerRow != null)
            {
                tableDescriptor.Header(header =>
                {
                    EmitHeaderRowCells(header, headerRow, columnCount);
                });
            }

            foreach (var row in bodyRows)
            {
                EmitBodyRowCells(tableDescriptor, row, columnCount);
            }
        });
    }

    private static void EmitHeaderRowCells(TableCellDescriptor header, TableRow row, int columnCount)
    {
        var cells = row.OfType<TableCell>().Take(columnCount).ToList();
        for (var i = 0; i < columnCount; i++)
        {
            var text = i < cells.Count ? GetCellText(cells[i]) : string.Empty;
            header.Cell().Background("#F3F6FA").Border(1).BorderColor(BorderColor)
                .Padding(6).Text(text).FontSize(9).Bold().FontColor(TextPrimary);
        }
    }

    private static void EmitBodyRowCells(TableDescriptor tableDescriptor, TableRow row, int columnCount)
    {
        var cells = row.OfType<TableCell>().Take(columnCount).ToList();
        for (var i = 0; i < columnCount; i++)
        {
            var text = i < cells.Count ? GetCellText(cells[i]) : string.Empty;
            tableDescriptor.Cell().Border(1).BorderColor(BorderColor).Padding(6)
                .Text(text).FontSize(9).FontColor(TextPrimary);
        }
    }
    private static List<TableRow> GetContentRows(Table table)
    {
        return table.OfType<TableRow>()
            .Where(r => !IsDelimiterRow(r))
            .ToList();
    }

    private static bool IsDelimiterRow(TableRow row)
    {
        var cells = row.OfType<TableCell>().Select(GetCellText).ToList();
        if (cells.Count == 0)
            return true;

        return cells.All(static text =>
            string.IsNullOrWhiteSpace(text)
            || text.Trim().All(static c => c is '-' or ':' or ' '));
    }

    private static string GetCellText(TableCell cell)
    {
        var sb = new StringBuilder();
        foreach (var block in cell)
        {
            if (block is ParagraphBlock p)
            {
                sb.Append(GetInlineText(p.Inline));
                sb.Append(' ');
            }
        }

        return sb.ToString().Trim();
    }

    private static void RenderInlines(IContainer container, ContainerInline? inline)
    {
        container.Text(text => AppendInlines(text, inline));
    }

    private static void AppendInlines(TextDescriptor text, ContainerInline? inline)
    {
        if (inline == null)
            return;

        foreach (var child in inline)
        {
            switch (child)
            {
                case LiteralInline literal:
                    text.Span(literal.ToString() ?? string.Empty);
                    break;
                case EmphasisInline emphasis when emphasis.DelimiterCount >= 2:
                    text.Span(GetInlineText(emphasis)).Bold();
                    break;
                case EmphasisInline emphasis:
                    text.Span(GetInlineText(emphasis)).Italic();
                    break;
                case CodeInline code:
                    text.Span(code.Content).FontFamily("Consolas").FontSize(9);
                    break;
                case LineBreakInline:
                    text.Span("\n");
                    break;
                case ContainerInline container:
                    AppendInlines(text, container);
                    break;
                default:
                    if (child is LeafInline leaf)
                        text.Span(leaf.ToString() ?? string.Empty);
                    break;
            }
        }
    }

    private static string GetInlineText(ContainerInline? inline)
    {
        if (inline == null)
            return string.Empty;

        var sb = new StringBuilder();
        foreach (var child in inline)
        {
            switch (child)
            {
                case LiteralInline literal:
                    sb.Append(literal.ToString());
                    break;
                case EmphasisInline emphasis:
                    sb.Append(GetInlineText(emphasis));
                    break;
                case CodeInline code:
                    sb.Append(code.Content);
                    break;
                case LineBreakInline:
                    sb.Append(' ');
                    break;
                case ContainerInline container:
                    sb.Append(GetInlineText(container));
                    break;
                default:
                    if (child is LeafInline leaf && !string.IsNullOrEmpty(leaf.ToString()))
                        sb.Append(leaf.ToString());
                    break;
            }
        }

        return sb.ToString();
    }

    private sealed class RenderedChapter
    {
        public RenderedChapter(UserGuideChapterEntry entry, MarkdownDocument document)
        {
            Entry = entry;
            Document = document;
        }

        public UserGuideChapterEntry Entry { get; }
        public MarkdownDocument Document { get; }
    }

    private sealed class UserGuideManifest
    {
        public string? Title { get; set; }
        public string? Subtitle { get; set; }
        public List<UserGuideChapterEntry> Chapters { get; set; } = new();
    }

    private sealed class UserGuideChapterEntry
    {
        public string File { get; set; } = string.Empty;
        public string? Title { get; set; }
        public bool IncludeInToc { get; set; } = true;
    }
}
