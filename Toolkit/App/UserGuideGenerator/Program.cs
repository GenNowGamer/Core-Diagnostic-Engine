using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;
using UserGuideGenerator.Services;

if (args.Length >= 3 && string.Equals(args[0], "--workorder-pdf", StringComparison.OrdinalIgnoreCase))
{
    var orderJsonPath = args[1];
    var pdfOutPath = args[2];
    if (!File.Exists(orderJsonPath))
    {
        Console.Error.WriteLine($"Work order JSON not found: {orderJsonPath}");
        return 1;
    }

    try
    {
        var order = JsonNode.Parse(File.ReadAllText(orderJsonPath)) as JsonObject;
        if (order == null)
        {
            Console.Error.WriteLine("Work order JSON is invalid.");
            return 1;
        }

        QuestPDF.Settings.License = LicenseType.Community;
        var outDir = Path.GetDirectoryName(pdfOutPath);
        if (!string.IsNullOrWhiteSpace(outDir))
            Directory.CreateDirectory(outDir);

        var caseId = order["CaseId"]?.GetValue<string>() ?? "Work Order";
        var clientName = order["ClientName"]?.GetValue<string>() ?? string.Empty;
        var clientPhone = order["ClientPhone"]?.GetValue<string>() ?? string.Empty;
        var notes = order["TechnicianNotes"]?.GetValue<string>() ?? string.Empty;
        var createdAt = order["CreatedAt"]?.GetValue<string>() ?? string.Empty;
        var closedAt = order["ClosedAt"]?.GetValue<string>() ?? string.Empty;
        var runs = order["Runs"] as JsonArray ?? new JsonArray();

        Document.Create(container =>
        {
            container.Page(page =>
            {
                page.Size(PageSizes.A4);
                page.Margin(36);
                page.DefaultTextStyle(x => x.FontSize(10).FontColor(Colors.Grey.Darken3));
                page.Header().Column(col =>
                {
                    col.Item().Text("CDE Work Order").FontSize(20).Bold().FontColor(Colors.Blue.Darken2);
                    col.Item().PaddingTop(4).Text(caseId).FontSize(12).SemiBold();
                });
                page.Content().PaddingTop(12).Column(col =>
                {
                    col.Spacing(8);
                    col.Item().Text($"Client: {clientName}    Phone: {clientPhone}");
                    col.Item().Text($"Opened: {createdAt}    Closed: {closedAt}");
                    col.Item().PaddingTop(6).Text("Technician notes").SemiBold();
                    col.Item().Text(string.IsNullOrWhiteSpace(notes) ? "(none)" : notes);
                    col.Item().PaddingTop(10).Text($"Recorded runs ({runs.Count})").FontSize(12).SemiBold();
                    foreach (var node in runs)
                    {
                        if (node is not JsonObject r) continue;
                        var label = r["DisplayLabel"]?.GetValue<string>() ?? r["WorkflowName"]?.GetValue<string>() ?? "Workflow";
                        var health = r["OverallHealth"]?.GetValue<string>() ?? "Healthy";
                        var summary = r["Summary"]?.GetValue<string>() ?? string.Empty;
                        col.Item().PaddingTop(4).Text($"{label} [{health}]: {summary}");
                    }
                });
            });
        }).GeneratePdf(pdfOutPath);

        return File.Exists(pdfOutPath) ? 0 : 1;
    }
    catch (Exception ex)
    {
        Console.Error.WriteLine(ex.Message);
        return 1;
    }
}

var toolkitRoot = args.Length > 0 && !string.IsNullOrWhiteSpace(args[0])
    ? Path.GetFullPath(args[0])
    : Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", ".."));

var sourceDir = args.Length > 1 && !string.IsNullOrWhiteSpace(args[1])
    ? Path.GetFullPath(args[1])
    : Path.Combine(toolkitRoot, "Docs", "UserGuide");

var outputPath = args.Length > 2 && !string.IsNullOrWhiteSpace(args[2])
    ? Path.GetFullPath(args[2])
    : Path.Combine(toolkitRoot, "HALP", "CDE_User_Guide.pdf");

string? version = null;
var versionJsonPath = Path.Combine(toolkitRoot, "VERSION.json");
if (File.Exists(versionJsonPath))
{
    try
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(versionJsonPath));
        if (doc.RootElement.TryGetProperty("version", out var vProp))
        {
            version = vProp.GetString();
        }
    }
    catch
    {
        // Fall back to assembly version.
    }
}

if (string.IsNullOrWhiteSpace(version))
{
    version = Assembly.GetExecutingAssembly()
        .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
}
if (string.IsNullOrWhiteSpace(version))
{
    version = Assembly.GetExecutingAssembly().GetName().Version?.ToString();
}
if (!string.IsNullOrWhiteSpace(version))
{
    var plus = version.IndexOf('+');
    if (plus > 0)
        version = version[..plus];
}

Console.WriteLine($"Source:  {sourceDir}");
Console.WriteLine($"Output:  {outputPath}");
Console.WriteLine($"Version: {version ?? "1.0"}");

if (!UserGuidePdfService.TryGeneratePdf(sourceDir, outputPath, version, out var error))
{
    Console.Error.WriteLine($"User guide generation failed: {error}");
    return 1;
}

var info = new FileInfo(outputPath);
Console.WriteLine($"Generated {info.Length:N0} bytes -> {outputPath}");
return 0;
