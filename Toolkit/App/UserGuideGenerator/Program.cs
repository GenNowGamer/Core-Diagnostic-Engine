using System.Reflection;
using UserGuideGenerator.Services;

var toolkitRoot = args.Length > 0 && !string.IsNullOrWhiteSpace(args[0])
    ? Path.GetFullPath(args[0])
    : Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", ".."));

var sourceDir = args.Length > 1 && !string.IsNullOrWhiteSpace(args[1])
    ? Path.GetFullPath(args[1])
    : Path.Combine(toolkitRoot, "Docs", "UserGuide");

var outputPath = args.Length > 2 && !string.IsNullOrWhiteSpace(args[2])
    ? Path.GetFullPath(args[2])
    : Path.Combine(toolkitRoot, "HALP", "CDE_User_Guide.pdf");

var version = Assembly.GetExecutingAssembly()
    .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
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
