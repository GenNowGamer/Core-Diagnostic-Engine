using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Input;
using Newtonsoft.Json;
using ToolkitGUI.Models;
using ToolkitGUI.Services;

namespace ToolkitGUI.ViewModels
{
    public enum ProcessAnalyzerFilterPreset
    {
        All,
        HighCpu,
        HighRam,
        NotResponding,
        Unsigned,
        SuspiciousPath,
        NoPath,
        RiskWarning,
        InStartup,
        NewSinceInvestigation
    }

    public class ProcessAnalyzerViewModel : INotifyPropertyChanged
    {
        private const int NormalRefreshMs = 10000;
        private const int InvestigationRefreshMs = 3000;
        private const int NormalSampleMs = 900;
        private const int InvestigationSampleMs = 600;

        private static readonly HashSet<string> ProtectedProcessNames = new(StringComparer.OrdinalIgnoreCase)
        {
            "System", "Idle", "csrss", "wininit", "winlogon", "services", "lsass", "smss", "Registry"
        };

        private bool _isLoading;
        private bool _autoRefreshEnabled = true;
        private bool _investigationMode;
        private bool _freezeSnapshot;
        private bool _treeViewMode;
        private bool _deepScanEnabled;
        private string _statusText = "Ready";
        private string _filterText = string.Empty;
        private ProcessAnalyzerFilterPreset _filterPreset = ProcessAnalyzerFilterPreset.All;
        private ProcessEntry? _selectedProcess;
        private ProcessDetail? _selectedDetail;
        private string _detailStatusText = "Select a process for details.";
        private System.Timers.Timer? _autoRefreshTimer;
        private readonly SemaphoreSlim _autoRefreshGate = new(1, 1);
        private HashSet<int> _knownPids = new();
        private int? _preserveSelectedPid;
        private int _detailLoadSerial;
        private string? _snapshotReportBaseName;
        private TabularScanReportPaths? _snapshotReportPaths;
        private string _snapshotPdfPath = string.Empty;
        private string _snapshotJsonPath = string.Empty;

        public ObservableCollection<ProcessEntry> Processes { get; } = new();
        public ObservableCollection<ProcessEntry> FilteredProcesses { get; } = new();
        public ObservableCollection<ProcessTreeNode> ProcessTreeRoots { get; } = new();

        public IEnumerable<ProcessAnalyzerFilterPreset> FilterPresets { get; } = Enum.GetValues<ProcessAnalyzerFilterPreset>();

        public bool IsAutoRefreshEnabled
        {
            get => _autoRefreshEnabled;
            set { _autoRefreshEnabled = value; OnPropertyChanged(); OnPropertyChanged(nameof(AutoRefreshLabel)); }
        }

        public string AutoRefreshLabel => _autoRefreshEnabled ? "Pause refresh" : "Resume refresh";

        public bool InvestigationMode
        {
            get => _investigationMode;
            set
            {
                _investigationMode = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(InvestigationLabel));
                RestartAutoRefreshTimer();
            }
        }

        public string InvestigationLabel => InvestigationMode ? "Investigation ON" : "Investigation";

        public bool FreezeSnapshot
        {
            get => _freezeSnapshot;
            set { _freezeSnapshot = value; OnPropertyChanged(); OnPropertyChanged(nameof(FreezeLabel)); }
        }

        public string FreezeLabel => _freezeSnapshot ? "Unfreeze" : "Freeze";

        public bool TreeViewMode
        {
            get => _treeViewMode;
            set { _treeViewMode = value; OnPropertyChanged(); BuildProcessTree(); }
        }

        public bool DeepScanEnabled
        {
            get => _deepScanEnabled;
            set { _deepScanEnabled = value; OnPropertyChanged(); }
        }

        public bool IsLoading
        {
            get => _isLoading;
            set { _isLoading = value; OnPropertyChanged(); OnPropertyChanged(nameof(IsIdle)); }
        }

        public bool IsIdle => !_isLoading;

        public string StatusText
        {
            get => _statusText;
            set { _statusText = value; OnPropertyChanged(); }
        }

        public string FilterText
        {
            get => _filterText;
            set { _filterText = value; OnPropertyChanged(); ApplyFilter(); }
        }

        public ProcessAnalyzerFilterPreset FilterPreset
        {
            get => _filterPreset;
            set { _filterPreset = value; OnPropertyChanged(); ApplyFilter(); }
        }

