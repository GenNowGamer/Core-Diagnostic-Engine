using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;
using ToolkitGUI;
using ToolkitGUI.Models;
using ToolkitGUI.Services;

namespace ToolkitGUI.ViewModels
{
    public sealed class SystemHealthViewModel : WorkflowViewModelBase
    {
        private static readonly JsonSerializerOptions JsonOpts = new() { PropertyNameCaseInsensitive = true };
        private static readonly Regex HealthPhaseRegex = new(
            @"^\[HEALTH:PHASE\]\s*(?<json>\{.*\})$",
            RegexOptions.Compiled);
        private static readonly Regex HealthRecommendationRegex = new(
            @"^\[HEALTH:RECOMMENDATION\]\s*(?<json>\{.*\})$",
            RegexOptions.Compiled);

        private SystemHealthViewState _viewState = SystemHealthViewState.Picker;
        private string _overallHealthDisplay = "—";
        private Brush _overallHealthBrush = new SolidColorBrush(Color.FromRgb(0x5A, 0x6B, 0x80));
        private string _estimatedMinutesDisplay = "0 min";
        private int _phaseIndex;
        private int _phaseTotal;
        private string _phaseLabel = string.Empty;
        private readonly Dictionary<string, string> _checkLabels = new(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, string> _checkCategories = new(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, int> _findingsDisplayRank = new(StringComparer.OrdinalIgnoreCase);
        private readonly HashSet<string> _recommendationKeys = new(StringComparer.OrdinalIgnoreCase);

        public ObservableCollection<HealthCheckCategoryViewModel> Categories { get; } = new();
        public ObservableCollection<HealthFindingViewModel> Findings { get; } = new();
        public ObservableCollection<HealthRecommendationViewModel> Recommendations { get; } = new();
        public ObservableCollection<HealthRecommendationViewModel> SelectedFindingRecommendations { get; } = new();
        public ObservableCollection<StructuredResultItemViewModel> SelectedAttentionItems { get; } = new();
        public ObservableCollection<FormattedResultSectionViewModel> SelectedFindingSections { get; } = new();
        public ObservableCollection<HealthActionViewModel> SelectedFindingActions { get; } = new();

        private readonly List<HealthCheckRecommendationDto> _catalogRecommendations = new();
        private HealthFindingViewModel? _selectedFinding;
        private string _selectedFindingGuidance = string.Empty;
        private string _selectedFindingHeadline = string.Empty;
        private string _selectedFindingPlainText = string.Empty;

        public HealthFindingViewModel? SelectedFinding
        {
            get => _selectedFinding;
            set
            {
                if (ReferenceEquals(_selectedFinding, value))
                    return;
                _selectedFinding = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(HasSelectedFinding));
                RefreshSelectedFindingPanel();
            }
        }

        public bool HasSelectedFinding => SelectedFinding != null;

        public bool HasSelectedFindingRecommendations => SelectedFindingRecommendations.Count > 0;

        public bool HasSelectedFindingSections => SelectedFindingSections.Count > 0;

        public bool HasSelectedFindingPlainText => !string.IsNullOrWhiteSpace(SelectedFindingPlainText);

        public bool HasSelectedFindingDetail => HasSelectedFindingSections || HasSelectedFindingPlainText;

        public bool ShowGenericDetailHeading =>
            HasSelectedFindingDetail
            && SelectedFinding is not { PreferNamedDetailSections: true };

        public string SelectedFindingPlainText
        {
            get => _selectedFindingPlainText;
            private set
            {
                _selectedFindingPlainText = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(HasSelectedFindingPlainText));
            }
        }

        public bool HasSelectedAttentionItems => SelectedAttentionItems.Count > 0;

        public bool HasSelectedFindingActions => SelectedFindingActions.Count > 0;

        public string SelectedFindingHeadline
        {
            get => _selectedFindingHeadline;
            private set { _selectedFindingHeadline = value; OnPropertyChanged(); }
        }

        public string SelectedFindingGuidance
        {
            get => _selectedFindingGuidance;
            private set { _selectedFindingGuidance = value; OnPropertyChanged(); }
        }

