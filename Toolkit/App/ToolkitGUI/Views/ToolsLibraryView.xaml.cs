using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Xml.Linq;
using ToolkitGUI.ViewModels;

namespace ToolkitGUI.Views
{
    public partial class ToolsLibraryView : UserControl
    {
        private readonly List<ToolCategory> _categories = new();
        private readonly Dictionary<string, ManifestEntry> _manifestByPath = new(StringComparer.OrdinalIgnoreCase);
        private static readonly HttpClient HttpClient = new() { Timeout = TimeSpan.FromMinutes(3) };
        private static readonly JsonSerializerOptions ManifestJsonOptions = new()
        {
            PropertyNameCaseInsensitive = true
        };
        private string _activeCategory = "Show All";

        public ToolsLibraryView()
        {
            InitializeComponent();
            LoadToolCatalog();
        }

        private static string ToolsRoot => FindToolsRoot() ?? Path.GetFullPath(Path.Combine(
            AppDomain.CurrentDomain.BaseDirectory,
            "..", "..", "..", "..", "..", "Tools"));

        private static string CatalogPath => Path.Combine(ToolsRoot, "ToolCatalog.xml");
        private static string ManifestPath => Path.Combine(ToolsRoot, "tools_manifest.json");

        private static string? ToolkitRoot => FindToolkitRoot();

        private static string? FindToolsRoot()
        {
            var dir = new DirectoryInfo(AppDomain.CurrentDomain.BaseDirectory);
            while (dir != null)
            {
                var candidate = Path.Combine(dir.FullName, "Tools");
                if (Directory.Exists(candidate))
                    return candidate;
                dir = dir.Parent;
            }
            return null;
        }

        private static string? FindToolkitRoot()
        {
            var fromEnv = Environment.GetEnvironmentVariable("TOOLKIT_ROOT");
            if (!string.IsNullOrWhiteSpace(fromEnv))
                return fromEnv.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

            var toolsRoot = ToolsRoot;
            if (string.IsNullOrWhiteSpace(toolsRoot))
                return null;

            var parent = Directory.GetParent(toolsRoot);
            return parent?.FullName;
        }

        private void LoadToolCatalog()
        {
            CategoryButtonsHost.Children.Clear();
            ToolGroupsHost.Children.Clear();
            _categories.Clear();
            _manifestByPath.Clear();
            _activeCategory = "Show All";

            if (!Directory.Exists(ToolsRoot))
            {
                AddInfoCard("Tools missing", $"Tools root not found. Expected: {ToolsRoot}");
                return;
            }

            if (!File.Exists(CatalogPath))
            {
                AddInfoCard("Catalog missing", $"ToolCatalog.xml not found in Tools root. Expected: {CatalogPath}");
                return;
            }

            LoadManifestLookup();

            try
            {
                var doc = XDocument.Load(CatalogPath);
                var rootName = doc.Root?.Name.LocalName ?? string.Empty;
                List<ToolCategory> categories;

                if (rootName.Equals("face", StringComparison.OrdinalIgnoreCase))
                {
                    categories = ParseMriFaceCatalog(doc);
                }
                else
                {
                    categories = doc.Root?.Elements("Category")
                        .Select(ParseCdeCategory)
                        .Where(c => c.Tools.Any())
                        .ToList() ?? new List<ToolCategory>();
                }

                if (!categories.Any())
                {
                    AddInfoCard("No tools configured", "Catalog did not contain any tool entries.");
                    return;
                }

                _categories.AddRange(categories);
                BuildCategoryButtons();
                RenderToolGroups();
            }
            catch (Exception ex)
            {
                AddInfoCard("Catalog error", ex.Message);
            }
        }

        private void LoadManifestLookup()
        {
            _manifestByPath.Clear();
            if (!File.Exists(ManifestPath))
                return;

            try
            {
                var manifest = JsonSerializer.Deserialize<ToolsManifest>(File.ReadAllText(ManifestPath), ManifestJsonOptions);
                foreach (var entry in manifest?.Entries ?? new List<ManifestEntry>())
                {
                    if (string.IsNullOrWhiteSpace(entry.RelativePath))
                        continue;
                    _manifestByPath[NormalizePath(entry.RelativePath)] = entry;
                }
            }
            catch
            {
                // Best effort: launch validation path still handles missing manifest.
            }
        }

        private bool TryGetManifestEntry(ToolEntry tool, string relativePath, out ManifestEntry entry)
        {
            // Reload each acquire attempt to avoid stale in-memory state.
            LoadManifestLookup();

            if (_manifestByPath.TryGetValue(NormalizePath(relativePath), out entry!))
                return true;

            // Fallback: some entries may drift in relativePath format over time.
            if (!string.IsNullOrWhiteSpace(tool.Name))
            {
                var byName = _manifestByPath.Values.FirstOrDefault(e =>
                    string.Equals(e.Name, tool.Name, StringComparison.OrdinalIgnoreCase));
                if (byName != null)
                {
                    entry = byName;
                    return true;
                }
            }

            entry = null!;
            return false;
        }

        private static List<ToolCategory> ParseMriFaceCatalog(XDocument doc)
        {
            var categoriesById = doc.Root?
                .Element("categories")?
                .Elements("category")
                .Select(c => new
                {
                    Id = (c.Element("cat_id")?.Value ?? string.Empty).Trim(),
                    Name = (c.Element("name")?.Value ?? "Tools").Trim()
                })
                .Where(x => x.Id.Length > 0)
                .ToDictionary(x => x.Id, x => new ToolCategory { Name = x.Name }, StringComparer.OrdinalIgnoreCase)
                ?? new Dictionary<string, ToolCategory>(StringComparer.OrdinalIgnoreCase);

            var uncategorized = new ToolCategory { Name = "Uncategorized" };

            foreach (var app in doc.Root?.Element("apps")?.Elements("app") ?? Enumerable.Empty<XElement>())
            {
                var catId = (app.Element("cat_id")?.Value ?? string.Empty).Trim();
                var category = categoriesById.TryGetValue(catId, out var found) ? found : uncategorized;
                category.Tools.Add(ParseMriTool(app));
            }

            var output = categoriesById.Values.Where(c => c.Tools.Any()).ToList();
            if (uncategorized.Tools.Any())
                output.Add(uncategorized);
            return output;
        }

        private static ToolCategory ParseCdeCategory(XElement element)
        {
            var category = new ToolCategory
            {
                Name = GetValue(element, "name", "Name") ?? "Tools"
            };

            category.Tools.AddRange(element.Elements("Tool")
                .Select(ParseCdeTool)
                .Where(t => t.MonetizationApproved || t.PlaceholderVisible));
            return category;
        }

        private static ToolEntry ParseCdeTool(XElement x)
        {
            var dlFile = GetValue(x, "dlFile", "dl_file") ?? string.Empty;
            return new ToolEntry
            {
                Name = GetValue(x, "name", "Name") ?? "Unnamed Tool",
                Description = GetValue(x, "description", "Description") ?? string.Empty,
                RelativePath = GetValue(x, "relativePath", "RelativePath") ?? string.Empty,
                DiscFolder = GetValue(x, "discFolder", "disc_folder") ?? string.Empty,
                ExecuteFile = GetValue(x, "executeFile", "execute_file") ?? string.Empty,
                Arguments = GetValue(x, "arguments", "Arguments") ?? string.Empty,
                ExecuteArgs = GetValue(x, "executeArgs", "execute_args") ?? string.Empty,
                DownloadUrl = GetValue(x, "downloadUrl", "DownloadUrl") ?? string.Empty,
                DlUrl = GetValue(x, "dlUrl", "dl_url") ?? string.Empty,
                DlFile = dlFile,
                DownloadType = GetValue(x, "downloadType", "downloadType") ?? string.Empty,
                MemberPath = GetValue(x, "memberPath", "memberPath") ?? string.Empty,
                SourceUrl = GetValue(x, "sourceUrl", "SourceUrl") ?? string.Empty,
                WinPESupport = GetValue(x, "winpeSupport", "WinPESupport") ?? "limited",
                RequiresAdmin = ParseBool(GetValue(x, "requiresAdmin", "RequiresAdmin")),
                RequiresNetwork = ParseBool(GetValue(x, "requiresNetwork", "RequiresNetwork")),
                MonetizationApproved = ParseBool(GetValue(x, "monetizationApproved", "MonetizationApproved")),
                ApprovalSource = GetValue(x, "approvalSource", "ApprovalSource") ?? string.Empty,
                ApprovedOn = GetValue(x, "approvedOn", "ApprovedOn") ?? string.Empty,
                LicenseNote = GetValue(x, "licenseNote", "LicenseNote") ?? string.Empty,
                AutoCleanup = ParseBool(GetValue(x, "autoCleanup", "auto_cleanup")),
                PlaceholderVisible = ParseBool(GetValue(x, "placeholderVisible", "placeholderVisible")),
                ExecutionMode = ParseExecutionMode(GetValue(x, "executionMode", "ExecutionMode")),
                WorkflowScript = GetValue(x, "workflowScript", "WorkflowScript") ?? string.Empty
            };
        }