        public ProcessEntry? SelectedProcess
        {
            get => _selectedProcess;
            set
            {
                _selectedProcess = value;
                OnPropertyChanged();
                _ = LoadDetailAsync(value);
            }
        }

        public ProcessDetail? SelectedDetail
        {
            get => _selectedDetail;
            set { _selectedDetail = value; OnPropertyChanged(); }
        }

        public string DetailStatusText
        {
            get => _detailStatusText;
            set { _detailStatusText = value; OnPropertyChanged(); }
        }

        public IEnumerable<FilterPresetOption> FilterPresetOptions { get; } = new[]
        {
            new FilterPresetOption("All processes", ProcessAnalyzerFilterPreset.All),
            new FilterPresetOption("High CPU (>=10%)", ProcessAnalyzerFilterPreset.HighCpu),
            new FilterPresetOption("High RAM (>=500 MB)", ProcessAnalyzerFilterPreset.HighRam),
            new FilterPresetOption("Not responding", ProcessAnalyzerFilterPreset.NotResponding),
            new FilterPresetOption("Unsigned (deep scan)", ProcessAnalyzerFilterPreset.Unsigned),
            new FilterPresetOption("Writable path", ProcessAnalyzerFilterPreset.SuspiciousPath),
            new FilterPresetOption("No image path", ProcessAnalyzerFilterPreset.NoPath),
            new FilterPresetOption("Risk: caution/warning", ProcessAnalyzerFilterPreset.RiskWarning),
            new FilterPresetOption("In startup", ProcessAnalyzerFilterPreset.InStartup),
            new FilterPresetOption("New since investigation", ProcessAnalyzerFilterPreset.NewSinceInvestigation),
        };

        public sealed class FilterPresetOption
        {
            public FilterPresetOption(string label, ProcessAnalyzerFilterPreset value)
            {
                Label = label;
                Value = value;
            }

            public string Label { get; }
            public ProcessAnalyzerFilterPreset Value { get; }
        }

        private static string ScriptPath => WorkflowViewModelBase.GetScriptPath("ProcessAnalyzer.ps1");

        public bool CanViewSnapshotReport => Processes.Count > 0;

        public ICommand RefreshCommand => new RelayCommand(async () => await LoadAsync(silent: false));
        public ICommand KillCommand => new RelayCommand<ProcessEntry>(async p => await KillAsync(p));
        public ICommand ToggleAutoRefreshCommand => new RelayCommand(async () =>
        {
            IsAutoRefreshEnabled = !IsAutoRefreshEnabled;
            if (IsAutoRefreshEnabled) _autoRefreshTimer?.Start();
            else _autoRefreshTimer?.Stop();
            await Task.CompletedTask;
        });
        public ICommand ToggleFreezeCommand => new RelayCommand(async () =>
        {
            FreezeSnapshot = !FreezeSnapshot;
            if (FreezeSnapshot)
                _autoRefreshTimer?.Stop();
            else if (IsAutoRefreshEnabled)
                _autoRefreshTimer?.Start();
            await Task.CompletedTask;
        });
        public ICommand ToggleInvestigationCommand => new RelayCommand(async () =>
        {
            InvestigationMode = !InvestigationMode;
            _knownPids.Clear();
            await LoadAsync(silent: false);
        });
        public ICommand OpenReportCommand => new RelayCommand(async () => await OpenSnapshotReportAsync());
        public ICommand OpenPdfReportCommand => new RelayCommand(async () => await OpenSnapshotReportAsync());
        public ICommand OpenStartupManagerCommand => new RelayCommand(async () =>
        {
            NavigationService.Request("StartupManager");
            await Task.CompletedTask;
        });
        public ICommand OpenMalwareCleanupCommand => new RelayCommand(async () =>
        {
            NavigationService.Request("MalwareCleanup");
            await Task.CompletedTask;
        });
        public ICommand CstScanSelectedCommand => new RelayCommand(async () => await CstScanSelectedAsync());
        public ICommand OpenFileLocationCommand => new RelayCommand(async () => await OpenFileLocationAsync());
        public ICommand CopyPathCommand => new RelayCommand(async () => await CopyPathAsync());

