using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using WinForms = System.Windows.Forms;
using ToolkitGUI.Services;

namespace ToolkitGUI.Views
{
    public partial class CoreSecurityToolConfigDialog : Window
    {
        public string ScanMode { get; private set; } = "ThreatScan";
        public string DetectionScope { get; private set; } = "All";
        public string ActionMode { get; private set; } = "ScanOnly";
        public IReadOnlyList<string> CustomTargetPaths => _customTargetPaths;

        /// <summary>When set, the Update Hash IOCs button runs this workflow (typically MalwareSweep UpdateHashIOCs).</summary>
        public Func<Task>? OnUpdateHashIocRequested { get; set; }

        private readonly List<string> _customTargetPaths = new();
        private const int MaxCustomTargets = 12;
        private bool _isInitialized;

        public CoreSecurityToolConfigDialog()
        {
            InitializeComponent();
            WindowSizingHelper.EnableAdaptiveDialog(this);
            Loaded += (_, _) =>
            {
                _isInitialized = true;
                RefreshTargetsValidation();
            };
        }

        private void ScanTypeComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (!_isInitialized)
                return;

            ScanMode = SelectedTag(ScanTypeComboBox, "ThreatScan");

            var customMode = string.Equals(ScanMode, "CustomScan", StringComparison.OrdinalIgnoreCase);
            AddTargetButton.IsEnabled = customMode;
            RemoveTargetButton.IsEnabled = customMode && TargetsListBox.SelectedItem is string;
            ClearTargetsButton.IsEnabled = customMode && _customTargetPaths.Count > 0;

            TargetHintText.Text = customMode
                ? "Add one or more existing folders to scan"
                : "(used only when Scan Type = Custom Scan)";

            RefreshTargetsValidation();
        }

        private void DetectionScopeComboBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (!_isInitialized)
                return;