        public RelayCommand RunHealthCheckCommand { get; }
        public RelayCommand SelectRecommendedCommand { get; }
        public RelayCommand SelectQuickVitalsCommand { get; }
        public RelayCommand SelectDeepSystemCommand { get; }
        public RelayCommand SelectFullAuditCommand { get; }
        public RelayCommand SelectAllCommand { get; }
        public RelayCommand ClearAllCommand { get; }
        public RelayCommand BackToPickerCommand { get; }
        public RelayCommand OpenReportCommand { get; }
        public RelayCommand OpenPdfReportCommand { get; }

        public SystemHealthViewState ViewState
        {
            get => _viewState;
            private set
            {
                _viewState = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(IsPickerVisible));
                OnPropertyChanged(nameof(IsRunningVisible));
                OnPropertyChanged(nameof(IsResultsVisible));
            }
        }

        public bool IsPickerVisible => ViewState == SystemHealthViewState.Picker;
        public bool IsRunningVisible => ViewState == SystemHealthViewState.Running;
        public bool IsResultsVisible => ViewState == SystemHealthViewState.Results;

        public string EstimatedMinutesDisplay
        {
            get => _estimatedMinutesDisplay;
            private set { _estimatedMinutesDisplay = value; OnPropertyChanged(); }
        }

        public string PhaseLabel
        {
            get => _phaseLabel;
            private set { _phaseLabel = value; OnPropertyChanged(); }
        }

        public string OverallHealthDisplay
        {
            get => _overallHealthDisplay;
            private set { _overallHealthDisplay = value; OnPropertyChanged(); }
        }

        public Brush OverallHealthBrush
        {
            get => _overallHealthBrush;
            private set { _overallHealthBrush = value; OnPropertyChanged(); }
        }

        public SystemHealthViewModel()
        {
            RunHealthCheckCommand = new RelayCommand(RunHealthCheckAsync);
            SelectRecommendedCommand = new RelayCommand(() => { ApplyCatalogPreset("recommended"); return Task.CompletedTask; });
            SelectQuickVitalsCommand = new RelayCommand(() => { ApplyCatalogPreset("quick_vitals"); return Task.CompletedTask; });
            SelectDeepSystemCommand = new RelayCommand(() => { ApplyCatalogPreset("deep_system"); return Task.CompletedTask; });
            SelectFullAuditCommand = new RelayCommand(() => { ApplyCatalogPreset("full_audit"); return Task.CompletedTask; });
            SelectAllCommand = new RelayCommand(() => { SetAllAvailable(selected: true); return Task.CompletedTask; });
            ClearAllCommand = new RelayCommand(() => { SetAllAvailable(selected: false); return Task.CompletedTask; });
            BackToPickerCommand = new RelayCommand(() => { ViewState = SystemHealthViewState.Picker; return Task.CompletedTask; });
            OpenReportCommand = new RelayCommand(async () => { await OpenPdfReportAsync(); });
            OpenPdfReportCommand = new RelayCommand(async () => { await OpenPdfReportAsync(); });
            LoadCatalog();
            UpdateEstimatedMinutes();
        }

        protected override bool ShowWorkflowExecutionWindow => false;