        public void ApplyNavigationContext(string? context)
        {
            if (string.IsNullOrWhiteSpace(context))
                return;

            FilterPreset = context.ToUpperInvariant() switch
            {
                "HIGHCPU" => ProcessAnalyzerFilterPreset.HighCpu,
                "HIGHRAM" => ProcessAnalyzerFilterPreset.HighRam,
                "RISKWARNING" => ProcessAnalyzerFilterPreset.RiskWarning,
                "SUSPICIOUS" => ProcessAnalyzerFilterPreset.RiskWarning,
                _ => ProcessAnalyzerFilterPreset.All
            };

            if (context.Equals("Investigation", StringComparison.OrdinalIgnoreCase))
                InvestigationMode = true;
        }

        public async Task LoadAsync(bool silent = false)
        {
            if (FreezeSnapshot && silent)
                return;

            if (!silent) IsLoading = true;
            if (!silent) StatusText = "Loading processes...";

            try
            {
                var sampleMs = InvestigationMode ? InvestigationSampleMs : NormalSampleMs;
                var deep = DeepScanEnabled ? "-DeepScan" : string.Empty;
                var (json, psErr) = await PowerShellService.QueryAsync(
                    $"& '{ScriptPath}' -Action List -SampleMs {sampleMs} {deep}");

                if (!string.IsNullOrWhiteSpace(psErr) && string.IsNullOrWhiteSpace(json))
                {
                    Application.Current.Dispatcher.Invoke(() =>
                        StatusText = $"PowerShell error: {psErr.Trim()}");
                    return;
                }

                ProcessEntry[]? procs = null;
                if (!string.IsNullOrWhiteSpace(json))
                {
                    procs = TryDeserializeProcessList(json);
                    if (procs == null)
                    {
                        Application.Current.Dispatcher.Invoke(() =>
                            StatusText = "Could not parse process list JSON.");
                        return;
                    }
                }

                if (procs != null && procs.Length > 0)
                {
                    var wmiMap = await Task.Run(ProcessWmiEnricher.QueryAll);
                    foreach (var p in procs)
                    {
                        if (wmiMap.TryGetValue(p.Pid, out var wmi))
                            ProcessWmiEnricher.ApplyToEntry(p, wmi);
                    }
                }

                var selectedPid = _preserveSelectedPid ?? SelectedProcess?.Pid;

                Application.Current.Dispatcher.Invoke(() =>
                {
                    Processes.Clear();
                    if (procs != null)
                    {
                        foreach (var p in procs
                                     .GroupBy(x => x.Pid)
                                     .Select(g => g.First())
                                     .OrderByDescending(x => x.RamMB))
                        {
                            if (InvestigationMode && _knownPids.Count > 0 && !_knownPids.Contains(p.Pid))
                                p.IsNew = true;
                            Processes.Add(p);
                        }
                    }

                    ApplyFilter();
                    OnPropertyChanged(nameof(CanViewSnapshotReport));
                    if (TreeViewMode)
                        BuildProcessTree();

                    if (selectedPid.HasValue)
                    {
                        var restored = FilteredProcesses.FirstOrDefault(p => p.Pid == selectedPid.Value)
                                         ?? Processes.FirstOrDefault(p => p.Pid == selectedPid.Value);
                        if (restored != null)
                            SelectedProcess = restored;
                    }

                    if (InvestigationMode && _knownPids.Count == 0)
                        _knownPids = Processes.Select(p => p.Pid).ToHashSet();

                    if (!silent || InvestigationMode)
                        UpdateStatusText();
                });

                _preserveSelectedPid = null;

                if (Processes.Count > 0)
                    _ = AutoSaveSnapshotReportAsync();
            }
            catch (Exception ex)
            {
                if (!silent)
                {
                    Application.Current.Dispatcher.Invoke(() =>
                        StatusText = $"Error: {ex.Message}");
                }
            }
            finally
            {
                if (!silent) IsLoading = false;
            }
        }

        private static readonly JsonSerializerSettings DetailJsonSettings = new()
        {
            MetadataPropertyHandling = MetadataPropertyHandling.Ignore
        };