            DetectionScope = SelectedTag(DetectionScopeComboBox, "All");
        }

        private void AddTargetButton_Click(object sender, RoutedEventArgs e)
        {
            if (!_isInitialized)
                return;

            if (IsWinPeEnvironment())
            {
                if (TryPromptWinPeTargetPath(out var winPeSelectedPath))
                {
                    AddCustomTarget(winPeSelectedPath);
                    RefreshTargetsValidation();
                }
                return;
            }

            try
            {
                using var dialog = new WinForms.FolderBrowserDialog
                {
                    Description = "Select a folder to add to the Core Security Tool custom scan scope",
                    UseDescriptionForTitle = true,
                    RootFolder = Environment.SpecialFolder.MyComputer,
                    SelectedPath = GetSuggestedRootPath(),
                    ShowNewFolderButton = false
                };

                if (dialog.ShowDialog() == WinForms.DialogResult.OK)
                {
                    AddCustomTarget(dialog.SelectedPath);
                    RefreshTargetsValidation();
                }
            }
            catch (Exception ex)
            {
                // WinPE shell environments can fail to resolve default shell roots for FolderBrowserDialog.
                var fallback = GetSuggestedRootPath();
                if (!string.IsNullOrWhiteSpace(fallback) && Directory.Exists(fallback))
                {
                    AddCustomTarget(fallback);
                    RefreshTargetsValidation();
                    MessageBox.Show(
                        $"Folder picker is unavailable in this WinPE shell. Added fallback target: {fallback}",
                        "Core Security Tool",
                        MessageBoxButton.OK,
                        MessageBoxImage.Information);
                    return;
                }

                MessageBox.Show(
                    $"Unable to open folder picker in this environment: {ex.Message}",
                    "Core Security Tool",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }

        private bool TryPromptWinPeTargetPath(out string selectedPath)
        {
            selectedPath = string.Empty;
            var selectedFromDialog = string.Empty;

            var candidateRoots = GetWinPeTargetCandidates();
            var defaultValue = candidateRoots.FirstOrDefault() ?? GetSuggestedRootPath();

            var owner = this;
            var dialog = new Window
            {
                Title = "Select WinPE Scan Target",
                Width = 620,
                Height = 260,
                WindowStartupLocation = WindowStartupLocation.CenterOwner,
                ResizeMode = ResizeMode.NoResize,
                Owner = owner,
                Background = owner.Background
            };
            WindowSizingHelper.EnableAdaptiveDialog(dialog);

            var layout = new Grid { Margin = new Thickness(16) };
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            var info = new TextBlock
            {
                Text = "WinPE shell folder browsing can be unavailable. Select a discovered drive root or type a full existing path.",
                TextWrapping = TextWrapping.Wrap,
                Foreground = (System.Windows.Media.Brush)FindResource("TextSecondaryBrush")
            };
            Grid.SetRow(info, 0);
            layout.Children.Add(info);

            var combo = new ComboBox
            {
                Margin = new Thickness(0, 10, 0, 8),
                ItemsSource = candidateRoots,
                IsEditable = false
            };
            if (candidateRoots.Count > 0)
            {
                combo.SelectedIndex = 0;
            }
            Grid.SetRow(combo, 1);
            layout.Children.Add(combo);

            var pathBox = new TextBox
            {
                Text = defaultValue,
                Margin = new Thickness(0, 0, 0, 8)
            };
            Grid.SetRow(pathBox, 2);
            layout.Children.Add(pathBox);

            combo.SelectionChanged += (_, _) =>
            {
                if (combo.SelectedItem is string selected && !string.IsNullOrWhiteSpace(selected))
                {
                    pathBox.Text = selected;
                }
            };

            var hint = new TextBlock
            {
                Text = "Examples: C:\\, D:\\Windows, D:\\Users\\Public\\Downloads",
                Foreground = (System.Windows.Media.Brush)FindResource("TextSecondaryBrush"),
                TextWrapping = TextWrapping.Wrap
            };
            Grid.SetRow(hint, 3);
            layout.Children.Add(hint);

            var buttons = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Right
            };
            var cancel = new Button
            {
                Content = "Cancel",
                MinWidth = 96,
                Margin = new Thickness(0, 0, 8, 0)
            };
            var add = new Button
            {
                Content = "Add Target",
                MinWidth = 110,
                IsDefault = true
            };

            cancel.Click += (_, _) =>
            {
                dialog.DialogResult = false;
                dialog.Close();
            };

            add.Click += (_, _) =>
            {
                var input = (pathBox.Text ?? string.Empty).Trim();
                if (string.IsNullOrWhiteSpace(input))
                {
                    MessageBox.Show(dialog, "Enter a path or select a discovered root.", "Core Security Tool", MessageBoxButton.OK, MessageBoxImage.Warning);
                    return;
                }

                string normalized;
                try
                {
                    normalized = NormalizePath(input);
                }
                catch (Exception ex)
                {
                    MessageBox.Show(dialog, $"The path is not valid: {ex.Message}", "Core Security Tool", MessageBoxButton.OK, MessageBoxImage.Warning);
                    return;
                }

                if (!Directory.Exists(normalized))
                {
                    MessageBox.Show(dialog, $"The selected path does not exist in this WinPE session:\n{normalized}", "Core Security Tool", MessageBoxButton.OK, MessageBoxImage.Warning);
                    return;
                }

                selectedFromDialog = normalized;
                dialog.DialogResult = true;
                dialog.Close();
            };

            buttons.Children.Add(cancel);
            buttons.Children.Add(add);
            Grid.SetRow(buttons, 4);
            layout.Children.Add(buttons);

            dialog.Content = layout;
            var result = dialog.ShowDialog() == true;
            if (result)
            {
                selectedPath = selectedFromDialog;
            }

            return result;
        }

        private static List<string> GetWinPeTargetCandidates()
        {
            var candidates = new List<string>();

            var offlineRoot = Environment.GetEnvironmentVariable("OFFLINE_WINDOWS_ROOT");
            if (!string.IsNullOrWhiteSpace(offlineRoot) && Directory.Exists(offlineRoot))
            {
                candidates.Add(NormalizeRoot(offlineRoot));
            }

            var windowsRoots = DriveInfo
                .GetDrives()
                .Where(d => d.IsReady)
                .Select(d => d.RootDirectory.FullName)
                .Where(root => !root.StartsWith("X", StringComparison.OrdinalIgnoreCase))
                .Where(root => Directory.Exists(Path.Combine(root, "Windows", "System32")))
                .Select(NormalizeRoot)
                .ToList();

            candidates.AddRange(windowsRoots);

            var additionalRoots = DriveInfo
                .GetDrives()
                .Where(d => d.IsReady)
                .Select(d => NormalizeRoot(d.RootDirectory.FullName))
                .Where(root => !root.StartsWith("X", StringComparison.OrdinalIgnoreCase))
                .ToList();

            candidates.AddRange(additionalRoots);

            if (candidates.Count == 0)
            {
                candidates.Add(GetSuggestedRootPath());
            }

            return candidates
                .Where(path => !string.IsNullOrWhiteSpace(path))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();
        }

        private static bool IsWinPeEnvironment()
        {
            return Directory.Exists("X:\\Windows\\System32");
        }

        private void RemoveTargetButton_Click(object sender, RoutedEventArgs e)
        {
            if (!_isInitialized || TargetsListBox.SelectedItem is not string selectedPath)
                return;

            _customTargetPaths.Remove(selectedPath);
            RefreshTargetsList();
            RefreshTargetsValidation();
        }

        private void ClearTargetsButton_Click(object sender, RoutedEventArgs e)
        {
            if (!_isInitialized)
                return;

            _customTargetPaths.Clear();
            RefreshTargetsList();
            RefreshTargetsValidation();
        }

        private void TargetsListBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (!_isInitialized)
                return;

            RemoveTargetButton.IsEnabled = string.Equals(ScanMode, "CustomScan", StringComparison.OrdinalIgnoreCase)
                                           && TargetsListBox.SelectedItem is string;
        }

        private void CancelButton_Click(object sender, RoutedEventArgs e)
        {
            DialogResult = false;
            Close();
        }

        private async void UpdateHashIocButton_Click(object sender, RoutedEventArgs e)
        {
            if (!_isInitialized)
                return;

            if (OnUpdateHashIocRequested is null)
            {
                MessageBox.Show(
                    "Hash IOC update is not available from this dialog context.",
                    "Core Security Tool",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            UpdateHashIocButton.IsEnabled = false;
            try
            {
                await OnUpdateHashIocRequested();
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    $"Hash IOC update failed: {ex.Message}",
                    "Core Security Tool",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
            finally
            {
                UpdateHashIocButton.IsEnabled = true;
            }
        }

        private void RunButton_Click(object sender, RoutedEventArgs e)
        {
            if (!_isInitialized)
                return;

            ScanMode = SelectedTag(ScanTypeComboBox, "ThreatScan");
            DetectionScope = SelectedTag(DetectionScopeComboBox, "All");
            ActionMode = "ScanOnly";

            if (string.Equals(ScanMode, "CustomScan", StringComparison.OrdinalIgnoreCase))
            {
                if (_customTargetPaths.Count == 0)
                {
                    MessageBox.Show("Add at least one custom scan target folder before running Custom Scan.", "Core Security Tool", MessageBoxButton.OK, MessageBoxImage.Warning);
                    return;
                }

                var missing = _customTargetPaths.Where(path => !Directory.Exists(path)).ToList();
                if (missing.Count > 0)
                {
                    MessageBox.Show("One or more selected target folders no longer exist. Remove missing paths before continuing.", "Core Security Tool", MessageBoxButton.OK, MessageBoxImage.Warning);
                    return;
                }
            }

            DialogResult = true;
            Close();
        }

        private void AddCustomTarget(string selectedPath)
        {
            if (string.IsNullOrWhiteSpace(selectedPath))
                return;

            var normalized = NormalizePath(selectedPath);
            if (_customTargetPaths.Any(existing => string.Equals(existing, normalized, StringComparison.OrdinalIgnoreCase)))
            {
                MessageBox.Show("That target folder is already in the custom scan list.", "Core Security Tool", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            if (_customTargetPaths.Count >= MaxCustomTargets)
            {
                MessageBox.Show($"Custom scan supports up to {MaxCustomTargets} target folders in one run.", "Core Security Tool", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            _customTargetPaths.Add(normalized);
            RefreshTargetsList();
        }

        private void RefreshTargetsList()
        {
            TargetsListBox.ItemsSource = null;
            TargetsListBox.ItemsSource = _customTargetPaths.ToList();
            ClearTargetsButton.IsEnabled = string.Equals(ScanMode, "CustomScan", StringComparison.OrdinalIgnoreCase)
                                           && _customTargetPaths.Count > 0;
        }

        private void RefreshTargetsValidation()
        {
            var existing = _customTargetPaths.Count(path => Directory.Exists(path));
            var missing = _customTargetPaths.Count - existing;

            if (_customTargetPaths.Count == 0)
            {
                TargetsValidationText.Text = "No custom targets selected.";
                return;
            }

            TargetsValidationText.Text = $"Targets: {_customTargetPaths.Count} | Existing: {existing} | Missing: {missing}";
        }

        private static string GetSuggestedRootPath()
        {
            var offlineRoot = Environment.GetEnvironmentVariable("OFFLINE_WINDOWS_ROOT");
            if (!string.IsNullOrWhiteSpace(offlineRoot) && Directory.Exists(offlineRoot))
            {
                return NormalizeRoot(offlineRoot);
            }

            if (Directory.Exists("C:\\"))
            {
                return "C:\\";
            }

            var candidate = DriveInfo
                .GetDrives()
                .Where(d => d.IsReady)
                .OrderBy(d => d.Name.StartsWith("X", StringComparison.OrdinalIgnoreCase) ? 1 : 0)
                .Select(d => d.RootDirectory.FullName)
                .FirstOrDefault();

            return string.IsNullOrWhiteSpace(candidate) ? "C:\\" : NormalizeRoot(candidate);
        }

        private static string NormalizeRoot(string path)
        {
            var root = Path.GetPathRoot(Path.GetFullPath(path));
            if (string.IsNullOrWhiteSpace(root))
            {
                return "C:\\";
            }

            return root.EndsWith(Path.DirectorySeparatorChar)
                ? root
                : root + Path.DirectorySeparatorChar;
        }

        private static string NormalizePath(string path)
        {
            var full = Path.GetFullPath(path);
            return full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        }

        private static string SelectedTag(ComboBox comboBox, string fallback)
        {
            if (comboBox.SelectedItem is ComboBoxItem item && item.Tag is string tag && !string.IsNullOrWhiteSpace(tag))
            {
                return tag;
            }
            return fallback;
        }
    }
}
