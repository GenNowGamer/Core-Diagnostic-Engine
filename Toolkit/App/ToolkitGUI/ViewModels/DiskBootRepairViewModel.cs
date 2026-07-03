using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;
using ToolkitGUI.Models;
using ToolkitGUI.Services;

namespace ToolkitGUI.ViewModels
{
    public sealed class DiskBootRepairViewModel : WorkflowViewModelBase
    {
        private readonly AsyncRelayCommand _refreshCommand;
        private readonly AsyncRelayCommand<string> _runRepairCommand;
        private readonly AsyncRelayCommand<string> _runGlobalCommand;
        private readonly AsyncRelayCommand<string> _runBackupCommand;
        private readonly AsyncRelayCommand _runRestoreCommand;
        private bool _isWinPe;
        private bool _isLoadingLayout;
        private string _layoutStatus = "Click Refresh to scan disks.";
        private CdeDiskLayoutDocument? _layout;
        private CdePhysicalDiskModel? _selectedDisk;
        private CdePartitionModel? _selectedPartition;
        private CdeWindowsInstallModel? _selectedInstall;
        private CdeEfiVolumeModel? _selectedEfiVolume;
        private string _detailText = "Select a partition on the disk map.";
        private string _actionSummary = string.Empty;

        public DiskBootRepairViewModel()
        {
            _isWinPe = IsWinPeMode();
            Disks = new ObservableCollection<CdePhysicalDiskModel>();
            EfiBackupFiles = new ObservableCollection<BcdBackupFileItem>();
            BiosBackupFiles = new ObservableCollection<BcdBackupFileItem>();

            _refreshCommand = new AsyncRelayCommand(RefreshLayoutAsync, () => !IsRunning && !_isLoadingLayout && _isWinPe);
            RefreshCommand = _refreshCommand;

            _runRepairCommand = new AsyncRelayCommand<string>(RunRepairScriptAsync, () => CanRunTargetedRepair());
            RunRepairCommand = _runRepairCommand;

            _runGlobalCommand = new AsyncRelayCommand<string>(RunGlobalScriptAsync, () => _isWinPe && !IsRunning);
            RunGlobalCommand = _runGlobalCommand;

            _runBackupCommand = new AsyncRelayCommand<string>(RunBackupAsync, () => CanRunBackup());
            RunBackupCommand = _runBackupCommand;

            _runRestoreCommand = new AsyncRelayCommand(RunRestoreBcdAsync, () => CanRunRestore());
            RunRestoreBcdCommand = _runRestoreCommand;
        }

        public ObservableCollection<CdePhysicalDiskModel> Disks { get; }
        public ObservableCollection<BcdBackupFileItem> EfiBackupFiles { get; }
        public ObservableCollection<BcdBackupFileItem> BiosBackupFiles { get; }

        public bool IsWinPeAvailable => _isWinPe;
        public bool ShowWinPeGateMessage => !_isWinPe;
        public string WinPeGateMessage => "Disk & Boot Repair is available in WinPE only.";

        public string LayoutStatus
        {
            get => _layoutStatus;
            private set { _layoutStatus = value; OnPropertyChanged(); }
        }

        public CdePartitionModel? SelectedPartition
        {
            get => _selectedPartition;
            set
            {
                _selectedPartition = value;
                OnPropertyChanged();
                UpdateSelectionContext();
            }
        }

        public string DetailText
        {
            get => _detailText;
            private set { _detailText = value; OnPropertyChanged(); }
        }

        public string ActionSummary
        {
            get => _actionSummary;
            private set
            {
                _actionSummary = value;
                OnPropertyChanged();
                HasActionSummary = !string.IsNullOrWhiteSpace(value);
            }
        }

        public bool HasActionSummary
        {
            get => _hasActionSummary;
            private set { _hasActionSummary = value; OnPropertyChanged(); }
        }

        private bool _hasActionSummary;

