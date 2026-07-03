using System;

using System.IO;

using System.Windows;

using System.Windows.Controls;

using System.Windows.Input;

using ToolkitGUI.Services;

using ToolkitGUI.ViewModels;

using ToolkitGUI.Views;



namespace ToolkitGUI

{

    public partial class MainWindow : Window

    {

        private readonly MainViewModel _viewModel;

        private Button? _activeNavButton;

        private bool _closingConfirmed;

        private Rect _restoreBounds;

        private bool _isPseudoMaximized;



        public MainWindow()

        {

            InitializeComponent();

            BorderlessWindowHelper.Enable(this);

            _viewModel = (MainViewModel)DataContext;

            _activeNavButton = BtnDashboard;

            NavigationService.NavigateRequested += OnNavigateRequested;

            Loaded += OnMainWindowLoaded;

            BorderlessWindowHelper.EnableDisplayChangeRelayout(this, OnDisplayChanged);

            _ = _viewModel.InitializeAsync();

        }



        private void OnMainWindowLoaded(object sender, RoutedEventArgs e)

        {

            BorderlessWindowHelper.ApplyShellStartup(

                this,

                designWidth: 1340,

                designHeight: 820,

                designMinWidth: 1060,

                designMinHeight: 640,

                fillWorkArea: IsWinPe());



            if (IsWinPe())

                _isPseudoMaximized = true;



            UpdateNavFlyoutMaxHeight();

        }



        private void UpdateNavFlyoutMaxHeight()

        {

            var flyoutBorder = NavFlyoutPopup.Child as FrameworkElement;

            if (flyoutBorder == null)

                return;



            var maxHeight = Math.Max(320, ActualHeight - 120);

            flyoutBorder.MaxHeight = maxHeight;

        }



        private void OnDisplayChanged(Window window)

        {

            if (_isPseudoMaximized)

                BorderlessWindowHelper.FillWorkArea(window);

            else

                BorderlessWindowHelper.EnsureWithinWorkArea(window);



            UpdateNavFlyoutMaxHeight();

        }



        private void OnNavigateRequested(string section)

        {

            Dispatcher.Invoke(() =>

            {

                _viewModel.NavigateTo(section);

                if (string.Equals(section, "SystemHealth", StringComparison.OrdinalIgnoreCase)

                    || string.Equals(section, "SystemAudit", StringComparison.OrdinalIgnoreCase))

                {

                    if (_viewModel.CurrentView is SystemHealthView healthView)

                        healthView.ApplyPendingNavigationContext();

                }



                if (string.Equals(section, "ProcessAnalyzer", StringComparison.OrdinalIgnoreCase))

                {

                    if (_viewModel.CurrentView is ProcessAnalyzerView processView)

                        processView.ApplyPendingNavigationContext();

                }



                if (string.Equals(section, "HijackRepair", StringComparison.OrdinalIgnoreCase))

                {

                    if (_viewModel.CurrentView is HijackRepairView hijackView)

                        hijackView.ApplyPendingNavigationContext();

                }



                if (string.Equals(section, "DiagAndRepair", StringComparison.OrdinalIgnoreCase)

                    || string.Equals(section, "HardwareDiagnostics", StringComparison.OrdinalIgnoreCase))

                {

                    if (_viewModel.CurrentView is DiagAndRepairView diagView)

                        diagView.ApplyPendingNavigationContext();

                }



                var button = FindName($"Btn{section}") as Button;

                if (button == null)

                {

                    button = section switch

                    {

                        "SystemHealth" => BtnSystemHealth,

                        "SystemAudit" => BtnSystemHealth,

                        "TempFileCleaner" => BtnTempCleaner,

                        "StartupManager" => BtnStartupMgr,

                        "MalwareCleanup" => BtnMalware,

                        "HijackRepair" => BtnHijackRepair,

                        "SmartAnalyzer" => BtnSmartAnalyzer,

                        "DiagAndRepair" => BtnHwDiag,

                        "HardwareDiagnostics" => BtnHwDiag,

                        "FastFixes" => BtnFastFixes,

                        "ProcessAnalyzer" => BtnProcessAnalyzer,

                        _ => null

                    };

                }

                if (button != null)

                {

                    if (_activeNavButton != null)

                        _activeNavButton.Style = (Style)FindResource("NavButtonStyle");

                    _activeNavButton = button;

                    button.Style = (Style)FindResource("NavButtonActiveStyle");

                }

            });

        }



        private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)

        {

            if (e.ClickCount == 2)

                ToggleMaximize();

            else

                DragMove();

        }



        private void NavMenu_Click(object sender, RoutedEventArgs e)

        {

            UpdateNavFlyoutMaxHeight();

            NavFlyoutPopup.IsOpen = !NavFlyoutPopup.IsOpen;

        }



        private void MinimizeButton_Click(object sender, RoutedEventArgs e) =>

            WindowState = WindowState.Minimized;



        private void MaximizeButton_Click(object sender, RoutedEventArgs e) =>

            ToggleMaximize();



        private void CloseButton_Click(object sender, RoutedEventArgs e) =>

            Close();



        protected override async void OnClosing(System.ComponentModel.CancelEventArgs e)

        {

            if (!_closingConfirmed && IsWinPe() && IsOfflineOsLoaded())

            {

                e.Cancel = true;

                var dlg = new UnmountOnCloseDialog { Owner = this };

                if (dlg.ShowDialog() == true)

                {

                    await PowerShellService.ExecuteAsync(SettingsView.GetOfflineHiveCleanupScript());

                    _closingConfirmed = true;

                    Close();

                }

                return;

            }

            base.OnClosing(e);

        }



        protected override void OnClosed(EventArgs e)

        {

            _viewModel.Dispose();

            base.OnClosed(e);

        }



        private void ToggleMaximize()

        {

            if (_isPseudoMaximized)

                RestoreFromPseudoMaximize();

            else

                ApplyPseudoMaximize();

        }



        private void ApplyPseudoMaximize()

        {

            _restoreBounds = new Rect(Left, Top, Width, Height);

            BorderlessWindowHelper.FillWorkArea(this);

            _isPseudoMaximized = true;

            UpdateNavFlyoutMaxHeight();

        }



        private void RestoreFromPseudoMaximize()

        {

            WindowState = WindowState.Normal;

            Left = _restoreBounds.Left;

            Top = _restoreBounds.Top;

            Width = _restoreBounds.Width;

            Height = _restoreBounds.Height;

            _isPseudoMaximized = false;

            UpdateNavFlyoutMaxHeight();

        }



        private void Nav_Click(object sender, RoutedEventArgs e)

        {

            if (sender is not Button btn) return;



            if (_activeNavButton != null)

                _activeNavButton.Style = (Style)FindResource("NavButtonStyle");



            _activeNavButton = btn;

            btn.Style = (Style)FindResource("NavButtonActiveStyle");



            string tag = btn.Tag?.ToString() ?? "Dashboard";

            _viewModel.NavigateTo(tag);



            NavFlyoutPopup.IsOpen = false;



            if (tag == "StartupManager")

            {

                Dispatcher.BeginInvoke(new Action(() =>

                {

                    MainContent.InvalidateMeasure();

                    MainContent.InvalidateArrange();

                    MainContent.UpdateLayout();

                }), System.Windows.Threading.DispatcherPriority.Loaded);

            }

        }



        private static bool IsWinPe() =>

            Directory.Exists(@"X:\Windows\System32");



        private static bool IsOfflineOsLoaded() =>

            !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("OFFLINE_WINDOWS_ROOT"));

    }

}