        private async Task LoadDetailAsync(ProcessEntry? entry)
        {
            if (entry == null)
            {
                Application.Current.Dispatcher.Invoke(() =>
                {
                    SelectedDetail = null;
                    DetailStatusText = "Select a process for details.";
                });
                return;
            }

            var loadId = Interlocked.Increment(ref _detailLoadSerial);

            var wmi = await Task.Run(() => ProcessWmiEnricher.QueryOne(entry.Pid));
            if (wmi != null)
                ProcessWmiEnricher.ApplyToEntry(entry, wmi);

            var shell = CreateDetailShell(entry);
            if (wmi != null)
                ProcessWmiEnricher.ApplyToDetail(shell, wmi);

            PublishSelectedDetail(shell, $"Loading PID {entry.Pid}...");

            try
            {
                var (json, _) = await PowerShellService.QueryAsync(
                    $"& '{ScriptPath}' -Action Detail -TargetPid {entry.Pid}");

                if (loadId != _detailLoadSerial)
                    return;

                json = TryExtractJsonObject(json);
                if (!string.IsNullOrWhiteSpace(json))
                {
                    var loaded = JsonConvert.DeserializeObject<ProcessDetail>(json, DetailJsonSettings);
                    if (loaded != null)
                        MergeDetailPayload(shell, loaded);
                }

                if (wmi != null)
                    ProcessWmiEnricher.ApplyToDetail(shell, wmi);
            }
            catch (Exception ex)
            {
                if (loadId != _detailLoadSerial)
                    return;

                PublishSelectedDetail(shell, $"Detail error: {ex.Message}  |  Showing WMI/list data.");
                return;
            }

            if (loadId != _detailLoadSerial)
                return;

            PublishSelectedDetail(shell, $"PID {shell.Pid}  |  Risk: {shell.RiskBand} ({shell.RiskScore})");
        }

        private void PublishSelectedDetail(ProcessDetail detail, string statusText)
        {
            var snapshot = CloneDetail(detail);
            Application.Current.Dispatcher.Invoke(() =>
            {
                SelectedDetail = snapshot;
                DetailStatusText = statusText;
            });
        }

        private static ProcessDetail CloneDetail(ProcessDetail source)
        {
            var clone = new ProcessDetail
            {
                Pid = source.Pid,
                Name = source.Name,
                FilePath = source.FilePath,
                StartupCommandLine = source.StartupCommandLine,
                ParentPid = source.ParentPid,
                SessionId = source.SessionId,
                StartTime = source.StartTime,
                UserName = source.UserName,
                IsSigned = source.IsSigned,
                SignatureChecked = source.SignatureChecked,
                Arch = source.Arch,
                RamMB = source.RamMB,
                Status = source.Status,
                RiskScore = source.RiskScore,
                RiskBand = source.RiskBand,
                RiskFlags = source.RiskFlags,
                InStartup = source.InStartup,
                Sha256 = source.Sha256,
            };

            foreach (var link in source.ParentChain)
                clone.ParentChain.Add(link);
            foreach (var svc in source.Services)
                clone.Services.Add(svc);
            foreach (var mod in source.Modules)
                clone.Modules.Add(mod);

            return clone;
        }

        private static ProcessDetail CreateDetailShell(ProcessEntry entry) => new()
        {
            Pid = entry.Pid,
            Name = entry.Name,
            FilePath = entry.FilePath,
            StartupCommandLine = entry.CommandLine,
            ParentPid = entry.ParentPid,
            SessionId = entry.SessionId,
            StartTime = entry.StartTime,
            RiskScore = entry.RiskScore,
            RiskBand = entry.RiskBand,
            RiskFlags = entry.RiskFlags,
            RamMB = entry.RamMB,
            InStartup = entry.InStartup,
            IsSigned = entry.IsSigned,
            SignatureChecked = entry.SignatureChecked,
            Status = entry.Status,
            Arch = entry.Arch,
        };

        private static void MergeDetailPayload(ProcessDetail shell, ProcessDetail loaded)
        {
            shell.FilePath = PreferNonEmpty(loaded.FilePath, shell.FilePath);
            shell.StartupCommandLine = PreferNonEmpty(loaded.StartupCommandLine, shell.StartupCommandLine);
            if (loaded.SessionId != 0)
                shell.SessionId = loaded.SessionId;
            if (loaded.ParentPid != 0)
                shell.ParentPid = loaded.ParentPid;
            shell.StartTime = PreferNonEmpty(loaded.StartTime, shell.StartTime);
            shell.UserName = PreferNonEmpty(loaded.UserName, shell.UserName);
            if (loaded.SignatureChecked)
            {
                shell.IsSigned = loaded.IsSigned;
                shell.SignatureChecked = true;
            }
            shell.Arch = PreferNonEmpty(loaded.Arch, shell.Arch);
            if (loaded.RamMB > 0)
                shell.RamMB = loaded.RamMB;
            shell.Status = PreferNonEmpty(loaded.Status, shell.Status);
            if (!string.IsNullOrWhiteSpace(loaded.RiskBand))
            {
                shell.RiskScore = loaded.RiskScore;
                shell.RiskBand = loaded.RiskBand;
                shell.RiskFlags = loaded.RiskFlags;
            }
            shell.InStartup = loaded.InStartup;
            shell.Sha256 = PreferNonEmpty(loaded.Sha256, shell.Sha256);
            if (loaded.ParentChain.Count > 0)
                shell.ParentChain = loaded.ParentChain;
            if (loaded.Services.Count > 0)
                shell.Services = loaded.Services;
            if (loaded.Modules.Count > 0)
                shell.Modules = loaded.Modules;
        }