        public bool CanFixMbr => _isWinPe && _selectedInstall != null &&
            string.Equals(_selectedDisk?.PartitionStyle, "MBR", StringComparison.OrdinalIgnoreCase);

        public ICommand RefreshCommand { get; }
        public ICommand RunRepairCommand { get; }
        public ICommand RunGlobalCommand { get; }
        public ICommand RunBackupCommand { get; }
        public ICommand RunRestoreBcdCommand { get; }

        protected override bool ShowWorkflowExecutionWindow => false;

        public void NotifyBackupSelectionChanged() => RaiseAllCommandStates();

        private static bool IsWinPeMode()
        {
            try
            {
                using var key = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\MiniNT");
                if (key != null) return true;
            }
            catch { }

            var systemRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? string.Empty;
            return systemRoot.StartsWith(@"X:\", StringComparison.OrdinalIgnoreCase);
        }

        private async Task RefreshLayoutAsync()
        {
            if (!_isWinPe || _isLoadingLayout) return;

            _isLoadingLayout = true;
            _refreshCommand.RaiseCanExecuteChanged();
            LayoutStatus = "Scanning disks...";
            try
            {
                _layout = await DiskLayoutService.LoadLayoutAsync();
                Disks.Clear();
                if (_layout?.Disks != null)
                {
                    foreach (var disk in _layout.Disks.OrderBy(d => d.DiskNumber))
                        Disks.Add(disk);
                }

                LayoutStatus = Disks.Count == 0
                    ? "No disks found."
                    : $"{Disks.Count} disk(s), {_layout?.WindowsInstalls?.Count ?? 0} Windows install(s)";

                AutoSelectWindowsPartition();
                RefreshBackupInventory();
                RaiseAllCommandStates();
            }
            catch (Exception ex)
            {
                LayoutStatus = "Scan failed.";
                AppendLog($"Disk layout error: {ex.Message}");
            }
            finally
            {
                _isLoadingLayout = false;
                RaiseAllCommandStates();
            }
        }

        private void AutoSelectWindowsPartition()
        {
            CdePartitionModel? pick = null;
            foreach (var disk in Disks)
            {
                pick = disk.Partitions.FirstOrDefault(p => p.HasWindows);
                if (pick != null)
                    break;
            }

            if (pick == null && _layout?.WindowsInstalls is { Count: > 0 })
            {
                var install = _layout.WindowsInstalls[0];
                foreach (var disk in Disks)
                {
                    pick = disk.Partitions.FirstOrDefault(p =>
                        string.Equals(p.DriveRoot, install.DriveRoot, StringComparison.OrdinalIgnoreCase));
                    if (pick != null)
                        break;
                }
            }

            SelectedPartition = pick;
        }

        private void UpdateSelectionContext()
        {
            _selectedDisk = null;
            _selectedInstall = null;
            _selectedEfiVolume = null;

            if (_selectedPartition == null || _layout == null)
            {
                DetailText = "Select a partition on the disk map.";
                RaiseAllCommandStates();
                return;
            }

            _selectedDisk = Disks.FirstOrDefault(d =>
                d.Partitions.Any(p =>
                    ReferenceEquals(p, _selectedPartition) ||
                    (p.PartitionNumber == _selectedPartition.PartitionNumber &&
                     string.Equals(p.DriveRoot, _selectedPartition.DriveRoot, StringComparison.OrdinalIgnoreCase))));

            if (!string.IsNullOrWhiteSpace(_selectedPartition.DriveRoot))
            {
                _selectedInstall = _layout.WindowsInstalls
                    .FirstOrDefault(i => string.Equals(i.DriveRoot, _selectedPartition.DriveRoot, StringComparison.OrdinalIgnoreCase));
            }

            if (_selectedInstall == null && _selectedPartition.HasWindows)
            {
                _selectedInstall = new CdeWindowsInstallModel
                {
                    DriveRoot = _selectedPartition.DriveRoot,
                    WindowsDir = _selectedPartition.WindowsDir,
                    EfiBcdPath = _selectedPartition.EfiBcdPath,
                    BiosBcdPath = _selectedPartition.BiosBcdPath,
                    Score = _selectedPartition.BootScore
                };
            }

            if (_selectedDisk != null)
            {
                _selectedEfiVolume = _layout.EfiVolumes.FirstOrDefault(v =>
                    string.Equals(v.DriveRoot, _selectedInstall?.DriveRoot, StringComparison.OrdinalIgnoreCase));

                if (_selectedEfiVolume == null && _selectedPartition.IsSystem)
                {
                    _selectedEfiVolume = _layout.EfiVolumes.FirstOrDefault(v =>
                        string.Equals(v.DriveRoot, _selectedPartition.DriveRoot, StringComparison.OrdinalIgnoreCase));
                }
            }

            var lines = new List<string>();
            if (_selectedDisk != null)
            {
                lines.Add($"Disk {_selectedDisk.DiskNumber}: {_selectedDisk.FriendlyName}");
                lines.Add($"Style: {_selectedDisk.PartitionStyle}  Size: {CdePartitionModel.FormatSize(_selectedDisk.Size)}");
            }

            lines.Add(_selectedPartition.DisplayLabel);
            if (_selectedPartition.IsSystem) lines.Add("Flag: System");
            if (_selectedPartition.IsBoot) lines.Add("Flag: Boot");
            if (_selectedPartition.HasWindows)
            {
                lines.Add($"Windows: {_selectedPartition.WindowsDir}");
                if (_selectedInstall != null &&
                    !string.IsNullOrWhiteSpace(_selectedInstall.EfiDriveRoot) &&
                    !string.Equals(_selectedInstall.EfiDriveRoot, _selectedInstall.DriveRoot, StringComparison.OrdinalIgnoreCase))
                {
                    lines.Add($"EFI volume: {_selectedInstall.EfiDriveRoot}");
                }

                lines.Add($"EFI BCD: {_selectedPartition.EfiBcdPath}");
                lines.Add($"BIOS BCD: {_selectedPartition.BiosBcdPath}");
            }

            DetailText = string.Join(Environment.NewLine, lines);
            RefreshBackupInventory();
            RaiseAllCommandStates();
        }

        private void RaiseAllCommandStates()
        {
            OnPropertyChanged(nameof(CanFixMbr));
            _refreshCommand.RaiseCanExecuteChanged();
            _runRepairCommand.RaiseCanExecuteChanged();
            _runGlobalCommand.RaiseCanExecuteChanged();
            _runBackupCommand.RaiseCanExecuteChanged();
            _runRestoreCommand.RaiseCanExecuteChanged();
        }

        private void RefreshBackupInventory()
        {
            EfiBackupFiles.Clear();
            BiosBackupFiles.Clear();

            var root = _selectedInstall?.DriveRoot;
            if (string.IsNullOrWhiteSpace(root)) return;

            var backupRoot = GetBackupRoot(root);
            if (!Directory.Exists(backupRoot)) return;

            foreach (var file in Directory.GetFiles(backupRoot, "EFI_BCDExport_*.bcd").Concat(Directory.GetFiles(backupRoot, "EFI_BCD_*.bcd")).Distinct().OrderByDescending(File.GetLastWriteTime))
            {
                EfiBackupFiles.Add(new BcdBackupFileItem
                {
                    FullPath = file,
                    FileName = Path.GetFileName(file),
                    Kind = "EFI",
                    DisplayTime = File.GetLastWriteTime(file).ToString("g")
                });
            }

            foreach (var file in Directory.GetFiles(backupRoot, "BIOS_BCDExport_*.bcd").Concat(Directory.GetFiles(backupRoot, "BIOS_BCD_*.bcd")).Distinct().OrderByDescending(File.GetLastWriteTime))
            {
                BiosBackupFiles.Add(new BcdBackupFileItem
                {
                    FullPath = file,
                    FileName = Path.GetFileName(file),
                    Kind = "BIOS",
                    DisplayTime = File.GetLastWriteTime(file).ToString("g")
                });
            }
        }

        private bool CanRunTargetedRepair() => _isWinPe && !IsRunning && _selectedInstall != null;

        private bool CanRunBackup() => _isWinPe && !IsRunning && (_selectedInstall != null || _selectedDisk != null);

        private bool CanRunRestore() => _isWinPe && !IsRunning && _selectedInstall != null &&
            (EfiBackupFiles.Any(f => f.IsSelected) || BiosBackupFiles.Any(f => f.IsSelected));

        private static string QuotePath(string path) => $"\"{path.Replace("\"", "`\"")}\"";

