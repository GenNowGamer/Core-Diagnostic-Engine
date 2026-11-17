using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using CdeRecovery.Core.Evidence;
using CdeRecovery.Core.Imaging;
using CdeRecovery.Core.Models;
using Microsoft.Win32;
using ToolkitGUI.Models;
using ToolkitGUI.Services;
using WinForms = System.Windows.Forms;

namespace ToolkitGUI.ViewModels
{
    public sealed class StorageRecoveryViewModel : INotifyPropertyChanged
    {
        private StorageTargetChoice? _selectedTarget;
        private StorageRecoveryAssessment? _currentAssessment;
        private VerifiedRepairPlan? _selectedRepairPlan;
        private MetadataSnapshotManifest? _lastSnapshot;
        private bool _isBusy;
        private int _selectedTabIndex;
        private string _statusText = "Select a physical drive or disk image, then click Inspect Disk (Read-Only).";
        private string _hardwareBadge = "Not Scanned";
        private string _partitionBadge = "Not Scanned";
        private string _fileSystemBadge = "Not Scanned";
        private string _overallVerdict = "Ready";
        private string _executiveSummary = "Read-only protection active: Diagnostic operations never open writable handles to the source drive.";
        private string _snapshotDirectory;
        private string _lastSnapshotSummary = "No metadata snapshot captured in this session yet.";
        private string _inPlaceConfirmPhrase = string.Empty;
        private string _selectedFixturePreset = "10 TB Sparse — Damaged Primary GPT (Backup GPT Intact)";
        private string _reportJsonPath = string.Empty;
        private string _reportPdfPath = string.Empty;
        private readonly List<string> _auditEntries = new();
        private string _auditLogText = string.Empty;

        // Release 4: Resumable Imaging & File Recovery fields
        private string _imagingOutputPath;
        private bool _scrapeFailedBlocks = true;
        private bool _isImagingRunning;
        private double _imagingProgressPercent;
        private string _imagingStatusSummary = "Ready to create or resume a raw disk/partition backup image (.img + .cdemap).";
        private System.Threading.CancellationTokenSource? _imagingCts;
        private System.Threading.CancellationTokenSource? _fileScanCts;
        private System.Threading.CancellationTokenSource? _inspectCts;
        private System.Threading.CancellationTokenSource? _fileExportCts;
        private ImagingScopeOption? _selectedImagingScope;

        private FileSystemAnalysisResult? _selectedRecoveryPartition;
        private bool _includeDeletedFiles = true;
        private bool _fullMftScan;
        private string _fileSearchFilter = string.Empty;
        private bool _hasBitLockerPartition;
        private int _bitLockerPartitionIndex = 1;
        private string _bitLockerDriveLetter = string.Empty;
        private string _bitLockerKeyProtectorId = string.Empty;
        private string _bitLockerRecoveryKey = string.Empty;
        private string _bitLockerStatusMessage = string.Empty;
        private string _fileExportDestination;
        private string _fileRecoveryStatusText = "Select an NTFS partition and click 'Scan $MFT for Recoverable Files'.";
        private readonly List<RecoverableFileRowViewModel> _allRecoverableFiles = new();

        public ObservableCollection<StorageTargetChoice> Targets { get; } = new();
        public ObservableCollection<StorageWorkflowStageItem> WorkflowStages { get; } = new();
        public ObservableCollection<StorageFindingRowViewModel> Findings { get; } = new();
        public ObservableCollection<CdePhysicalDiskModel> RawDiskMapCollection { get; } = new();
        public ObservableCollection<DiscoveredPartitionCandidate> DiscoveredPartitions { get; } = new();
        public ObservableCollection<FileSystemAnalysisResult> FileSystems { get; } = new();
        public ObservableCollection<MetadataSnapshotRegion> CapturedSnapshotRegions { get; } = new();
        public ObservableCollection<VerifiedRepairPlan> ProposedRepairs { get; } = new();
        public ObservableCollection<RepairBytePatch> SelectedPlanPatches { get; } = new();
        public ObservableCollection<RecoverableFileRowViewModel> DisplayedRecoverableFiles { get; } = new();
        public ObservableCollection<ImagingScopeOption> ImagingScopes { get; } = new();
        public ObservableCollection<string> FixturePresets { get; } = new()
        {
            "10 TB Sparse — Damaged Primary GPT (Backup GPT Intact)",
            "10 TB Sparse — Damaged NTFS Boot Sector (Backup VBR Intact)",
            "10 TB Sparse — Wiped Partition Table (Lost NTFS Partition)",
            "10 TB Sparse — Severely Damaged $MFT (Recommend File Extraction)",
            "64 MB — Malformed MBR Signature (BenchLab S20)",
            "64 MB — Protective MBR Mismatch (BenchLab S21)",
            "64 MB — BitLocker Encrypted Volume (-FVE-FS-)",
            "10 TB Sparse — Healthy GPT + NTFS Baseline"
        };

        public RelayCommand RefreshDisksCommand { get; }
        public RelayCommand OpenImageFileCommand { get; }
        public RelayCommand CreateTestFixtureCommand { get; }
        public RelayCommand InspectTargetCommand { get; }
        public RelayCommand CancelInspectCommand { get; }
        public RelayCommand CaptureSnapshotCommand { get; }
        public RelayCommand BrowseSnapshotDirCommand { get; }
        public RelayCommand VerifyExistingSnapshotCommand { get; }
        public RelayCommand ApplyRepairToImageCommand { get; }
        public RelayCommand ApplyRepairInPlacePhysicalCommand { get; }
        public RelayCommand ExportReportCommand { get; }
        public RelayCommand OpenPdfReportCommand { get; }
        public RelayCommand NavigateSmartAnalyzerCommand { get; }
        public RelayCommand NavigateBackupImagingCommand { get; }

        // Release 4 commands
        public RelayCommand BrowseImagingOutputCommand { get; }
        public RelayCommand StartOrResumeImagingCommand { get; }
        public RelayCommand StopImagingCommand { get; }
        public RelayCommand ScanRecoverableFilesCommand { get; }
        public RelayCommand CancelFileScanCommand { get; }
        public RelayCommand CancelFileExportCommand { get; }
        public RelayCommand SelectAllFilesCommand { get; }
        public RelayCommand ClearSelectedFilesCommand { get; }
        public RelayCommand BrowseExportDestCommand { get; }
        public RelayCommand ExportSelectedFilesCommand { get; }
        public RelayCommand UnlockBitLockerCommand { get; }
        public RelayCommand GoToBitLockerUnlockCommand { get; }