        private static string PreferNonEmpty(string? value, string fallback)
            => string.IsNullOrWhiteSpace(value) ? fallback : value;

        private static ProcessEntry[]? TryDeserializeProcessList(string? json)
        {
            if (string.IsNullOrWhiteSpace(json))
                return null;

            var trimmed = json.Trim();
            var candidates = new[] { trimmed, TryExtractJsonArray(trimmed) };

            foreach (var candidate in candidates)
            {
                if (string.IsNullOrWhiteSpace(candidate))
                    continue;

                var normalized = candidate.TrimStart().StartsWith("[") ? candidate : $"[{candidate}]";
                try
                {
                    return JsonConvert.DeserializeObject<ProcessEntry[]>(normalized);
                }
                catch (JsonException)
                {
                    /* try next candidate */
                }
            }

            return null;
        }

        private static string? TryExtractJsonObject(string? rawOutput)
        {
            if (string.IsNullOrWhiteSpace(rawOutput))
                return null;

            var trimmed = rawOutput.Trim();
            if (trimmed.StartsWith("{", StringComparison.Ordinal))
            {
                try
                {
                    JsonConvert.DeserializeObject(trimmed);
                    return trimmed;
                }
                catch (JsonException)
                {
                    /* fall through to balanced scan */
                }
            }

            return ExtractBalancedJson(trimmed, '{', '}');
        }

        private static string? TryExtractJsonArray(string? rawOutput)
        {
            if (string.IsNullOrWhiteSpace(rawOutput))
                return null;

            var trimmed = rawOutput.Trim();
            if (trimmed.StartsWith("[", StringComparison.Ordinal))
            {
                try
                {
                    JsonConvert.DeserializeObject(trimmed);
                    return trimmed;
                }
                catch (JsonException)
                {
                    /* fall through to balanced scan */
                }
            }

            return ExtractBalancedJson(trimmed, '[', ']');
        }

        private static string? ExtractBalancedJson(string raw, char open, char close)
        {
            var start = raw.IndexOf(open);
            if (start < 0)
                return null;

            var depth = 0;
            var inString = false;
            var escape = false;

            for (var i = start; i < raw.Length; i++)
            {
                var c = raw[i];
                if (escape)
                {
                    escape = false;
                    continue;
                }

                if (inString)
                {
                    if (c == '\\')
                        escape = true;
                    else if (c == '"')
                        inString = false;
                    continue;
                }

                if (c == '"')
                {
                    inString = true;
                    continue;
                }

                if (c == open)
                    depth++;
                else if (c == close)
                {
                    depth--;
                    if (depth == 0)
                        return raw.Substring(start, i - start + 1);
                }
            }

            return null;
        }