        private static string GetBackupRoot(string driveRoot)
        {
            var root = driveRoot.Trim().TrimEnd('\\');
            if (!root.EndsWith(":", StringComparison.Ordinal))
                root += ":";
            return $"{root}\\CDE_Bootloader_Backups";
        }

        private async Task RunRepairScriptAsync(string? scriptName)
        {
            if (string.IsNullOrWhiteSpace(scriptName) || _selectedInstall == null) return;

            if (!DestructiveActionDialog.Confirm(
                    "Disk & Boot Repair",
                    $"Run {scriptName} on {_selectedInstall.DriveRoot}?",
                    "This modifies boot configuration, partition tables, or boot records. Ensure backups exist.",
                    defaultNo: true))
            {
                AppendLog("Repair cancelled by operator.");
                return;
            }

            if (scriptName.Equals("BootloaderFixMbr.ps1", StringComparison.OrdinalIgnoreCase) && !CanFixMbr)
            {
                AppendLog("Fix MBR is only offered for MBR-style disks.");
                return;
            }

            var parameters = $"-TargetDrive {QuotePath(_selectedInstall.DriveRoot)} -Confirmed";

            if (scriptName.Equals("BootloaderRebuildEfi.ps1", StringComparison.OrdinalIgnoreCase))
            {
                var efiDrive = _selectedInstall.DriveRoot;
                if (!File.Exists(_selectedInstall.EfiBcdPath) && _selectedEfiVolume != null)
                    efiDrive = _selectedEfiVolume.DriveRoot;
                else if (!File.Exists(_selectedInstall.EfiBcdPath))
                {
                    var pick = PickEfiVolume();
                    if (pick == null) return;
                    efiDrive = pick.DriveRoot;
                }

                parameters += $" -EfiTargetDrive {QuotePath(efiDrive)}";
            }

            await ExecuteWorkflowAsync(scriptName, parameters, scriptName);
        }