        private void LoadCatalog()
        {
            Categories.Clear();
            _checkLabels.Clear();
            _checkCategories.Clear();
            _findingsDisplayRank.Clear();
            _catalogRecommendations.Clear();

            var path = ToolkitPaths.GetHealthCheckCatalogPath();
            if (!File.Exists(path))
            {
                return;
            }

            var json = File.ReadAllText(path);
            var catalog = JsonSerializer.Deserialize<HealthCheckCatalogDto>(json, JsonOpts);
            if (catalog?.Categories == null)
                return;

            var order = catalog.FindingsDisplayOrder is { Count: > 0 }
                ? catalog.FindingsDisplayOrder
                : DefaultFindingsDisplayOrder;
            for (var i = 0; i < order.Count; i++)
            {
                var id = order[i]?.Trim() ?? string.Empty;
                if (string.IsNullOrWhiteSpace(id) || _findingsDisplayRank.ContainsKey(id))
                    continue;
                _findingsDisplayRank[id] = i;
            }

            var isWinPe = IsWinPeMode();
            foreach (var cat in catalog.Categories)
            {
                var catVm = new HealthCheckCategoryViewModel
                {
                    Id = cat.Id ?? string.Empty,
                    Label = cat.Label ?? string.Empty
                };

                foreach (var check in cat.Checks ?? new List<HealthCheckEntryDto>())
                {
                    var id = check.Id ?? string.Empty;
                    _checkLabels[id] = check.Label ?? id;
                    _checkCategories[id] = catVm.Label;

                    var available = IsCheckAvailable(check.WinPe, isWinPe);
                    var item = new HealthCheckItemViewModel
                    {
                        CheckId = id,
                        CategoryId = catVm.Id,
                        Label = check.Label ?? id,
                        Description = check.Description ?? string.Empty,
                        EstimatedMinutes = check.EstimatedMinutes,
                        IsAvailable = available,
                        UnavailableReason = available ? string.Empty : GetUnavailableReason(check.WinPe, isWinPe)
                    };
                    item.PropertyChanged += (_, e) =>
                    {
                        if (e.PropertyName == nameof(HealthCheckItemViewModel.IsSelected))
                            UpdateEstimatedMinutes();
                    };
                    catVm.Checks.Add(item);
                }

                if (catVm.Checks.Count > 0)
                    Categories.Add(catVm);
            }

            if (catalog.Recommendations is { Count: > 0 })
                _catalogRecommendations.AddRange(catalog.Recommendations);
        }

        /// <summary>Fallback when catalog omits findingsDisplayOrder.</summary>
        private static readonly IReadOnlyList<string> DefaultFindingsDisplayOrder = new[]
        {
            "activation",
            "os_version",
            "system_info",
            "gpu_info",
            "cpu_load",
            "ram",
            "disk_space",
            "network_adapters",
            "audit_network_config",
            "windows_update_service",
            "event_errors_24h",
            "critical_events_7d",
            "audit_event_logs",
            "driver_signature_audit",
            "audit_drivers",
            "audit_pnp_devices",
            "audit_services",
            "audit_startup",
            "sec_autoruns",
            "audit_partition_table",
            "sec_hosts",
            "sec_browser_extensions",
            "sec_scheduled_tasks",
            "sec_browser_hijack",
            "sec_network_hijack",
            "audit_installed_software",
            "sec_security_tampering",
            "sec_remote_access"
        };

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

        private static bool IsCheckAvailable(string? winPeMode, bool isWinPe)
        {
            var mode = (winPeMode ?? "available").ToLowerInvariant();
            if (string.Equals(mode, "offline_registry", StringComparison.OrdinalIgnoreCase))
            {
                if (!isWinPe) return true;
                return string.Equals(
                    Environment.GetEnvironmentVariable("OFFLINE_REGISTRY_LOADED"),
                    "1",
                    StringComparison.OrdinalIgnoreCase);
            }

            return mode switch
            {
                "windows_only" => !isWinPe,
                "unavailable" => !isWinPe,
                _ => true
            };
        }

        private static string GetUnavailableReason(string? winPeMode, bool isWinPe)
        {
            if (!isWinPe) return "Not available on this system.";
            var mode = (winPeMode ?? "").ToLowerInvariant();
            if (string.Equals(mode, "offline_registry", StringComparison.OrdinalIgnoreCase))
            {
                return "WinPE: load an offline Windows installation (Option 2) to audit startup registry hives.";
            }

            return mode switch
            {
                "windows_only" => "N/A in WinPE (requires full Windows).",
                "unavailable" => "N/A in WinPE.",
                _ => "Unavailable."
            };
        }

        private void ApplyCatalogPreset(string presetName)
        {
            var path = ToolkitPaths.GetHealthCheckCatalogPath();
            if (!File.Exists(path)) return;

            var catalog = JsonSerializer.Deserialize<HealthCheckCatalogDto>(File.ReadAllText(path), JsonOpts);
            var preset = catalog?.Presets != null && catalog.Presets.TryGetValue(presetName, out var ids)
                ? ids
                : new List<string>();

            SetAllAvailable(false);
            foreach (var item in Categories.SelectMany(c => c.Checks))
            {
                if (item.IsAvailable && preset.Contains(item.CheckId, StringComparer.OrdinalIgnoreCase))
                    item.IsSelected = true;
            }
            UpdateEstimatedMinutes();
        }

