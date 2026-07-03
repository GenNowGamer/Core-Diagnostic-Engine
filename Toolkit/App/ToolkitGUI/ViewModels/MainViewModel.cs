using System;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Media;
using ToolkitGUI.Services;
using ToolkitGUI.Views;

namespace ToolkitGUI.ViewModels
{
    public class MainViewModel : INotifyPropertyChanged, IDisposable
    {
        private object? _currentView;
        private string _machineName = "Loading...";
        private string _osVersion = "Loading...";
        private double _cpuUsage;
        private double _ramUsage;
        private string _smartSummary = "Checking...";
        private string _environmentMode = "Windows Mode";
        private string _uptime = "--";
        private Brush _smartStatusBrush = Brushes.Gray;
        private bool _hasActiveWorkOrder;
        private string _activeCaseId = string.Empty;
        private string _activeWorkOrderDetail = string.Empty;

        private Timer? _refreshTimer;
        private bool _disposed;
        private SystemHealthView? _systemHealthView;
        private ProcessAnalyzerView? _processAnalyzerView;
        private HijackRepairView? _hijackRepairView;

        public object? CurrentView
        {
            get => _currentView;
            set { _currentView = value; OnPropertyChanged(); }
        }

        public string MachineName
        {
            get => _machineName;
            set { _machineName = value; OnPropertyChanged(); }
        }

        public string OsVersion
        {
            get => _osVersion;
            set { _osVersion = value; OnPropertyChanged(); }
        }

        public double CpuUsage
        {
            get => _cpuUsage;
            set { _cpuUsage = value; OnPropertyChanged(); }
        }

        public double RamUsage
        {
            get => _ramUsage;
            set { _ramUsage = value; OnPropertyChanged(); }
        }

        public string SmartSummary
        {
            get => _smartSummary;
            set { _smartSummary = value; OnPropertyChanged(); }
        }

        public string EnvironmentMode
        {
            get => _environmentMode;
            set { _environmentMode = value; OnPropertyChanged(); }
        }

        public string Uptime
        {
            get => _uptime;
            set { _uptime = value; OnPropertyChanged(); }
        }

        public Brush SmartStatusBrush
        {
            get => _smartStatusBrush;
            set { _smartStatusBrush = value; OnPropertyChanged(); }
        }

        public bool HasActiveWorkOrder
        {
            get => _hasActiveWorkOrder;
            set { _hasActiveWorkOrder = value; OnPropertyChanged(); }
        }

        public string ActiveCaseId
        {
            get => _activeCaseId;
            set { _activeCaseId = value; OnPropertyChanged(); }
        }

        public string ActiveWorkOrderDetail
        {
            get => _activeWorkOrderDetail;
            set { _activeWorkOrderDetail = value; OnPropertyChanged(); }
        }

        public MainViewModel()
        {
            CurrentView = new DashboardView();
            WorkOrderService.ActiveWorkOrderChanged += OnActiveWorkOrderChanged;
            RefreshActiveWorkOrder();
        }

        public async Task InitializeAsync()
        {
            RefreshActiveWorkOrder();
            await RefreshSystemInfoAsync();
            _refreshTimer?.Dispose();
            _refreshTimer = new Timer(_ =>
            {
                if (_disposed) return;
                _ = RefreshSystemInfoAsync();
            }, null,
                TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(5));
        }

        private async Task RefreshSystemInfoAsync()
        {
            if (_disposed) return;

            try
            {
                var info = await PowerShellService.GetSystemInfoAsync();
                App.Current.Dispatcher.Invoke(() =>
                {
                    MachineName = info.MachineName;
                    OsVersion = info.OsVersion;
                    CpuUsage = info.CpuUsage;
                    RamUsage = info.RamUsage;
                    SmartSummary = info.SmartSummary;
                    EnvironmentMode = info.EnvironmentMode;
                    Uptime = info.Uptime;

                    SmartStatusBrush = info.SmartSummary switch
                    {
                        "Healthy" => new SolidColorBrush(Color.FromRgb(0x3F, 0xB9, 0x50)),
                        "Warning" => new SolidColorBrush(Color.FromRgb(0xD2, 0x99, 0x22)),
                        "Critical" => new SolidColorBrush(Color.FromRgb(0xF8, 0x51, 0x49)),
                        _ => Brushes.Gray
                    };
                });
            }
            catch (Exception ex)
            {
                App.Current.Dispatcher.Invoke(() =>
                {
                    MachineName = Environment.MachineName;
                    OsVersion = Environment.OSVersion.VersionString;
                    SmartSummary = $"Unavailable ({ex.Message})";
                    SmartStatusBrush = Brushes.Gray;
                });
            }
        }

        public void RefreshActiveWorkOrder()
        {
            var active = WorkOrderService.GetActiveWorkOrder();
            HasActiveWorkOrder = active != null;
            ActiveCaseId = active?.CaseId ?? string.Empty;
            ActiveWorkOrderDetail = active == null
                ? string.Empty
                : $"{active.RunCount} run{(active.RunCount == 1 ? string.Empty : "s")} recorded";
        }

        private void OnActiveWorkOrderChanged()
        {
            if (_disposed)
                return;

            App.Current?.Dispatcher.Invoke(RefreshActiveWorkOrder);
        }

        public void NavigateTo(string section)
        {
            CurrentView = section switch
            {
                "Dashboard" => new DashboardView(),
                "SystemHealth" => _systemHealthView ??= new SystemHealthView(),
                "SystemAudit" => _systemHealthView ??= new SystemHealthView(),
                "ChuResults"       => new ChuResultsView(),
                "SmartAnalyzer"    => new SmartAnalyzerView(),
                "DiagAndRepair" => new DiagAndRepairView(),
                "HardwareDiagnostics" => new DiagAndRepairView(),
                "OSRepair" => new OSRepairView(),
                "MalwareCleanup" => new MalwareCleanupView(),
                "BootloaderRepair" => new BootloaderRepairView(),
                "BackupAndImaging" => new BackupAndImagingView(),
                "PostOp" => new PostOpView(),
                "HijackRepair" => _hijackRepairView ??= new HijackRepairView(),
                "ToolsLibrary" => new ToolsLibraryView(),
                "FileManager" => new FileManagerView(),
                "StartupManager" => new StartupManagerView(),
                "ProcessAnalyzer" => _processAnalyzerView ??= new ProcessAnalyzerView(),
                "TempFileCleaner" => new TempFileCleanerView(),
                "UninstallManager" => new UninstallManagerView(),
                "FastFixes" => new FastFixesView(),
                "Settings" => new SettingsView(),
                _ => new DashboardView()
            };
        }

        public event PropertyChangedEventHandler? PropertyChanged;
        protected void OnPropertyChanged([CallerMemberName] string? name = null)
            => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;

            _refreshTimer?.Dispose();
            _refreshTimer = null;
            WorkOrderService.ActiveWorkOrderChanged -= OnActiveWorkOrderChanged;
        }
    }
}