        private async Task RunGlobalScriptAsync(string? scriptName)
        {
            if (string.IsNullOrWhiteSpace(scriptName)) return;

            if (!DestructiveActionDialog.Confirm(
                    "Disk & Boot Repair",
                    $"Run {scriptName}?",
                    "This may modify boot configuration on the selected installation.",
                    defaultNo: true))
            {
                AppendLog("Operation cancelled by operator.");
                return;
            }

            var parameters = string.Empty;
            if (_selectedInstall != null)
                parameters = $"-TargetDrive {QuotePath(_selectedInstall.DriveRoot)} -Confirmed";
            await ExecuteWorkflowAsync(scriptName, parameters, scriptName);
        }

        private async Task RunBackupAsync(string? kind)
        {
            if (string.IsNullOrWhiteSpace(kind)) return;

            switch (kind.ToLowerInvariant())
            {
                case "bcd":
                    if (_selectedInstall == null) return;
                    await ExecuteWorkflowAsync("BootloaderBcdBackup.ps1",
                        $"-TargetDrive {QuotePath(_selectedInstall.DriveRoot)} -Confirmed", "Backup BCD");
                    break;
                case "partition":
                    if (_selectedDisk == null) return;
                    var backupRoot = _selectedInstall != null
                        ? GetBackupRoot(_selectedInstall.DriveRoot)
                        : string.Empty;
                    var p = $"-DiskNumber {_selectedDisk.DiskNumber} -Confirmed";
                    if (!string.IsNullOrWhiteSpace(backupRoot))
                        p += $" -BackupRoot {QuotePath(backupRoot)}";
                    else if (_selectedInstall != null)
                        p += $" -TargetDrive {QuotePath(_selectedInstall.DriveRoot)}";
                    await ExecuteWorkflowAsync("PartitionTableBackup.ps1", p, "Backup partition table");
                    break;
                case "all":
                    if (_selectedInstall == null || _selectedDisk == null) return;
                    await ExecuteWorkflowAsync("BootArtifactsBackup.ps1",
                        $"-TargetDrive {QuotePath(_selectedInstall.DriveRoot)} -DiskNumber {_selectedDisk.DiskNumber} -Confirmed",
                        "Backup all boot artifacts");
                    break;
            }
        }