        public void ApplyNavigationContext(string? context)
        {
            if (string.IsNullOrWhiteSpace(context))
                return;

            if (context.StartsWith("preset:", StringComparison.OrdinalIgnoreCase))
            {
                var presetName = context["preset:".Length..].Trim();
                if (presetName.Length == 0)
                    return;

                ViewState = SystemHealthViewState.Picker;
                ApplyCatalogPreset(presetName);
            }
        }

        private void SetAllAvailable(bool selected)
        {
            foreach (var item in Categories.SelectMany(c => c.Checks).Where(c => c.IsAvailable))
                item.IsSelected = selected;
            UpdateEstimatedMinutes();
        }

        private int GetSelectedAvailableCount()
            => Categories.SelectMany(c => c.Checks).Count(c => c.IsAvailable && c.IsSelected);

        private void UpdateEstimatedMinutes()
        {
            var total = Categories.SelectMany(c => c.Checks)
                .Where(c => c.IsAvailable && c.IsSelected)
                .Sum(c => c.EstimatedMinutes);
            EstimatedMinutesDisplay = total < 1
                ? "< 1 min estimated"
                : $"~{Math.Ceiling(total)} min estimated";
        }

        private async Task RunHealthCheckAsync()
        {
            var selected = Categories.SelectMany(c => c.Checks)
                .Where(c => c.IsAvailable && c.IsSelected)
                .Select(c => c.CheckId)
                .ToList();

            if (selected.Count == 0)
                return;

            Findings.Clear();
            Recommendations.Clear();
            SelectedFindingRecommendations.Clear();
            SelectedAttentionItems.Clear();
            SelectedFindingActions.Clear();
            SelectedFinding = null;
            _recommendationKeys.Clear();
            ViewState = SystemHealthViewState.Running;

            var csv = string.Join(",", selected);
            var script = GetScriptPath("SystemHealthCheck.ps1");
            var args = $"-SelectedChecks \"{csv}\"";

            await RunWorkflowAsync(
                script,
                args,
                operationTitle: "System Health Check",
                operationDescription: "Running selected diagnostic checks.");

            StructuredResultItems.Clear();
            HasStructuredResult = false;

            BuildResultsFromWorkflow();
            ViewState = SystemHealthViewState.Results;
        }

        protected override bool HandleLiveWorkflowOutput(string line)
        {
            if (string.IsNullOrWhiteSpace(line))
                return false;

            var phaseMatch = HealthPhaseRegex.Match(line.Trim());
            if (phaseMatch.Success)
            {
                try
                {
                    using var doc = JsonDocument.Parse(phaseMatch.Groups["json"].Value);
                    var root = doc.RootElement;
                    _phaseIndex = root.TryGetProperty("index", out var idx) ? idx.GetInt32() : 0;
                    _phaseTotal = root.TryGetProperty("total", out var tot) ? tot.GetInt32() : 0;
                    PhaseLabel = root.TryGetProperty("label", out var lbl) ? lbl.GetString() ?? string.Empty : string.Empty;
                    if (_phaseTotal > 0)
                    {
                        Progress = Math.Min(99, (int)Math.Round(_phaseIndex * 100.0 / _phaseTotal));
                        ProgressPercentText = $"{Progress}%";
                    }
                    ProgressCaption = $"Check {_phaseIndex} of {_phaseTotal}: {PhaseLabel}";
                }
                catch { }
                return true;
            }

            var recMatch = HealthRecommendationRegex.Match(line.Trim());
            if (recMatch.Success)
            {
                try
                {
                    using var doc = JsonDocument.Parse(recMatch.Groups["json"].Value);
                    var root = doc.RootElement;
                    var checkId = root.TryGetProperty("checkId", out var cid) ? cid.GetString() ?? "" : "";
                    var navTarget = root.TryGetProperty("navTarget", out var nav) ? nav.GetString() ?? "" : "";
                    var title = root.TryGetProperty("title", out var t) ? t.GetString() ?? "" : "";
                    var reason = root.TryGetProperty("reason", out var r) ? r.GetString() ?? "" : "";
                    if (string.IsNullOrWhiteSpace(navTarget))
                        return true;

                    var key = $"{checkId}|{navTarget}|{title}";
                    if (_recommendationKeys.Add(key))
                    {
                        Application.Current?.Dispatcher.Invoke(() =>
                        {
                            Recommendations.Add(new HealthRecommendationViewModel
                            {
                                CheckId = checkId,
                                Title = title,
                                Reason = reason,
                                NavTarget = navTarget,
                                NavTargetLabel = GetNavTargetLabel(navTarget),
                                OpenToolCommand = new RelayCommand(() => { NavigationService.Request(navTarget); return Task.CompletedTask; })
                            });
                        });
                    }
                }
                catch { }
                return true;
            }

            return base.HandleLiveWorkflowOutput(line);
        }