        private async Task KillAsync(ProcessEntry? p)
        {
            if (p == null) return;

            if (ProtectedProcessNames.Contains(p.Name) || p.Pid <= 4)
            {
                MessageBox.Show(
                    $"Refusing to terminate protected process {p.Name} (PID {p.Pid}).",
                    "Process Analyzer",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return;
            }

            var confirm = MessageBox.Show(
                $"Terminate {p.Name} (PID {p.Pid})?\n\n{p.FilePath}",
                "Confirm terminate",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);
            if (confirm != MessageBoxResult.Yes)
                return;

            _preserveSelectedPid = null;
            StatusText = $"Terminating PID {p.Pid}...";
            var result = await PowerShellService.ExecuteAsync($"& '{ScriptPath}' -Action Kill -TargetPid {p.Pid}");
            if (!result.Success)
            {
                StatusText = $"Terminate failed: {FormatExecError(result)}";
                return;
            }

            Processes.Remove(p);
            FilteredProcesses.Remove(p);
            SelectedProcess = null;
            SelectedDetail = null;
            StatusText = $"Terminated: {p.Name} (PID {p.Pid})";
            if (TreeViewMode)
                BuildProcessTree();
        }

        private async Task OpenSnapshotReportAsync()
        {
            if (!CanViewSnapshotReport)
            {
                MessageBox.Show(
                    "Load processes first, then open the report.",
                    "Open Report",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            try
            {
                await EnsureSnapshotPdfAsync();
                ShellFileOpenHelper.OpenWithDefaultApplication(_snapshotPdfPath);
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    $"Unable to open the report:\n{ex.Message}",
                    "Open Report",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }

        private async Task AutoSaveSnapshotReportAsync()
        {
            try
            {
                await EnsureSnapshotPdfAsync();
            }
            catch
            {
                /* PDF generation is best-effort when processes load */
            }
        }

        private async Task EnsureSnapshotReportsAsync()
        {
            var document = BuildProcessSnapshotDocument();
            _snapshotReportPaths = await Task.Run(() =>
                TabularScanReportService.EnsureReports(document, _snapshotReportBaseName));
            _snapshotReportBaseName = _snapshotReportPaths.BaseName;
            _snapshotJsonPath = _snapshotReportPaths.JsonPath;
            _snapshotPdfPath = _snapshotReportPaths.PdfPath;
        }

        private async Task EnsureSnapshotPdfAsync()
        {
            await EnsureSnapshotReportsAsync();
            if (File.Exists(_snapshotPdfPath))
                return;

            var document = BuildProcessSnapshotDocument();
            string? error = null;
            var generated = await Task.Run(() =>
                TabularScanReportService.TryGeneratePdf(document, _snapshotPdfPath, out error));
            if (!generated)
                throw new InvalidOperationException(error ?? "Unknown PDF generation error.");
        }

        private TabularScanReportDocument BuildProcessSnapshotDocument()
        {
            var warningCount = FilteredProcesses.Count(p =>
                p.RiskBand.Equals("Warning", StringComparison.OrdinalIgnoreCase)
                || p.RiskBand.Equals("Caution", StringComparison.OrdinalIgnoreCase));
            var overall = warningCount > 0 ? "Warning" : "Healthy";
            var headers = new[]
            {
                "Process", "PID", "CPU", "RAM", "Path", "Signed", "Risk", "Status", "User", "Startup"
            };
            var rows = FilteredProcesses
                .Select(p => (IReadOnlyList<string>)new[]
                {
                    p.Name,
                    p.Pid.ToString(),
                    p.CpuDisplay,
                    p.RamDisplay,
                    p.FilePath,
                    p.SignedDisplay,
                    p.RiskBand,
                    p.Status,
                    p.UserName,
                    p.InStartup ? "Yes" : "No"
                })
                .ToList();

            return new TabularScanReportDocument
            {
                WorkflowName = "ProcessAnalyzer_Snapshot",
                Title = "Process Analyzer Snapshot",
                Summary = StatusText,
                OverallHealth = overall,
                GeneratedAt = DateTime.Now,
                ColumnHeaders = headers,
                Rows = rows,
                Metrics = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                {
                    ["Processes"] = FilteredProcesses.Count.ToString(),
                    ["Filter"] = FilterPreset.ToString(),
                    ["Investigation"] = InvestigationMode ? "On" : "Off"
                }
            };
        }

        private async Task ExportSnapshotCsvAsync(string path)
        {
            var sampleMs = InvestigationMode ? InvestigationSampleMs : NormalSampleMs;
            var deep = DeepScanEnabled ? "-DeepScan" : string.Empty;
            var result = await PowerShellService.ExecuteAsync(
                $"& '{ScriptPath}' -Action Export -SampleMs {sampleMs} {deep} -OutputPath \"{path}\" -Format Csv");
            if (!result.Success)
                throw new InvalidOperationException(FormatExecError(result));
        }

        private async Task CstScanSelectedAsync()
        {
            var path = ResolveSelectedImagePath(SelectedDetail, SelectedProcess);
            if (string.IsNullOrWhiteSpace(path))
            {
                MessageBox.Show("Selected process has no image path to scan.", "CST Scan",
                    MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            StatusText = "Running CST custom scan on selected file...";
            var result = await PowerShellService.ExecuteAsync(
                $"& '{ScriptPath}' -Action CstScan -TargetPath \"{path}\"");

            if (!result.Success)
            {
                StatusText = $"CST scan failed: {FormatExecError(result)}";
                MessageBox.Show(FormatExecError(result), "CST Scan", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            StatusText = "CST scan completed.";
            var processName = SelectedProcess?.Name ?? SelectedDetail?.Name ?? "Selected process";
            var owner = Application.Current?.Windows.OfType<Window>().FirstOrDefault(window => window.IsActive);
            if (ProcessAnalyzerCstResultService.TryBuildPresentation(result.Output, path, processName, out var presentation, out _))
            {
                var artifactPath = CstStructuredResultsService.ResolveArtifactPathFromStepOutput(result.Output)
                    ?? FindLatestCstArtifactPath();
                WorkOrderService.TryRecordCstScanRun(artifactPath, path, presentation.Verdict);
            }

            ProcessAnalyzerCstResultService.TryShowResults(result.Output, path, processName, owner);
        }

        private static string? FindLatestCstArtifactPath()
        {
            var cstDir = ReportPathHelper.GetCstDataRoot();
            if (!Directory.Exists(cstDir))
                return null;

            return Directory.GetFiles(cstDir, "CST_Result_*.json")
                .OrderByDescending(File.GetLastWriteTimeUtc)
                .FirstOrDefault();
        }

        private Task OpenFileLocationAsync()
        {
            var path = ResolveSelectedImagePath(SelectedDetail, SelectedProcess);
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            {
                MessageBox.Show("No accessible file path for this process.", "Process Analyzer",
                    MessageBoxButton.OK, MessageBoxImage.Information);
                return Task.CompletedTask;
            }

            try
            {
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "explorer.exe",
                    Arguments = $"/select,\"{path}\"",
                    UseShellExecute = true
                });
            }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "Open file location", MessageBoxButton.OK, MessageBoxImage.Warning);
            }

            return Task.CompletedTask;
        }

        private Task CopyPathAsync()
        {
            var path = ResolveSelectedImagePath(SelectedDetail, SelectedProcess);
            if (string.IsNullOrWhiteSpace(path))
                return Task.CompletedTask;

            try { Clipboard.SetText(path); StatusText = "Path copied."; }
            catch { }
            return Task.CompletedTask;
        }

        public void StartAutoRefresh()
        {
            RestartAutoRefreshTimer();
        }

        public void StopAutoRefresh()
        {
            if (_autoRefreshTimer == null) return;
            _autoRefreshTimer.Stop();
            _autoRefreshTimer.Dispose();
            _autoRefreshTimer = null;
        }

        private void RestartAutoRefreshTimer()
        {
            StopAutoRefresh();
            var interval = InvestigationMode ? InvestigationRefreshMs : NormalRefreshMs;
            _autoRefreshTimer = new System.Timers.Timer(interval);
            _autoRefreshTimer.AutoReset = true;
            _autoRefreshTimer.Elapsed += (_, _) => _ = RefreshFromTimerAsync();
            if (IsAutoRefreshEnabled && !FreezeSnapshot)
                _autoRefreshTimer.Start();
        }

        private async Task RefreshFromTimerAsync()
        {
            if (!IsAutoRefreshEnabled || FreezeSnapshot) return;
            if (!await _autoRefreshGate.WaitAsync(0)) return;
            try { await LoadAsync(silent: true); }
            finally { _autoRefreshGate.Release(); }
        }

        private void ApplyFilter()
        {
            var q = FilterText.Trim().ToLowerInvariant();
            FilteredProcesses.Clear();

            var seen = new HashSet<int>();
            foreach (var p in Processes)
            {
                if (!seen.Add(p.Pid))
                    continue;

                if (!MatchesPreset(p))
                    continue;

                if (!string.IsNullOrEmpty(q))
                {
                    var hit = p.Name.Contains(q, StringComparison.OrdinalIgnoreCase)
                              || p.Company.Contains(q, StringComparison.OrdinalIgnoreCase)
                              || p.FilePath.Contains(q, StringComparison.OrdinalIgnoreCase)
                              || p.CommandLine.Contains(q, StringComparison.OrdinalIgnoreCase)
                              || p.UserName.Contains(q, StringComparison.OrdinalIgnoreCase)
                              || p.RiskFlags.Contains(q, StringComparison.OrdinalIgnoreCase)
                              || p.Pid.ToString().Contains(q, StringComparison.OrdinalIgnoreCase);
                    if (!hit) continue;
                }

                FilteredProcesses.Add(p);
            }

            if (TreeViewMode)
                BuildProcessTree();
        }

        private bool MatchesPreset(ProcessEntry p)
        {
            return FilterPreset switch
            {
                ProcessAnalyzerFilterPreset.HighCpu => p.CpuPercent >= 10,
                ProcessAnalyzerFilterPreset.HighRam => p.RamMB >= 500,
                ProcessAnalyzerFilterPreset.NotResponding => p.Status.Equals("Not Responding", StringComparison.OrdinalIgnoreCase),
                ProcessAnalyzerFilterPreset.Unsigned => p.SignatureChecked && p.IsSigned == false,
                ProcessAnalyzerFilterPreset.SuspiciousPath => ContainsSuspiciousPath(p.FilePath),
                ProcessAnalyzerFilterPreset.NoPath => string.IsNullOrWhiteSpace(p.FilePath),
                ProcessAnalyzerFilterPreset.RiskWarning => p.RiskBand.Equals("Warning", StringComparison.OrdinalIgnoreCase)
                    || p.RiskBand.Equals("Caution", StringComparison.OrdinalIgnoreCase),
                ProcessAnalyzerFilterPreset.InStartup => p.InStartup,
                ProcessAnalyzerFilterPreset.NewSinceInvestigation => p.IsNew,
                _ => true
            };
        }

        private void UpdateStatusText()
        {
            if (Processes.Count == 0)
            {
                StatusText = "No processes returned";
                return;
            }

            var newCount = Processes.Count(p => p.IsNew);
            var newSuffix = newCount > 0
                ? $"  |  {newCount} new since investigation"
                : string.Empty;

            StatusText =
                $"{Processes.Count} processes  |  Total RAM: {SizeDisplayFormatter.FormatMegabytes(Processes.Sum(p => p.RamMB))}{newSuffix}";
        }

        private static bool ContainsSuspiciousPath(string path)
        {
            if (string.IsNullOrWhiteSpace(path)) return false;
            return path.Contains(@"\Temp\", StringComparison.OrdinalIgnoreCase)
                   || path.Contains(@"\Downloads\", StringComparison.OrdinalIgnoreCase)
                   || path.Contains(@"AppData\Local\Temp", StringComparison.OrdinalIgnoreCase);
        }

        private void BuildProcessTree()
        {
            ProcessTreeRoots.Clear();
            var source = (FilteredProcesses.Count > 0 ? FilteredProcesses : Processes)
                .GroupBy(p => p.Pid)
                .Select(g => g.First())
                .ToList();
            if (source.Count == 0)
                return;

            var nodes = new Dictionary<int, ProcessTreeNode>();
            foreach (var p in source)
                nodes[p.Pid] = new ProcessTreeNode { Entry = p };

            var roots = new List<ProcessTreeNode>();
            foreach (var node in nodes.Values.OrderBy(n => n.Entry?.Name))
            {
                var parentPid = node.Entry?.ParentPid ?? 0;
                if (parentPid > 0 && nodes.TryGetValue(parentPid, out var parent))
                    parent.Children.Add(node);
                else
                    roots.Add(node);
            }

            foreach (var root in roots.OrderBy(r => r.DisplayName))
                ProcessTreeRoots.Add(root);
        }

        private static string? ResolveSelectedImagePath(ProcessDetail? detail, ProcessEntry? process)
        {
            if (!string.IsNullOrWhiteSpace(detail?.FilePath))
                return detail.FilePath.Trim();
            if (!string.IsNullOrWhiteSpace(process?.FilePath))
                return process.FilePath.Trim();
            return null;
        }

        private static string FormatExecError(PowerShellExecutionResult result)
        {
            if (!string.IsNullOrWhiteSpace(result.Error)) return result.Error;
            if (!string.IsNullOrWhiteSpace(result.ExceptionMessage)) return result.ExceptionMessage;
            if (!string.IsNullOrWhiteSpace(result.Output)) return result.Output;
            return "Unknown execution error";
        }

        public event PropertyChangedEventHandler? PropertyChanged;
        protected void OnPropertyChanged([CallerMemberName] string? n = null)
            => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
    }
}