        private async Task RunRestoreBcdAsync()
        {
            if (_selectedInstall == null) return;

            var efi = EfiBackupFiles.FirstOrDefault(f => f.IsSelected);
            var bios = BiosBackupFiles.FirstOrDefault(f => f.IsSelected);
            if (efi == null && bios == null) return;

            var result = MessageBox.Show(
                "Restore replaces the target BCD store file after saving a safety snapshot.\n\nProceed?",
                "Restore BCD",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);
            if (result != MessageBoxResult.Yes) return;

            var parameters = $"-TargetDrive {QuotePath(_selectedInstall.DriveRoot)} -Confirmed";
            if (efi != null) parameters += $" -EfiBackupPath {QuotePath(efi.FullPath)}";
            if (bios != null) parameters += $" -BiosBackupPath {QuotePath(bios.FullPath)}";

            await ExecuteWorkflowAsync("BootloaderBcdRestore.ps1", parameters, "Restore BCD");
        }

        private CdeEfiVolumeModel? PickEfiVolume()
        {
            if (_layout?.EfiVolumes == null || _layout.EfiVolumes.Count == 0)
            {
                AppendLog("No EFI system volume found.");
                return null;
            }

            if (_layout.EfiVolumes.Count == 1)
                return _layout.EfiVolumes[0];

            AppendLog("Multiple EFI volumes detected; using the first entry. Re-run with a mapped install that includes EFI BCD on the Windows volume.");
            return _layout.EfiVolumes[0];
        }

        private async Task ExecuteWorkflowAsync(string scriptName, string parameters, string title)
        {
            if (IsRunning) return;
            try
            {
                var scriptPath = GetScriptPath(scriptName);
                await RunWorkflowAsync(scriptPath, parameters, title, title);
                PostProcessWorkflowOutput(scriptName);
            }
            catch (Exception ex)
            {
                AppendLog($"Error: {ex.Message}");
            }
            finally
            {
                if (IsBackupRelatedWorkflow(scriptName))
                    RefreshBackupInventory();
                RaiseAllCommandStates();
            }
        }

        private static bool IsBackupRelatedWorkflow(string scriptName) =>
            scriptName.Contains("Backup", StringComparison.OrdinalIgnoreCase) ||
            scriptName.Contains("BcdRestore", StringComparison.OrdinalIgnoreCase);

        private void SetActionSummaryFromSteps(string header)
        {
            if (ResultSteps.Count == 0)
            {
                ActionSummary = header;
                return;
            }

            var lines = ResultSteps
                .Select(s =>
                {
                    var output = string.IsNullOrWhiteSpace(s.Output) ? string.Empty : s.Output.Trim();
                    if (output.Length > 120)
                        output = output[..117] + "...";
                    return string.IsNullOrWhiteSpace(output)
                        ? $"{s.Name}: {s.Status}"
                        : $"{s.Name}: {s.Status} — {output}";
                })
                .ToList();

            ActionSummary = $"{header}{Environment.NewLine}{string.Join(Environment.NewLine, lines)}";
        }