        private void BuildResultsFromWorkflow()
        {
            Findings.Clear();

            string? overall = null;
            try
            {
                if (!string.IsNullOrWhiteSpace(ResultJson) && ResultJson.TrimStart().StartsWith('{'))
                {
                    using var doc = JsonDocument.Parse(ResultJson);
                    if (doc.RootElement.TryGetProperty("OverallHealth", out var oh))
                        overall = oh.GetString();
                }
            }
            catch { }

            OverallHealthDisplay = string.IsNullOrWhiteSpace(overall) ? "Unknown" : overall!;
            OverallHealthBrush = overall?.ToUpperInvariant() switch
            {
                "HEALTHY" => new SolidColorBrush(Color.FromRgb(0x0D, 0x7A, 0x3E)),
                "WARNING" => new SolidColorBrush(Color.FromRgb(0x92, 0x68, 0x00)),
                "CRITICAL" => new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C)),
                _ => new SolidColorBrush(Color.FromRgb(0x5A, 0x6B, 0x80))
            };

            var built = new List<HealthFindingViewModel>();
            var originalIndex = 0;
            foreach (var step in ResultSteps)
            {
                var checkId = !string.IsNullOrWhiteSpace(step.CheckId) ? step.CheckId : (step.Name ?? string.Empty);
                var detail = step.Output;
                var stepName = step.Name ?? string.Empty;
                _checkLabels.TryGetValue(checkId, out var catalogLabel);
                var label = BuildFindingLabel(catalogLabel, stepName, checkId);
                var category = _checkCategories.TryGetValue(checkId, out var c) ? c : "Other";
                var formatted = WorkflowResultFormatter.Format(
                    stepName,
                    detail,
                    step.StructuredFindings);
                var formattedItems = formatted.AllItems
                    .Select(StructuredResultItemViewModel.FromFormattedItem)
                    .Where(item => !string.IsNullOrWhiteSpace(item.Name))
                    .ToList();

                built.Add(new HealthFindingViewModel
                {
                    CheckId = checkId,
                    StepName = step.Name ?? string.Empty,
                    CategoryLabel = category,
                    CheckLabel = label,
                    Status = step.Status,
                    Detail = detail,
                    DetailOverview = BuildHealthCheckOverview(formatted, detail, step.Status),
                    FormattedItems = formattedItems,
                    FormattedSections = FormattedResultSectionMapper.MapSections(formatted),
                    StatusBrush = BrushForStatus(step.Status),
                    DisplayOrder = originalIndex++
                });

                if (StructuredResultItemViewModel.IsDiagnosticIssueStatus(step.Status))
                {
                    AddStructuredResultItem(() =>
                        StructuredResultItemViewModel.FromDiagnosticFinding(step.Name, detail, step.Status));
                }
            }

            foreach (var finding in built
                         .OrderBy(f => GetFindingsDisplayRank(f.CheckId))
                         .ThenBy(f => f.DisplayOrder))
            {
                Findings.Add(finding);
            }

            if (Findings.Count == 0)
            {
                Findings.Add(new HealthFindingViewModel
                {
                    CheckId = string.Empty,
                    CategoryLabel = "Summary",
                    CheckLabel = "Health Check",
                    Status = OverallHealthDisplay,
                    Detail = ResultSummary,
                    StatusBrush = OverallHealthBrush
                });
            }

            SelectedFinding = Findings.FirstOrDefault();
        }

        private int GetFindingsDisplayRank(string? checkId)
        {
            if (string.IsNullOrWhiteSpace(checkId))
                return int.MaxValue;

            if (_findingsDisplayRank.TryGetValue(checkId, out var rank))
                return rank;

            // Legacy alias folded into system_info.
            if (string.Equals(checkId, "audit_system_info", StringComparison.OrdinalIgnoreCase)
                && _findingsDisplayRank.TryGetValue("system_info", out var systemInfoRank))
            {
                return systemInfoRank;
            }

            return int.MaxValue - 1000;
        }

        private static string BuildHealthCheckOverview(FormattedWorkflowOutput formatted, string? detail, string? status)
        {
            var overview = formatted.Overview ?? string.Empty;
            if (!string.IsNullOrWhiteSpace(overview)
                && overview.IndexOf("detail record", StringComparison.OrdinalIgnoreCase) < 0
                && overview.IndexOf("detail line", StringComparison.OrdinalIgnoreCase) < 0
                && overview.Length <= 200)
            {
                return overview;
            }

            foreach (var item in formatted.AllItems)
            {
                if (string.IsNullOrWhiteSpace(item.Title))
                {
                    continue;
                }

                if (!string.IsNullOrWhiteSpace(item.Subtitle))
                {
                    return $"{item.Title}: {item.Subtitle}";
                }

                if (!string.IsNullOrWhiteSpace(item.Notes))
                {
                    return $"{item.Title}: {item.Notes}";
                }
            }

            return SystemHealthReviewHelper.ExtractHeadline(detail, status);
        }

        private void RefreshSelectedFindingPanel()
        {
            SelectedFindingRecommendations.Clear();
            SelectedAttentionItems.Clear();
            SelectedFindingSections.Clear();
            SelectedFindingActions.Clear();
            SelectedFindingPlainText = string.Empty;
            OnPropertyChanged(nameof(HasSelectedFindingRecommendations));
            OnPropertyChanged(nameof(HasSelectedAttentionItems));
            OnPropertyChanged(nameof(HasSelectedFindingSections));
            OnPropertyChanged(nameof(HasSelectedFindingActions));

            if (SelectedFinding == null)
            {
                SelectedFindingHeadline = string.Empty;
                SelectedFindingGuidance = string.Empty;
                return;
            }

            SelectedFindingHeadline = !string.IsNullOrWhiteSpace(SelectedFinding.DetailOverview)
                ? SelectedFinding.DetailOverview
                : SystemHealthReviewHelper.ExtractHeadline(
                    SelectedFinding.Detail,
                    SelectedFinding.Status);

            var sections = SelectedFinding.FormattedSections?.ToList()
                ?? new List<FormattedResultSectionViewModel>();

            if (!sections.Any(section => section.HasItems || section.HasLines))
            {
                var flatItems = SelectedFinding.FormattedItems?
                    .Where(item => !string.IsNullOrWhiteSpace(item.Name))
                    .ToList() ?? new List<StructuredResultItemViewModel>();

                if (flatItems.Count > 0)
                {
                    sections.Add(new FormattedResultSectionViewModel
                    {
                        Title = "Technical details",
                        Items = flatItems
                    });
                }
            }

            foreach (var section in sections.Where(section => section.HasItems || section.HasLines))
                SelectedFindingSections.Add(section);

            if (SelectedFindingSections.Count == 0
                && !string.IsNullOrWhiteSpace(SelectedFinding.Detail))
            {
                SelectedFindingPlainText = WorkflowResultFormatter.BuildPlainText(
                    SelectedFinding.StepName,
                    SelectedFinding.Detail);
            }

            OnPropertyChanged(nameof(HasSelectedFindingSections));
            OnPropertyChanged(nameof(HasSelectedFindingDetail));
            OnPropertyChanged(nameof(ShowGenericDetailHeading));

            foreach (var item in SystemHealthReviewHelper.BuildAttentionItems(
                SelectedFinding.StepName,
                SelectedFinding.CheckId,
                SelectedFinding.Detail,
                SelectedFinding.Status,
                SelectedFinding.FormattedItems))
            {
                SelectedAttentionItems.Add(item);
            }

            foreach (var action in SystemHealthReviewHelper.BuildActions(SelectedFinding, _catalogRecommendations))
                SelectedFindingActions.Add(action);

            foreach (var rec in GetRecommendationsForFinding(SelectedFinding))
            {
                SelectedFindingRecommendations.Add(rec);
                if (SelectedFindingActions.Count == 0
                    && !SystemHealthReviewHelper.IsUsbSmartLimitationDetail(SelectedFinding.Detail)
                    && !string.IsNullOrWhiteSpace(rec.NavTarget)
                    && rec.OpenToolCommand != null)
                {
                    SelectedFindingActions.Add(new HealthActionViewModel
                    {
                        Label = rec.NavTargetLabel,
                        IsExternal = false,
                        Command = rec.OpenToolCommand
                    });
                }
            }

            OnPropertyChanged(nameof(HasSelectedFindingRecommendations));
            OnPropertyChanged(nameof(HasSelectedAttentionItems));
            OnPropertyChanged(nameof(HasSelectedFindingActions));

            SelectedFindingGuidance = SystemHealthReviewHelper.BuildGuidance(
                SelectedFinding,
                HasSelectedAttentionItems,
                HasSelectedFindingActions);
        }

        private IEnumerable<HealthRecommendationViewModel> GetRecommendationsForFinding(HealthFindingViewModel finding)
        {
            var forCheck = Recommendations
                .Where(r => string.Equals(r.CheckId, finding.CheckId, StringComparison.OrdinalIgnoreCase))
                .ToList();

            if (forCheck.Count == 0)
                return forCheck;

            if (forCheck.Count == 1)
                return forCheck;

            var detailMatches = forCheck
                .Where(r => RecommendationMatchesDetail(r, finding.Detail))
                .ToList();

            return detailMatches.Count > 0 ? detailMatches : forCheck;
        }

        private static bool RecommendationMatchesDetail(HealthRecommendationViewModel rec, string detail)
        {
            if (string.IsNullOrWhiteSpace(detail) || string.IsNullOrWhiteSpace(rec.Reason))
                return false;

            return detail.IndexOf(rec.Reason, StringComparison.OrdinalIgnoreCase) >= 0
                || rec.Reason.IndexOf(detail, StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private static string GetNavTargetLabel(string navTarget)
        {
            var section = navTarget.Contains(':') ? navTarget.Split(':')[0] : navTarget;
            return section switch
            {
                "TempFileCleaner" => "Temp File Cleaner",
                "SmartAnalyzer" => "S.M.A.R.T. Analyzer",
                "StartupManager" => "Startup Manager",
                "SystemHealth" => "System Health Check",
                "SystemAudit" => "System Health Check",
                "MalwareCleanup" => "Malware Cleanup",
                "DiagAndRepair" => "Diag & Repair",
                "HardwareDiagnostics" => "Diag & Repair",
                "FastFixes" => "Fast Fixes",
                "ProcessAnalyzer" => "Process Analyzer",
                _ => string.IsNullOrWhiteSpace(section) ? "Open Tool" : section
            };
        }

        private static string BuildFindingLabel(string? catalogLabel, string stepName, string checkId)
        {
            if (!string.IsNullOrWhiteSpace(catalogLabel)
                && !string.IsNullOrWhiteSpace(stepName)
                && !string.Equals(stepName, catalogLabel, StringComparison.OrdinalIgnoreCase))
            {
                return $"{catalogLabel} — {stepName}";
            }

            if (!string.IsNullOrWhiteSpace(stepName))
                return stepName;

            if (!string.IsNullOrWhiteSpace(catalogLabel))
                return catalogLabel;

            return string.IsNullOrWhiteSpace(checkId) ? "Unknown" : checkId;
        }

        private static Brush BrushForStatus(string? status) => status?.ToUpperInvariant() switch
        {
            "PASS" => new SolidColorBrush(Color.FromRgb(0x0D, 0x7A, 0x3E)),
            "WARN" => new SolidColorBrush(Color.FromRgb(0x92, 0x68, 0x00)),
            "FAIL" => new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C)),
            _ => new SolidColorBrush(Color.FromRgb(0x5A, 0x6B, 0x80))
        };
    }
}
