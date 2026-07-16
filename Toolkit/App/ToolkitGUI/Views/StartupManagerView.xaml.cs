using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using ToolkitGUI.Models;
using ToolkitGUI.Services;
using ToolkitGUI.ViewModels;

namespace ToolkitGUI.Views
{
    public partial class StartupManagerView : UserControl
    {
        private StartupManagerViewModel _vm;
        private bool _layoutRefreshed;

        public StartupManagerView()
        {
            InitializeComponent();
            _vm = new StartupManagerViewModel();
            DataContext = _vm;
            Loaded += async (_, _) =>
            {
                ApplyNavigationContext();
                await _vm.LoadStartupItemsAsync();
                Dispatcher.BeginInvoke(new Action(RefreshLayout), DispatcherPriority.Loaded);
            };
            SizeChanged += (_, _) => RefreshLayout();
        }

        private void ApplyNavigationContext()
        {
            var context = NavigationService.ConsumePendingContext();
            if (string.IsNullOrWhiteSpace(context))
                return;

            if (context.Equals("SuspiciousOnly", StringComparison.OrdinalIgnoreCase))
            {
                _vm.ShowSuspiciousOnly = true;
                _vm.IncludeWindowsScheduledTasks = true;
                return;
            }

            if (context.StartsWith("filter:", StringComparison.OrdinalIgnoreCase))
            {
                _vm.FilterText = context.Substring("filter:".Length);
                _vm.IncludeWindowsScheduledTasks = true;
            }
        }

        private async void TabStartup_Click(object sender, RoutedEventArgs e)
        {
            await SetActiveStartupTabAsync(StartupManagerViewModel.TabStartupItems, _vm.LoadStartupItemsAsync, TabStartup);
        }

        private async void TabDrivers_Click(object sender, RoutedEventArgs e)
        {
            await SetActiveStartupTabAsync(StartupManagerViewModel.TabDrivers, _vm.LoadDriversAsync, TabDrivers);
        }

        private async void TabExtensions_Click(object sender, RoutedEventArgs e)
        {
            await SetActiveStartupTabAsync(StartupManagerViewModel.TabExtensions, _vm.LoadExtensionsAsync, TabExtensions);
        }

        private async void TabServices_Click(object sender, RoutedEventArgs e)
        {
            _vm.ActiveTab = StartupManagerViewModel.TabServices;
            StartupGrid.Visibility = Visibility.Collapsed;
            ServicesGrid.Visibility = Visibility.Visible;
            SetTabStyles(TabServices);
            await _vm.LoadServicesAsync();
        }

        private async System.Threading.Tasks.Task SetActiveStartupTabAsync(string tab, System.Func<System.Threading.Tasks.Task> loader, Button activeButton)
        {
            _vm.ActiveTab = tab;
            StartupGrid.Visibility = Visibility.Visible;
            ServicesGrid.Visibility = Visibility.Collapsed;
            SetTabStyles(activeButton);
            await loader();
        }

        private void SetTabStyles(Button activeButton)
        {
            TabStartup.Style = (Style)FindResource("TabBtnStyle");
            TabDrivers.Style = (Style)FindResource("TabBtnStyle");
            TabExtensions.Style = (Style)FindResource("TabBtnStyle");
            TabServices.Style = (Style)FindResource("TabBtnStyle");
            activeButton.Style = (Style)FindResource("TabBtnActiveStyle");
        }

        private async void IncludeWindowsTasks_Changed(object sender, RoutedEventArgs e)
        {
            if (!IsLoaded)
                return;

            if (_vm.ActiveTab == StartupManagerViewModel.TabStartupItems)
                await _vm.LoadStartupItemsAsync();
        }

