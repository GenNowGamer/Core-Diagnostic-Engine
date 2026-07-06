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
        private MainViewModel? _viewModel;
        private Button? _activeNavButton;
        private bool _closingConfirmed;
        private Rect _restoreBounds;
        private bool _isPseudoMaximized;
        private bool _shellInitialized;

        public MainWindow()
        {
            // Chrome must be configured before InitializeComponent / HWND creation.
            // WinPE has no DWM: AllowsTransparency windows fail or render invisible.
            ConfigureShellChromeForEnvironment();
            InitializeComponent();
            ApplyWinPeShellDecorations();
            BorderlessWindowHelper.Enable(this);
            NavigationService.NavigateRequested += OnNavigateRequested;
            Loaded += OnMainWindowLoaded;
            ContentRendered += OnMainWindowContentRendered;
            BorderlessWindowHelper.EnableDisplayChangeRelayout(this, OnDisplayChanged);
            if (IsWinPe())
                StateChanged += OnWinPeWindowStateChanged;
            WinPeStartupLog.Write("MainWindowCtor", "complete (deferred view-model init)");
        }

        /// <summary>
        /// Sets window chrome before the window source exists. Must not be driven by XAML.
        /// </summary>
        private void ConfigureShellChromeForEnvironment()
        {
            if (IsWinPe())
            {
                // Standard frame is the most reliable presentation path in WinPE.
                WindowStyle = WindowStyle.SingleBorderWindow;
                AllowsTransparency = false;
                ResizeMode = ResizeMode.CanResize;
                MinWidth = 640;
                MinHeight = 480;
                Background = new System.Windows.Media.SolidColorBrush(
                    System.Windows.Media.Color.FromRgb(0xEE, 0xF2, 0xF7));
            }
            else
            {
                WindowStyle = WindowStyle.None;
                AllowsTransparency = true;
                ResizeMode = ResizeMode.CanResizeWithGrip;
                Background = System.Windows.Media.Brushes.Transparent;
            }
        }

        /// <summary>
        /// WinPE-only post-init tweaks (rounded corners need DWM).
        /// </summary>
        private void ApplyWinPeShellDecorations()
        {
            if (!IsWinPe())
            {
                // Full Windows: restore layered flyout chrome.
                NavFlyoutPopup.AllowsTransparency = true;
                NavFlyoutPopup.PopupAnimation = System.Windows.Controls.Primitives.PopupAnimation.Fade;
                return;
            }

            if (TryFindResource("BackgroundDarkBrush") is System.Windows.Media.Brush brush)
                Background = brush;

            if (Content is Border shellBorder)
                shellBorder.CornerRadius = default;

            NavFlyoutPopup.AllowsTransparency = false;
            NavFlyoutPopup.PopupAnimation = System.Windows.Controls.Primitives.PopupAnimation.None;
            if (NavFlyoutBorder != null)
                NavFlyoutBorder.CornerRadius = default;
        }

        private void OnMainWindowLoaded(object sender, RoutedEventArgs e)
        {
            try
            {
                if (IsWinPe())
                    _restoreBounds = CreateDefaultRestoreBounds();

                BorderlessWindowHelper.ApplyShellStartup(
                    this,
                    designWidth: 1340,
                    designHeight: 820,
                    designMinWidth: IsWinPe() ? 640 : 1060,
                    designMinHeight: IsWinPe() ? 480 : 640,
                    fillWorkArea: IsWinPe());
                if (IsWinPe())
                    _isPseudoMaximized = true;
                UpdateNavFlyoutMaxHeight();
                WinPeStartupLog.Write("MainWindowLoaded",
                    $"Size={ActualWidth}x{ActualHeight} Pos={Left},{Top} Style={WindowStyle} " +
                    $"Restore={_restoreBounds.Width}x{_restoreBounds.Height}");
            }
            catch (Exception ex)
            {
                WinPeStartupLog.Write("MainWindowLoadedError", ex.ToString());
            }
        }

        /// <summary>
        /// WinPE system maximize (WindowState.Maximized) is unsafe under software rendering.
        /// Convert it to the same pseudo-maximize path as the in-window maximize button.
        /// </summary>
        private void OnWinPeWindowStateChanged(object? sender, EventArgs e)
        {
            if (WindowState != WindowState.Maximized)
                return;

            try
            {
                WindowState = WindowState.Normal;
                ApplyPseudoMaximize();
            }
            catch (Exception ex)
            {
                WinPeStartupLog.Write("WinPeMaximizeInterceptFailed", ex.ToString());
                try
                {
                    WindowState = WindowState.Normal;
                    Width = Math.Max(MinWidth, 1024);
                    Height = Math.Max(MinHeight, 768);
                    _isPseudoMaximized = false;
                }
                catch
                {
                    /* best-effort recovery */
                }
            }
        }

        private void OnMainWindowContentRendered(object? sender, EventArgs e)
        {
            ContentRendered -= OnMainWindowContentRendered;
            if (_shellInitialized)
                return;
            _shellInitialized = true;

            try
            {
                WinPeStartupLog.Write("ShellInit", "creating MainViewModel");
                _viewModel = new MainViewModel();
                DataContext = _viewModel;
                _activeNavButton = BtnDashboard;
                _ = _viewModel.InitializeAsync();
                WinPeStartupLog.Write("ShellInit", "MainViewModel ready");
            }
            catch (Exception ex)
            {
                WinPeStartupLog.Write("ShellInitFailed", ex.ToString());
                MessageBox.Show(
                    this,
                    $"CDE shell opened but the dashboard failed to initialize:\n\n{ex.Message}\n\n" +
                    "See CDE\\Runtime\\winpe_startup.log on the USB.",
                    "ToolkitGUI Warning",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
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
                if (_viewModel == null)
                    return;
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
            {
                try { ToggleMaximize(); }
                catch (Exception ex) { WinPeStartupLog.Write("TitleBarMaximizeFailed", ex.ToString()); }
            }
            else
            {
                try { DragMove(); }
                catch { /* ignore drag failures */ }
            }
        }
        private void NavMenu_Click(object sender, RoutedEventArgs e)
        {
            UpdateNavFlyoutMaxHeight();
            NavFlyoutPopup.IsOpen = !NavFlyoutPopup.IsOpen;
        }
        private void MinimizeButton_Click(object sender, RoutedEventArgs e) =>
            WindowState = WindowState.Minimized;
        private void MaximizeButton_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                ToggleMaximize();
            }
            catch (Exception ex)
            {
                WinPeStartupLog.Write("MaximizeButtonFailed", ex.ToString());
            }
        }

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
            _viewModel?.Dispose();
            base.OnClosed(e);
        }
        private void ToggleMaximize()
        {
            if (_isPseudoMaximized || WindowState == WindowState.Maximized)
                RestoreFromPseudoMaximize();
            else
                ApplyPseudoMaximize();
        }

        private void ApplyPseudoMaximize()
        {
            if (WindowState != WindowState.Normal)
                WindowState = WindowState.Normal;

            // Preserve a valid restore size. Startup fill-work-area used to set
            // _isPseudoMaximized without saving bounds, so maximize restored to 0x0 and crashed WinPE.
            if (!_isPseudoMaximized && IsUsableSize(Width, Height))
                _restoreBounds = new Rect(Left, Top, Width, Height);
            else if (!IsUsableSize(_restoreBounds.Width, _restoreBounds.Height))
                _restoreBounds = CreateDefaultRestoreBounds();

            BorderlessWindowHelper.FillWorkArea(this);
            _isPseudoMaximized = true;
            UpdateNavFlyoutMaxHeight();
        }

        private void RestoreFromPseudoMaximize()
        {
            if (WindowState != WindowState.Normal)
                WindowState = WindowState.Normal;

            var bounds = _restoreBounds;
            if (!IsUsableSize(bounds.Width, bounds.Height))
                bounds = CreateDefaultRestoreBounds();

            Left = double.IsFinite(bounds.Left) ? bounds.Left : 40;
            Top = double.IsFinite(bounds.Top) ? bounds.Top : 40;
            Width = bounds.Width;
            Height = bounds.Height;
            _isPseudoMaximized = false;
            UpdateNavFlyoutMaxHeight();
        }

        private Rect CreateDefaultRestoreBounds()
        {
            var area = BorderlessWindowHelper.GetSafeWorkAreaDips(this);
            var width = Math.Min(1340, Math.Max(MinWidth, area.Width - 80));
            var height = Math.Min(820, Math.Max(MinHeight, area.Height - 80));
            if (!IsUsableSize(width, height))
            {
                width = Math.Max(MinWidth, 1024);
                height = Math.Max(MinHeight, 768);
            }

            var left = area.Left + Math.Max(20, (area.Width - width) / 2);
            var top = area.Top + Math.Max(20, (area.Height - height) / 2);
            if (!double.IsFinite(left)) left = 40;
            if (!double.IsFinite(top)) top = 40;
            return new Rect(left, top, width, height);
        }

        private static bool IsUsableSize(double width, double height) =>
            width >= 640 &&
            height >= 480 &&
            double.IsFinite(width) &&
            double.IsFinite(height);
        private void Nav_Click(object sender, RoutedEventArgs e)
        {
            if (sender is not Button btn) return;
            if (_activeNavButton != null)
                _activeNavButton.Style = (Style)FindResource("NavButtonStyle");
            _activeNavButton = btn;
            btn.Style = (Style)FindResource("NavButtonActiveStyle");
            string tag = btn.Tag?.ToString() ?? "Dashboard";
            _viewModel?.NavigateTo(tag);
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