        public StorageRecoveryViewModel()
        {
            _snapshotDirectory = StorageRecoveryService.GetDefaultSnapshotRoot();
            _imagingOutputPath = Path.Combine(_snapshotDirectory, "DiskBackupImage.img");
            _fileExportDestination = Path.Combine(_snapshotDirectory, "RecoveredFiles");

            WorkflowStages.Add(new StorageWorkflowStageItem
            {
                StageNumber = 1,
                Title = "1. Inspect disk",
                Description = "Read-only structure and health analysis",
                State = "Active"
            });
            WorkflowStages.Add(new StorageWorkflowStageItem
            {
                StageNumber = 2,
                Title = "2. Preserve metadata",
                Description = "Create verified binary recovery snapshots",
                State = "Pending"
            });
            WorkflowStages.Add(new StorageWorkflowStageItem
            {
                StageNumber = 3,
                Title = "3. Review recovery options",
                Description = "Compare evidence and proposed actions",
                State = "Pending"
            });
            WorkflowStages.Add(new StorageWorkflowStageItem
            {
                StageNumber = 4,
                Title = "4. Recover or repair",
                Description = "Apply verified repair on image or authorized disk",
                State = "Pending"
            });
            WorkflowStages.Add(new StorageWorkflowStageItem
            {
                StageNumber = 5,
                Title = "5. Verify and report",
                Description = "Validate results and save case findings",
                State = "Pending"
            });

            RefreshDisksCommand = new RelayCommand(() => { RefreshPhysicalDisks(); return Task.CompletedTask; });
            OpenImageFileCommand = new RelayCommand(OpenImageFileAsync);
            CreateTestFixtureCommand = new RelayCommand(CreateTestFixtureAsync);
            InspectTargetCommand = new RelayCommand(InspectSelectedTargetAsync);
            CancelInspectCommand = new RelayCommand(() => { _inspectCts?.Cancel(); return Task.CompletedTask; });
            CaptureSnapshotCommand = new RelayCommand(CaptureMetadataSnapshotAsync);
            BrowseSnapshotDirCommand = new RelayCommand(BrowseSnapshotDirAsync);
            VerifyExistingSnapshotCommand = new RelayCommand(VerifyExistingSnapshotAsync);
            ApplyRepairToImageCommand = new RelayCommand(ApplyRepairToImageAsync);
            ApplyRepairInPlacePhysicalCommand = new RelayCommand(ApplyRepairInPlacePhysicalAsync);
            ExportReportCommand = new RelayCommand(ExportReportAsync);
            OpenPdfReportCommand = new RelayCommand(OpenPdfReportAsync);
            NavigateSmartAnalyzerCommand = new RelayCommand(() => { NavigationService.Request("SmartAnalyzer"); return Task.CompletedTask; });
            NavigateBackupImagingCommand = new RelayCommand(() => { NavigationService.Request("BackupAndImaging"); return Task.CompletedTask; });

            BrowseImagingOutputCommand = new RelayCommand(BrowseImagingOutputAsync);
            StartOrResumeImagingCommand = new RelayCommand(StartOrResumeImagingAsync);
            StopImagingCommand = new RelayCommand(StopImagingAsync);
            ScanRecoverableFilesCommand = new RelayCommand(ScanRecoverableFilesAsync);
            CancelFileScanCommand = new RelayCommand(() => { _fileScanCts?.Cancel(); return Task.CompletedTask; });
            SelectAllFilesCommand = new RelayCommand(() => { SetAllFileSelections(true); return Task.CompletedTask; });
            ClearSelectedFilesCommand = new RelayCommand(() => { SetAllFileSelections(false); return Task.CompletedTask; });
            BrowseExportDestCommand = new RelayCommand(BrowseExportDestAsync);
            ExportSelectedFilesCommand = new RelayCommand(ExportSelectedFilesAsync);
            CancelFileExportCommand = new RelayCommand(() => { _fileExportCts?.Cancel(); return Task.CompletedTask; });
            UnlockBitLockerCommand = new RelayCommand(UnlockBitLockerAsync);
            GoToBitLockerUnlockCommand = new RelayCommand(() => { SelectedTabIndex = 4; return Task.CompletedTask; });

            ImagingScopes.Add(new ImagingScopeOption { Label = "Whole Disk", StartOffset = 0, LengthBytes = 0, FileTag = "WholeDisk" });
            _selectedImagingScope = ImagingScopes[0];

            AppendAudit("Storage Recovery module initialized in read-only diagnostic mode.");
            RefreshPhysicalDisks();
        }

        public StorageTargetChoice? SelectedTarget
        {
            get => _selectedTarget;
            set
            {
                if (ReferenceEquals(_selectedTarget, value)) return;
                _selectedTarget = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(SelectedDeviceSummary));
                OnPropertyChanged(nameof(IsPhysicalTargetSelected));
                OnPropertyChanged(nameof(IsImageTargetSelected));
                OnPropertyChanged(nameof(RequiredConfirmationPhraseHint));
            }
        }

        public string SelectedDeviceSummary => _selectedTarget == null
            ? "No device selected"
            : $"{_selectedTarget.DisplayTitle}  |  {_selectedTarget.Subtitle}";

        public bool IsPhysicalTargetSelected => _selectedTarget != null && !_selectedTarget.IsDiskImage;
        public bool IsImageTargetSelected => _selectedTarget != null && _selectedTarget.IsDiskImage;

        public string RequiredConfirmationPhraseHint => _selectedTarget != null && !_selectedTarget.IsDiskImage
            ? $"Type 'REPAIR DISK {_selectedTarget.Device.DiskNumber}' to authorize in-place metadata write:"
            : "In-place physical disk authorization (only used when target is a physical disk):";