        private static ToolEntry ParseMriTool(XElement app)
        {
            var dlFile = (app.Element("dl_file")?.Value ?? string.Empty).Trim();
            var executeFile = (app.Element("execute_file")?.Value ?? string.Empty).Trim();
            if (executeFile.Contains("%dl_file%", StringComparison.OrdinalIgnoreCase))
                executeFile = executeFile.Replace("%dl_file%", dlFile, StringComparison.OrdinalIgnoreCase);

            return new ToolEntry
            {
                Name = (app.Element("name")?.Value ?? "Unnamed Tool").Trim(),
                Description = $"Publisher: {(app.Element("publisher")?.Value ?? "Unknown").Trim()}",
                DiscFolder = (app.Element("disc_folder")?.Value ?? string.Empty).Trim(),
                ExecuteFile = executeFile,
                ExecuteArgs = (app.Element("execute_args")?.Value ?? string.Empty).Trim(),
                DlUrl = (app.Element("dl_url")?.Value ?? string.Empty).Trim(),
                DlFile = dlFile,
                DownloadType = "file",
                MemberPath = string.Empty,
                MonetizationApproved = true,
                PlaceholderVisible = true,
                AutoCleanup = (app.Element("auto_cleanup")?.Value ?? "0").Trim() == "1",
                WinPESupport = "limited",
                ExecutionMode = ToolExecutionMode.Native
            };
        }

        private static bool ParseBool(string? value)
            => bool.TryParse(value, out var parsed) && parsed;

        private static string? GetValue(XElement element, string attributeName, string elementName)
            => element.Attribute(attributeName)?.Value ?? element.Element(elementName)?.Value;

        private static ToolExecutionMode ParseExecutionMode(string? value)
            => value?.Trim().ToLowerInvariant() switch
            {
                "native" => ToolExecutionMode.Native,
                "boot_iso" => ToolExecutionMode.BootIso,
                "boot_folder" => ToolExecutionMode.BootFolder,
                "boot_efi" => ToolExecutionMode.BootEfi,
                "boot_secondary_winpe_wim" => ToolExecutionMode.BootSecondaryWinPe,
                "placeholder" => ToolExecutionMode.Placeholder,
                "cde_workflow" => ToolExecutionMode.CdeWorkflow,
                _ => ToolExecutionMode.Native
            };

        private void BuildCategoryButtons()
        {
            CategoryButtonsHost.Children.Clear();
            AddCategoryButton("Show All", true);
            foreach (var category in _categories)
                AddCategoryButton(category.Name, false);
        }

        private void AddCategoryButton(string categoryName, bool isSelected)
        {
            var button = new Button
            {
                Content = categoryName,
                Style = isSelected ? (Style)FindResource("ActionButtonStyle") : (Style)FindResource("NavButtonStyle"),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                Margin = new Thickness(0, 0, 0, 6),
                Tag = categoryName
            };
            button.Click += CategoryButton_Click;
            CategoryButtonsHost.Children.Add(button);
        }

        private void CategoryButton_Click(object sender, RoutedEventArgs e)
        {
            if (sender is not Button button || button.Tag is not string selected)
                return;

            _activeCategory = selected;
            UpdateCategoryButtonStyles();
            RenderToolGroups();
        }

        private void UpdateCategoryButtonStyles()
        {
            foreach (var child in CategoryButtonsHost.Children.OfType<Button>())
            {
                child.Style = child.Tag is string tag && tag == _activeCategory
                    ? (Style)FindResource("ActionButtonStyle")
                    : (Style)FindResource("NavButtonStyle");
            }
        }

        private void RenderToolGroups()
        {
            ToolGroupsHost.Children.Clear();
            var query = SearchTextBox.Text.Trim();
            var categories = _categories
                .Select(c => new ToolCategory
                {
                    Name = c.Name,
                    Tools = c.Tools.Where(t => MatchesQuery(t, query)).ToList()
                })
                .Where(c => c.Tools.Any())
                .Where(c => _activeCategory == "Show All" || c.Name.Equals(_activeCategory, StringComparison.OrdinalIgnoreCase))
                .ToList();

            if (!categories.Any())
            {
                AddInfoCard("No matching tools", "Adjust the search or choose a different category.");
                return;
            }

            foreach (var category in categories)
                ToolGroupsHost.Children.Add(CreateCategoryCard(category));
        }

        private static bool MatchesQuery(ToolEntry tool, string query)
        {
            if (string.IsNullOrEmpty(query))
                return true;

            return tool.Name.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                   tool.Description.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                   tool.WinPESupport.Contains(query, StringComparison.OrdinalIgnoreCase);
        }

        private UIElement CreateCategoryCard(ToolCategory category)
        {
            var border = new Border
            {
                Style = (Style)FindResource("CardStyle"),
                Margin = new Thickness(0, 0, 0, 12)
            };

            var stack = new StackPanel();
            stack.Children.Add(new TextBlock
            {
                Text = category.Name,
                FontSize = 14,
                FontWeight = FontWeights.Bold,
                Margin = new Thickness(0, 0, 0, 8)
            });

            foreach (var tool in category.Tools)
            {
                var row = new Grid { Margin = new Thickness(0, 0, 0, 8) };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

                var details = new StackPanel { Margin = new Thickness(0, 0, 10, 0) };
                details.Children.Add(new TextBlock
                {
                    Text = tool.Name,
                    FontWeight = FontWeights.SemiBold
                });
                details.Children.Add(new TextBlock
                {
                    Text = tool.Description,
                    Foreground = (Brush)FindResource("TextSecondaryBrush"),
                    FontSize = 11,
                    TextWrapping = TextWrapping.Wrap
                });

                var status = EvaluateToolStatus(tool);
                details.Children.Add(new TextBlock
                {
                    Text = status.StatusMessage,
                    Foreground = status.CanLaunch ? Brushes.SeaGreen : Brushes.IndianRed,
                    FontSize = 11,
                    Margin = new Thickness(0, 3, 0, 0),
                    TextWrapping = TextWrapping.Wrap
                });

                var badges = BuildBadges(tool, status);
                badges.Margin = new Thickness(0, 4, 0, 0);
                details.Children.Add(badges);

                Grid.SetColumn(details, 0);
                row.Children.Add(details);

                var actions = new StackPanel { Orientation = Orientation.Horizontal };
                var actionButton = new Button
                {
                    Content = GetLaunchButtonText(tool),
                    Style = (Style)FindResource("ActionButtonStyle"),
                    HorizontalAlignment = HorizontalAlignment.Left,
                    MinWidth = 100,
                    Margin = new Thickness(0, 0, 6, 0),
                    Tag = tool,
                    IsEnabled = status.CanLaunch
                };
                actionButton.Click += LaunchTool_Click;
                actions.Children.Add(actionButton);

                var acquireButton = new Button
                {
                    Style = (Style)FindResource("ActionButtonStyle"),
                    HorizontalAlignment = HorizontalAlignment.Left,
                    MinWidth = 165,
                    Tag = tool
                };
                ConfigureAcquireButton(acquireButton, tool, status);
                acquireButton.Click += AcquireTool_Click;
                actions.Children.Add(acquireButton);

                Grid.SetColumn(actions, 1);
                row.Children.Add(actions);
                stack.Children.Add(row);
            }

            border.Child = stack;
            return border;
        }

