using System;
using System.Windows;
using System.Windows.Controls;
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