        public bool IsBusy
        {
            get => _isBusy;
            set
            {
                _isBusy = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(CanUnlockBitLocker));
            }
        }

        public int SelectedTabIndex
        {
            get => _selectedTabIndex;
            set { _selectedTabIndex = value; OnPropertyChanged(); }
        }

        public string StatusText
        {
            get => _statusText;
            set { _statusText = value; OnPropertyChanged(); }
        }

        public string HardwareBadge
        {
            get => _hardwareBadge;
            set { _hardwareBadge = value; OnPropertyChanged(); OnPropertyChanged(nameof(HardwareBadgeBrush)); }
        }

        public string PartitionBadge
        {
            get => _partitionBadge;
            set { _partitionBadge = value; OnPropertyChanged(); OnPropertyChanged(nameof(PartitionBadgeBrush)); }
        }

        public string FileSystemBadge
        {
            get => _fileSystemBadge;
            set { _fileSystemBadge = value; OnPropertyChanged(); OnPropertyChanged(nameof(FileSystemBadgeBrush)); }
        }

        public string OverallVerdict
        {
            get => _overallVerdict;
            set { _overallVerdict = value; OnPropertyChanged(); OnPropertyChanged(nameof(OverallVerdictBrush)); }
        }

        public Brush HardwareBadgeBrush => PickBadgeBrush(HardwareBadge);
        public Brush PartitionBadgeBrush => PickBadgeBrush(PartitionBadge);
        public Brush FileSystemBadgeBrush => PickBadgeBrush(FileSystemBadge);
        public Brush OverallVerdictBrush => PickBadgeBrush(OverallVerdict);

        public string ExecutiveSummary
        {
            get => _executiveSummary;
            set { _executiveSummary = value; OnPropertyChanged(); }
        }

        public string SnapshotDirectory
        {
            get => _snapshotDirectory;
            set { _snapshotDirectory = value; OnPropertyChanged(); }
        }

        public string LastSnapshotSummary
        {
            get => _lastSnapshotSummary;
            set { _lastSnapshotSummary = value; OnPropertyChanged(); }
        }

        public string InPlaceConfirmPhrase
        {
            get => _inPlaceConfirmPhrase;
            set { _inPlaceConfirmPhrase = value; OnPropertyChanged(); }
        }

        public bool HasBitLockerPartition
        {
            get => _hasBitLockerPartition;
            set
            {
                _hasBitLockerPartition = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(CanUnlockBitLocker));
            }
        }

        public string BitLockerDriveLetter
        {
            get => _bitLockerDriveLetter;
            set
            {
                _bitLockerDriveLetter = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(BitLockerDriveDisplay));
            }
        }

        public string BitLockerDriveDisplay =>
            string.IsNullOrWhiteSpace(_bitLockerDriveLetter) ? "(Not assigned yet)" : $"{_bitLockerDriveLetter}:";

        public string BitLockerKeyProtectorId
        {
            get => _bitLockerKeyProtectorId;
            set
            {
                _bitLockerKeyProtectorId = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(HasBitLockerKeyId));
            }
        }

        public bool HasBitLockerKeyId => !string.IsNullOrWhiteSpace(_bitLockerKeyProtectorId);

        public string BitLockerRecoveryKey
        {
            get => _bitLockerRecoveryKey;
            set { _bitLockerRecoveryKey = value; OnPropertyChanged(); }
        }

        public string BitLockerStatusMessage
        {
            get => _bitLockerStatusMessage;
            set { _bitLockerStatusMessage = value; OnPropertyChanged(); }
        }

        public bool CanUnlockBitLocker => _hasBitLockerPartition && IsPhysicalTargetSelected && !IsBusy;

        // Internal developer toggle to show/hide the BenchLab Test Fixture generator on the toolbar.
        // Set EnableTestFixtureToolbar = true (or env CDE_SHOW_STORAGE_FIXTURES=1) when needed.
        private const bool EnableTestFixtureToolbar = false;

        public bool ShowTestFixtureControls =>
            EnableTestFixtureToolbar ||
            string.Equals(Environment.GetEnvironmentVariable("CDE_SHOW_STORAGE_FIXTURES"), "1", StringComparison.OrdinalIgnoreCase);

        public string SelectedFixturePreset
        {
            get => _selectedFixturePreset;
            set { _selectedFixturePreset = value; OnPropertyChanged(); }
        }

        public VerifiedRepairPlan? SelectedRepairPlan
        {
            get => _selectedRepairPlan;
            set
            {
                if (ReferenceEquals(_selectedRepairPlan, value)) return;
                _selectedRepairPlan = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(HasSelectedRepairPlan));
                OnPropertyChanged(nameof(CanApplySelectedPlanToImage));
                OnPropertyChanged(nameof(CanApplySelectedPlanToPhysicalDisk));
                SelectedPlanPatches.Clear();
                if (_selectedRepairPlan != null)
                {
                    foreach (var p in _selectedRepairPlan.Patches)
                        SelectedPlanPatches.Add(p);
                }
            }
        }

        public bool HasSelectedRepairPlan => _selectedRepairPlan != null;
        public bool CanApplySelectedPlanToImage => _selectedRepairPlan?.IsExecutable == true && IsImageTargetSelected;
        public bool CanApplySelectedPlanToPhysicalDisk => _selectedRepairPlan?.IsExecutable == true && IsPhysicalTargetSelected;

        public string GptComparisonSummary
        {
            get
            {
                if (_currentAssessment == null) return "Run Inspect Disk to view MBR and Primary/Backup GPT structural comparison.";
                var m = _currentAssessment.Mbr;
                var g = _currentAssessment.Gpt;
                var sb = new StringBuilder();
                sb.AppendLine($"Sector 0 (MBR): Signature=0x{m.Signature:X4} (Valid={m.HasValidSignature}), Protective 0xEE={m.HasProtectiveMbr}, Note={m.ProtectiveMbrNote}");
                if (g.IsGptCandidate)
                {
                    sb.AppendLine($"Primary GPT (LBA {g.Primary.HeaderLba}): Sig='{g.Primary.SignatureText}', HeaderCRC=0x{g.Primary.ComputedHeaderCrc32:X8} (Valid={g.Primary.HeaderCrcValid}), EntriesCRC=0x{g.Primary.ComputedEntriesCrc32:X8} (Valid={g.Primary.EntriesCrcValid}), DiskGUID={g.Primary.DiskGuid}");
                    sb.AppendLine($"Backup  GPT (LBA {g.Backup.HeaderLba}): Sig='{g.Backup.SignatureText}', HeaderCRC=0x{g.Backup.ComputedHeaderCrc32:X8} (Valid={g.Backup.HeaderCrcValid}), EntriesCRC=0x{g.Backup.ComputedEntriesCrc32:X8} (Valid={g.Backup.EntriesCrcValid}), DiskGUID={g.Backup.DiskGuid}");
                    sb.AppendLine($"Primary vs Backup Consistent: {g.PrimaryAndBackupConsistent}  |  Active GPT Partitions: {g.ActivePartitions.Count}");
                }
                return sb.ToString().TrimEnd();
            }
        }

        public string AuditLogText
        {
            get => _auditLogText;
            private set { _auditLogText = value; OnPropertyChanged(); }
        }

        public bool CanOpenPdfReport => !string.IsNullOrWhiteSpace(_reportPdfPath) && File.Exists(_reportPdfPath);

        // ═══ RELEASE 4 PROPERTIES (IMAGING & FILE RECOVERY) ═══

        public string ImagingOutputPath
        {
            get => _imagingOutputPath;
            set { _imagingOutputPath = value; OnPropertyChanged(); }
        }

        public bool ScrapeFailedBlocks
        {
            get => _scrapeFailedBlocks;
            set { _scrapeFailedBlocks = value; OnPropertyChanged(); }
        }

        public bool IsImagingRunning
        {
            get => _isImagingRunning;
            set { _isImagingRunning = value; OnPropertyChanged(); }
        }

        public double ImagingProgressPercent
        {
            get => _imagingProgressPercent;
            set { _imagingProgressPercent = value; OnPropertyChanged(); }
        }

        public string ImagingStatusSummary
        {
            get => _imagingStatusSummary;
            set { _imagingStatusSummary = value; OnPropertyChanged(); }
        }

        public ImagingScopeOption? SelectedImagingScope
        {
            get => _selectedImagingScope;
            set
            {
                _selectedImagingScope = value;
                OnPropertyChanged();
                UpdateDefaultImagingFilenameForScope();
            }
        }

        public FileSystemAnalysisResult? SelectedRecoveryPartition
        {
            get => _selectedRecoveryPartition;
            set { _selectedRecoveryPartition = value; OnPropertyChanged(); }
        }

        public bool IncludeDeletedFiles
        {
            get => _includeDeletedFiles;
            set { _includeDeletedFiles = value; OnPropertyChanged(); }
        }

        public bool FullMftScan
        {
            get => _fullMftScan;
            set { _fullMftScan = value; OnPropertyChanged(); }
        }

        public string FileSearchFilter
        {
            get => _fileSearchFilter;
            set
            {
                if (_fileSearchFilter == value) return;
                _fileSearchFilter = value;
                OnPropertyChanged();
                RefreshDisplayedRecoverableFiles();
            }
        }

        public string FileExportDestination
        {
            get => _fileExportDestination;
            set { _fileExportDestination = value; OnPropertyChanged(); }
        }

        public string FileRecoveryStatusText
        {
            get => _fileRecoveryStatusText;
            set { _fileRecoveryStatusText = value; OnPropertyChanged(); }
        }

        public void RefreshPhysicalDisks()
        {
            try
            {
                var existingImages = Targets.Where(t => t.IsDiskImage).ToList();
                var physical = StorageRecoveryService.DiscoverPhysicalDiskTargets();
                Targets.Clear();
                foreach (var p in physical)
                    Targets.Add(p);
                foreach (var img in existingImages)
                    Targets.Add(img);

                if (SelectedTarget == null && Targets.Count > 0)
                {
                    // Prefer first non-system disk if available
                    SelectedTarget = Targets.FirstOrDefault(t => !t.Device.IsSystemDisk) ?? Targets[0];
                }
                StatusText = $"Detected {physical.Count} physical drive(s) and {existingImages.Count} loaded disk image(s).";
            }
            catch (Exception ex)
            {
                StatusText = $"Disk discovery error: {ex.Message}";
            }
        }

        private Task OpenImageFileAsync()
        {
            var dlg = new OpenFileDialog
            {
                Title = "Open Raw Disk Image File (Read-Only Inspection)",
                Filter = "Disk Images (*.img;*.bin;*.raw;*.dd)|*.img;*.bin;*.raw;*.dd|All Files (*.*)|*.*"
            };
            if (dlg.ShowDialog() == true)
            {
                try
                {
                    var choice = StorageRecoveryService.CreateImageTargetChoice(dlg.FileName);
                    Targets.Add(choice);
                    SelectedTarget = choice;
                    AppendAudit($"Loaded disk image for inspection: {dlg.FileName} ({choice.Device.DisplayCapacity})");
                    StatusText = $"Loaded image {Path.GetFileName(dlg.FileName)}. Click Inspect Disk to analyze.";
                }
                catch (Exception ex)
                {
                    MessageBox.Show($"Unable to open disk image:\n{ex.Message}", "Storage Recovery", MessageBoxButton.OK, MessageBoxImage.Warning);
                }
            }
            return Task.CompletedTask;
        }

        private async Task CreateTestFixtureAsync()
        {
            if (IsBusy) return;
            IsBusy = true;
            try
            {
                var (scenario, capBytes, fileTag) = ResolvePreset(SelectedFixturePreset);
                string fixDir = StorageRecoveryService.GetDefaultFixturesRoot();
                string filePath = Path.Combine(fixDir, $"Fixture_{fileTag}_{DateTime.Now:HHmmss}.img");

                StatusText = $"Creating sparse test fixture ({fileTag})...";
                await Task.Run(() => DiskFixtureBuilder.CreateFixtureImage(filePath, scenario, capBytes, 512, "Friend10TB_NTFS"));

                var choice = StorageRecoveryService.CreateImageTargetChoice(filePath, 512);
                Targets.Add(choice);
                SelectedTarget = choice;
                AppendAudit($"Created test fixture '{SelectedFixturePreset}' at {filePath} (Logical capacity: {choice.Device.DisplayCapacity}).");
                StatusText = $"Created fixture {Path.GetFileName(filePath)}. Running read-only inspection...";
            }
            catch (Exception ex)
            {
                StatusText = $"Fixture creation failed: {ex.Message}";
                MessageBox.Show($"Failed to create test fixture:\n{ex.Message}", "Storage Recovery", MessageBoxButton.OK, MessageBoxImage.Warning);
                IsBusy = false;
                return;
            }
            IsBusy = false;
            await InspectSelectedTargetAsync();
        }

        private static (DiskFixtureScenario Scenario, long CapacityBytes, string FileTag) ResolvePreset(string preset)
        {
            const long tenTb = 10L * 1024 * 1024 * 1024 * 1024; // 10 TiB sparse
            const long sixtyFourMb = 64L * 1024 * 1024;

            if (preset.Contains("Damaged Primary GPT", StringComparison.OrdinalIgnoreCase))
                return (DiskFixtureScenario.DamagedPrimaryGpt_ValidBackupGpt, tenTb, "10TB_DamagedPrimaryGPT");
            if (preset.Contains("Damaged NTFS Boot Sector", StringComparison.OrdinalIgnoreCase))
                return (DiskFixtureScenario.DamagedNtfsPrimaryVbr_ValidBackupVbr, tenTb, "10TB_DamagedNtfsVBR");
            if (preset.Contains("Wiped Partition Table", StringComparison.OrdinalIgnoreCase))
                return (DiskFixtureScenario.WipedPartitionTable_LostNtfsPartition, tenTb, "10TB_LostPartition");
            if (preset.Contains("Severely Damaged $MFT", StringComparison.OrdinalIgnoreCase))
                return (DiskFixtureScenario.SeverelyDamagedNtfsMft, tenTb, "10TB_DamagedMFT");
            if (preset.Contains("S20", StringComparison.OrdinalIgnoreCase))
                return (DiskFixtureScenario.MalformedMbrSignature_S20, sixtyFourMb, "S20_MalformedMBR");
            if (preset.Contains("S21", StringComparison.OrdinalIgnoreCase))
                return (DiskFixtureScenario.ProtectiveMbrMismatch_S21, sixtyFourMb, "S21_ProtectiveMismatch");
            if (preset.Contains("BitLocker", StringComparison.OrdinalIgnoreCase))
                return (DiskFixtureScenario.BitLockerEncryptedPartition, sixtyFourMb, "BitLockerVolume");
            return (DiskFixtureScenario.HealthyGptNtfs, tenTb, "10TB_HealthyBaseline");
        }

        public async Task InspectSelectedTargetAsync()
        {
            if (IsBusy) return;
            if (SelectedTarget == null)
            {
                MessageBox.Show("Select a physical drive or open a disk image first.", "Inspect Disk", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            IsBusy = true;
            _inspectCts?.Dispose();
            _inspectCts = new System.Threading.CancellationTokenSource();
            StatusText = $"Inspecting {SelectedTarget.DisplayTitle} (strictly read-only)...";
            try
            {
                var assessment = await StorageRecoveryService.InspectTargetAsync(SelectedTarget, _inspectCts.Token);
                ApplyAssessmentToViewModel(assessment);
                AppendAudit($"Completed read-only inspection of {assessment.Device.FriendlyName} ({assessment.Device.DisplayCapacity}): Verdict='{assessment.OverallVerdict}', Findings={assessment.Findings.Count}, RepairPlans={assessment.ProposedRepairs.Count}.");
                StatusText = $"Inspection complete — {assessment.OverallVerdict}.";
            }
            catch (OperationCanceledException)
            {
                StatusText = "Read-only disk inspection cancelled.";
                AppendAudit("[INSPECT] Cancelled by user.");
            }
            catch (Exception ex)
            {
                StatusText = $"Inspection error: {ex.Message}";
                AppendAudit($"[ERROR] Inspection failed: {ex.Message}");
                MessageBox.Show($"Read-only disk inspection failed:\n\n{ex.Message}", "Storage Recovery", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
            finally
            {
                IsBusy = false;
            }
        }

        private void ApplyAssessmentToViewModel(StorageRecoveryAssessment a)
        {
            _currentAssessment = a;
            HardwareBadge = a.HardwareHealthBadge;
            PartitionBadge = a.PartitionTableBadge;
            FileSystemBadge = a.FileSystemBadge;
            OverallVerdict = a.OverallVerdict;
            ExecutiveSummary = a.ExecutiveSummary;

            Findings.Clear();
            foreach (var f in a.Findings)
                Findings.Add(StorageFindingRowViewModel.FromModel(f));

            RawDiskMapCollection.Clear();
            RawDiskMapCollection.Add(DiskLayoutService.BuildMapModelFromAssessment(a));

            DiscoveredPartitions.Clear();
            foreach (var d in a.DiscoveredPartitions)
                DiscoveredPartitions.Add(d);

            FileSystems.Clear();
            foreach (var fs in a.FileSystems)
                FileSystems.Add(fs);

            SelectedRecoveryPartition = FileSystems.FirstOrDefault(f =>
                string.Equals(f.DetectedFileSystem, "NTFS", StringComparison.OrdinalIgnoreCase)
                || string.Equals(f.DetectedFileSystem, "exFAT", StringComparison.OrdinalIgnoreCase)
                || string.Equals(f.DetectedFileSystem, "FAT32", StringComparison.OrdinalIgnoreCase))
                ?? FileSystems.FirstOrDefault();

            ImagingScopes.Clear();
            ImagingScopes.Add(new ImagingScopeOption
            {
                Label = $"Whole Disk ({a.Device.DisplayCapacity})",
                StartOffset = 0,
                LengthBytes = 0,
                FileTag = "WholeDisk"
            });
            foreach (var fs in a.FileSystems)
            {
                if (fs.PartitionSizeBytes <= 0) continue;
                string sizeStr = fs.PartitionSizeBytes >= (1024L * 1024 * 1024)
                    ? $"{fs.PartitionSizeBytes / (1024.0 * 1024 * 1024):0.##} GB"
                    : $"{fs.PartitionSizeBytes / (1024.0 * 1024):0.#} MB";
                ImagingScopes.Add(new ImagingScopeOption
                {
                    Label = $"Partition {fs.PartitionIndex}: {fs.PartitionName} ({fs.DetectedFileSystem}, {sizeStr})",
                    StartOffset = fs.PartitionStartOffset,
                    LengthBytes = fs.PartitionSizeBytes,
                    FileTag = $"Part{fs.PartitionIndex}_{fs.DetectedFileSystem}"
                });
            }
            SelectedImagingScope = ImagingScopes.FirstOrDefault();

            ProposedRepairs.Clear();
            foreach (var p in a.ProposedRepairs)
                ProposedRepairs.Add(p);

            SelectedRepairPlan = ProposedRepairs.FirstOrDefault();
            OnPropertyChanged(nameof(GptComparisonSummary));

            var bitLockerFs = FileSystems.FirstOrDefault(f => f.IsEncryptedBitLocker);
            HasBitLockerPartition = bitLockerFs != null;
            if (bitLockerFs != null)
            {
                _bitLockerPartitionIndex = bitLockerFs.PartitionIndex;
                BitLockerDriveLetter = string.Empty;
                BitLockerKeyProtectorId = string.Empty;
                if (IsPhysicalTargetSelected && SelectedTarget != null)
                {
                    BitLockerStatusMessage = "Checking BitLocker lock status and Recovery Key ID...";
                    _ = RefreshBitLockerStatusAsync(SelectedTarget.Device.DiskNumber, _bitLockerPartitionIndex);
                }
                else
                {
                    BitLockerStatusMessage = "BitLocker unlock requires a physical disk (not a .img file).";
                }
            }
            else
            {
                BitLockerDriveLetter = string.Empty;
                BitLockerKeyProtectorId = string.Empty;
                BitLockerStatusMessage = string.Empty;
            }

            // Update workflow stages
            WorkflowStages[0].State = "Completed";
            WorkflowStages[1].State = _lastSnapshot != null ? "Completed" : "Active";
            WorkflowStages[2].State = a.ProposedRepairs.Count > 0 ? "Active" : "Completed";
            WorkflowStages[3].State = a.ProposedRepairs.Any(p => p.ActionType == "SafetyStop")
                ? "Blocked"
                : (a.ProposedRepairs.Any(p => p.IsExecutable) ? "Pending" : "Completed");
        }

        private async Task CaptureMetadataSnapshotAsync()
        {
            if (IsBusy || SelectedTarget == null) return;
            IsBusy = true;
            StatusText = "Capturing binary metadata snapshot (MBR, Primary/Backup GPT, Boot Sectors, MFT headers)...";
            try
            {
                var manifest = await StorageRecoveryService.CaptureSnapshotAsync(SelectedTarget, _currentAssessment, SnapshotDirectory);
                _lastSnapshot = manifest;
                CapturedSnapshotRegions.Clear();
                foreach (var r in manifest.Regions)
                    CapturedSnapshotRegions.Add(r);

                LastSnapshotSummary = $"Captured {manifest.Regions.Count} binary region(s) to {manifest.SnapshotDirectory}";
                WorkflowStages[1].State = "Completed";
                AppendAudit($"[SNAPSHOT] Saved binary metadata snapshot '{manifest.SnapshotId}' ({manifest.Regions.Count} regions) to {manifest.SnapshotDirectory}");
                StatusText = $"Snapshot saved: {manifest.SnapshotId}";
            }
            catch (Exception ex)
            {
                StatusText = $"Snapshot failed: {ex.Message}";
                MessageBox.Show($"Metadata snapshot failed:\n\n{ex.Message}", "Metadata Snapshot", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
            finally
            {
                IsBusy = false;
            }
        }

        private Task BrowseSnapshotDirAsync()
        {
            using var dlg = new WinForms.FolderBrowserDialog
            {
                Description = "Select healthy destination folder for Metadata Snapshots (must NOT be on the source drive)",
                SelectedPath = SnapshotDirectory
            };
            if (dlg.ShowDialog() == WinForms.DialogResult.OK && !string.IsNullOrWhiteSpace(dlg.SelectedPath))
            {
                SnapshotDirectory = dlg.SelectedPath;
            }
            return Task.CompletedTask;
        }

        private async Task VerifyExistingSnapshotAsync()
        {
            var dlg = new OpenFileDialog
            {
                Title = "Select Metadata Snapshot manifest.json to Verify",
                InitialDirectory = Directory.Exists(SnapshotDirectory) ? SnapshotDirectory : StorageRecoveryService.GetDefaultSnapshotRoot(),
                Filter = "Snapshot Manifest (manifest.json)|manifest.json|JSON Files (*.json)|*.json"
            };
            if (dlg.ShowDialog() != true) return;

            IsBusy = true;
            try
            {
                var (isValid, manifest, message) = await MetadataSnapshotService.VerifySnapshotAsync(dlg.FileName);
                if (manifest != null)
                {
                    _lastSnapshot = manifest;
                    CapturedSnapshotRegions.Clear();
                    foreach (var r in manifest.Regions)
                        CapturedSnapshotRegions.Add(r);
                }
                LastSnapshotSummary = message;
                AppendAudit($"[SNAPSHOT VERIFY] {message} (Valid={isValid})");
                MessageBox.Show(message, isValid ? "Snapshot Verified ✓" : "Snapshot Verification Failed", MessageBoxButton.OK, isValid ? MessageBoxImage.Information : MessageBoxImage.Warning);
            }
            finally
            {
                IsBusy = false;
            }
        }

        private async Task ApplyRepairToImageAsync()
        {
            if (IsBusy || SelectedRepairPlan == null || SelectedTarget == null || !SelectedTarget.IsDiskImage)
                return;

            var confirm = MessageBox.Show(
                $"Apply repair plan to disk image?\n\n" +
                $"Plan: {SelectedRepairPlan.Title}\n" +
                $"Target Image: {SelectedTarget.ImagePath}\n" +
                $"Regions to modify: {SelectedRepairPlan.Patches.Count}\n\n" +
                $"A binary Metadata Snapshot will be saved automatically before modifying the image.",
                "Confirm Guided Image Repair",
                MessageBoxButton.YesNo,
                MessageBoxImage.Question);

            if (confirm != MessageBoxResult.Yes)
                return;

            IsBusy = true;
            StatusText = $"Applying '{SelectedRepairPlan.Title}' to disk image...";
            try
            {
                var result = await StorageRecoveryService.ExecuteRepairOnImageAsync(
                    SelectedRepairPlan,
                    SelectedTarget.ImagePath,
                    SnapshotDirectory);

                foreach (var entry in result.AuditLogEntries)
                    AppendAudit(entry);

                if (result.Succeeded)
                {
                    WorkflowStages[1].State = "Completed";
                    WorkflowStages[2].State = "Completed";
                    WorkflowStages[3].State = "Completed";
                    StatusText = result.SummaryMessage;
                    MessageBox.Show(
                        $"{result.SummaryMessage}\n\nPre-repair snapshot: {result.PreRepairSnapshotManifestPath}\n\nRe-running read-only inspection to verify repaired state...",
                        "Repair Succeeded ✓",
                        MessageBoxButton.OK,
                        MessageBoxImage.Information);
                    await StorageRecoveryService.RecordActivityWorkOrderReportAsync(
                        $"Image Repair: {SelectedRepairPlan.Title}",
                        "Pass",
                        result.SummaryMessage,
                        _auditEntries);
                }
                else
                {
                    StatusText = $"Repair failed: {result.SummaryMessage}";
                    MessageBox.Show(result.SummaryMessage, "Repair Stopped", MessageBoxButton.OK, MessageBoxImage.Warning);
                }
            }
            catch (Exception ex)
            {
                StatusText = $"Repair error: {ex.Message}";
                AppendAudit($"[REPAIR ERROR] {ex.Message}");
                MessageBox.Show($"Error applying repair:\n{ex.Message}", "Storage Recovery", MessageBoxButton.OK, MessageBoxImage.Error);
            }
            finally
            {
                IsBusy = false;
            }

            // Automatically re-inspect after repair to verify healthy state
            await InspectSelectedTargetAsync();
            WorkflowStages[4].State = "Completed";
        }

        private async Task ApplyRepairInPlacePhysicalAsync()
        {
            if (IsBusy || SelectedRepairPlan == null || SelectedTarget == null || SelectedTarget.IsDiskImage)
                return;

            string expectedPhrase = $"REPAIR DISK {SelectedTarget.Device.DiskNumber}";
            if (!string.Equals(InPlaceConfirmPhrase?.Trim(), expectedPhrase, StringComparison.OrdinalIgnoreCase))
            {
                MessageBox.Show(
                    $"To authorize an in-place physical disk metadata repair when no clone drive is available, type:\n\n{expectedPhrase}\n\nin the authorization box first.",
                    "Authorization Required",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return;
            }

            var confirm = MessageBox.Show(
                $"AUTHORIZED IN-PLACE PHYSICAL DISK REPAIR\n\n" +
                $"Target Drive: {SelectedTarget.DisplayTitle}\n" +
                $"Serial: {SelectedTarget.Device.SerialNumber}\n" +
                $"Plan: {SelectedRepairPlan.Title}\n" +
                $"Sectors Modified: {SelectedRepairPlan.Patches.Sum(p => p.SectorCount)} sector(s) across {SelectedRepairPlan.Patches.Count} metadata region(s)\n" +
                $"Snapshot Backup Folder: {SnapshotDirectory}\n\n" +
                $"CDE will first re-verify the physical drive identity, verify that original bytes have not changed since your scan, and save a verified binary Metadata Snapshot before writing.\n\n" +
                $"Proceed with in-place metadata repair?",
                "Confirm Physical Disk In-Place Repair",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning,
                MessageBoxResult.No);

            if (confirm != MessageBoxResult.Yes)
                return;

            IsBusy = true;
            StatusText = $"Executing authorized in-place repair on PhysicalDrive{SelectedTarget.Device.DiskNumber}...";
            try
            {
                var auth = new PhysicalDiskRepairAuthorization
                {
                    OperatorConfirmedInPlaceWrite = true,
                    MandatorySnapshotDirectory = SnapshotDirectory,
                    OperatorConfirmationPhrase = (InPlaceConfirmPhrase ?? string.Empty).Trim()
                };

                var result = await StorageRecoveryService.ExecuteRepairOnPhysicalDiskInPlaceAsync(SelectedRepairPlan, auth);
                foreach (var entry in result.AuditLogEntries)
                    AppendAudit(entry);

                if (result.Succeeded)
                {
                    InPlaceConfirmPhrase = string.Empty;
                    WorkflowStages[1].State = "Completed";
                    WorkflowStages[2].State = "Completed";
                    WorkflowStages[3].State = "Completed";
                    StatusText = result.SummaryMessage;
                    MessageBox.Show(
                        $"{result.SummaryMessage}\n\nRollback snapshot saved at:\n{result.PreRepairSnapshotManifestPath}",
                        "Physical Disk Repair Verified ✓",
                        MessageBoxButton.OK,
                        MessageBoxImage.Information);
                    await StorageRecoveryService.RecordActivityWorkOrderReportAsync(
                        $"Physical Disk Repair: {SelectedRepairPlan.Title}",
                        "Pass",
                        $"{result.SummaryMessage} (Snapshot: {result.PreRepairSnapshotManifestPath})",
                        _auditEntries);
                }
                else
                {
                    StatusText = result.SummaryMessage;
                    MessageBox.Show(result.SummaryMessage, "Physical Disk Repair Aborted", MessageBoxButton.OK, MessageBoxImage.Warning);
                }
            }
            catch (Exception ex)
            {
                StatusText = $"Physical repair error: {ex.Message}";
                AppendAudit($"[PHYSICAL REPAIR ERROR] {ex.Message}");
                MessageBox.Show($"Physical disk repair failed:\n\n{ex.Message}", "Storage Recovery", MessageBoxButton.OK, MessageBoxImage.Error);
            }
            finally
            {
                IsBusy = false;
            }

            await InspectSelectedTargetAsync();
            WorkflowStages[4].State = "Completed";
        }

        private async Task ExportReportAsync()
        {
            if (_currentAssessment == null)
            {
                MessageBox.Show("Run Inspect Disk first before exporting a session report.", "Session Report", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            IsBusy = true;
            StatusText = "Exporting JSON and PDF Storage Recovery report...";
            try
            {
                var (jsonPath, pdfPath) = await StorageRecoveryService.ExportAssessmentReportAsync(_currentAssessment, _auditEntries);
                _reportJsonPath = jsonPath;
                _reportPdfPath = pdfPath;
                OnPropertyChanged(nameof(CanOpenPdfReport));
                WorkflowStages[4].State = "Completed";
                AppendAudit($"[REPORT] Exported assessment JSON ({jsonPath}) and PDF ({pdfPath}).");
                StatusText = $"Saved report: {Path.GetFileName(string.IsNullOrWhiteSpace(pdfPath) ? jsonPath : pdfPath)}";
            }
            catch (Exception ex)
            {
                StatusText = $"Report export failed: {ex.Message}";
                MessageBox.Show($"Unable to export report:\n{ex.Message}", "Session Report", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
            finally
            {
                IsBusy = false;
            }
        }

        private async Task OpenPdfReportAsync()
        {
            if (!CanOpenPdfReport && _currentAssessment != null)
            {
                await ExportReportAsync();
            }

            if (CanOpenPdfReport)
            {
                ShellFileOpenHelper.OpenWithDefaultApplication(_reportPdfPath);
            }
        }

        // ═══ RELEASE 4 METHODS (RESUMABLE IMAGING & NTFS FILE RECOVERY) ═══

        private Task BrowseImagingOutputAsync()
        {
            var dlg = new SaveFileDialog
            {
                Title = "Select Destination Disk Image File (.img)",
                InitialDirectory = Directory.Exists(SnapshotDirectory) ? SnapshotDirectory : StorageRecoveryService.GetDefaultSnapshotRoot(),
                FileName = Path.GetFileName(ImagingOutputPath),
                Filter = "Raw Disk Image (*.img)|*.img|Binary Image (*.bin)|*.bin"
            };
            if (dlg.ShowDialog() == true)
            {
                ImagingOutputPath = dlg.FileName;
            }
            return Task.CompletedTask;
        }

        private async Task StartOrResumeImagingAsync()
        {
            if (IsBusy || IsImagingRunning || SelectedTarget == null)
                return;

            if (string.IsNullOrWhiteSpace(ImagingOutputPath))
            {
                MessageBox.Show("Specify a destination .img file path first.", "Disk Imaging", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            IsBusy = true;
            IsImagingRunning = true;
            _imagingCts?.Dispose();
            _imagingCts = new System.Threading.CancellationTokenSource();

            var progress = new Progress<ImagingProgressReport>(rep =>
            {
                ImagingProgressPercent = rep.PercentComplete;
                ImagingStatusSummary = $"{rep.Phase}: {rep.PercentComplete:0.0}% — {rep.StatusMessage} (Bad blocks: {rep.BadRangeCount})";
                StatusText = ImagingStatusSummary;
            });

            var scope = SelectedImagingScope ?? new ImagingScopeOption { Label = "Whole Disk", StartOffset = 0, LengthBytes = 0, FileTag = "WholeDisk" };
            AppendAudit($"[IMAGING] Starting/resuming block-level imaging ({scope.Label}) of {SelectedTarget.DisplayTitle} to {ImagingOutputPath} (ScrapeFailedBlocks={ScrapeFailedBlocks}).");
            try
            {
                var manifest = await StorageRecoveryService.RunOrResumeImagingJobAsync(
                    SelectedTarget,
                    ImagingOutputPath,
                    sourceStartOffset: scope.StartOffset,
                    lengthBytes: scope.LengthBytes,
                    scrapeFailedBlocks: ScrapeFailedBlocks,
                    targetScopeLabel: scope.Label,
                    progress: progress,
                    cancellationToken: _imagingCts.Token);

                ImagingProgressPercent = manifest.TotalBytesToCopy > 0
                    ? ((manifest.BytesRescued + manifest.BytesBad) * 100.0) / manifest.TotalBytesToCopy
                    : 100;
                ImagingStatusSummary = $"{manifest.LastStatusMessage}  |  Mapfile: {Path.GetFileName(manifest.MapFilePath)}";
                StatusText = manifest.LastStatusMessage;
                WorkflowStages[1].State = "Completed";
                AppendAudit($"[IMAGING {manifest.CurrentPhase.ToUpperInvariant()}] {manifest.LastStatusMessage} (Mapfile: {manifest.MapFilePath})");
                await StorageRecoveryService.RecordActivityWorkOrderReportAsync(
                    $"Disk Imaging ({scope.Label})",
                    manifest.BytesBad > 0 ? "Warn" : "Pass",
                    manifest.LastStatusMessage,
                    _auditEntries);
            }
            catch (OperationCanceledException)
            {
                ImagingStatusSummary = "Imaging job paused. Progress saved to .cdemap — click 'Start / Resume Image Job' to continue.";
                StatusText = ImagingStatusSummary;
                AppendAudit("[IMAGING PAUSED] Operator paused imaging job; progress checkpointed to .cdemap.");
            }
            catch (Exception ex)
            {
                ImagingStatusSummary = $"Imaging error: {ex.Message}";
                StatusText = ImagingStatusSummary;
                AppendAudit($"[IMAGING ERROR] {ex.Message}");
                MessageBox.Show($"Disk imaging error:\n\n{ex.Message}", "Disk Imaging", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
            finally
            {
                IsImagingRunning = false;
                IsBusy = false;
            }
        }

        private Task StopImagingAsync()
        {
            _imagingCts?.Cancel();
            return Task.CompletedTask;
        }

        private async Task ScanRecoverableFilesAsync()
        {
            if (IsBusy || SelectedTarget == null)
                return;

            var part = SelectedRecoveryPartition ?? FileSystems.FirstOrDefault();
            if (part == null)
            {
                MessageBox.Show("Run 'Inspect Disk (Read-Only)' first so CDE can locate the partition and $MFT boundaries.", "File Recovery", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            IsBusy = true;
            _allRecoverableFiles.Clear();
            DisplayedRecoverableFiles.Clear();
            FileRecoveryStatusText = $"Scanning $MFT on Partition {part.PartitionIndex} ({part.PartitionName})...";
            StatusText = FileRecoveryStatusText;

            var progress = new Progress<string>(msg =>
            {
                FileRecoveryStatusText = msg;
                StatusText = msg;
            });

            try
            {
                _fileScanCts?.Dispose();
                _fileScanCts = new System.Threading.CancellationTokenSource();
                int maxRecords = FullMftScan ? 0 : 16384;
                var recovered = await StorageRecoveryService.ScanRecoverableFilesAsync(
                    SelectedTarget,
                    part,
                    IncludeDeletedFiles,
                    maxRecords: maxRecords,
                    progress: progress,
                    cancellationToken: _fileScanCts.Token);

                foreach (var item in recovered)
                {
                    _allRecoverableFiles.Add(new RecoverableFileRowViewModel
                    {
                        Model = item,
                        IsSelected = true
                    });
                }

                RefreshDisplayedRecoverableFiles();
                int delCount = _allRecoverableFiles.Count(f => f.Model.IsDeleted);
                int fragCount = _allRecoverableFiles.Count(f => f.Model.IsFragmented);
                string limitNote = (!FullMftScan && recovered.Count >= 16384)
                    ? " (Quick-scan limit 16,384 reached — enable 'Full $MFT scan' for complete volume)"
                    : string.Empty;
                FileRecoveryStatusText = $"Found {_allRecoverableFiles.Count:N0} recoverable file(s) ({delCount:N0} deleted, {fragCount:N0} fragmented){limitNote}. Select files and click Export.";
                StatusText = FileRecoveryStatusText;
                AppendAudit($"[FILE SCAN] Found {_allRecoverableFiles.Count} recoverable file(s) on Partition {part.PartitionIndex} (IncludeDeleted={IncludeDeletedFiles}, FullMftScan={FullMftScan}).");
            }
            catch (OperationCanceledException)
            {
                FileRecoveryStatusText = "File scan cancelled.";
                StatusText = FileRecoveryStatusText;
                AppendAudit("[FILE SCAN] Cancelled by user.");
            }
            catch (Exception ex)
            {
                FileRecoveryStatusText = $"File scan failed: {ex.Message}";
                StatusText = FileRecoveryStatusText;
                AppendAudit($"[FILE SCAN ERROR] {ex.Message}");
                MessageBox.Show($"Unable to scan $MFT for recoverable files:\n\n{ex.Message}", "File Recovery", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
            finally
            {
                IsBusy = false;
            }
        }

        private void RefreshDisplayedRecoverableFiles()
        {
            DisplayedRecoverableFiles.Clear();
            string filter = (FileSearchFilter ?? string.Empty).Trim();
            foreach (var row in _allRecoverableFiles)
            {
                if (!string.IsNullOrEmpty(filter)
                    && !row.FileName.Contains(filter, StringComparison.OrdinalIgnoreCase)
                    && !row.ReconstructedPath.Contains(filter, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }
                DisplayedRecoverableFiles.Add(row);
            }
        }

        private void SetAllFileSelections(bool selected)
        {
            foreach (var row in DisplayedRecoverableFiles)
                row.IsSelected = selected;
        }

        private Task BrowseExportDestAsync()
        {
            using var dlg = new WinForms.FolderBrowserDialog
            {
                Description = "Select healthy destination folder for recovered files (must NOT be on the source drive)",
                SelectedPath = FileExportDestination
            };
            if (dlg.ShowDialog() == WinForms.DialogResult.OK && !string.IsNullOrWhiteSpace(dlg.SelectedPath))
            {
                FileExportDestination = dlg.SelectedPath;
            }
            return Task.CompletedTask;
        }

        private async Task ExportSelectedFilesAsync()
        {
            if (IsBusy || SelectedTarget == null)
                return;

            var selectedModels = DisplayedRecoverableFiles
                .Where(r => r.IsSelected)
                .Select(r => r.Model)
                .ToList();

            if (selectedModels.Count == 0)
            {
                MessageBox.Show("Check one or more files in the list to export.", "Export Files", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            IsBusy = true;
            _fileExportCts?.Dispose();
            _fileExportCts = new System.Threading.CancellationTokenSource();
            var progress = new Progress<string>(msg =>
            {
                FileRecoveryStatusText = msg;
                StatusText = msg;
            });

            try
            {
                var manifest = await StorageRecoveryService.ExportRecoverableFilesAsync(
                    SelectedTarget,
                    selectedModels,
                    FileExportDestination,
                    progress,
                    _fileExportCts.Token);

                WorkflowStages[3].State = "Completed";
                WorkflowStages[4].State = "Completed";
                FileRecoveryStatusText = $"Exported {manifest.VerifiedFilesCount} verified file(s), {manifest.PartialFilesCount} partial, {manifest.FailedFilesCount} failed to {manifest.DestinationRoot}";
                StatusText = FileRecoveryStatusText;
                AppendAudit($"[FILE EXPORT] {FileRecoveryStatusText} (Manifest: {manifest.ManifestFilePath})");
                await StorageRecoveryService.RecordActivityWorkOrderReportAsync(
                    "File Recovery Export",
                    manifest.FailedFilesCount > 0 || manifest.PartialFilesCount > 0 ? "Warn" : "Pass",
                    FileRecoveryStatusText,
                    _auditEntries);

                MessageBox.Show(
                    $"File Recovery Export Complete!\n\n" +
                    $"Destination: {manifest.DestinationRoot}\n" +
                    $"Verified Intact Files: {manifest.VerifiedFilesCount}\n" +
                    $"Partial (Bad Sector Zero-Filled): {manifest.PartialFilesCount}\n" +
                    $"Failed: {manifest.FailedFilesCount}\n" +
                    $"Total Bytes Written: {manifest.TotalBytesWritten:N0}\n\n" +
                    $"SHA-256 verification manifest saved to:\n{manifest.ManifestFilePath}",
                    "File Recovery Export Complete ✓",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
            }
            catch (OperationCanceledException)
            {
                FileRecoveryStatusText = "File export cancelled by user.";
                StatusText = FileRecoveryStatusText;
                AppendAudit("[FILE EXPORT] Cancelled by user.");
            }
            catch (Exception ex)
            {
                FileRecoveryStatusText = $"Export error: {ex.Message}";
                StatusText = FileRecoveryStatusText;
                AppendAudit($"[FILE EXPORT ERROR] {ex.Message}");
                MessageBox.Show($"File export failed:\n\n{ex.Message}", "Export Files", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
            finally
            {
                IsBusy = false;
            }
        }

        private void UpdateDefaultImagingFilenameForScope()
        {
            if (SelectedImagingScope == null || string.IsNullOrWhiteSpace(ImagingOutputPath))
                return;
            string? dir = Path.GetDirectoryName(ImagingOutputPath);
            if (string.IsNullOrWhiteSpace(dir))
                return;

            string diskTag = SelectedTarget != null && !SelectedTarget.IsDiskImage
                ? $"Disk{SelectedTarget.Device.DiskNumber}"
                : "Image";
            string fileName = SelectedImagingScope.StartOffset == 0 && SelectedImagingScope.LengthBytes == 0
                ? $"{diskTag}_RecoveryImage.img"
                : $"{diskTag}_{SelectedImagingScope.FileTag}.img";
            ImagingOutputPath = Path.Combine(dir, fileName);
        }

        private async Task RefreshBitLockerStatusAsync(int diskNumber, int partitionNumber)
        {
            try
            {
                var info = await StorageRecoveryService.QueryBitLockerStatusAsync(diskNumber, partitionNumber);
                BitLockerDriveLetter = info.DriveLetter;
                BitLockerKeyProtectorId = info.KeyProtectorId;
                BitLockerStatusMessage = info.StatusMessage;
            }
            catch (Exception ex)
            {
                BitLockerStatusMessage = $"Could not query BitLocker status: {ex.Message}";
            }
        }

        private async Task UnlockBitLockerAsync()
        {
            if (IsBusy || SelectedTarget == null || SelectedTarget.IsDiskImage || !HasBitLockerPartition)
                return;

            IsBusy = true;
            BitLockerStatusMessage = "Unlocking BitLocker partition...";
            StatusText = "Running manage-bde to unlock BitLocker partition...";
            try
            {
                var res = await StorageRecoveryService.UnlockBitLockerPartitionAsync(
                    SelectedTarget.Device.DiskNumber,
                    _bitLockerPartitionIndex,
                    BitLockerRecoveryKey);

                if (!string.IsNullOrWhiteSpace(res.DriveLetter))
                    BitLockerDriveLetter = res.DriveLetter;

                BitLockerStatusMessage = res.Message;
                AppendAudit($"BitLocker unlock attempt on Disk {SelectedTarget.Device.DiskNumber} Partition {_bitLockerPartitionIndex}: {res.Message}");

                if (res.Succeeded)
                {
                    BitLockerRecoveryKey = string.Empty;
                    StatusText = res.Message;
                    MessageBox.Show(res.Message, "BitLocker Unlocked", MessageBoxButton.OK, MessageBoxImage.Information);
                }
                else
                {
                    StatusText = "BitLocker unlock failed.";
                    MessageBox.Show(res.Message, "BitLocker Unlock", MessageBoxButton.OK, MessageBoxImage.Warning);
                }
            }
            catch (Exception ex)
            {
                BitLockerStatusMessage = $"BitLocker unlock error: {ex.Message}";
                MessageBox.Show($"BitLocker unlock failed:\n{ex.Message}", "BitLocker Unlock", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
            finally
            {
                IsBusy = false;
            }
        }

        private void AppendAudit(string message)
        {
            string line = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {message}";
            _auditEntries.Add(line);
            AuditLogText = string.Join(Environment.NewLine, _auditEntries);
        }

        private static Brush PickBadgeBrush(string text)
        {
            string t = (text ?? string.Empty).ToLowerInvariant();
            if (t.Contains("healthy") || t.Contains("verified") || t.Contains("valid") && !t.Contains("damaged") && !t.Contains("invalid"))
                return new SolidColorBrush(Color.FromRgb(0x0D, 0x7A, 0x3E));
            if (t.Contains("damaged") || t.Contains("critical") || t.Contains("fail") || t.Contains("error") || t.Contains("corrupt"))
                return new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C));
            if (t.Contains("degraded") || t.Contains("warn") || t.Contains("mismatch") || t.Contains("bitlocker") || t.Contains("repairable"))
                return new SolidColorBrush(Color.FromRgb(0xD2, 0x99, 0x22));
            return new SolidColorBrush(Color.FromRgb(0x5A, 0x6B, 0x80));
        }

        public event PropertyChangedEventHandler? PropertyChanged;
        private void OnPropertyChanged([CallerMemberName] string? name = null) =>
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    public sealed class ImagingScopeOption
    {
        public string Label { get; init; } = "Whole Disk";
        public long StartOffset { get; init; }
        public long LengthBytes { get; init; }
        public string FileTag { get; init; } = "WholeDisk";
        public override string ToString() => Label;
    }
}