        private static string GetLaunchButtonText(ToolEntry tool) => tool.ExecutionMode switch
        {
            ToolExecutionMode.Native => "Launch",
            ToolExecutionMode.CdeWorkflow => "Run",
            ToolExecutionMode.BootIso => "Open",
            ToolExecutionMode.BootFolder => "Open",
            ToolExecutionMode.BootEfi => "Open",
            ToolExecutionMode.BootSecondaryWinPe => "Open",
            _ => "Launch"
        };

        private ToolStatus EvaluateToolStatus(ToolEntry tool)
        {
            if (!tool.MonetizationApproved && !tool.PlaceholderVisible)
                return new ToolStatus(false, false, "Blocked: not approved for distribution.", true);

            if (tool.ExecutionMode == ToolExecutionMode.CdeWorkflow)
            {
                if (!TryResolveCdeWorkflowScript(tool, out var scriptPath, out var workflowError))
                    return new ToolStatus(false, false, workflowError ?? "CDE workflow script is not available.", true);
                if (!File.Exists(scriptPath))
                    return new ToolStatus(false, false, $"Missing workflow script: {scriptPath}", true);
            }

            if (!TryResolveToolPath(tool, out var toolPath, out var pathError))
            {
                var canAcquire = !string.IsNullOrWhiteSpace(GetDirectDownloadUrl(tool)) && IsDownloadTypeSupportedForAcquire(ParseDownloadType(tool.DownloadType));
                var message = pathError ?? "Placeholder entry: launch path not mapped yet.";
                return new ToolStatus(false, canAcquire, message, true);
            }

            if (tool.ExecutionMode != ToolExecutionMode.CdeWorkflow && !ValidateToolPath(toolPath!, out var validationMessage))
                return new ToolStatus(false, false, validationMessage, true);

            var exists = File.Exists(toolPath) || Directory.Exists(toolPath);
            if (!exists)
            {
                var canAcquire = !string.IsNullOrWhiteSpace(GetDirectDownloadUrl(tool)) && IsDownloadTypeSupportedForAcquire(ParseDownloadType(tool.DownloadType));
                return new ToolStatus(false, canAcquire, $"Missing payload: {toolPath}", true);
            }

            if (!ValidateManifestStatusForListing(tool, toolPath!, out var hashMessage))
            {
                var canAcquire = !string.IsNullOrWhiteSpace(GetDirectDownloadUrl(tool)) && IsDownloadTypeSupportedForAcquire(ParseDownloadType(tool.DownloadType));
                return new ToolStatus(false, canAcquire, hashMessage, true);
            }

            if (tool.ExecutionMode == ToolExecutionMode.Placeholder)
                return new ToolStatus(false, false, "Placeholder function: visible for review only.", true);

            if (!IsDownloadTypeSupportedForAcquire(ParseDownloadType(tool.DownloadType)) && !string.IsNullOrWhiteSpace(GetDirectDownloadUrl(tool)))
            {
                var reason = ParseDownloadType(tool.DownloadType) == DownloadType.PortableAppsPaf
                    ? "Acquire planned: install 7-Zip to enable PortableApps package extraction."
                    : $"Acquire planned: downloadType '{tool.DownloadType}' requires installer unpack support.";
                return new ToolStatus(true, false, $"Ready ({reason})", true);
            }

            return new ToolStatus(true, !string.IsNullOrWhiteSpace(GetDirectDownloadUrl(tool)), "Ready", false);
        }

        private static string FormatMode(ToolExecutionMode mode) => mode switch
        {
            ToolExecutionMode.Native => "Native",
            ToolExecutionMode.CdeWorkflow => "CDE Workflow",
            ToolExecutionMode.BootIso => "Boot ISO",
            ToolExecutionMode.BootFolder => "Boot Folder",
            ToolExecutionMode.BootEfi => "Boot EFI",
            ToolExecutionMode.BootSecondaryWinPe => "Boot WinPE",
            ToolExecutionMode.Placeholder => "Placeholder",
            _ => "Native"
        };

        private WrapPanel BuildBadges(ToolEntry tool, ToolStatus status)
        {
            var panel = new WrapPanel();
            panel.Children.Add(CreateBadge(FormatMode(tool.ExecutionMode), GetModeBrush(tool.ExecutionMode)));
            panel.Children.Add(CreateBadge(GetWinPeBadgeText(tool), GetWinPeBrush(tool.WinPESupport)));
            if (tool.RequiresAdmin)
                panel.Children.Add(CreateBadge("Admin", Brushes.IndianRed));
            if (tool.RequiresNetwork)
                panel.Children.Add(CreateBadge("Network", Brushes.DarkGoldenrod));
            if (status.IsPlaceholder)
                panel.Children.Add(CreateBadge("Placeholder", Brushes.DimGray));
            return panel;
        }

        private static string GetWinPeBadgeText(ToolEntry tool)
            => tool.ExecutionMode is ToolExecutionMode.BootIso or ToolExecutionMode.BootFolder
                or ToolExecutionMode.BootEfi or ToolExecutionMode.BootSecondaryWinPe
                ? "Boot-only"
                : $"WinPE: {tool.WinPESupport}";

        private static Brush GetModeBrush(ToolExecutionMode mode)
            => mode == ToolExecutionMode.Native ? Brushes.SeaGreen :
                mode == ToolExecutionMode.CdeWorkflow ? Brushes.DarkOrange :
                mode == ToolExecutionMode.Placeholder ? Brushes.DimGray :
                Brushes.SteelBlue;

        private static Brush GetWinPeBrush(string support)
            => support.Trim().ToLowerInvariant() switch
            {
                "yes" => Brushes.SeaGreen,
                "no" => Brushes.IndianRed,
                "boot_only" => Brushes.SteelBlue,
                _ => Brushes.DimGray
            };

        private static Border CreateBadge(string text, Brush brush)
            => new()
            {
                CornerRadius = new CornerRadius(10),
                BorderThickness = new Thickness(1),
                BorderBrush = brush,
                Padding = new Thickness(8, 2, 8, 2),
                Margin = new Thickness(0, 0, 6, 0),
                Child = new TextBlock
                {
                    Text = text,
                    FontSize = 10,
                    Foreground = brush
                }
            };

        private void SearchTextBox_TextChanged(object sender, TextChangedEventArgs e) => RenderToolGroups();

        private void RefreshButton_Click(object sender, RoutedEventArgs e)
        {
            SearchTextBox.Text = string.Empty;
            LoadToolCatalog();
        }

        private void AddInfoCard(string title, string message)
        {
            var border = new Border
            {
                Style = (Style)FindResource("CardStyle"),
                Margin = new Thickness(0, 0, 0, 12)
            };

            var stack = new StackPanel();
            stack.Children.Add(new TextBlock
            {
                Text = title,
                FontSize = 14,
                FontWeight = FontWeights.Bold,
                Margin = new Thickness(0, 0, 0, 8)
            });
            stack.Children.Add(new TextBlock
            {
                Text = message,
                TextWrapping = TextWrapping.Wrap,
                Foreground = (Brush)FindResource("TextSecondaryBrush")
            });

            border.Child = stack;
            ToolGroupsHost.Children.Add(border);
        }