        private void PostProcessWorkflowOutput(string scriptName)
        {
            if (scriptName.Equals("BootloaderScanOs.ps1", StringComparison.OrdinalIgnoreCase))
            {
                var scanOutput = ResultSteps
                    .FirstOrDefault(s => s.Name.Contains("Scan", StringComparison.OrdinalIgnoreCase))?.Output;
                if (!string.IsNullOrWhiteSpace(scanOutput))
                {
                    ActionSummary = scanOutput.Trim();
                    return;
                }

                var summaryLines = new List<string>();
                foreach (var line in LogLines)
                {
                    var trimmed = line.Trim();
                    if (trimmed.Contains("Scanning all drives", StringComparison.OrdinalIgnoreCase) ||
                        trimmed.StartsWith('[') ||
                        trimmed.StartsWith("Total identified", StringComparison.OrdinalIgnoreCase) ||
                        trimmed.StartsWith("EFI system volumes", StringComparison.OrdinalIgnoreCase) ||
                        trimmed.StartsWith("Total EFI", StringComparison.OrdinalIgnoreCase) ||
                        (trimmed.StartsWith("  ", StringComparison.Ordinal) && trimmed.Contains("EFI", StringComparison.OrdinalIgnoreCase)))
                    {
                        summaryLines.Add(trimmed);
                    }
                }

                ActionSummary = summaryLines.Count > 0
                    ? string.Join(Environment.NewLine, summaryLines)
                    : "Scan completed. See log for details.";
                return;
            }

            if (scriptName.Equals("BootloaderCheckIntegrity.ps1", StringComparison.OrdinalIgnoreCase))
            {
                SetActionSummaryFromSteps("Integrity check results:");
                return;
            }

            if (scriptName.Equals("BootloaderBcdBackup.ps1", StringComparison.OrdinalIgnoreCase) ||
                scriptName.Equals("BootArtifactsBackup.ps1", StringComparison.OrdinalIgnoreCase) ||
                scriptName.Equals("PartitionTableBackup.ps1", StringComparison.OrdinalIgnoreCase))
            {
                var hasWarnings = ResultSteps.Any(s =>
                    s.Status.Equals("Warn", StringComparison.OrdinalIgnoreCase));
                SetActionSummaryFromSteps(HasResultErrors
                    ? "Backup completed with errors:"
                    : hasWarnings
                        ? "Backup completed with warnings:"
                        : "Backup completed:");
                return;
            }

            var actionHasWarnings = ResultSteps.Any(s =>
                s.Status.Equals("Warn", StringComparison.OrdinalIgnoreCase));
            ActionSummary = HasResultErrors
                ? "Last action completed with errors — see log."
                : actionHasWarnings
                    ? "Last action completed with warnings — see log."
                    : "Last action completed successfully.";
        }

        private sealed class AsyncRelayCommand : ICommand
        {
            private readonly Func<bool>? _canExecute;
            private readonly Func<Task>? _asyncAction;

            public AsyncRelayCommand(Func<Task> execute, Func<bool>? canExecute = null)
            {
                _asyncAction = execute;
                _canExecute = canExecute;
            }

            public event EventHandler? CanExecuteChanged;

            public bool CanExecute(object? parameter) => _canExecute?.Invoke() ?? true;

            public async void Execute(object? parameter)
            {
                if (_asyncAction != null)
                    await _asyncAction();
            }

            public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
        }

        private sealed class AsyncRelayCommand<T> : ICommand
        {
            private readonly Func<T?, Task> _execute;
            private readonly Func<bool>? _canExecute;

            public AsyncRelayCommand(Func<T?, Task> execute, Func<bool>? canExecute = null)
            {
                _execute = execute;
                _canExecute = canExecute;
            }

            public event EventHandler? CanExecuteChanged;

            public bool CanExecute(object? parameter) => _canExecute?.Invoke() ?? true;

            public async void Execute(object? parameter)
            {
                T? typed = parameter is T t ? t : default;
                await _execute(typed);
            }

            public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
        }
    }
}