        private void Enable_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as Button)?.Tag is StartupEntry entry)
                _vm.EnableCommand.Execute(entry);
        }

        private void Disable_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as Button)?.Tag is StartupEntry entry)
                _vm.DisableCommand.Execute(entry);
        }

        private void Delete_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as Button)?.Tag is StartupEntry entry)
                _vm.DeleteCommand.Execute(entry);
        }

        private void Reset_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as Button)?.Tag is StartupEntry entry)
                _vm.ResetCommand.Execute(entry);
        }

        private void Undo_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as Button)?.Tag is StartupEntry entry)
                _vm.UndoCommand.Execute(entry);
        }

        private void StartSvc_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as Button)?.Tag is ServiceEntry svc)
                _vm.StartSvcCommand.Execute(svc);
        }

        private void StopSvc_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as Button)?.Tag is ServiceEntry svc)
                _vm.StopSvcCommand.Execute(svc);
        }

        private void RestartSvc_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as Button)?.Tag is ServiceEntry svc)
                _vm.RestartSvcCommand.Execute(svc);
        }

        private void DeleteSvc_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as Button)?.Tag is ServiceEntry svc)
                _vm.DeleteSvcCommand.Execute(svc);
        }

        private void StartupGrid_PreviewMouseRightButtonUp(object sender, MouseButtonEventArgs e)
        {
            if (FindAncestor<DataGridRow>(e.OriginalSource as DependencyObject)?.Item is not StartupEntry entry)
                return;

            StartupGrid.SelectedItem = entry;
            var resolved = _vm.TryResolveEntryFilePath(entry);
            var hasFile = !string.IsNullOrWhiteSpace(resolved);
            var hasRegistry = !string.IsNullOrWhiteSpace(entry.RegistryPath)
                || !string.IsNullOrWhiteSpace(entry.RegistryKey)
                || (!string.IsNullOrWhiteSpace(entry.Source)
                    && (entry.Source.StartsWith("HK", StringComparison.OrdinalIgnoreCase)
                        || entry.Source.StartsWith("HKEY_", StringComparison.OrdinalIgnoreCase)));
            var hasCommand = !string.IsNullOrWhiteSpace(entry.FilePath);

            var menu = CreateStyledContextMenu();
            menu.Items.Add(CreateMenuItem("Open target folder", () => _vm.OpenEntryFileLocation(entry), hasFile));
            menu.Items.Add(CreateMenuItem("Copy target file path", () => _vm.CopyEntryFilePath(entry), hasFile || hasCommand));
            menu.Items.Add(CreateMenuItem("Copy command line", () => _vm.CopyEntryCommandLine(entry), hasCommand));
            var canDeleteTarget = hasFile
                && !string.IsNullOrWhiteSpace(resolved)
                && StartupTargetFileCleanup.IsRemediableDropPath(resolved);
            menu.Items.Add(CreateMenuItem("Delete target file...", () => _vm.DeleteEntryTargetFile(entry), canDeleteTarget));
            menu.Items.Add(CreateMenuItem("Scan with CST", () => _ = _vm.ScanEntryWithCstAsync(entry), hasFile));
            menu.Items.Add(new Separator());
            menu.Items.Add(CreateMenuItem("Copy registry path", () => _vm.CopyEntryRegistryPath(entry), hasRegistry));
            menu.Items.Add(CreateMenuItem("Open in Registry Editor", () => _vm.OpenEntryInRegistryEditor(entry), hasRegistry));
            menu.Items.Add(new Separator());
            menu.Items.Add(CreateMenuItem("Show entry details", () => _vm.ShowEntryDetails(entry)));
            menu.Items.Add(CreateMenuItem("Open Malware Cleanup", () => _vm.OpenMalwareCleanup()));
            menu.Items.Add(CreateMenuItem("Open Process Analyzer", () => _vm.OpenProcessAnalyzer()));
            menu.Items.Add(CreateMenuItem("Open File Manager", () => NavigationService.Request("FileManager")));

            menu.PlacementTarget = StartupGrid;
            menu.Placement = System.Windows.Controls.Primitives.PlacementMode.MousePoint;
            menu.IsOpen = true;
            e.Handled = true;
        }

        private void ServicesGrid_PreviewMouseRightButtonUp(object sender, MouseButtonEventArgs e)
        {
            if (FindAncestor<DataGridRow>(e.OriginalSource as DependencyObject)?.Item is not ServiceEntry service)
                return;

            // Don't steal right-click from the startup-type ComboBox.
            if (FindAncestor<ComboBox>(e.OriginalSource as DependencyObject) != null)
                return;

            ServicesGrid.SelectedItem = service;
            var resolved = _vm.TryResolveServiceFilePath(service);
            var hasFile = !string.IsNullOrWhiteSpace(resolved);
            var hasPath = !string.IsNullOrWhiteSpace(service.FilePath);
            var hasName = !string.IsNullOrWhiteSpace(service.ServiceName);

            var menu = CreateStyledContextMenu();
            menu.Items.Add(CreateMenuItem("Open file location", () => _vm.OpenServiceFileLocation(service), hasFile));
            menu.Items.Add(CreateMenuItem("Copy file path", () => _vm.CopyServiceFilePath(service), hasFile || hasPath));
            menu.Items.Add(CreateMenuItem("Copy service name", () => _vm.CopyServiceName(service), hasName));
            menu.Items.Add(CreateMenuItem("Scan with CST", () => _ = _vm.ScanServiceWithCstAsync(service), hasFile));
            menu.Items.Add(CreateMenuItem("Delete service...", () => _vm.DeleteSvcCommand.Execute(service), service.SupportsDelete));
            menu.Items.Add(new Separator());
            menu.Items.Add(CreateMenuItem("Show service details", () => _vm.ShowServiceDetails(service)));
            menu.Items.Add(CreateMenuItem("Open Malware Cleanup", () => _vm.OpenMalwareCleanup()));
            menu.Items.Add(CreateMenuItem("Open Process Analyzer", () => _vm.OpenProcessAnalyzer()));

            menu.PlacementTarget = ServicesGrid;
            menu.Placement = System.Windows.Controls.Primitives.PlacementMode.MousePoint;
            menu.IsOpen = true;
            e.Handled = true;
        }

        private ContextMenu CreateStyledContextMenu()
        {
            return new ContextMenu
            {
                Background = (Brush)FindResource("BackgroundDarkBrush"),
                Foreground = (Brush)FindResource("TextPrimaryBrush"),
                BorderBrush = (Brush)FindResource("TextSecondaryBrush")
            };
        }

        private static MenuItem CreateMenuItem(string header, Action action, bool isEnabled = true)
        {
            var item = new MenuItem { Header = header, IsEnabled = isEnabled };
            item.Click += (_, _) => action();
            return item;
        }

        private static T? FindAncestor<T>(DependencyObject? current) where T : DependencyObject
        {
            while (current != null)
            {
                if (current is T match)
                    return match;
                current = VisualTreeHelper.GetParent(current);
            }

            return null;
        }

        private void RefreshLayout()
        {
            if (_layoutRefreshed || ActualWidth <= 0 || ActualHeight <= 0)
                return;

            _layoutRefreshed = true;
            InvalidateMeasure();
            InvalidateArrange();
            UpdateLayout();
            StartupGrid.InvalidateMeasure();
            StartupGrid.InvalidateArrange();
            StartupGrid.UpdateLayout();
            ServicesGrid.InvalidateMeasure();
            ServicesGrid.InvalidateArrange();
            ServicesGrid.UpdateLayout();
        }

        private void StartupType_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (sender is not ComboBox combo)
                return;

            if (combo.DataContext is not ServiceEntry svc)
                return;

            // Ignore initial binding/setup churn and only react to user-driven changes.
            if (e.AddedItems.Count == 0 || e.RemovedItems.Count == 0)
                return;

            if (!(combo.IsDropDownOpen || combo.IsKeyboardFocusWithin))
                return;

            if (_vm.SetStartTypeCommand.CanExecute(svc))
                _vm.SetStartTypeCommand.Execute(svc);
        }
    }
}