        private void LaunchTool_Click(object? sender, RoutedEventArgs e)
        {
            if (sender is not Button btn || btn.Tag is not ToolEntry tool)
                return;

            var status = EvaluateToolStatus(tool);
            if (!status.CanLaunch)
            {
                MessageBox.Show(status.StatusMessage, "Tool Status", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            if (tool.ExecutionMode == ToolExecutionMode.CdeWorkflow)
            {
                _ = LaunchCdeWorkflowAsync(tool);
                return;
            }

            if (!TryResolveToolPath(tool, out var toolPath, out _))
                return;

            if (tool.ExecutionMode is ToolExecutionMode.BootIso or ToolExecutionMode.BootFolder
                or ToolExecutionMode.BootEfi or ToolExecutionMode.BootSecondaryWinPe)
            {
                ShowBootToolGuidance(tool, toolPath!);
                OpenContainingFolder(toolPath!);
                return;
            }

            var psi = new ProcessStartInfo
            {
                FileName = toolPath,
                UseShellExecute = true
            };
            if (tool.ExecutionMode == ToolExecutionMode.Native)
            {
                var dir = Path.GetDirectoryName(toolPath);
                if (!string.IsNullOrWhiteSpace(dir))
                    psi.WorkingDirectory = dir;
            }

            var args = !string.IsNullOrWhiteSpace(tool.Arguments) ? tool.Arguments : tool.ExecuteArgs;
            if (!string.IsNullOrWhiteSpace(args))
            {
                // Expand path tokens so tools that need an absolute path (e.g. a
                // portable browser profile) do not depend on the working directory.
                var toolDir = Path.GetDirectoryName(toolPath) ?? ToolsRoot;
                args = args
                    .Replace("{TOOLDIR}", toolDir, StringComparison.OrdinalIgnoreCase)
                    .Replace("{TOOLSROOT}", ToolsRoot, StringComparison.OrdinalIgnoreCase);
                psi.Arguments = args;
            }

            try
            {
                Process.Start(psi);
                if (tool.AutoCleanup)
                    ShowAutoCleanupPlannedMessage(tool);
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Unable to launch tool:\n{ex.Message}", "Launch Failed", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private async Task LaunchCdeWorkflowAsync(ToolEntry tool)
        {
            if (!TryResolveCdeWorkflowScript(tool, out var scriptPath, out var error))
            {
                MessageBox.Show(error ?? "Unable to resolve workflow script.", "CDE Workflow", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            if (!IsOfflineRecoveryEnvironmentReady(out var environmentMessage))
            {
                MessageBox.Show(environmentMessage, "Offline Recovery Required", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            try
            {
                var runner = new CdeWorkflowRunnerViewModel();
                await runner.RunAsync(
                    scriptPath,
                    parameters: null,
                    tool.Name,
                    tool.Description);
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Workflow failed:\n{ex.Message}", tool.Name, MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private static bool IsOfflineRecoveryEnvironmentReady(out string message)
        {
            message = string.Empty;
            if (!IsWinPeEnvironment())
            {
                message =
                    "This recovery tool must run from CDE WinPE while the target Windows installation is offline.\n\n" +
                    "Boot from the CDE USB, choose option 2 to attach the offline Windows install, then run this tool again.";
                return false;
            }

            if (!OfflineRuntimePaths.IsOfflineSoftwareHiveLoaded())
            {
                message =
                    "Offline registry hives are not loaded.\n\n" +
                    "From WinPE startup, choose option 2 to load the offline Windows installation, then retry.";
                return false;
            }

            if (!TryResolveOfflineWindowsRoot(out var offlineRoot, out var rootError))
            {
                message = rootError;
                return false;
            }

            Environment.SetEnvironmentVariable("OFFLINE_WINDOWS_ROOT", offlineRoot, EnvironmentVariableTarget.Process);
            return true;
        }

        private static bool TryResolveOfflineWindowsRoot(out string offlineRoot, out string error)
        {
            offlineRoot = string.Empty;
            error = string.Empty;

            var fromEnv = NormalizeOfflineWindowsRoot(Environment.GetEnvironmentVariable("OFFLINE_WINDOWS_ROOT"));
            if (!string.IsNullOrEmpty(fromEnv))
            {
                offlineRoot = fromEnv;
                return true;
            }

            var toolkitRoot = ToolkitRoot;
            if (!string.IsNullOrWhiteSpace(toolkitRoot))
            {
                var envFile = OfflineRuntimePaths.ResolveEnvFilePath(toolkitRoot);
                if (!string.IsNullOrEmpty(envFile) && File.Exists(envFile))
                {
                    foreach (var line in File.ReadAllLines(envFile))
                    {
                        if (string.IsNullOrWhiteSpace(line) || line.TrimStart().StartsWith("#", StringComparison.Ordinal))
                            continue;
                        var idx = line.IndexOf('=');
                        if (idx <= 0)
                            continue;
                        if (!line[..idx].Trim().Equals("OFFLINE_WINDOWS_ROOT", StringComparison.OrdinalIgnoreCase))
                            continue;
                        var fromFile = NormalizeOfflineWindowsRoot(line[(idx + 1)..].Trim());
                        if (!string.IsNullOrEmpty(fromFile))
                        {
                            offlineRoot = fromFile;
                            return true;
                        }
                    }
                }
            }

            error =
                "Offline Windows root could not be resolved.\n\n" +
                "Boot WinPE, choose option 2 to attach the offline Windows installation, then retry.";
            return false;
        }

        private static string? NormalizeOfflineWindowsRoot(string? root)
        {
            if (string.IsNullOrWhiteSpace(root))
                return null;

            var trimmed = root.Trim();
            if (trimmed.Length == 2 && trimmed[1] == ':')
                trimmed += @"\";
            else if (trimmed.Length >= 2 && trimmed[1] == ':' && !trimmed.EndsWith(@"\", StringComparison.Ordinal))
                trimmed += @"\";

            return Directory.Exists(Path.Combine(trimmed, "Windows")) ? trimmed : null;
        }

        private static bool IsWinPeEnvironment()
        {
            try
            {
                using var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\MiniNT");
                if (key != null)
                    return true;
            }
            catch
            {
                // Ignore and continue with fallbacks.
            }

            var systemRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? string.Empty;
            return systemRoot.StartsWith(@"X:\", StringComparison.OrdinalIgnoreCase);
        }

        private static bool TryResolveCdeWorkflowScript(ToolEntry tool, out string scriptPath, out string? error)
        {
            scriptPath = string.Empty;
            error = null;
            var toolkitRoot = ToolkitRoot;
            if (string.IsNullOrWhiteSpace(toolkitRoot))
            {
                error = "TOOLKIT_ROOT could not be resolved for this CDE workflow.";
                return false;
            }

            if (string.IsNullOrWhiteSpace(tool.WorkflowScript))
            {
                error = "Catalog entry is missing workflowScript for this CDE workflow.";
                return false;
            }

            scriptPath = Path.GetFullPath(Path.Combine(toolkitRoot, tool.WorkflowScript));
            if (!scriptPath.StartsWith(Path.GetFullPath(toolkitRoot), StringComparison.OrdinalIgnoreCase))
            {
                error = $"Workflow script path is outside toolkit root:\n{scriptPath}";
                return false;
            }

            return true;
        }

        private async void AcquireTool_Click(object? sender, RoutedEventArgs e)
        {
            if (sender is not Button btn || btn.Tag is not ToolEntry tool)
                return;

            var currentStatus = EvaluateToolStatus(tool);
            if (currentStatus.CanLaunch)
            {
                MessageBox.Show(
                    $"{tool.Name} is already acquired and verified.",
                    "Tool Ready",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            var url = GetDirectDownloadUrl(tool);
            if (string.IsNullOrWhiteSpace(url))
            {
                LogAcquireActivity(tool.Name, "Acquire blocked: no direct URL configured.", AcquireEventLevel.Warning);
                MessageBox.Show(
                    "No direct download URL is configured for this tool. Add dlUrl/downloadUrl metadata before using Acquire.",
                    "Acquire Unavailable",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            var downloadType = ParseDownloadType(tool.DownloadType);
            if (!IsDownloadTypeSupportedForAcquire(downloadType))
            {
                LogAcquireActivity(tool.Name, $"Acquire planned only: unsupported downloadType '{tool.DownloadType}'.", AcquireEventLevel.Warning);
                MessageBox.Show(
                    $"Acquire is planned for downloadType '{tool.DownloadType}', but this package requires installer unpack logic that is not enabled yet.\n\n" +
                    $"Use the source link to install/update manually for now:\n{url}",
                    "Acquire Planned",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            if (!TryResolveToolPath(tool, out var targetPath, out var resolveError))
            {
                LogAcquireActivity(tool.Name, $"Acquire failed: {resolveError ?? "target path unresolved"}", AcquireEventLevel.Error);
                MessageBox.Show(
                    resolveError ?? "Unable to resolve target path for this tool entry.",
                    "Acquire Failed",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return;
            }

            if (!ValidateToolPath(targetPath!, out var validationMessage))
            {
                LogAcquireActivity(tool.Name, "Acquire blocked: target path failed validation.", AcquireEventLevel.Warning);
                MessageBox.Show(validationMessage, "Acquire Blocked", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            var relativePath = tool.RelativePath;
            if (string.IsNullOrWhiteSpace(relativePath))
                relativePath = GetPathRelativeToToolsRoot(targetPath!);
            if (string.IsNullOrWhiteSpace(relativePath))
            {
                LogAcquireActivity(tool.Name, "Acquire failed: could not map relative path.", AcquireEventLevel.Error);
                MessageBox.Show("Unable to map tool path to manifest-relative path.", "Acquire Failed", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            if (!TryGetManifestEntry(tool, relativePath, out var entry))
            {
                LogAcquireActivity(tool.Name, $"Acquire blocked: no manifest entry for '{relativePath}'.", AcquireEventLevel.Warning);
                MessageBox.Show(
                    $"No manifest entry found for '{relativePath}'.\n\n" +
                    $"Manifest path checked:\n{ManifestPath}\n\n" +
                    "Reload the Tools view or update tools_manifest.json, then retry.",
                    "Acquire Blocked",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return;
            }

            if (string.IsNullOrWhiteSpace(entry.Sha256))
            {
                LogAcquireActivity(tool.Name, "Acquire blocked: manifest SHA256 missing.", AcquireEventLevel.Warning);
                MessageBox.Show(
                    $"Manifest SHA256 is missing for '{tool.Name}'. Controlled acquire requires a pinned hash.",
                    "Acquire Blocked",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return;
            }

            var folderTarget = IsFolderTarget(tool, targetPath!, downloadType);

            var preflight = BuildAcquirePreflightSummary(tool, url, targetPath!, entry);
            var preflightDialog = new AcquirePreflightWindow(preflight)
            {
                Owner = Window.GetWindow(this)
            };
            var confirm = preflightDialog.ShowDialog() == true;
            if (!confirm)
            {
                LogAcquireActivity(tool.Name, "Acquire cancelled by user.", AcquireEventLevel.Info);
                return;
            }

            btn.IsEnabled = false;
            var originalContent = btn.Content?.ToString() ?? "Acquire";
            btn.Content = "Acquiring...";
            try
            {
                LogAcquireActivity(tool.Name, $"Acquire started from {url}", AcquireEventLevel.Info);
                var stageDir = Path.Combine(ToolsRoot, ".staging", SanitizeFileName(tool.Name));
                Directory.CreateDirectory(stageDir);

                var fileName = !string.IsNullOrWhiteSpace(tool.DlFile)
                    ? tool.DlFile
                    : GetFileNameFromUrl(url);
                var stagePath = Path.Combine(stageDir, fileName);

                using (var response = await HttpClient.GetAsync(url, HttpCompletionOption.ResponseHeadersRead))
                {
                    response.EnsureSuccessStatusCode();
                    await using var network = await response.Content.ReadAsStreamAsync();
                    await using var local = File.Create(stagePath);
                    await network.CopyToAsync(local);
                }
                LogAcquireActivity(tool.Name, $"Downloaded to staging: {stagePath}", AcquireEventLevel.Info);

                var promotedDescription = string.Empty;
                string? promotedFileForHash = null;
                string? promotedFolderForHash = null;

                switch (downloadType)
                {
                    case DownloadType.File:
                    {
                        if (folderTarget)
                        {
                            LogAcquireActivity(tool.Name, "Acquire blocked: file download type cannot target a folder payload.", AcquireEventLevel.Warning);
                            MessageBox.Show(
                                "Download type 'file' is not compatible with this folder target.",
                                "Acquire Blocked",
                                MessageBoxButton.OK,
                                MessageBoxImage.Warning);
                            return;
                        }

                        promotedFileForHash = stagePath;
                        promotedDescription = "file payload";
                        break;
                    }
                    case DownloadType.ZipMember:
                    {
                        if (!IsZipArchive(stagePath))
                        {
                            LogAcquireActivity(tool.Name, "Acquire blocked: zip_member requires a .zip download.", AcquireEventLevel.Warning);
                            MessageBox.Show(
                                $"Download type 'zip_member' requires a .zip archive.\nDownloaded file: {Path.GetFileName(stagePath)}",
                                "Acquire Blocked",
                                MessageBoxButton.OK,
                                MessageBoxImage.Warning);
                            return;
                        }

                        var extractDir = Path.Combine(stageDir, "extract");
                        if (Directory.Exists(extractDir))
                            Directory.Delete(extractDir, true);
                        Directory.CreateDirectory(extractDir);
                        ZipFile.ExtractToDirectory(stagePath, extractDir, true);
                        LogAcquireActivity(tool.Name, "Extracted archive for member payload mapping.", AcquireEventLevel.Info);

                        var memberPath = ResolveZipMemberPath(extractDir, tool, targetPath!);
                        if (string.IsNullOrWhiteSpace(memberPath) || !File.Exists(memberPath))
                        {
                            LogAcquireActivity(tool.Name, "Acquire blocked: memberPath could not be resolved in extracted archive.", AcquireEventLevel.Warning);
                            MessageBox.Show(
                                "Could not resolve the target file inside the downloaded archive. Check memberPath/download metadata.",
                                "Acquire Blocked",
                                MessageBoxButton.OK,
                                MessageBoxImage.Warning);
                            return;
                        }

                        promotedFileForHash = memberPath;
                        promotedDescription = "archive member payload";
                        break;
                    }
                    case DownloadType.ZipFolder:
                    {
                        if (!folderTarget)
                        {
                            LogAcquireActivity(tool.Name, "Acquire blocked: zip_folder requires a folder target.", AcquireEventLevel.Warning);
                            MessageBox.Show(
                                "Download type 'zip_folder' requires a folder target path.",
                                "Acquire Blocked",
                                MessageBoxButton.OK,
                                MessageBoxImage.Warning);
                            return;
                        }

                        if (!IsZipArchive(stagePath))
                        {
                            LogAcquireActivity(tool.Name, "Acquire blocked: zip_folder requires a .zip archive.", AcquireEventLevel.Warning);
                            MessageBox.Show(
                                $"Download type 'zip_folder' requires a .zip archive.\nDownloaded file: {Path.GetFileName(stagePath)}",
                                "Acquire Blocked",
                                MessageBoxButton.OK,
                                MessageBoxImage.Warning);
                            return;
                        }

                        var extractDir = Path.Combine(stageDir, "extract");
                        if (Directory.Exists(extractDir))
                            Directory.Delete(extractDir, true);
                        Directory.CreateDirectory(extractDir);
                        ZipFile.ExtractToDirectory(stagePath, extractDir, true);
                        LogAcquireActivity(tool.Name, "Extracted archive for folder payload mapping.", AcquireEventLevel.Info);

                        var sourceFolder = ResolveZipFolderPath(extractDir, tool);
                        if (string.IsNullOrWhiteSpace(sourceFolder) || !Directory.Exists(sourceFolder))
                        {
                            LogAcquireActivity(tool.Name, "Acquire blocked: folder memberPath could not be resolved in extracted archive.", AcquireEventLevel.Warning);
                            MessageBox.Show(
                                "Could not resolve the target folder inside the downloaded archive. Check memberPath/download metadata.",
                                "Acquire Blocked",
                                MessageBoxButton.OK,
                                MessageBoxImage.Warning);
                            return;
                        }

                        promotedFolderForHash = sourceFolder;
                        promotedDescription = "archive folder payload";
                        break;
                    }
                    case DownloadType.PortableAppsPaf:
                    {
                        var extractDir = Path.Combine(stageDir, "extract");
                        if (Directory.Exists(extractDir))
                            Directory.Delete(extractDir, true);
                        Directory.CreateDirectory(extractDir);

                        if (!TryExtractWithSevenZip(stagePath, extractDir, out var extractError))
                        {
                            LogAcquireActivity(tool.Name, $"Acquire blocked: {extractError}", AcquireEventLevel.Warning);
                            MessageBox.Show(
                                $"Unable to extract PortableApps package.\n\n{extractError}",
                                "Acquire Blocked",
                                MessageBoxButton.OK,
                                MessageBoxImage.Warning);
                            return;
                        }
                        LogAcquireActivity(tool.Name, "Extracted PortableApps package with 7-Zip.", AcquireEventLevel.Info);

                        var memberPath = ResolvePortableAppsMemberPath(extractDir, tool, targetPath!);
                        if (string.IsNullOrWhiteSpace(memberPath) || !File.Exists(memberPath))
                        {
                            LogAcquireActivity(tool.Name, "Acquire blocked: could not resolve executable in PortableApps package.", AcquireEventLevel.Warning);
                            MessageBox.Show(
                                "Could not resolve the runtime executable inside the PortableApps package.\n" +
                                "Add memberPath metadata or verify package structure.",
                                "Acquire Blocked",
                                MessageBoxButton.OK,
                                MessageBoxImage.Warning);
                            return;
                        }

                        promotedFileForHash = memberPath;
                        promotedDescription = "portableapps payload";
                        break;
                    }
                    default:
                    {
                        LogAcquireActivity(tool.Name, "Acquire blocked: unsupported download type.", AcquireEventLevel.Warning);
                        MessageBox.Show(
                            "This tool has an unsupported download type. Update the catalog metadata.",
                            "Acquire Blocked",
                            MessageBoxButton.OK,
                            MessageBoxImage.Warning);
                        return;
                    }
                }

                string candidateHash;
                if (promotedFileForHash != null)
                    candidateHash = ComputeSha256(promotedFileForHash);
                else if (promotedFolderForHash != null)
                    candidateHash = ComputeFolderSha256(promotedFolderForHash);
                else
                    throw new InvalidOperationException("No promoted payload candidate was selected for hash verification.");

                if (!candidateHash.Equals(entry.Sha256, StringComparison.OrdinalIgnoreCase))
                {
                    LogAcquireActivity(tool.Name, $"Hash failed for {promotedDescription}. Expected {entry.Sha256}, actual {candidateHash}.", AcquireEventLevel.Error);
                    MessageBox.Show(
                        $"Hash verification failed for '{tool.Name}'.\n\nExpected: {entry.Sha256}\nActual: {candidateHash}",
                        "Acquire Blocked",
                        MessageBoxButton.OK,
                        MessageBoxImage.Warning);
                    return;
                }

                if (promotedFileForHash != null)
                {
                    var targetDirectory = Path.GetDirectoryName(targetPath!) ?? ToolsRoot;
                    Directory.CreateDirectory(targetDirectory);
                    if (File.Exists(targetPath!))
                        File.Delete(targetPath!);
                    File.Copy(promotedFileForHash, targetPath!, true);
                    LogAcquireActivity(tool.Name, $"Promoted file payload to {targetPath}", AcquireEventLevel.Success);
                }
                else if (promotedFolderForHash != null)
                {
                    if (Directory.Exists(targetPath!))
                        Directory.Delete(targetPath!, true);
                    Directory.CreateDirectory(targetPath!);
                    PromoteExtractedFolder(promotedFolderForHash, targetPath!);
                    LogAcquireActivity(tool.Name, $"Promoted extracted folder payload to {targetPath}", AcquireEventLevel.Success);
                }

                if (tool.AutoCleanup)
                {
                    CleanupStagingFolder(stageDir);
                    LogAcquireActivity(tool.Name, "Auto-cleanup complete for staging folder.", AcquireEventLevel.Success);
                }

                MessageBox.Show(
                    $"Acquire complete and verified.\n\nTool: {tool.Name}\nPath: {targetPath}\n\nRun update_tools_manifest.ps1 if status updates are needed.",
                    "Acquire Complete",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                LogAcquireActivity(tool.Name, "Acquire completed successfully.", AcquireEventLevel.Success);
                LoadToolCatalog();
            }
            catch (Exception ex)
            {
                LogAcquireActivity(tool.Name, $"Acquire failed: {ex.Message}", AcquireEventLevel.Error);
                MessageBox.Show($"Acquire failed:\n{ex.Message}", "Acquire Failed", MessageBoxButton.OK, MessageBoxImage.Error);
            }
            finally
            {
                btn.Content = originalContent;
                btn.IsEnabled = true;
            }
        }

        private void LogAcquireActivity(string toolName, string message, AcquireEventLevel level = AcquireEventLevel.Info)
        {
            var line = $"[{DateTime.Now:HH:mm:ss}] {toolName}: {message}";
            Debug.WriteLine(line);
        }

        private static string GetDirectDownloadUrl(ToolEntry tool)
            => !string.IsNullOrWhiteSpace(tool.DlUrl) ? tool.DlUrl : tool.DownloadUrl;

        private static void ConfigureAcquireButton(Button button, ToolEntry tool, ToolStatus status)
        {
            if (status.CanLaunch)
            {
                button.Content = "Ready";
                button.Background = Brushes.SeaGreen;
                button.Foreground = Brushes.White;
                button.ToolTip = "Tool payload is present and verified.";
                return;
            }

            if (status.CanAcquire)
            {
                button.Content = "Acquire";
                button.Background = Brushes.IndianRed;
                button.Foreground = Brushes.White;
                button.ToolTip = "Tool payload is missing or invalid. Acquire now.";
                return;
            }

            button.Content = "Acquire (Planned)";
            button.Background = (Brush)Application.Current.FindResource("AccentBlueBrush");
            button.Foreground = Brushes.White;
            button.ToolTip = "Acquire is planned for this tool configuration.";
        }

        private static string GetFileNameFromUrl(string url)
        {
            try
            {
                var uri = new Uri(url);
                var name = Path.GetFileName(uri.LocalPath);
                if (!string.IsNullOrWhiteSpace(name))
                    return name;
            }
            catch
            {
                // ignore and use fallback
            }
            return "downloaded_tool.bin";
        }

        private static string SanitizeFileName(string name)
        {
            var invalid = Path.GetInvalidFileNameChars();
            var chars = name.Select(ch => invalid.Contains(ch) ? '_' : ch).ToArray();
            return new string(chars);
        }

        private static void CleanupStagingFolder(string stageDir)
        {
            try
            {
                if (Directory.Exists(stageDir))
                    Directory.Delete(stageDir, true);
            }
            catch
            {
                // best effort cleanup
            }
        }

        private static bool IsFolderTarget(ToolEntry tool, string targetPath, DownloadType downloadType)
        {
            if (tool.ExecutionMode == ToolExecutionMode.BootFolder)
                return true;
            if (downloadType == DownloadType.ZipFolder)
                return true;
            if (Directory.Exists(targetPath))
                return true;
            return !Path.HasExtension(targetPath);
        }

        private static bool IsZipArchive(string filePath)
            => string.Equals(Path.GetExtension(filePath), ".zip", StringComparison.OrdinalIgnoreCase);

        private static DownloadType ParseDownloadType(string? value)
            => value?.Trim().ToLowerInvariant() switch
            {
                "zip_member" => DownloadType.ZipMember,
                "zip_folder" => DownloadType.ZipFolder,
                "portableapps_paf" => DownloadType.PortableAppsPaf,
                _ => DownloadType.File
            };

        private static bool IsDownloadTypeSupportedForAcquire(DownloadType downloadType)
            => downloadType switch
            {
                DownloadType.File => true,
                DownloadType.ZipMember => true,
                DownloadType.ZipFolder => true,
                DownloadType.PortableAppsPaf => ResolveSevenZipPath() != null,
                _ => false
            };

        private static string? ResolveZipMemberPath(string extractDir, ToolEntry tool, string targetPath)
        {
            if (!string.IsNullOrWhiteSpace(tool.MemberPath))
            {
                var candidate = Path.Combine(extractDir, tool.MemberPath.Replace('/', '\\'));
                if (File.Exists(candidate))
                    return candidate;
            }

            var targetName = Path.GetFileName(targetPath);
            if (!string.IsNullOrWhiteSpace(targetName))
            {
                var matches = Directory.GetFiles(extractDir, targetName, SearchOption.AllDirectories);
                if (matches.Length > 0)
                    return matches[0];
            }

            if (!string.IsNullOrWhiteSpace(tool.ExecuteFile))
            {
                var executeName = Path.GetFileName(tool.ExecuteFile.Replace("%dl_file%", tool.DlFile, StringComparison.OrdinalIgnoreCase));
                if (!string.IsNullOrWhiteSpace(executeName))
                {
                    var matches = Directory.GetFiles(extractDir, executeName, SearchOption.AllDirectories);
                    if (matches.Length > 0)
                        return matches[0];
                }
            }

            return null;
        }

        private static string? ResolveZipFolderPath(string extractDir, ToolEntry tool)
        {
            if (!string.IsNullOrWhiteSpace(tool.MemberPath))
            {
                var candidate = Path.Combine(extractDir, tool.MemberPath.Replace('/', '\\'));
                if (Directory.Exists(candidate))
                    return candidate;
            }

            var directories = Directory.GetDirectories(extractDir);
            if (directories.Length == 1)
                return directories[0];
            return extractDir;
        }

        private static string? ResolvePortableAppsMemberPath(string extractDir, ToolEntry tool, string targetPath)
        {
            if (!string.IsNullOrWhiteSpace(tool.MemberPath))
            {
                var explicitPath = Path.Combine(extractDir, tool.MemberPath.Replace('/', '\\'));
                if (File.Exists(explicitPath))
                    return explicitPath;
            }

            var targetName = Path.GetFileName(targetPath);
            if (!string.IsNullOrWhiteSpace(targetName))
            {
                var matches = Directory.GetFiles(extractDir, targetName, SearchOption.AllDirectories);
                if (matches.Length > 0)
                    return matches[0];
            }

            return null;
        }

        private static bool TryExtractWithSevenZip(string archivePath, string outputDir, out string error)
        {
            error = string.Empty;
            var sevenZip = ResolveSevenZipPath();
            if (string.IsNullOrWhiteSpace(sevenZip))
            {
                error = "7-Zip is not installed. Install 7-Zip to enable .paf.exe extraction.";
                return false;
            }

            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = sevenZip,
                    Arguments = $"x -y -o\"{outputDir}\" \"{archivePath}\"",
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };

                using var proc = Process.Start(psi);
                if (proc == null)
                {
                    error = "Failed to start 7-Zip process.";
                    return false;
                }

                proc.WaitForExit();
                if (proc.ExitCode != 0)
                {
                    var stderr = proc.StandardError.ReadToEnd();
                    error = string.IsNullOrWhiteSpace(stderr)
                        ? $"7-Zip exited with code {proc.ExitCode}."
                        : $"7-Zip exited with code {proc.ExitCode}: {stderr}";
                    return false;
                }

                return true;
            }
            catch (Exception ex)
            {
                error = ex.Message;
                return false;
            }
        }

        private static string? ResolveSevenZipPath()
        {
            var bundled = Path.Combine(ToolsRoot, "Utils", "7Zip", "7z.exe");
            if (File.Exists(bundled))
                return bundled;

            try
            {
                var fromPath = Environment.GetEnvironmentVariable("PATH")?
                    .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
                    .Select(p => Path.Combine(p.Trim(), "7z.exe"))
                    .FirstOrDefault(File.Exists);
                if (!string.IsNullOrWhiteSpace(fromPath))
                    return fromPath;
            }
            catch
            {
                // ignore
            }

            var candidates = new[]
            {
                @"C:\Program Files\7-Zip\7z.exe",
                @"C:\Program Files (x86)\7-Zip\7z.exe",
                @"D:\Program Files\7-Zip\7z.exe",
                @"D:\Program Files (x86)\7-Zip\7z.exe"
            };
            return candidates.FirstOrDefault(File.Exists);
        }

        private static string BuildAcquirePreflightSummary(ToolEntry tool, string url, string targetPath, ManifestEntry manifestEntry)
        {
            var downloadType = ParseDownloadType(tool.DownloadType);
            var planSteps = downloadType switch
            {
                DownloadType.File => "1) Download artifact to staging\n2) Verify SHA256 against manifest\n3) Promote file to target path",
                DownloadType.ZipMember => "1) Download archive to staging\n2) Extract archive\n3) Resolve member file\n4) Verify member SHA256 against manifest\n5) Promote file to target path",
                DownloadType.ZipFolder => "1) Download archive to staging\n2) Extract archive\n3) Resolve member folder\n4) Verify folder SHA256 against manifest\n5) Promote folder payload to target path",
                DownloadType.PortableAppsPaf => "1) Download PortableApps package to staging\n2) Extract package with 7-Zip\n3) Resolve runtime executable\n4) Verify extracted runtime SHA256\n5) Promote file to target path",
                _ => "1) Download artifact\n2) Verify\n3) Promote"
            };

            var sb = new StringBuilder();
            sb.AppendLine("Review acquire details before continuing:");
            sb.AppendLine();
            sb.AppendLine($"Tool: {tool.Name}");
            sb.AppendLine($"Target: {targetPath}");
            sb.AppendLine($"Download URL: {url}");
            sb.AppendLine($"Download Type: {tool.DownloadType}");
            sb.AppendLine($"Member Path: {(string.IsNullOrWhiteSpace(tool.MemberPath) ? "(not set)" : tool.MemberPath)}");
            sb.AppendLine($"Expected SHA256: {manifestEntry.Sha256}");
            sb.AppendLine($"Manifest Status: {manifestEntry.Status ?? "unknown"}");
            sb.AppendLine($"Auto Cleanup: {tool.AutoCleanup}");
            sb.AppendLine();
            sb.AppendLine("Planned Steps:");
            sb.AppendLine(planSteps);
            sb.AppendLine();
            sb.AppendLine("Proceed with Acquire?");
            return sb.ToString();
        }

        private static void PromoteExtractedFolder(string extractDir, string targetPath)
        {
            var topDirectories = Directory.GetDirectories(extractDir);
            var topFiles = Directory.GetFiles(extractDir);
            if (topDirectories.Length == 1 && topFiles.Length == 0)
            {
                CopyDirectory(topDirectories[0], targetPath);
                return;
            }

            foreach (var dir in topDirectories)
            {
                var name = Path.GetFileName(dir);
                CopyDirectory(dir, Path.Combine(targetPath, name));
            }

            foreach (var file in topFiles)
            {
                var name = Path.GetFileName(file);
                File.Copy(file, Path.Combine(targetPath, name), true);
            }
        }

        private static void CopyDirectory(string sourceDir, string destinationDir)
        {
            Directory.CreateDirectory(destinationDir);
            foreach (var file in Directory.GetFiles(sourceDir))
            {
                var dest = Path.Combine(destinationDir, Path.GetFileName(file));
                File.Copy(file, dest, true);
            }

            foreach (var directory in Directory.GetDirectories(sourceDir))
            {
                var destSub = Path.Combine(destinationDir, Path.GetFileName(directory));
                CopyDirectory(directory, destSub);
            }
        }

        private static string ComputeFolderSha256(string folderPath)
        {
            var files = Directory.GetFiles(folderPath, "*", SearchOption.AllDirectories)
                .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
                .ToList();

            var sb = new StringBuilder();
            foreach (var file in files)
            {
                var relative = Path.GetRelativePath(folderPath, file).Replace('/', '\\');
                sb.Append(relative);
                sb.Append('|');
                sb.Append(ComputeSha256(file));
                sb.AppendLine();
            }

            var bytes = Encoding.UTF8.GetBytes(sb.ToString());
            var hash = SHA256.HashData(bytes);
            return Convert.ToHexString(hash);
        }

        private bool TryResolveToolPath(ToolEntry tool, out string? resolvedPath, out string? error)
        {
            resolvedPath = null;
            error = null;

            if (!string.IsNullOrWhiteSpace(tool.RelativePath))
            {
                resolvedPath = Path.Combine(ToolsRoot, tool.RelativePath);
                return true;
            }

            if (!string.IsNullOrWhiteSpace(tool.DiscFolder) && !string.IsNullOrWhiteSpace(tool.ExecuteFile))
            {
                var execFile = tool.ExecuteFile;
                if (execFile.Contains("%dl_file%", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(tool.DlFile))
                    execFile = execFile.Replace("%dl_file%", tool.DlFile, StringComparison.OrdinalIgnoreCase);
                resolvedPath = Path.Combine(ToolsRoot, tool.DiscFolder, execFile);
                return true;
            }

            error = "Catalog entry missing launch path. Needs relativePath or disc_folder + execute_file.";
            return false;
        }

        private static bool ValidateToolPath(string toolPath, out string message)
        {
            message = string.Empty;
            try
            {
                var fullToolsRoot = Path.GetFullPath(ToolsRoot)
                    .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
                var fullToolPath = Path.GetFullPath(toolPath);
                if (!fullToolPath.StartsWith(fullToolsRoot, StringComparison.OrdinalIgnoreCase))
                {
                    message = $"Blocked tool path outside Tools root:\n{fullToolPath}\n\nExpected root:\n{fullToolsRoot}";
                    return false;
                }
            }
            catch (Exception ex)
            {
                message = $"Invalid tool path:\n{ex.Message}";
                return false;
            }
            return true;
        }

        private static void ShowBootToolGuidance(ToolEntry tool, string toolPath)
        {
            var sb = new StringBuilder();
            sb.AppendLine($"{tool.Name} is a boot-environment tool.");
            sb.AppendLine();
            sb.AppendLine("It cannot run directly inside the Toolkit GUI.");
            if (tool.ExecutionMode == ToolExecutionMode.BootEfi)
            {
                sb.AppendLine("After a Windows BCD USB build, reboot from that USB and choose “Windows Memory Diagnostic” in the boot menu.");
            }
            else if (tool.ExecutionMode == ToolExecutionMode.BootSecondaryWinPe)
            {
                sb.AppendLine("After a Windows BCD USB build, reboot and choose the secondary WinPE item if your manifest includes one.");
            }
            else
            {
                sb.AppendLine("CDE will open the tool location so you can use it in your boot workflow.");
            }
            sb.AppendLine();
            sb.AppendLine($"Path: {toolPath}");
            if (File.Exists(toolPath))
            {
                sb.AppendLine($"Size: {FormatFileSize(new FileInfo(toolPath).Length)}");
                sb.AppendLine($"SHA256: {ComputeSha256(toolPath)}");
            }
            if (!string.IsNullOrWhiteSpace(tool.SourceUrl))
            {
                sb.AppendLine();
                sb.AppendLine($"Source: {tool.SourceUrl}");
            }
            MessageBox.Show(sb.ToString(), "Boot Tool Guidance", MessageBoxButton.OK, MessageBoxImage.Information);
        }

        private static void ShowAutoCleanupPlannedMessage(ToolEntry tool)
        {
            MessageBox.Show(
                $"Auto-cleanup for '{tool.Name}' is currently visible as a placeholder.\n\n" +
                "Cleanup policy will be wired to CDE-managed staging folders in a follow-up change.",
                "Auto-Cleanup Placeholder",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
        }

        private static string FormatFileSize(long bytes)
        {
            string[] units = { "B", "KB", "MB", "GB", "TB" };
            double value = bytes;
            var unit = 0;
            while (value >= 1024 && unit < units.Length - 1)
            {
                value /= 1024;
                unit++;
            }
            return $"{value:0.##} {units[unit]}";
        }

        private static string ComputeSha256(string filePath)
        {
            using var stream = File.OpenRead(filePath);
            using var sha = SHA256.Create();
            var hash = sha.ComputeHash(stream);
            return Convert.ToHexString(hash);
        }

        private bool ValidateManifestHash(ToolEntry tool, string toolPath, out string message)
        {
            message = string.Empty;
            if (!File.Exists(toolPath))
                return true;

            var relativePath = tool.RelativePath;
            if (string.IsNullOrWhiteSpace(relativePath))
                relativePath = GetPathRelativeToToolsRoot(toolPath);
            if (string.IsNullOrWhiteSpace(relativePath))
                return true;

            if (!_manifestByPath.TryGetValue(NormalizePath(relativePath), out var entry))
                return true;

            if (!string.Equals(entry.Status, "acquired", StringComparison.OrdinalIgnoreCase))
            {
                message =
                    $"Tool payload status is '{entry.Status ?? "unknown"}' for {tool.Name}.\n\n" +
                    "Run update_tools_manifest.ps1 after placing the official tool file to move status to 'acquired'.";
                return false;
            }

            if (string.IsNullOrWhiteSpace(entry.Sha256))
                return true;

            var actual = ComputeSha256(toolPath);
            if (!actual.Equals(entry.Sha256, StringComparison.OrdinalIgnoreCase))
            {
                message =
                    $"Hash mismatch for {tool.Name}.\n\nExpected: {entry.Sha256}\nActual:   {actual}\n\n" +
                    "Replace the tool payload with the approved artifact or regenerate tools_manifest.json.";
                return false;
            }

            return true;
        }

        private bool ValidateManifestStatusForListing(ToolEntry tool, string toolPath, out string message)
        {
            message = string.Empty;
            if (!File.Exists(toolPath))
                return true;

            var relativePath = tool.RelativePath;
            if (string.IsNullOrWhiteSpace(relativePath))
                relativePath = GetPathRelativeToToolsRoot(toolPath);
            if (string.IsNullOrWhiteSpace(relativePath))
                return true;

            if (!_manifestByPath.TryGetValue(NormalizePath(relativePath), out var entry))
                return true;

            if (!string.Equals(entry.Status, "acquired", StringComparison.OrdinalIgnoreCase))
            {
                message =
                    $"Tool payload status is '{entry.Status ?? "unknown"}' for {tool.Name}.\n\n" +
                    "Run update_tools_manifest.ps1 after placing the official tool file to move status to 'acquired'.";
                return false;
            }

            // UI listing remains fast by skipping file hashing here.
            // Full SHA256 verification still runs on launch/acquire actions.
            return true;
        }

        private static string? GetPathRelativeToToolsRoot(string fullPath)
        {
            try
            {
                var toolsRoot = Path.GetFullPath(ToolsRoot);
                var candidate = Path.GetFullPath(fullPath);
                var rootWithSep = toolsRoot.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
                if (!candidate.StartsWith(rootWithSep, StringComparison.OrdinalIgnoreCase))
                    return null;
                return candidate[rootWithSep.Length..];
            }
            catch
            {
                return null;
            }
        }

        private static string NormalizePath(string path)
            => path.Replace('/', '\\').Trim();

        private static void OpenContainingFolder(string path)
        {
            try
            {
                var target = File.Exists(path) ? Path.GetDirectoryName(path) ?? ToolsRoot : path;
                if (Directory.Exists(target))
                {
                    Process.Start(new ProcessStartInfo
                    {
                        FileName = target,
                        UseShellExecute = true
                    });
                }
            }
            catch
            {
                // best effort only
            }
        }

        private sealed record ToolStatus(bool CanLaunch, bool CanAcquire, string StatusMessage, bool IsPlaceholder);

        private enum AcquireEventLevel
        {
            Info,
            Success,
            Warning,
            Error
        }

        private sealed record ToolCategory
        {
            public string Name { get; init; } = string.Empty;
            public List<ToolEntry> Tools { get; init; } = new();
        }

        private sealed record ToolEntry
        {
            public string Name { get; init; } = string.Empty;
            public string Description { get; init; } = string.Empty;
            public string RelativePath { get; init; } = string.Empty;
            public string DiscFolder { get; init; } = string.Empty;
            public string ExecuteFile { get; init; } = string.Empty;
            public string Arguments { get; init; } = string.Empty;
            public string ExecuteArgs { get; init; } = string.Empty;
            public string DownloadUrl { get; init; } = string.Empty;
            public string DlUrl { get; init; } = string.Empty;
            public string DlFile { get; init; } = string.Empty;
            public string DownloadType { get; init; } = string.Empty;
            public string MemberPath { get; init; } = string.Empty;
            public string SourceUrl { get; init; } = string.Empty;
            public string WinPESupport { get; init; } = "limited";
            public bool RequiresAdmin { get; init; }
            public bool RequiresNetwork { get; init; }
            public bool MonetizationApproved { get; init; }
            public string ApprovalSource { get; init; } = string.Empty;
            public string ApprovedOn { get; init; } = string.Empty;
            public string LicenseNote { get; init; } = string.Empty;
            public bool AutoCleanup { get; init; }
            public bool PlaceholderVisible { get; init; }
            public ToolExecutionMode ExecutionMode { get; init; } = ToolExecutionMode.Native;
            public string WorkflowScript { get; init; } = string.Empty;
        }

        private enum ToolExecutionMode
        {
            Native,
            CdeWorkflow,
            BootIso,
            BootFolder,
            BootEfi,
            BootSecondaryWinPe,
            Placeholder
        }

        private enum DownloadType
        {
            File,
            ZipMember,
            ZipFolder,
            PortableAppsPaf
        }

        private sealed record ToolsManifest
        {
            public string? ManifestSchemaVersion { get; init; }
            public string? GeneratedUtc { get; init; }
            public string? ChecksumAlgorithm { get; init; }
            public List<ManifestEntry>? Entries { get; init; }
        }

        private sealed record ManifestEntry
        {
            public string? Name { get; init; }
            public string? Status { get; init; }
            public string? RelativePath { get; init; }
            public string? Sha256 { get; init; }
            public string? DownloadDirectUrl { get; init; }
        }
    }
}
