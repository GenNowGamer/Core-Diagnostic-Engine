using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Management;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Threading;
using Microsoft.Win32;
using System.Windows;
using System.Windows.Media;
using ToolkitGUI.Models;
using ToolkitGUI.Services;
using ToolkitGUI.Views;
using WinForms = System.Windows.Forms;

namespace ToolkitGUI.ViewModels
{
    // ── CHU Results ──────────────────────────────────────────────────────────
    public class ChuTestEntryViewModel
    {
        public bool   IsCategoryHeader { get; }
        public string Category       { get; }
        public string TestName       { get; }
        public string CatalogId      { get; }
        public string Status         { get; }
        public int    Errors         { get; }
        public string Details        { get; }
        public Brush  StatusColor    { get; }
        public bool   ShowDiagRepairLink { get; }
        public string HighlightContext { get; }

        public ChuTestEntryViewModel(string categoryHeader)
        {
            IsCategoryHeader = true;
            Category         = categoryHeader;
            TestName         = categoryHeader;
            CatalogId        = string.Empty;
            Status           = string.Empty;
            Errors           = 0;
            Details          = string.Empty;
            StatusColor      = Brushes.Transparent;
            ShowDiagRepairLink = false;
            HighlightContext = string.Empty;
        }

        public ChuTestEntryViewModel(ChuCorrelatedEntry correlated)
        {
            var entry = correlated.Entry;
            IsCategoryHeader = false;
            Category = entry.Category;
            CatalogId = entry.Id;
            TestName = !string.IsNullOrWhiteSpace(correlated.CatalogDisplayName)
                ? correlated.CatalogDisplayName
                : (!string.IsNullOrWhiteSpace(entry.DisplayName) ? entry.DisplayName : entry.Test);
            Status   = entry.Status;
            Errors   = entry.Errors;
            if (entry.DurationSec > 0 && !string.IsNullOrWhiteSpace(entry.Details)) {
                Details = $"{entry.Details} ({entry.DurationSec:0.0}s)";
            } else if (entry.DurationSec > 0) {
                Details = $"{entry.DurationSec:0.0}s";
            } else {
                Details = entry.Details;
            }
            if (!string.IsNullOrWhiteSpace(CatalogId))
                Details = string.IsNullOrWhiteSpace(Details) ? $"id: {CatalogId}" : $"{Details}  |  id: {CatalogId}";

            StatusColor = entry.Status?.ToUpperInvariant() switch
            {
                "PASS"    => new SolidColorBrush(Color.FromRgb(0x3F, 0xB9, 0x50)),
                "WARN"    => new SolidColorBrush(Color.FromRgb(0xD2, 0x99, 0x22)),
                "FAIL"    => new SolidColorBrush(Color.FromRgb(0xF8, 0x51, 0x49)),
                "ABORTED" => new SolidColorBrush(Color.FromRgb(0xD2, 0x99, 0x22)),
                "SKIP"    => Brushes.Gray,
                _         => Brushes.LightGray
            };
            ShowDiagRepairLink = correlated.ShowDiagRepairLink;
            HighlightContext = correlated.HighlightContext;
        }
    }

    public class ChuResultsViewModel : WorkflowViewModelBase
    {
        private string _runLabel   = "No results loaded";
        private string _timestamp  = "--";
        private string _noDataMsg  = string.Empty;
        private string _rollupText = string.Empty;
        private bool   _hasData;
        private string _loadedJsonPath = string.Empty;

        public string RunLabel
        {
            get => _runLabel;
            set { _runLabel = value; OnPropertyChanged(); }
        }

        public string Timestamp
        {
            get => _timestamp;
            set { _timestamp = value; OnPropertyChanged(); }
        }

        public string NoDataMessage
        {
            get => _noDataMsg;
            set { _noDataMsg = value; OnPropertyChanged(); }
        }

        public bool HasData
        {
            get => _hasData;
            set { _hasData = value; OnPropertyChanged(); OnPropertyChanged(nameof(NoData)); }
        }

        public bool NoData => !_hasData;

        public string RollupText
        {
            get => _rollupText;
            set { _rollupText = value; OnPropertyChanged(); OnPropertyChanged(nameof(HasRollup)); }
        }

        public bool HasRollup => !string.IsNullOrWhiteSpace(RollupText);

        public ObservableCollection<ChuTestEntryViewModel> Entries { get; } = new();

        public ChuResultsViewModel() => RefreshResults();

        public void RefreshResults()
        {
            Entries.Clear();
            HasData       = false;
            NoDataMessage = "Searching for CDEDATA partition...";
            StatusText    = "Scanning...";

            // Find the CDEDATA volume (look at all fixed/removable drives for an
            // \EFI\CoreDiag\Results\ directory — this works both in WinPE and
            // full Windows, regardless of drive letter assignment).
            var resultFiles = DriveInfo.GetDrives()
                .Where(d => { try { return d.IsReady; } catch { return false; } })
                .Select(d => Path.Combine(d.RootDirectory.FullName, "EFI", "CoreDiag", "Results"))
                .Where(Directory.Exists)
                .SelectMany(dir => Directory.GetFiles(dir, "*.json"))
                .OrderByDescending(File.GetLastWriteTime)
                .ToList();

            if (resultFiles.Count == 0)
            {
                NoDataMessage = "No CHU result files found.\n\nBoot via rEFInd → Core Hardware Utility (CHU), run at least one test,\nthen return here.";
                RollupText = string.Empty;
                StatusText    = "No data";
                return;
            }

            // Load the most recent result file
            try
            {
                _loadedJsonPath = resultFiles[0];
                var json = File.ReadAllText(_loadedJsonPath);
                var opts = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
                var result = JsonSerializer.Deserialize<ChuResultFile>(json, opts);
                if (result == null) throw new InvalidDataException("Empty or invalid JSON.");

                RunLabel  = result.RunLabel;
                Timestamp = result.Timestamp;

                var rollup = ChuResultsCorrelationHelper.ComputeRollup(result.Results);
                RollupText = $"Overall: {rollup.OverallLabel}  |  Pass: {rollup.PassCount}  Warn: {rollup.WarnCount}  Fail: {rollup.FailCount}  Skip: {rollup.SkipCount}";

                var correlated = ChuResultsCorrelationHelper.CorrelateEntries(result.Results);
                string? lastCategory = null;
                foreach (var item in correlated)
                {
                    var entry = item.Entry;
                    if (!string.IsNullOrWhiteSpace(entry.Category)
                        && !string.Equals(entry.Category, lastCategory, StringComparison.OrdinalIgnoreCase))
                    {
                        Entries.Add(new ChuTestEntryViewModel(entry.Category));
                        lastCategory = entry.Category;
                    }
                    Entries.Add(new ChuTestEntryViewModel(item));
                }

                HasData    = true;
                StatusText = $"Loaded: {Path.GetFileName(_loadedJsonPath)}";
                WorkOrderService.TryRecordChuPreBootRun(_loadedJsonPath, rollup.PassCount, rollup.WarnCount, rollup.FailCount);
            }
            catch (Exception ex)
            {
                NoDataMessage = $"Failed to parse result file: {ex.Message}";
                StatusText    = "Parse error";
            }
        }
    }

    public class OSRepairViewModel : WorkflowViewModelBase
    {
        public ObservableCollection<ToolItem> Tools { get; } = new();
        private static readonly Regex SfcProgressTokenRegex = new(@"SFC_PROGRESS\s*:\s*(?<percent>\d{1,3})", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        private static readonly Regex DismProgressTokenRegex = new(@"DISM_PROGRESS\s*:\s*(?<percent>\d{1,3})", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        private static readonly Regex SfcVerificationRegex = new(@"Verification\s*(?<percent>\d{1,3})\s*%\s*complete", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        private static readonly Regex SfcVerificationCompactRegex = new(@"verification(?<percent>\d{1,3})%complete", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        private static readonly Regex DismProgressRegex = new(@"\[\s*=+\s*(?<percent>\d{1,3}(?:\.\d+)?)\s*%\s*=*\s*\]", RegexOptions.IgnoreCase | RegexOptions.Compiled);
        private int _sfcProgressLogIndex = -1;
        private int _dismProgressLogIndex = -1;
        private System.Windows.Threading.DispatcherTimer? _progressSmoothTimer;
        private int _smoothTargetPercent;
        private double _smoothDisplayPercent;
        private string _smoothPhaseLabel = string.Empty;
        private string _smoothLatestPercentText = string.Empty;

        private static bool IsWinPeMode()
        {
            try
            {
                using var key = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\MiniNT");
                if (key != null) return true;
            }
            catch
            {
                // Ignore registry lookup failures and continue with fallbacks.
            }

            var systemRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? string.Empty;
            if (systemRoot.StartsWith(@"X:\\", System.StringComparison.OrdinalIgnoreCase))
                return true;

            return false;
        }

        public OSRepairViewModel()
        {
            var isWinPe = IsWinPeMode();
            var script = GetScriptPath("OSRepair.ps1");
            Tools.Add(new ToolItem("System File Checker (SFC)",
                "Scan and repair protected Windows system files",
                "SFC", item => RunToolAsync(item, script)));
            Tools.Add(new ToolItem("DISM Image Repair",
                "Repair the Windows component store using DISM (optional install.wim for error 0x800f081f)",
                "DISM", item => RunToolAsync(item, script)));
            var networkReset = new ToolItem("Network Stack Reset",
                "Reset TCP/IP stack and Winsock catalog",
                "NetworkReset", item => RunToolAsync(item, script));
            Tools.Add(networkReset);
            var windowsUpdateRepair = new ToolItem("Windows Update Repair",
                "Reset Windows Update components and clear cache",
                "WindowsUpdateRepair", item => RunToolAsync(item, script));
            Tools.Add(windowsUpdateRepair);
            var offlineUpdateUninstall = new ToolItem("Offline Update Uninstall",
                "Revert interrupted updates and remove a selected update package on an offline image (WinPE)",
                "OfflineUpdateUninstall", item => RunOfflineUpdateUninstallAsync(item, script));
            Tools.Add(offlineUpdateUninstall);

            if (isWinPe)
            {
                // These actions require live Windows services/network stack and are not actionable in WinPE.
                foreach (var unavailable in new[] { networkReset, windowsUpdateRepair })
                {
                    unavailable.IsEnabled = false;
                    unavailable.ActionButtonLabel = "N/A";
                    unavailable.StatusText = "N/A in WinPE";
                }
            }
            else
            {
                // Offline servicing targets an offline image; not applicable to the live OS.
                offlineUpdateUninstall.IsEnabled = false;
                offlineUpdateUninstall.ActionButtonLabel = "WinPE only";
                offlineUpdateUninstall.StatusText = "WinPE only";
            }
        }

        private async Task RunToolAsync(ToolItem item, string scriptPath)
        {
            if (IsRunning) return;

            if (RequiresOsRepairConfirmation(item.ToolKey)
                && !DestructiveActionDialog.Confirm(
                    item.Name,
                    item.Description,
                    "This may take several minutes and modifies Windows system files or network configuration.",
                    defaultNo: true))
            {
                item.StatusText = "Cancelled";
                return;
            }

            string? dismSource = null;
            var dismSourceIndex = 0;
            if (string.Equals(item.ToolKey, "DISM", StringComparison.OrdinalIgnoreCase))
            {
                if (!TryPromptDismSource(out dismSource, out dismSourceIndex))
                {
                    item.StatusText = "Cancelled";
                    return;
                }
            }

            item.IsRunning = true;
            item.StatusText = "Running...";
            _sfcProgressLogIndex = -1;
            _dismProgressLogIndex = -1;
            _smoothTargetPercent = 0;
            _smoothDisplayPercent = 0;
            _smoothPhaseLabel = string.Empty;
            _smoothLatestPercentText = string.Empty;
            var smoothable = string.Equals(item.ToolKey, "SFC", StringComparison.OrdinalIgnoreCase)
                || string.Equals(item.ToolKey, "DISM", StringComparison.OrdinalIgnoreCase);
            if (smoothable)
            {
                StartProgressSmoothTimer();
            }
            try
            {
                var parameters = $"-ToolName {item.ToolKey}";

                // In WinPE there is no live OS on C:\. Resolve the offline Windows
                // volume (boot-time selection, single install, or operator pick) and
                // pass it explicitly; abort rather than ever defaulting to C:\.
                if (IsWinPeMode())
                {
                    var windowsDir = OfflineWindowsResolver.ResolveOfflineWindowsDir(
                        $"{item.Name} \u2014 Select Windows Installation",
                        out var failureStatus);
                    if (windowsDir == null)
                    {
                        item.StatusText = string.IsNullOrEmpty(failureStatus) ? "Cancelled" : failureStatus;
                        return;
                    }
                    parameters += $" -WindowsDir {PowerShellArgumentHelper.QuotePathParameterForProcess(windowsDir)}";
                }

                if (!string.IsNullOrWhiteSpace(dismSource))
                {
                    parameters += $" -DismSource {PowerShellArgumentHelper.QuotePathParameterForProcess(dismSource)} -DismSourceIndex {dismSourceIndex}";
                }

                var cancelled = await RunWorkflowAsync(scriptPath, parameters, item.Name, item.Description);
                if (cancelled)
                    item.StatusText = "Cancelled";
                else if (HasResultErrors)
                    item.StatusText = "Done with errors";
                else
                    item.StatusText = "Done \u2713";
            }
            catch (Exception ex) { item.StatusText = $"Error: {ex.Message}"; }
            finally { item.IsRunning = false; StopProgressSmoothTimer(); }
        }

        private static bool RequiresOsRepairConfirmation(string toolKey) =>
            string.Equals(toolKey, "SFC", StringComparison.OrdinalIgnoreCase)
            || string.Equals(toolKey, "DISM", StringComparison.OrdinalIgnoreCase)
            || string.Equals(toolKey, "NetworkReset", StringComparison.OrdinalIgnoreCase)
            || string.Equals(toolKey, "WindowsUpdateRepair", StringComparison.OrdinalIgnoreCase)
            || string.Equals(toolKey, "All", StringComparison.OrdinalIgnoreCase)
            || string.Equals(toolKey, "OfflineUpdateUninstall", StringComparison.OrdinalIgnoreCase);

        private static bool TryPromptDismSource(out string? dismSource, out int dismSourceIndex)
        {
            dismSource = null;
            dismSourceIndex = 0;

            var choice = MessageBox.Show(
                "DISM will try Windows Update first.\n\n" +
                "If repair fails with error 0x800f081f (source files could not be found), " +
                "provide a matching Windows install.wim from ISO media.\n\n" +
                "Browse for install.wim / install.esd now?\n\n" +
                "Yes = select repair source\n" +
                "No = Windows Update only\n" +
                "Cancel = abort",
                "DISM Image Repair",
                MessageBoxButton.YesNoCancel,
                MessageBoxImage.Question);

            if (choice == MessageBoxResult.Cancel)
            {
                return false;
            }

            if (choice == MessageBoxResult.No)
            {
                return true;
            }

            var dialog = new OpenFileDialog
            {
                Title = "Select Windows install.wim or install.esd",
                Filter = "Windows setup image (install.wim;install.esd)|install.wim;install.esd|Image files (*.wim;*.esd)|*.wim;*.esd|All files (*.*)|*.*",
                CheckFileExists = true,
                Multiselect = false
            };

            if (dialog.ShowDialog() != true)
            {
                return false;
            }

            dismSource = dialog.FileName;
            return true;
        }

        private void StartProgressSmoothTimer()
        {
            StopProgressSmoothTimer();
            _progressSmoothTimer = new System.Windows.Threading.DispatcherTimer
            {
                Interval = TimeSpan.FromMilliseconds(120)
            };
            _progressSmoothTimer.Tick += ProgressSmoothTimer_Tick;
            _progressSmoothTimer.Start();
        }

        private void StopProgressSmoothTimer()
        {
            if (_progressSmoothTimer == null)
            {
                return;
            }

            _progressSmoothTimer.Stop();
            _progressSmoothTimer.Tick -= ProgressSmoothTimer_Tick;
            _progressSmoothTimer = null;
        }

        private void ProgressSmoothTimer_Tick(object? sender, EventArgs e)
        {
            // sfc.exe / DISM only report coarse checkpoints when their output is
            // redirected. Climb the displayed bar one percent at a time toward the
            // latest real checkpoint so no integer is skipped, without overrunning it.
            if (_smoothDisplayPercent >= _smoothTargetPercent)
            {
                return;
            }

            _smoothDisplayPercent = Math.Min(_smoothDisplayPercent + 1, _smoothTargetPercent);
            var shown = (int)Math.Floor(_smoothDisplayPercent);
            if (shown > Progress)
            {
                Progress = shown;
            }

            ProgressPercentText = $"{shown}%";
            ProgressCaption = "Execution is in progress";
            var phase = string.IsNullOrEmpty(_smoothPhaseLabel) ? "Execution" : _smoothPhaseLabel;
            PhaseText = $"{phase} {shown}% complete";
        }

        protected override bool HandleLiveWorkflowOutput(string line)
        {
            var normalized = NormalizeProgressLine(line);

            // Live progress tokens emitted by OSRepair.ps1 (streamed, one per percent change).
            var sfcToken = SfcProgressTokenRegex.Match(line ?? string.Empty);
            if (sfcToken.Success)
            {
                var tokenPercent = sfcToken.Groups["percent"].Value;
                var progressLine = $"[{DateTime.Now:HH:mm:ss}] Verification {tokenPercent}% complete.";
                UpdateProgressLogLine(_sfcProgressLogIndex, progressLine, value => _sfcProgressLogIndex = value);
                UpdateWorkflowProgressFromPercent(tokenPercent, "SFC verification");
                return true;
            }

            var dismToken = DismProgressTokenRegex.Match(line ?? string.Empty);
            if (dismToken.Success)
            {
                var tokenPercent = dismToken.Groups["percent"].Value;
                var progressLine = $"[{DateTime.Now:HH:mm:ss}] DISM {tokenPercent}% complete.";
                UpdateProgressLogLine(_dismProgressLogIndex, progressLine, value => _dismProgressLogIndex = value);
                UpdateWorkflowProgressFromPercent(tokenPercent, "DISM");
                return true;
            }

            if (TryGetSfcProgressPercent(line, normalized, out var sfcPercent))
            {
                var progressLine = $"[{DateTime.Now:HH:mm:ss}] Verification {sfcPercent}% complete.";
                UpdateProgressLogLine(_sfcProgressLogIndex, progressLine, value => _sfcProgressLogIndex = value);
                UpdateWorkflowProgressFromPercent(sfcPercent, "SFC verification");
                return true;
            }

            var dismMatch = DismProgressRegex.Match(normalized);
            if (dismMatch.Success)
            {
                var progressLine = $"[{DateTime.Now:HH:mm:ss}] DISM {dismMatch.Groups["percent"].Value}% complete.";
                UpdateProgressLogLine(_dismProgressLogIndex, progressLine, value => _dismProgressLogIndex = value);
                UpdateWorkflowProgressFromPercent(dismMatch.Groups["percent"].Value, "DISM");
                return true;
            }

            return false;
        }

        private static bool TryGetSfcProgressPercent(string originalLine, string normalizedLine, out string percent)
        {
            percent = string.Empty;

            var sfcMatch = SfcVerificationRegex.Match(normalizedLine);
            if (sfcMatch.Success)
            {
                percent = sfcMatch.Groups["percent"].Value;
                return true;
            }

            var compact = Regex.Replace(originalLine ?? string.Empty, @"[^A-Za-z0-9%]", string.Empty);
            var compactMatch = SfcVerificationCompactRegex.Match(compact);
            if (!compactMatch.Success)
            {
                return false;
            }

            percent = compactMatch.Groups["percent"].Value;
            return true;
        }

        private void UpdateWorkflowProgressFromPercent(string percentText, string phaseLabel)
        {
            App.Current.Dispatcher.BeginInvoke(new Action(() =>
            {
                var integerPart = percentText.Split('.')[0];
                if (!int.TryParse(integerPart, out var parsedPercent))
                {
                    return;
                }

                var bounded = Math.Clamp(parsedPercent, 0, 100);

                if (_progressSmoothTimer != null)
                {
                    // Feed the smoother a new target; the timer animates 1% at a time.
                    if (bounded > _smoothTargetPercent)
                    {
                        _smoothTargetPercent = bounded;
                    }

                    _smoothPhaseLabel = phaseLabel;
                    _smoothLatestPercentText = percentText;
                    return;
                }

                if (bounded > Progress)
                {
                    Progress = bounded;
                }

                ProgressPercentText = $"{bounded}%";
                ProgressCaption = "Execution is in progress";
                PhaseText = $"{phaseLabel} {percentText}% complete";
            }));
        }

        private void UpdateProgressLogLine(int lineIndex, string progressLine, Action<int> setLineIndex)
        {
            App.Current.Dispatcher.BeginInvoke(new Action(() =>
            {
                if (lineIndex >= 0 && lineIndex < LogLines.Count)
                {
                    LogLines[lineIndex] = progressLine;
                }
                else
                {
                    lineIndex = LogLines.Count;
                    setLineIndex(lineIndex);
                    LogLines.Add(progressLine);
                }

                var removed = TrimLogLinesIfNeeded();
                if (removed > 0)
                {
                    AdjustProgressLogIndicesAfterTrim(removed);
                }

                RebuildLogTextFromLines();
            }));
        }

        protected override void OnLogLinesTrimmed(int removedCount)
        {
            base.OnLogLinesTrimmed(removedCount);
            AdjustProgressLogIndicesAfterTrim(removedCount);
        }

        private void AdjustProgressLogIndicesAfterTrim(int removedCount)
        {
            if (removedCount <= 0)
            {
                return;
            }

            _sfcProgressLogIndex = AdjustTrimmedIndex(_sfcProgressLogIndex, removedCount);
            _dismProgressLogIndex = AdjustTrimmedIndex(_dismProgressLogIndex, removedCount);
        }

        private static int AdjustTrimmedIndex(int index, int removedCount)
        {
            if (index < 0)
            {
                return index;
            }

            return index < removedCount ? -1 : index - removedCount;
        }

        private static string NormalizeProgressLine(string line)
        {
            if (string.IsNullOrWhiteSpace(line))
            {
                return string.Empty;
            }

            var normalized = Regex.Replace(line, @"(?<=\p{L}|\d)\s+(?=\p{L}|\d)", string.Empty);
            normalized = Regex.Replace(normalized, @"\s+%", "%");
            normalized = Regex.Replace(normalized, @"\s+", " ");
            return normalized.Trim();
        }

        // Offline update uninstall is a two-step flow: enumerate removable update
        // packages on the offline image, let the operator pick one (or choose
        // revert-only), then run the workflow (RevertPendingActions + optional
        // Remove-Package). WinPE-only; the live OS is never serviced offline.
        private async Task RunOfflineUpdateUninstallAsync(ToolItem item, string scriptPath)
        {
            if (IsRunning) return;
            item.IsRunning = true;
            item.StatusText = "Resolving target...";
            try
            {
                var windowsDir = OfflineWindowsResolver.ResolveOfflineWindowsDir(
                    "Offline Update Uninstall \u2014 Select Windows Installation",
                    out var failureStatus);
                if (windowsDir == null)
                {
                    item.StatusText = string.IsNullOrEmpty(failureStatus) ? "Cancelled" : failureStatus;
                    return;
                }

                item.StatusText = "Listing updates...";
                var listScript = $"& '{scriptPath}' -ToolName OfflineUpdateUninstall -UpdateAction ListPackages -WindowsDir '{windowsDir}'";
                var (json, err) = await PowerShellService.QueryAsync(listScript);
                if (string.IsNullOrWhiteSpace(json) && !string.IsNullOrWhiteSpace(err))
                {
                    item.StatusText = "Enumeration failed";
                    return;
                }

                var packages = ParseUpdatePackages(json);
                var selected = UpdatePackagePicker.Pick(packages,
                    "Offline Update Uninstall \u2014 Select Update to Remove");
                if (ReferenceEquals(selected, UpdatePackagePicker.Cancelled))
                {
                    item.StatusText = "Cancelled";
                    return;
                }

                var packageLabel = string.IsNullOrEmpty(selected.PackageName)
                    ? "Revert pending servicing actions only (no package removal)."
                    : $"Revert pending actions, then remove package:\n{selected.PackageName}";
                if (!DestructiveActionDialog.Confirm(
                        "Offline Update Uninstall",
                        $"Offline image:\n{windowsDir}\n\n{packageLabel}",
                        "This modifies the offline Windows image. Requires Confirmed continue; prefer a backup before removing updates.",
                        defaultNo: true))
                {
                    item.StatusText = "Cancelled";
                    return;
                }

                var parameters = $"-ToolName OfflineUpdateUninstall -WindowsDir {PowerShellArgumentHelper.QuotePathParameterForProcess(windowsDir)} -Confirmed";
                if (!string.IsNullOrEmpty(selected.PackageName))
                    parameters += $" -PackageName {PowerShellArgumentHelper.QuotePathParameterForProcess(selected.PackageName)}";

                var cancelled = await RunWorkflowAsync(scriptPath, parameters, item.Name, item.Description);
                if (cancelled)
                    item.StatusText = "Cancelled";
                else if (HasResultErrors)
                    item.StatusText = "Done with errors";
                else
                    item.StatusText = "Done \u2713";
            }
            catch (Exception ex) { item.StatusText = $"Error: {ex.Message}"; }
            finally { item.IsRunning = false; }
        }

        private static List<UpdatePackage> ParseUpdatePackages(string json)
        {
            var list = new List<UpdatePackage>();
            if (string.IsNullOrWhiteSpace(json)) return list;
            try
            {
                using var doc = JsonDocument.Parse(json);
                var root = doc.RootElement;
                // ConvertTo-Json emits an object for a single item and an array for many.
                IEnumerable<JsonElement> items = root.ValueKind == JsonValueKind.Array
                    ? root.EnumerateArray().ToList()
                    : new List<JsonElement> { root };
                foreach (var e in items)
                {
                    if (e.ValueKind != JsonValueKind.Object) continue;
                    string Get(string n) => e.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? string.Empty : string.Empty;
                    var name = Get("PackageName");
                    if (!string.IsNullOrWhiteSpace(name))
                        list.Add(new UpdatePackage(name, Get("ReleaseType"), Get("InstallTime"), Get("State")));
                }
            }
            catch { /* malformed JSON -> empty list; revert-only still available */ }
            return list;
        }
    }

    public class MalwareCleanupViewModel : WorkflowViewModelBase
    {
        private static readonly Regex CstTaggedPayloadRegex = new(@"^\[CST:(?<kind>[A-Z]+)\]\s*(?<json>\{.*\})$", RegexOptions.Compiled | RegexOptions.IgnoreCase);
        private static readonly HashSet<string> CstBootDetectors = new(StringComparer.OrdinalIgnoreCase)
        {
            "BootFileIntegrity",
            "BcdInspector",
            "MbrVbrInspector",
            "GptStructureInspector"
        };
        private readonly Dictionary<string, CstLiveFindingGroupViewModel> _liveFindingGroupIndex = new(StringComparer.OrdinalIgnoreCase);
        private readonly object _pendingProgressLock = new();
        private CstLiveProgressEvent? _pendingProgressEvent;
        private readonly object _pendingFindingLock = new();
        private readonly List<CstLiveFindingEvent> _pendingFindingEvents = new();
        private readonly System.Windows.Threading.DispatcherTimer _cstProgressUiTimer;
        private const int CstFindingFlushBatchSize = 40;
        private DateTime _lastProgressLogUtc = DateTime.MinValue;
        private int _lastProgressLoggedScanned;
        private int _lastProgressLoggedWalked;
        private DateTime _lastFindingLogUtc = DateTime.MinValue;
        private int _findingSinceLastLog;

        public ObservableCollection<ToolItem> Tools { get; } = new();
        public ObservableCollection<CstLiveFindingGroupViewModel> LiveFindingGroups { get; } = new();

        private static bool IsWinPeMode()
        {
            try
            {
                using var key = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\MiniNT");
                if (key != null) return true;
            }
            catch
            {
                // Ignore registry lookup failures and continue with fallbacks.
            }

            var systemRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? string.Empty;
            return systemRoot.StartsWith(@"X:\\", StringComparison.OrdinalIgnoreCase);
        }

        public MalwareCleanupViewModel()
        {
            _cstProgressUiTimer = new System.Windows.Threading.DispatcherTimer
            {
                Interval = TimeSpan.FromMilliseconds(120)
            };
            _cstProgressUiTimer.Tick += CstProgressUiTimer_Tick;
            _cstProgressUiTimer.Start();

            var isWinPe = IsWinPeMode();
            var script = GetScriptPath("MalwareSweep.ps1");
            Tools.Add(new ToolItem("Windows Defender Scan",
                "Run a Windows Defender quick scan with live elapsed time and estimated progress",
                "DefenderScan", item => RunToolAsync(item, script)));
            var cstTool = new ToolItem("Core Security Tool",
                "Run scan first, then choose selected findings to quarantine or remove",
                "CoreSecurityTool", item => RunToolAsync(item, script));
            cstTool.ActionButtonLabel = "⚙  Open";
            Tools.Add(cstTool);

            if (isWinPe)
            {
                var offlineRoot = Environment.GetEnvironmentVariable("OFFLINE_WINDOWS_ROOT");
                var installs = OfflineWindowsResolver.ScanWindowsInstalls();
                if (!string.IsNullOrWhiteSpace(offlineRoot))
                    cstTool.StatusText = $"Ready (offline {offlineRoot.TrimEnd('\\')})";
                else if (installs.Count > 0)
                    cstTool.StatusText = $"Ready ({installs.Count} Windows volume(s) detected)";
                else
                    cstTool.StatusText = "No Windows volume — use boot option 2 (Offline CDE)";
            }
        }

        protected override bool HandleLiveWorkflowOutput(string line)
        {
            if (string.IsNullOrWhiteSpace(line))
                return false;

            if (TryApplyDefenderProgress(line))
                return true;

            var match = CstTaggedPayloadRegex.Match(line);
            if (!match.Success)
                return false;

            var kind = match.Groups["kind"].Value.ToUpperInvariant();
            var json = match.Groups["json"].Value;

            try
            {
                if (string.Equals(kind, "PROGRESS", StringComparison.OrdinalIgnoreCase))
                {
                    var progress = JsonSerializer.Deserialize<CstLiveProgressEvent>(json, new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
                    if (progress is null)
                        return true;

                    lock (_pendingProgressLock)
                    {
                        _pendingProgressEvent = progress;
                    }
                    return true;
                }

                if (string.Equals(kind, "FINDING", StringComparison.OrdinalIgnoreCase))
                {
                    var finding = JsonSerializer.Deserialize<CstLiveFindingEvent>(json, new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
                    if (finding is null)
                        return true;

                    lock (_pendingFindingLock)
                    {
                        _pendingFindingEvents.Add(finding);
                    }
                    return true;
                }
            }
            catch
            {
                return false;
            }

            return false;
        }

        private void ResetLiveFindingState()
        {
            lock (_pendingProgressLock)
            {
                _pendingProgressEvent = null;
            }
            lock (_pendingFindingLock)
            {
                _pendingFindingEvents.Clear();
            }
            _liveFindingGroupIndex.Clear();
            LiveFindingGroups.Clear();
            _lastProgressLogUtc = DateTime.MinValue;
            _lastProgressLoggedScanned = 0;
            _lastProgressLoggedWalked = 0;
            _lastFindingLogUtc = DateTime.MinValue;
            _findingSinceLastLog = 0;
        }

        private void CstProgressUiTimer_Tick(object? sender, EventArgs e)
        {
            CstLiveProgressEvent? progress;
            lock (_pendingProgressLock)
            {
                progress = _pendingProgressEvent;
                _pendingProgressEvent = null;
            }

            if (progress is null)
            {
                FlushPendingFindingEvents();
                return;
            }

            ApplyProgressEvent(progress);
            FlushPendingFindingEvents();
        }

        private void FlushPendingFindingEvents()
        {
            List<CstLiveFindingEvent>? batch = null;
            lock (_pendingFindingLock)
            {
                if (_pendingFindingEvents.Count == 0)
                {
                    return;
                }

                var take = Math.Min(CstFindingFlushBatchSize, _pendingFindingEvents.Count);
                batch = _pendingFindingEvents.GetRange(0, take);
                _pendingFindingEvents.RemoveRange(0, take);
            }

            if (batch is null || batch.Count == 0)
            {
                return;
            }

            foreach (var finding in batch)
            {
                ApplyFindingEvent(finding);
            }
        }

        private void ApplyFindingEvent(CstLiveFindingEvent finding)
        {
            var normalizedType = NormalizeCstFindingType(finding.Type);
            var groupType = ResolveCstLiveGroupType(normalizedType, finding.Detector);
            var group = GetOrCreateLiveFindingGroup(groupType);
            group.AddFinding(new CstLiveFindingItemViewModel
            {
                Name = string.IsNullOrWhiteSpace(finding.Name) ? "Unnamed finding" : finding.Name!,
                Location = finding.Location ?? string.Empty,
                Evidence = finding.Evidence ?? string.Empty,
                Severity = finding.Severity ?? string.Empty,
                Type = normalizedType,
                Confidence = finding.Confidence,
                Detector = finding.Detector ?? string.Empty,
                SeverityBrush = GetSeverityBrush(finding.Severity)
            });

            if (ShouldLogFinding(finding.Severity))
            {
                var logType = string.IsNullOrWhiteSpace(groupType) ? "Detection" : groupType;
                var logLocation = string.IsNullOrWhiteSpace(finding.Location) ? "<unknown location>" : finding.Location;
                AppendLog($"{logType}: {finding.Name ?? "Unnamed finding"} -> {logLocation}");
            }
        }

        private void ApplyProgressEvent(CstLiveProgressEvent progress)
        {
            var effectivePercent = CstScanProgressHelper.ResolveDisplayPercent(
                progress.Phase,
                progress.Scanned,
                progress.ProgressTotal,
                progress.OverallPercent,
                progress.Percent);
            var percent = Math.Max(0.0, Math.Min(100.0, effectivePercent));
            Progress = (int)Math.Round(percent);
            ProgressPercentText = $"{percent:0.0}%";

            var phase = (progress.Phase ?? string.Empty).Trim();
            var phaseUpper = phase.ToUpperInvariant();
            var detail = progress.Detail ?? string.Empty;
            var currentDisplayPath = string.IsNullOrWhiteSpace(progress.CurrentPath) ? string.Empty : progress.CurrentPath;
            var currentFile = string.IsNullOrWhiteSpace(currentDisplayPath) ? "Scanning" : $"Scanning: {Path.GetFileName(currentDisplayPath)}";

            if (phaseUpper == "TARGETPREP")
            {
                PhaseText = string.IsNullOrWhiteSpace(detail) ? "Preparing scan targets..." : detail;
                ProgressCaption = "Preparing target roots and policy...";
            }
            else if (phaseUpper == "ENUMERATING")
            {
                PhaseText = string.IsNullOrWhiteSpace(detail) ? "Enumerating scan candidates..." : detail;
                var targetSummary = progress.TargetCount > 0
                    ? $"target {Math.Max(0, progress.TargetIndex):N0}/{progress.TargetCount:N0}"
                    : "target resolution";
                ProgressCaption = $"Enumerating: {progress.EnumeratedCandidates:N0} candidates • {targetSummary}";
            }
            else if (phaseUpper == "COMPLETED")
            {
                PhaseText = string.IsNullOrWhiteSpace(detail) ? "Finalizing results..." : detail;
                ProgressCaption = $"{progress.Scanned:N0} files analyzed • finalizing report";
            }
            else
            {
                StatusText = ProgressPercentText;

                if (progress.Scanned <= 0 && progress.EnumeratedCandidates > 0)
                {
                    PhaseText = string.IsNullOrWhiteSpace(currentDisplayPath)
                        ? "Scanning..."
                        : $"Scanning: {currentDisplayPath}";
                    ProgressCaption = string.IsNullOrWhiteSpace(detail)
                        ? $"Walking {progress.EnumeratedCandidates:N0} paths • preparing first analysis"
                        : detail;
                }
                else if (!string.IsNullOrWhiteSpace(detail) &&
                         (detail.Contains("walked", StringComparison.OrdinalIgnoreCase) ||
                          detail.Contains("Scanning", StringComparison.OrdinalIgnoreCase)))
                {
                    PhaseText = currentFile;
                    ProgressCaption = detail;
                }
                else
                {
                    PhaseText = currentFile;

                    var etaText = progress.EtaSec > 0
                        ? TimeSpan.FromSeconds(progress.EtaSec).ToString(progress.EtaSec >= 3600 ? @"h\:mm\:ss" : @"m\:ss")
                        : "calculating";

                    ProgressCaption = $"{progress.Scanned:N0} / {progress.ProgressTotal:N0} files scanned • ETA {etaText}";
                }
            }

            var walkedSinceLastLog = progress.EnumeratedCandidates - _lastProgressLoggedWalked;
            var shouldLogProgress = !string.IsNullOrWhiteSpace(currentDisplayPath)
                && phaseUpper != "TARGETPREP"
                && phaseUpper != "ENUMERATING"
                && (progress.Scanned - _lastProgressLoggedScanned >= 50
                    || walkedSinceLastLog >= 25
                    || (DateTime.UtcNow - _lastProgressLogUtc).TotalMilliseconds >= 350);
            if (shouldLogProgress)
            {
                AppendLog($"Scanning: {currentDisplayPath}");
                _lastProgressLogUtc = DateTime.UtcNow;
                _lastProgressLoggedScanned = progress.Scanned;
                _lastProgressLoggedWalked = progress.EnumeratedCandidates;
            }
        }

        private bool ShouldLogFinding(string? severity)
        {
            var now = DateTime.UtcNow;
            var isHighSeverity = string.Equals(severity, "Critical", StringComparison.OrdinalIgnoreCase)
                || string.Equals(severity, "High", StringComparison.OrdinalIgnoreCase);

            _findingSinceLastLog++;
            var shouldLog = isHighSeverity
                || _findingSinceLastLog >= 5
                || (now - _lastFindingLogUtc).TotalMilliseconds >= 500;

            if (!shouldLog)
            {
                return false;
            }

            _findingSinceLastLog = 0;
            _lastFindingLogUtc = now;
            return true;
        }

        private CstLiveFindingGroupViewModel GetOrCreateLiveFindingGroup(string type)
        {
            var key = string.IsNullOrWhiteSpace(type) ? "Suspicious" : type;
            if (_liveFindingGroupIndex.TryGetValue(key, out var group))
                return group;

            group = new CstLiveFindingGroupViewModel(key);
            _liveFindingGroupIndex[key] = group;
            LiveFindingGroups.Add(group);
            return group;
        }

        private static string NormalizeCstFindingType(string? findingType)
        {
            if (string.IsNullOrWhiteSpace(findingType))
                return "Suspicious";

            return findingType.Trim().ToUpperInvariant() switch
            {
                "MALWARE" => "Malware",
                "VIRUS" => "Virus",
                "PUP" => "PUP",
                "PUM" => "PUM",
                "SUSPICIOUS" => "Suspicious",
                _ => findingType.Trim()
            };
        }

        private static string ResolveCstLiveGroupType(string normalizedType, string? detector)
        {
            if (string.IsNullOrWhiteSpace(detector) || !CstBootDetectors.Contains(detector))
                return normalizedType;

            return detector.Trim() switch
            {
                "BootFileIntegrity" => "Boot - File Integrity",
                "BcdInspector" => "Boot - BCD Integrity",
                "MbrVbrInspector" => "Boot - MBR/VBR",
                "GptStructureInspector" => "Boot - GPT Structure",
                _ => "Boot - Other"
            };
        }

        private static Brush GetSeverityBrush(string? severity)
        {
            return severity?.Trim().ToUpperInvariant() switch
            {
                "CRITICAL" => new SolidColorBrush(Color.FromRgb(0xA9, 0x1F, 0x16)),
                "HIGH" => new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C)),
                "MEDIUM" => new SolidColorBrush(Color.FromRgb(0xD2, 0x99, 0x22)),
                "LOW" => new SolidColorBrush(Color.FromRgb(0x5A, 0x7D, 0x1A)),
                _ => new SolidColorBrush(Color.FromRgb(0x00, 0x78, 0xD4))
            };
        }

        private async Task RunHashIocUpdateAsync()
        {
            if (IsRunning)
            {
                MessageBox.Show(
                    "Wait for the current workflow to finish before updating hash IOCs.",
                    "Core Security Tool",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            var scriptPath = GetScriptPath("MalwareSweep.ps1");
            await RunWorkflowAsync(
                scriptPath,
                "-ToolName UpdateHashIOCs",
                "Update Hash IOCs",
                "Download the latest malware hash signatures from the CDE threat rules feed.");
        }

        private async Task RunToolAsync(ToolItem item, string scriptPath)
        {
            if (IsRunning) return;

            if (string.Equals(item.ToolKey, "CoreSecurityTool", StringComparison.OrdinalIgnoreCase))
            {
                await RunCoreSecurityToolLiveScanAsync(item, scriptPath);
                return;
            }

            if (string.Equals(item.ToolKey, "DefenderScan", StringComparison.OrdinalIgnoreCase))
            {
                await RunDefenderLiveScanAsync(item, scriptPath);
                return;
            }

            var parameters = BuildToolParameters(item.ToolKey);
            if (parameters is null)
            {
                item.StatusText = "Cancelled";
                return;
            }

            item.IsRunning = true;
            item.StatusText = "Running...";
            try
            {
                await RunWorkflowAsync(scriptPath, parameters, item.Name, item.Description);
                item.StatusText = "Done \u2713";
            }
            catch (Exception ex) { item.StatusText = $"Error: {ex.Message}"; }
            finally { item.IsRunning = false; }
        }

        private Task RunCoreSecurityToolLiveScanAsync(ToolItem item, string scriptPath)
        {
            var config = PromptCoreSecurityToolConfig();
            if (config is null)
            {
                item.StatusText = "Cancelled";
                return Task.CompletedTask;
            }

            ResetLiveFindingState();
            item.IsRunning = true;
            item.StatusText = "Scanning...";
            IsRunning = true;

            try
            {
                var owner = Application.Current?.Windows.OfType<Window>()
                    .FirstOrDefault(window => window.IsActive);
                var displayName = "Core Security Tool";
                var targetPath = config.TargetSummary;
                var subtitle = $"{config.ScanMode} • {config.DetectionScope}";

                ProcessAnalyzerCstResultService.ShowLiveScan(
                    owner,
                    displayName,
                    targetPath,
                    subtitle,
                    isStartupEntryScan: false,
                    scriptPath,
                    config.Parameters,
                    onSuccess: (presentation, rawOutput) =>
                    {
                        var artifactPath = string.IsNullOrWhiteSpace(presentation.ArtifactPath)
                            ? CstStructuredResultsService.ResolveArtifactPathFromStepOutput(rawOutput)
                            : presentation.ArtifactPath;
                        WorkOrderService.TryRecordCstScanRun(
                            artifactPath, targetPath, presentation.Verdict, presentation.ReportPdfPath);
                        item.StatusText = $"Done — {presentation.Verdict}";
                    },
                    showMalwareCleanupButton: false);

                if (string.Equals(item.StatusText, "Scanning...", StringComparison.Ordinal))
                    item.StatusText = "Done \u2713";
            }
            catch (Exception ex)
            {
                item.StatusText = $"Error: {ex.Message}";
                MessageBox.Show(ex.Message, "Core Security Tool", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
            finally
            {
                item.IsRunning = false;
                IsRunning = false;
            }

            return Task.CompletedTask;
        }

        private Task RunDefenderLiveScanAsync(ToolItem item, string scriptPath)
        {
            item.IsRunning = true;
            item.StatusText = "Scanning...";
            IsRunning = true;

            try
            {
                var owner = Application.Current?.Windows.OfType<Window>()
                    .FirstOrDefault(window => window.IsActive);

                DefenderScanResultService.ShowLiveScan(
                    owner,
                    scriptPath,
                    onSuccess: (_, _) => item.StatusText = "Done \u2713",
                    onFinished: () =>
                    {
                        item.IsRunning = false;
                        IsRunning = false;
                    });

                if (string.Equals(item.StatusText, "Scanning...", StringComparison.Ordinal))
                    item.StatusText = "Done \u2713";
            }
            catch (Exception ex)
            {
                item.StatusText = $"Error: {ex.Message}";
                MessageBox.Show(ex.Message, "Windows Defender Scan", MessageBoxButton.OK, MessageBoxImage.Warning);
                item.IsRunning = false;
                IsRunning = false;
            }

            return Task.CompletedTask;
        }

        private sealed class CoreSecurityToolLaunchConfig
        {
            public string Parameters { get; init; } = string.Empty;
            public string ScanMode { get; init; } = "ThreatScan";
            public string DetectionScope { get; init; } = "Strict";
            public string TargetSummary { get; init; } = "System scan";
        }

        private CoreSecurityToolLaunchConfig? PromptCoreSecurityToolConfig()
        {
            try
            {
                var dialog = new CoreSecurityToolConfigDialog
                {
                    Owner = Application.Current?.Windows.OfType<Window>().FirstOrDefault(window => window.IsActive),
                    OnUpdateHashIocRequested = RunHashIocUpdateAsync
                };
                if (dialog.ShowDialog() != true)
                    return null;

                var args = $"-ToolName CoreSecurityTool -CstMode {dialog.ScanMode} -CstDetectionScope {dialog.DetectionScope} -CstActionMode ScanOnly";
                var targetSummary = $"{dialog.ScanMode} targets";

                if (string.Equals(dialog.ScanMode, "CustomScan", StringComparison.OrdinalIgnoreCase)
                    && dialog.CustomTargetPaths.Count > 0)
                {
                    args += BuildNamedCliArguments("-ScanTarget", dialog.CustomTargetPaths);
                    targetSummary = dialog.CustomTargetPaths.Count == 1
                        ? dialog.CustomTargetPaths[0]
                        : $"{dialog.CustomTargetPaths.Count} custom paths";
                }
                else if (string.Equals(dialog.ScanMode, "ThreatScan", StringComparison.OrdinalIgnoreCase))
                {
                    targetSummary = "ThreatScan (quick high-risk paths)";
                }
                else if (string.Equals(dialog.ScanMode, "FullScan", StringComparison.OrdinalIgnoreCase))
                {
                    targetSummary = "FullScan (broad system coverage)";
                }

                return new CoreSecurityToolLaunchConfig
                {
                    Parameters = args,
                    ScanMode = dialog.ScanMode,
                    DetectionScope = dialog.DetectionScope,
                    TargetSummary = targetSummary
                };
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    $"Unable to open Core Security Tool configuration: {ex.Message}",
                    "Core Security Tool",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return null;
            }
        }

        public sealed class CstLiveFindingEvent
        {
            public string? Type { get; set; }
            public string? Severity { get; set; }
            public string? Name { get; set; }
            public string? Location { get; set; }
            public string? Evidence { get; set; }
            public string? Detector { get; set; }
            public double Confidence { get; set; }
        }

        public sealed class CstLiveProgressEvent
        {
            public int Scanned { get; set; }
            public int ProgressTotal { get; set; }
            public double Percent { get; set; }
            public string? Phase { get; set; }
            public double? PhasePercent { get; set; }
            public double? OverallPercent { get; set; }
            public int TargetIndex { get; set; }
            public int TargetCount { get; set; }
            public int EnumeratedCandidates { get; set; }
            public int FilteredByRiskPath { get; set; }
            public int FilteredByExclusion { get; set; }
            public string? Detail { get; set; }
            public string? CurrentPath { get; set; }
            public double ElapsedSec { get; set; }
            public double EtaSec { get; set; }
        }

        public sealed class CstLiveFindingGroupViewModel : INotifyPropertyChanged
        {
            private int _count;

            public CstLiveFindingGroupViewModel(string type)
            {
                Type = type;
                StatusBrush = type.ToUpperInvariant() switch
                {
                    "VIRUS" => new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C)),
                    "MALWARE" => new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C)),
                    "PUP" => new SolidColorBrush(Color.FromRgb(0xD2, 0x99, 0x22)),
                    "PUM" => new SolidColorBrush(Color.FromRgb(0xD2, 0x99, 0x22)),
                    "SUSPICIOUS" => new SolidColorBrush(Color.FromRgb(0x92, 0x68, 0x00)),
                    _ when type.StartsWith("Boot -", StringComparison.OrdinalIgnoreCase) => new SolidColorBrush(Color.FromRgb(0x92, 0x68, 0x00)),
                    _ => new SolidColorBrush(Color.FromRgb(0x00, 0x78, 0xD4))
                };
            }

            public string Type { get; }
            public string Title => $"{Type} ({Count})";
            public int Count
            {
                get => _count;
                private set
                {
                    if (_count == value) return;
                    _count = value;
                    OnPropertyChanged();
                    OnPropertyChanged(nameof(Title));
                }
            }
            public Brush StatusBrush { get; }
            public ObservableCollection<CstLiveFindingItemViewModel> Findings { get; } = new();

            public void AddFinding(CstLiveFindingItemViewModel finding)
            {
                Findings.Add(finding);
                Count = Findings.Count;
            }

            public event PropertyChangedEventHandler? PropertyChanged;

            private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
            {
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
            }
        }

        public sealed class CstLiveFindingItemViewModel
        {
            public string Name { get; init; } = string.Empty;
            public string Type { get; init; } = string.Empty;
            public string Severity { get; init; } = string.Empty;
            public string Location { get; init; } = string.Empty;
            public string Evidence { get; init; } = string.Empty;
            public string Detector { get; init; } = string.Empty;
            public double Confidence { get; init; }
            public Brush SeverityBrush { get; init; } = new SolidColorBrush(Color.FromRgb(0x00, 0x78, 0xD4));
        }

        private string? BuildToolParameters(string toolKey)
        {
            return $"-ToolName {toolKey}";
        }

        private static string BuildNamedCliArguments(string parameterName, IEnumerable<string> values)
        {
            var sb = new StringBuilder();
            foreach (var value in values)
            {
                if (string.IsNullOrWhiteSpace(value))
                    continue;

                sb.Append(' ');
                sb.Append(parameterName);
                sb.Append(' ');
                sb.Append(PowerShellArgumentHelper.QuotePathParameterForProcess(value));
            }

            return sb.ToString();
        }
    }

    public class BackupAndImagingViewModel : WorkflowViewModelBase
    {
        public ObservableCollection<ToolItem> Tools { get; } = new();

        public BackupAndImagingViewModel()
        {
            var script = GetScriptPath("BackupAndImage.ps1");
            
            var robocopyTool = new ToolItem("Robocopy Backup",
                "Mirror files to an external drive using Robocopy",
                "RobocopyBackup", item => RunToolAsync(item, script));
            robocopyTool.ActionButtonLabel = "⚙  Open";
            Tools.Add(robocopyTool);
        }

        private async Task RunToolAsync(ToolItem item, string scriptPath)
        {
            if (IsRunning) return;

            var parameters = BuildToolParameters(item.ToolKey);
            if (parameters is null)
            {
                item.StatusText = "Cancelled";
                return;
            }

            item.IsRunning = true;
            item.StatusText = "Running...";
            try
            {
                await RunWorkflowAsync(scriptPath, parameters, item.Name, item.Description);
                item.StatusText = "Done \u2713";
            }
            catch (Exception ex) { item.StatusText = $"Error: {ex.Message}"; }
            finally { item.IsRunning = false; }
        }

        private static string? BuildToolParameters(string toolKey)
        {
            if (string.Equals(toolKey, "RobocopyBackup", StringComparison.OrdinalIgnoreCase))
            {
                return BuildRobocopyParameters();
            }

            return $"-ToolName {toolKey}";
        }

        private static string? BuildRobocopyParameters()
        {
            var dialog = new RobocopyConfigDialog();
            if (dialog.ShowDialog() != true)
                return null;

            if (dialog.MirrorMode && !dialog.DryRun)
            {
                if (!DestructiveActionDialog.Confirm(
                        "Robocopy Mirror",
                        $"Mirror (purge) from:\n{dialog.SourcePath}\n\nto:\n{dialog.DestinationPath}",
                        "Mirror deletes files and folders in the destination that are not present in the source. Destination should be a dedicated backup folder, not a system or Offline OS root.",
                        defaultNo: true))
                {
                    return null;
                }
            }

            var args = $"-ToolName RobocopyBackup -BackupSource {PowerShellArgumentHelper.QuotePathParameterForProcess(dialog.SourcePath)} -BackupDestination {PowerShellArgumentHelper.QuotePathParameterForProcess(dialog.DestinationPath)}";
            if (dialog.DryRun) args += " -DryRun";
            if (dialog.MirrorMode) args += " -Mirror";
            return args;
        }
    }

    public class PostOpViewModel : WorkflowViewModelBase
    {
        public ObservableCollection<ToolItem> Tools { get; } = new();

        public PostOpViewModel()
        {
            var script = GetScriptPath("PostOp.ps1");
            Tools.Add(new ToolItem("Browser Cache Clear",
                "Clear browser disk cache for Edge, Chrome, and Firefox (not cookies or saved passwords)",
                "BrowserCacheClean", item => RunPostOpToolAsync(item, script)));
            Tools.Add(new ToolItem("Restore Default Services",
                "Reset commonly broken Windows services to default start types (requires elevation)",
                "RestoreDefaultServices", item => RunPostOpToolAsync(item, script)));
            Tools.Add(new ToolItem("File Association Fix",
                "Repair broken system handlers for .exe, .lnk, .bat, .cmd, and .com (recovery scenario)",
                "FileAssociationFix", item => RunPostOpToolAsync(item, script)));
            Tools.Add(new ToolItem("Icon + Thumbnail Cache Clear",
                "Delete icon and thumbnail cache databases; rebuild after Explorer restart",
                "IconThumbCacheClear", item => RunPostOpToolAsync(item, script)));
            Tools.Add(new ToolItem("DNS Cache Flush",
                "Flush the Windows DNS resolver cache (ipconfig /flushdns)",
                "DnsFlush", item => RunToolAsync(item, script)));
            Tools.Add(new ToolItem("Reset Proxy Settings",
                "Disable user Internet proxy and reset WinHTTP proxy to defaults",
                "ProxyReset", item => RunPostOpToolAsync(item, script)));
            Tools.Add(new ToolItem("Restore Hosts File",
                "Replace hosts file with Windows defaults (backup created first; confirmation required)",
                "HostsFileRestore", item => RunHostsRestoreAsync(item, script)));
            Tools.Add(new ToolItem("Restart Explorer",
                "Restart Windows Explorer to apply shell and cache changes",
                "RestartExplorer", item => RunPostOpToolAsync(item, script)));
        }

        private static bool IsDestructivePostOpTool(string toolKey) =>
            !string.Equals(toolKey, "DnsFlush", StringComparison.OrdinalIgnoreCase)
            && !string.Equals(toolKey, "HostsFileRestore", StringComparison.OrdinalIgnoreCase);

        private async Task RunPostOpToolAsync(ToolItem item, string scriptPath, string extraArgs = "")
        {
            if (IsDestructivePostOpTool(item.ToolKey)
                && !DestructiveActionDialog.Confirm(
                    item.Name,
                    item.Description,
                    "This operation modifies system configuration and may not be easily undone.",
                    defaultNo: true))
            {
                item.StatusText = "Cancelled";
                return;
            }

            await RunToolAsync(item, scriptPath, extraArgs);
        }

        private async Task RunHostsRestoreAsync(ToolItem item, string scriptPath)
        {
            if (IsRunning) return;

            var confirm = MessageBox.Show(
                "This replaces the system hosts file with Windows default localhost entries only.\n\n" +
                "A timestamped backup is created first. Custom entries (including legitimate block lists) will be removed.\n\n" +
                "Continue?",
                "Restore Hosts File",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);

            if (confirm != MessageBoxResult.Yes)
            {
                item.StatusText = "Cancelled";
                return;
            }

            await RunToolAsync(item, scriptPath, "-ConfirmHostsRestore");
        }

        private async Task RunToolAsync(ToolItem item, string scriptPath, string extraArgs = "")
        {
            if (IsRunning) return;
            item.IsRunning = true;
            item.StatusText = "Running...";
            try
            {
                var args = $"-ToolName {item.ToolKey}";
                if (!string.IsNullOrWhiteSpace(extraArgs))
                    args += $" {extraArgs}";
                await RunWorkflowAsync(scriptPath, args, item.Name, item.Description);
                item.StatusText = "Done \u2713";
            }
            catch (Exception ex) { item.StatusText = $"Error: {ex.Message}"; }
            finally { item.IsRunning = false; }
        }
    }

    public sealed class HijackFindingItemViewModel : INotifyPropertyChanged
    {
        private bool _isSelected;

        public string Id { get; init; } = string.Empty;
        public string Category { get; init; } = string.Empty;
        public string Name { get; init; } = string.Empty;
        public string Location { get; init; } = string.Empty;
        public string CurrentValue { get; init; } = string.Empty;
        public string Severity { get; init; } = string.Empty;
        public string Guidance { get; init; } = string.Empty;
        public string StartupEntryName { get; init; } = string.Empty;
        public string RepairAction { get; init; } = string.Empty;
        public bool IsFlagged { get; init; }
        public bool Repairable { get; init; }
        public Brush SeverityBrush { get; init; } = Brushes.SteelBlue;

        public string ActionLabel => GetActionLabel(Repairable, Category);
        public string RepairableDisplay => Repairable ? "Yes" : "Review";
        public bool CanManageInStartup =>
            Category.Equals("Startup", StringComparison.OrdinalIgnoreCase) && !Repairable;
        public bool CanRepairThis => Repairable;
        public string RepairActionDescription => DescribeRepairAction(RepairAction);
        public string GuidanceDisplay => string.IsNullOrWhiteSpace(Guidance)
            ? "No additional guidance for this finding."
            : Guidance;
        public string ToolTipText => string.IsNullOrWhiteSpace(Guidance)
            ? CurrentValue
            : $"{Guidance}\n\n{CurrentValue}";

        public static string GetActionLabel(bool repairable, string category)
        {
            if (repairable) return "Fix here";
            if (category.Equals("Startup", StringComparison.OrdinalIgnoreCase)) return "Startup Manager";
            return "Info only";
        }

        public static string DescribeRepairAction(string repairAction)
        {
            if (string.IsNullOrWhiteSpace(repairAction)) return string.Empty;
            return repairAction switch
            {
                "browser.policy.remove" => "Remove suspicious browser policy (registry backup created).",
                "browser.chromium.prefs" => "Reset hijacked Chromium preferences (backup created).",
                "browser.firefox.prefs" => "Reset hijacked Firefox prefs.js entries.",
                "browser.firefox.userjs" => "Move locked Firefox user.js aside (backup created).",
                "browser.lnk.reset" => "Reset browser shortcut target (backup created).",
                "network.hosts.restore" => "Restore hosts file to Windows defaults (backup created).",
                "network.proxy.reset" => "Reset user proxy and WinHTTP settings.",
                "network.dns.reset" => "Reset adapter DNS to DHCP and flush DNS cache.",
                "network.nrpt.remove" => "Remove the NRPT rule.",
                "security.defender.enable" => "Re-enable Defender service, RTP, and tamper protection.",
                "security.firewall.enable" => "Enable the affected firewall profile.",
                "security.uac.restore" => "Restore UAC defaults.",
                "security.smartscreen.restore" => "Restore SmartScreen setting.",
                "startup.winlogon.reset" => "Reset Winlogon value to Windows default (backup created).",
                _ => repairAction
            };
        }

        public bool IsSelected
        {
            get => _isSelected;
            set
            {
                if (_isSelected == value) return;
                _isSelected = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsSelected)));
            }
        }

        public event PropertyChangedEventHandler? PropertyChanged;

        public static HijackFindingItemViewModel FromEvent(HijackFindingEvent evt)
        {
            var severity = string.IsNullOrWhiteSpace(evt.Severity) ? "Info" : evt.Severity;
            var autoSelect = evt.IsFlagged && evt.Repairable;
            return new HijackFindingItemViewModel
            {
                Id = evt.Id ?? string.Empty,
                Category = evt.Category ?? string.Empty,
                Name = evt.Name ?? string.Empty,
                Location = evt.Location ?? string.Empty,
                CurrentValue = evt.CurrentValue ?? string.Empty,
                Severity = severity,
                Guidance = evt.Guidance ?? string.Empty,
                StartupEntryName = evt.StartupEntryName ?? string.Empty,
                RepairAction = evt.RepairAction ?? string.Empty,
                IsFlagged = evt.IsFlagged,
                Repairable = evt.Repairable,
                IsSelected = autoSelect,
                SeverityBrush = severity switch
                {
                    "Hijacked" => new SolidColorBrush(Color.FromRgb(0xF8, 0x51, 0x49)),
                    "Suspicious" => new SolidColorBrush(Color.FromRgb(0xD2, 0x99, 0x22)),
                    _ => new SolidColorBrush(Color.FromRgb(0x00, 0x78, 0xD4))
                }
            };
        }
    }

    public sealed class HijackFindingEvent
    {
        public string? Id { get; set; }
        public string? Category { get; set; }
        public string? Name { get; set; }
        public string? Location { get; set; }
        public string? CurrentValue { get; set; }
        public string? Severity { get; set; }
        public bool IsFlagged { get; set; }
        public bool Repairable { get; set; }
        public string? RepairAction { get; set; }
        public string? Guidance { get; set; }
        public string? StartupEntryName { get; set; }
    }

    public sealed class HijackScanCompleteEvent
    {
        public int Total { get; set; }
        public int Flagged { get; set; }
        public int Repairable { get; set; }
        public string? SnapshotPath { get; set; }
    }

    public class HijackRepairViewModel : WorkflowViewModelBase
    {
        private static readonly Regex HijackTaggedPayloadRegex = new(
            @"^\[HIJACK:(?<kind>[A-Z]+)\]\s*(?<json>\{.*\})$",
            RegexOptions.Compiled | RegexOptions.IgnoreCase);

        private readonly List<HijackFindingItemViewModel> _allFindings = new();
        private bool _showFlaggedOnly = true;
        private bool _showScanLog;
        private bool _showQuickRepairs;
        private bool _hasScanResults;
        private string? _scanReportBaseName;
        private TabularScanReportPaths? _scanReportPaths;
        private string _scanSummary = "Run Scan to inventory hijacks and scams on this system.";
        private string _detailStatusText = "Select a finding to review details and recommended actions.";
        private string _hijackScript = string.Empty;
        private string _hijackSnapshotPath = string.Empty;
        private HijackFindingItemViewModel? _selectedFinding;

        public ObservableCollection<HijackFindingItemViewModel> DisplayedFindings { get; } = new();
        public ObservableCollection<ToolItem> Tools { get; } = new();

        public HijackFindingItemViewModel? SelectedFinding
        {
            get => _selectedFinding;
            set
            {
                if (_selectedFinding is not null)
                    _selectedFinding.PropertyChanged -= OnSelectedFindingPropertyChanged;

                if (ReferenceEquals(_selectedFinding, value)) return;
                _selectedFinding = value;

                if (_selectedFinding is not null)
                    _selectedFinding.PropertyChanged += OnSelectedFindingPropertyChanged;

                OnPropertyChanged();
                UpdateDetailStatusText();
            }
        }

        private void OnSelectedFindingPropertyChanged(object? sender, PropertyChangedEventArgs e)
        {
            if (e.PropertyName == nameof(HijackFindingItemViewModel.IsSelected))
                UpdateDetailStatusText();
        }

        public string DetailStatusText
        {
            get => _detailStatusText;
            private set { _detailStatusText = value; OnPropertyChanged(); }
        }

        public bool ShowScanLog
        {
            get => _showScanLog;
            set { _showScanLog = value; OnPropertyChanged(); }
        }

        public bool ShowQuickRepairs
        {
            get => _showQuickRepairs;
            set { _showQuickRepairs = value; OnPropertyChanged(); }
        }

        public bool ShowFlaggedOnly
        {
            get => _showFlaggedOnly;
            set
            {
                if (_showFlaggedOnly == value) return;
                _showFlaggedOnly = value;
                OnPropertyChanged();
                RefreshDisplayedFindings();
            }
        }

        public string ScanSummary
        {
            get => _scanSummary;
            private set { _scanSummary = value; OnPropertyChanged(); }
        }

        public bool HasScanResults
        {
            get => _hasScanResults;
            private set
            {
                if (_hasScanResults == value) return;
                _hasScanResults = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(ScanButtonLabel));
                OnPropertyChanged(nameof(CanViewScanReport));
            }
        }

        public string ScanButtonLabel => HasScanResults ? "\u25b6  Re-Scan" : "\u25b6  Scan";

        public bool CanViewScanReport => HasScanResults;

        public RelayCommand ScanCommand { get; }
        public RelayCommand RepairSelectedCommand { get; }
        public RelayCommand RepairThisItemCommand { get; }
        public RelayCommand OpenReportCommand { get; }
        public RelayCommand OpenPdfReportCommand { get; }
        public RelayCommand OpenStartupManagerCommand { get; }
        public RelayCommand<HijackFindingItemViewModel> ManageStartupCommand { get; }
        public RelayCommand SelectRepairableCommand { get; }
        public RelayCommand ClearSelectionCommand { get; }

        protected override bool ShowWorkflowExecutionWindow => false;

        public HijackRepairViewModel()
        {
            _hijackScript = GetScriptPath("HijackRepair.ps1");
            ScanCommand = new RelayCommand(RunScanAsync);
            RepairSelectedCommand = new RelayCommand(RepairSelectedAsync);
            RepairThisItemCommand = new RelayCommand(RepairThisItemAsync);
            OpenReportCommand = new RelayCommand(OpenHijackPdfReportAsync);
            OpenPdfReportCommand = new RelayCommand(OpenHijackPdfReportAsync);
            OpenStartupManagerCommand = new RelayCommand(OpenStartupManagerAsync);
            ManageStartupCommand = new RelayCommand<HijackFindingItemViewModel>(OpenStartupManagerFromFinding);
            SelectRepairableCommand = new RelayCommand(() => { SetSelectionForDisplayed(select: true); return Task.CompletedTask; });
            ClearSelectionCommand = new RelayCommand(() => { SetSelectionForDisplayed(select: false); return Task.CompletedTask; });

            Tools.Add(new ToolItem("Browser Hijack Repair",
                "Remove suspicious homepage, search, and policy hijacks only (backs up prefs and registry)",
                "BrowserHijackRepair", item => RunHijackToolAsync(item)));
            Tools.Add(new ToolItem("Network Hijack Repair",
                "Reset DNS to DHCP, flush cache, clear proxy/PAC, and remove non-domain NRPT rules",
                "NetworkHijackRepair", item => RunHijackToolAsync(item)));
            Tools.Add(new ToolItem("Security Settings Restore",
                "Re-enable Defender, firewall, UAC, and SmartScreen after tampering",
                "SecurityTamperingRepair", item => RunHijackToolAsync(item)));
            Tools.Add(new ToolItem("Repair All Hijacks",
                "Run browser, network, and security repairs in one pass (elevation required)",
                "RepairAll", item => RunRepairAllAsync(item, _hijackScript)));
        }

        private async Task RunScanAsync()
        {
            if (IsRunning) return;
            _allFindings.Clear();
            _hijackSnapshotPath = string.Empty;
            _scanReportBaseName = null;
            _scanReportPaths = null;
            ReportPdfPath = string.Empty;
            ReportJsonPath = string.Empty;
            RefreshDisplayedFindings();
            ScanSummary = "Scanning for hijacks...";
            await RunWorkflowAsync(_hijackScript, "-ToolName Scan", "Hijack Scan", "Inventory browser, network, startup, security, and remote-access hijacks.");
            RefreshDisplayedFindings();
            FinalizeScanResultsIfNeeded();
        }

        private void FinalizeScanResultsIfNeeded()
        {
            if (HasScanResults)
                return;

            var flagged = _allFindings.Count(f => f.IsFlagged);
            var repairable = _allFindings.Count(f => f.Repairable);
            ScanSummary = _allFindings.Count == 0
                ? "Scan complete: no hijack indicators found."
                : $"{_allFindings.Count} item(s) | {flagged} flagged | {repairable} repairable";
            HasScanResults = true;
            _ = EnsureHijackScanReportsAndPdfAsync();
        }

        private async Task EnsureHijackScanReportsAndPdfAsync()
        {
            await EnsureHijackScanReportsAsync();
            try
            {
                await EnsureHijackScanPdfAsync();
            }
            catch
            {
                /* PDF generation is best-effort at scan completion */
            }
        }

        private Task OpenStartupManagerAsync()
        {
            NavigationService.Request("StartupManager", "SuspiciousOnly");
            return Task.CompletedTask;
        }

        private Task OpenStartupManagerFromFinding(HijackFindingItemViewModel? finding)
        {
            if (finding is null)
            {
                NavigationService.Request("StartupManager", "SuspiciousOnly");
                return Task.CompletedTask;
            }

            var filter = finding.StartupEntryName;
            if (string.IsNullOrWhiteSpace(filter))
            {
                var paren = finding.Name.IndexOf(" (", StringComparison.Ordinal);
                filter = paren > 0 ? finding.Name[..paren] : finding.Name;
            }

            NavigationService.Request("StartupManager", $"filter:{filter}");
            return Task.CompletedTask;
        }

        private Task OpenHijackPdfReportAsync() => OpenHijackReportAsync();

        private async Task OpenHijackReportAsync()
        {
            if (!HasScanResults)
            {
                MessageBox.Show(
                    "Run a scan first, then open the report.",
                    "Open Report",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            try
            {
                await EnsureHijackScanReportsAsync();
                await EnsureHijackScanPdfAsync();
                if (!HasPdfReport)
                {
                    throw new InvalidOperationException("The PDF report could not be generated.");
                }

                ShellFileOpenHelper.OpenWithDefaultApplication(ReportPdfPath);
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

        private async Task EnsureHijackScanReportsAsync()
        {
            var document = BuildHijackScanReportDocument();
            _scanReportPaths = await Task.Run(() =>
                TabularScanReportService.EnsureReports(document, _scanReportBaseName));
            _scanReportBaseName = _scanReportPaths.BaseName;
            ReportJsonPath = _scanReportPaths.JsonPath;
            ReportPdfPath = _scanReportPaths.PdfPath;
            OnPropertyChanged(nameof(HasJsonReport));
            OnPropertyChanged(nameof(CanOpenReport));
        }

        private async Task EnsureHijackScanPdfAsync()
        {
            await EnsureHijackScanReportsAsync();
            if (_scanReportPaths is null)
                return;

            if (File.Exists(_scanReportPaths.PdfPath))
            {
                ReportPdfPath = _scanReportPaths.PdfPath;
                OnPropertyChanged(nameof(HasPdfReport));
                OnPropertyChanged(nameof(CanOpenReport));
                return;
            }

            var document = BuildHijackScanReportDocument();
            string? error = null;
            var generated = await Task.Run(() =>
                TabularScanReportService.TryGeneratePdf(document, _scanReportPaths.PdfPath, out error));
            if (generated)
            {
                ReportPdfPath = _scanReportPaths.PdfPath;
                OnPropertyChanged(nameof(HasPdfReport));
                OnPropertyChanged(nameof(CanOpenReport));
                return;
            }

            throw new InvalidOperationException(error ?? "Unknown PDF generation error.");
        }

        private TabularScanReportDocument BuildHijackScanReportDocument()
        {
            var flagged = _allFindings.Count(f => f.IsFlagged);
            var repairable = _allFindings.Count(f => f.Repairable);
            var hijacked = _allFindings.Count(f =>
                f.Severity.Equals("Hijacked", StringComparison.OrdinalIgnoreCase));
            var overall = hijacked > 0
                ? "Hijacked"
                : flagged > 0
                    ? "Suspicious"
                    : "Healthy";

            var headers = new[]
            {
                "FIX", "Action", "Category", "Risk", "Name", "Location", "Value", "Repairable", "Guidance"
            };

            var rows = _allFindings
                .OrderBy(f => f.Category, StringComparer.OrdinalIgnoreCase)
                .ThenBy(f => f.Name, StringComparer.OrdinalIgnoreCase)
                .Select(f => (IReadOnlyList<string>)new[]
                {
                    f.IsSelected ? "Yes" : string.Empty,
                    f.ActionLabel,
                    f.Category,
                    f.Severity,
                    f.Name,
                    f.Location,
                    f.CurrentValue,
                    f.RepairableDisplay,
                    f.Guidance
                })
                .ToList();

            return new TabularScanReportDocument
            {
                WorkflowName = "HijackRepair_Scan",
                Title = "Hijack & Scam Repair Scan",
                Summary = ScanSummary,
                OverallHealth = overall,
                GeneratedAt = DateTime.Now,
                ColumnHeaders = headers,
                Rows = rows,
                Metrics = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                {
                    ["Total"] = _allFindings.Count.ToString(),
                    ["Flagged"] = flagged.ToString(),
                    ["Repairable"] = repairable.ToString()
                }
            };
        }

        private async Task RepairSelectedAsync()
        {
            if (IsRunning) return;

            var checkedRows = _allFindings.Where(f => f.IsSelected).ToList();
            var selected = checkedRows
                .Where(f => f.Repairable)
                .Select(f => f.Id)
                .Where(id => !string.IsNullOrWhiteSpace(id))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();

            if (selected.Count == 0)
            {
                string message;
                if (checkedRows.Any(f => f.CanManageInStartup))
                {
                    message =
                        "Startup items are review-only in this scanner.\n\n" +
                        "Use the Manage button on a row (or Startup Manager) to disable or delete the entry.";
                }
                else if (checkedRows.Count > 0)
                {
                    message =
                        "The selected item(s) are flagged for review only and cannot be auto-repaired here.\n\n" +
                        "Check the ACTION column - only Fix here items can use Repair Selected.";
                }
                else
                {
                    message = "Select one or more repairable items (ACTION = Fix here), then try again.";
                }

                MessageBox.Show(
                    message,
                    "Repair Selected",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            var confirm = MessageBox.Show(
                $"Repair {selected.Count} selected item(s)?\n\n" +
                "Backups are created where applicable. DNS, proxy, and security settings may change.\n\n" +
                "Administrator approval (UAC) may be required — accept the prompt if it appears.",
                "Repair Selected",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);
            if (confirm != MessageBoxResult.Yes)
                return;

            var confirmHosts = checkedRows.Any(f =>
                f.Repairable &&
                string.Equals(f.RepairAction, "network.hosts.restore", StringComparison.OrdinalIgnoreCase));
            if (confirmHosts)
            {
                var hostsConfirm = MessageBox.Show(
                    "One or more selected findings restore the hosts file to Windows defaults.\n\n" +
                    "A backup is created first. Continue with hosts restore?",
                    "Confirm hosts file restore",
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Warning,
                    MessageBoxResult.No);
                if (hostsConfirm != MessageBoxResult.Yes)
                    return;
            }

            _allFindings.Clear();
            RefreshDisplayedFindings();
            var idArg = string.Join(",", selected);
            await RunWorkflowAsync(
                _hijackScript,
                BuildHijackRepairParameters(idArg, confirmHostsRestore: confirmHosts),
                "Repair Selected Hijacks",
                "Apply repairs for the checked findings only.");
            RefreshDisplayedFindings();
            ShowHijackRepairOutcome("Repair Selected");
        }

        private void ShowHijackRepairOutcome(string title)
        {
            var step = ResultSteps.FirstOrDefault(s =>
                s.Name.Contains("RepairSelected", StringComparison.OrdinalIgnoreCase));
            if (step is null && ResultSteps.Count == 0)
                return;

            var stillRepairable = _allFindings.Count(f => f.IsFlagged && f.Repairable);
            var output = step?.Output ?? ResultSummary;
            if (string.IsNullOrWhiteSpace(output))
                output = ResultDetails;

            var message = output;
            if (stillRepairable > 0)
            {
                message += $"\n\n{stillRepairable} repairable item(s) are still flagged after re-scan.";
                message += "\n\nSome fixes require Administrator elevation or manual steps (for example Defender tamper protection in Windows Security).";
            }
            else if (step is not null && step.Status.Equals("Pass", StringComparison.OrdinalIgnoreCase))
            {
                message += "\n\nRe-scan shows no remaining repairable findings.";
            }

            var icon = stillRepairable > 0 ||
                       (step is not null && !step.Status.Equals("Pass", StringComparison.OrdinalIgnoreCase))
                ? MessageBoxImage.Warning
                : MessageBoxImage.Information;

            if (!string.IsNullOrWhiteSpace(message))
            {
                MessageBox.Show(message.Trim(), title, MessageBoxButton.OK, icon);
            }
        }

        protected override bool HandleLiveWorkflowOutput(string line)
        {
            if (string.IsNullOrWhiteSpace(line))
                return false;

            var match = HijackTaggedPayloadRegex.Match(line.Trim());
            if (!match.Success)
                return false;

            var kind = match.Groups["kind"].Value.ToUpperInvariant();
            var json = match.Groups["json"].Value;

            try
            {
                if (kind == "FINDING")
                {
                    var finding = JsonSerializer.Deserialize<HijackFindingEvent>(json, new JsonSerializerOptions
                    {
                        PropertyNameCaseInsensitive = true
                    });
                    if (finding is null || string.IsNullOrWhiteSpace(finding.Id))
                        return true;

                    Application.Current?.Dispatcher.Invoke(() =>
                    {
                        _allFindings.RemoveAll(f => string.Equals(f.Id, finding.Id, StringComparison.OrdinalIgnoreCase));
                        _allFindings.Add(HijackFindingItemViewModel.FromEvent(finding));
                        RefreshDisplayedFindings();
                    });
                    return true;
                }

                if (kind == "SCAN")
                {
                    var summary = JsonSerializer.Deserialize<HijackScanCompleteEvent>(json, new JsonSerializerOptions
                    {
                        PropertyNameCaseInsensitive = true
                    });
                    if (summary is null)
                        return true;

                    Application.Current?.Dispatcher.Invoke(() =>
                    {
                        ScanSummary = $"{summary.Total} item(s) | {summary.Flagged} flagged | {summary.Repairable} repairable";
                        if (!string.IsNullOrWhiteSpace(summary.SnapshotPath))
                            _hijackSnapshotPath = summary.SnapshotPath;
                        HasScanResults = true;
                        RefreshDisplayedFindings();
                        _ = EnsureHijackScanReportsAsync();
                    });
                    return true;
                }
            }
            catch
            {
                return false;
            }

            return false;
        }

        private void RefreshDisplayedFindings()
        {
            var previousId = SelectedFinding?.Id;
            DisplayedFindings.Clear();
            foreach (var finding in _allFindings
                         .Where(f => !ShowFlaggedOnly || f.IsFlagged)
                         .OrderBy(f => f.Category, StringComparer.OrdinalIgnoreCase)
                         .ThenBy(f => f.Name, StringComparer.OrdinalIgnoreCase))
            {
                DisplayedFindings.Add(finding);
            }

            if (!string.IsNullOrWhiteSpace(previousId))
            {
                SelectedFinding = DisplayedFindings.FirstOrDefault(f =>
                    string.Equals(f.Id, previousId, StringComparison.OrdinalIgnoreCase));
            }
            else if (SelectedFinding is not null && !DisplayedFindings.Contains(SelectedFinding))
            {
                SelectedFinding = null;
            }
        }

        private void UpdateDetailStatusText()
        {
            var finding = SelectedFinding;
            if (finding is null)
            {
                DetailStatusText = "Select a finding to review details and recommended actions.";
                return;
            }

            var fixState = finding.Repairable
                ? (finding.IsSelected ? "marked for repair" : "not selected for repair")
                : "review only";
            DetailStatusText = $"{finding.Category} | {finding.Severity} | {finding.ActionLabel} | {fixState}";
        }

        private void SetSelectionForDisplayed(bool select)
        {
            foreach (var finding in DisplayedFindings)
            {
                if (!select)
                {
                    finding.IsSelected = false;
                    continue;
                }

                finding.IsSelected = finding.Repairable && finding.IsFlagged;
            }

            UpdateDetailStatusText();
        }

        private async Task RepairThisItemAsync()
        {
            if (IsRunning) return;

            var finding = SelectedFinding;
            if (finding is null)
            {
                MessageBox.Show(
                    "Select a finding first.",
                    "Repair This Item",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            if (!finding.Repairable)
            {
                if (finding.CanManageInStartup)
                {
                    MessageBox.Show(
                        "Startup items are review-only in this scanner.\n\n" +
                        "Use Manage in Startup Manager to disable or delete the entry.",
                        "Repair This Item",
                        MessageBoxButton.OK,
                        MessageBoxImage.Information);
                }
                else
                {
                    MessageBox.Show(
                        "This finding is informational only and cannot be auto-repaired here.",
                        "Repair This Item",
                        MessageBoxButton.OK,
                        MessageBoxImage.Information);
                }

                return;
            }

            var confirm = MessageBox.Show(
                $"Repair this item?\n\n{finding.Name}\n\nBackups are created where applicable.",
                "Repair This Item",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);
            if (confirm != MessageBoxResult.Yes)
                return;

            var confirmHosts = string.Equals(
                finding.RepairAction, "network.hosts.restore", StringComparison.OrdinalIgnoreCase);
            if (confirmHosts)
            {
                var hostsConfirm = MessageBox.Show(
                    "This restores the hosts file to Windows defaults.\n\n" +
                    "A backup is created first. Continue?",
                    "Confirm hosts file restore",
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Warning,
                    MessageBoxResult.No);
                if (hostsConfirm != MessageBoxResult.Yes)
                    return;
            }

            _allFindings.Clear();
            RefreshDisplayedFindings();
            await RunWorkflowAsync(
                _hijackScript,
                BuildHijackRepairParameters(finding.Id, confirmHostsRestore: confirmHosts),
                "Repair Hijack Item",
                "Apply repair for the selected finding.");
            RefreshDisplayedFindings();
            ShowHijackRepairOutcome("Repair This Item");
        }

        private async Task RunRepairAllAsync(ToolItem item, string scriptPath)
        {
            if (IsRunning) return;

            var confirm = MessageBox.Show(
                "This runs browser, network, and security-setting repairs.\n\n" +
                "Browser preferences are backed up first. DNS, proxy, and NRPT rules may change.\n\n" +
                "Continue?",
                "Repair All Hijacks",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);

            if (confirm != MessageBoxResult.Yes)
            {
                item.StatusText = "Cancelled";
                return;
            }

            _allFindings.Clear();
            RefreshDisplayedFindings();
            await RunToolAsync(item, scriptPath);
            RefreshDisplayedFindings();
        }

        private string BuildHijackRepairParameters(string findingIds, bool confirmHostsRestore = false)
        {
            var args = $"-ToolName RepairSelected -FindingIds \"{findingIds}\"";
            if (!string.IsNullOrWhiteSpace(_hijackSnapshotPath))
                args += $" -SnapshotPath \"{_hijackSnapshotPath}\"";
            if (confirmHostsRestore)
                args += " -ConfirmHostsRestore";
            return args;
        }

        private async Task RunHijackToolAsync(ToolItem item)
        {
            if (!DestructiveActionDialog.Confirm(
                    item.Name,
                    item.Description,
                    "Registry, proxy, DNS, and security settings may be reset. A backup is created where applicable.",
                    defaultNo: true))
            {
                item.StatusText = "Cancelled";
                return;
            }

            _allFindings.Clear();
            RefreshDisplayedFindings();
            await RunToolAsync(item, _hijackScript);
            RefreshDisplayedFindings();
        }

        private async Task RunToolAsync(ToolItem item, string scriptPath)
        {
            if (IsRunning) return;
            item.IsRunning = true;
            item.StatusText = "Running...";
            try
            {
                await RunWorkflowAsync(scriptPath, $"-ToolName {item.ToolKey}", item.Name, item.Description);
                item.StatusText = "Done \u2713";
            }
            catch (Exception ex) { item.StatusText = $"Error: {ex.Message}"; }
            finally { item.IsRunning = false; }
        }
    }

    // ── S.M.A.R.T. Analyzer ─────────────────────────────────────────────────
    public sealed class SmartAttributeRow
    {
        public int Id { get; set; }
        public string Name { get; set; } = string.Empty;
        public int Current { get; set; } = -1;
        public int Worst { get; set; } = -1;
        public int Threshold { get; set; } = -1;
        public long Raw { get; set; }
        public string Status { get; set; } = "OK";

        public string IdDisplay => Id.ToString();
        public string CurrentDisplay => Current < 0 ? "-" : Current.ToString();
        public string WorstDisplay => Worst < 0 ? "-" : Worst.ToString();
        public string ThresholdDisplay => Threshold < 0 ? "-" : Threshold.ToString();
        public string RawDisplay => Raw.ToString();

        public Brush StatusColor => SmartHealthBrush.For(Status);
    }

    public sealed class SmartDriveResult
    {
        public int Index { get; set; }
        public string Model { get; set; } = string.Empty;
        public string Serial { get; set; } = string.Empty;
        public string Bus { get; set; } = string.Empty;
        public string Protocol { get; set; } = string.Empty;
        public double SizeGB { get; set; }
        public string Overall { get; set; } = "Unknown";
        public int TemperatureC { get; set; } = -1;
        public bool Supported { get; set; }
        public string Note { get; set; } = string.Empty;
        public ObservableCollection<SmartAttributeRow> Attributes { get; } = new();

        public string DisplayName =>
            $"Drive {Index}: {Model}  ({Bus}, {SizeGB:0.#} GB)";
        public string TempDisplay => TemperatureC >= 0 ? $"{TemperatureC} \u00B0C" : "N/A";
        public string OverallDisplay => string.IsNullOrEmpty(Note) ? Overall : $"{Overall} \u2013 {Note}";
        public Brush OverallColor => SmartHealthBrush.For(Overall);
    }

    internal static class SmartHealthBrush
    {
        private static readonly Brush Green = Freeze(Color.FromRgb(0x3F, 0xB9, 0x50));
        private static readonly Brush Yellow = Freeze(Color.FromRgb(0xD2, 0x99, 0x22));
        private static readonly Brush Red = Freeze(Color.FromRgb(0xF8, 0x51, 0x49));
        private static readonly Brush Gray = Freeze(Color.FromRgb(0x8B, 0x94, 0x9E));

        private static Brush Freeze(Color c)
        {
            var b = new SolidColorBrush(c);
            b.Freeze();
            return b;
        }

        public static Brush For(string status)
        {
            switch ((status ?? string.Empty).Trim().ToLowerInvariant())
            {
                case "ok":
                case "pass":
                case "healthy":
                    return Green;
                case "warn":
                case "warning":
                    return Yellow;
                case "fail":
                case "critical":
                    return Red;
                default:
                    return Gray;
            }
        }
    }

    public sealed class SmartAnalyzerViewModel : INotifyPropertyChanged
    {
        private static readonly JsonSerializerOptions JsonOpts = new() { PropertyNameCaseInsensitive = true };

        public ObservableCollection<SmartDriveResult> Drives { get; } = new();

        private SmartDriveResult? _selectedDrive;
        public SmartDriveResult? SelectedDrive
        {
            get => _selectedDrive;
            set { _selectedDrive = value; OnPropertyChanged(); }
        }

        private bool _isBusy;
        public bool IsBusy
        {
            get => _isBusy;
            set { _isBusy = value; OnPropertyChanged(); }
        }

        private string _statusText = "Ready. Click Scan to read S.M.A.R.T. data.";
        public string StatusText
        {
            get => _statusText;
            set { _statusText = value; OnPropertyChanged(); }
        }

        private string _overallHealth = "Unknown";
        public string OverallHealth
        {
            get => _overallHealth;
            set { _overallHealth = value; OnPropertyChanged(); OnPropertyChanged(nameof(OverallHealthColor)); }
        }

        public Brush OverallHealthColor => SmartHealthBrush.For(OverallHealth);

        public RelayCommand ScanCommand { get; }
        public RelayCommand OpenReportCommand { get; }

        private string _reportPdfPath = string.Empty;
        public bool CanOpenReport => !string.IsNullOrWhiteSpace(_reportPdfPath) && File.Exists(_reportPdfPath);

        public SmartAnalyzerViewModel()
        {
            ScanCommand = new RelayCommand(ScanAsync);
            OpenReportCommand = new RelayCommand(OpenReportAsync);
        }

        public async Task ScanAsync()
        {
            if (IsBusy) return;
            IsBusy = true;
            StatusText = "Scanning storage devices\u2026";
            try
            {
                var script = ToolkitPaths.GetWorkflowScriptPath("SmartAnalyzer.ps1");
                var (output, error) = await PowerShellService.QueryAsync($"& '{script}' -Mode Query");

                if (string.IsNullOrWhiteSpace(output))
                {
                    StatusText = string.IsNullOrWhiteSpace(error)
                        ? "No data returned. Ensure the application is running elevated."
                        : $"Scan error: {error}";
                    return;
                }

                SmartQueryDto? dto;
                try
                {
                    dto = JsonSerializer.Deserialize<SmartQueryDto>(output, JsonOpts);
                }
                catch (Exception ex)
                {
                    StatusText = $"Failed to parse SMART data: {ex.Message}";
                    return;
                }

                Drives.Clear();
                if (dto?.Drives != null)
                {
                    foreach (var d in dto.Drives)
                    {
                        var drive = new SmartDriveResult
                        {
                            Index = d.Index,
                            Model = d.Model ?? string.Empty,
                            Serial = d.Serial ?? string.Empty,
                            Bus = d.Bus ?? string.Empty,
                            Protocol = d.Protocol ?? string.Empty,
                            SizeGB = d.SizeGB,
                            Overall = d.Overall ?? "Unknown",
                            TemperatureC = d.TemperatureC,
                            Supported = d.Supported,
                            Note = d.Note ?? string.Empty
                        };
                        if (d.Attributes != null)
                        {
                            foreach (var a in d.Attributes)
                            {
                                drive.Attributes.Add(new SmartAttributeRow
                                {
                                    Id = a.Id,
                                    Name = a.Name ?? string.Empty,
                                    Current = a.Current,
                                    Worst = a.Worst,
                                    Threshold = a.Threshold,
                                    Raw = a.Raw,
                                    Status = a.Status ?? "OK"
                                });
                            }
                        }
                        Drives.Add(drive);
                    }
                }

                SelectedDrive = Drives.Count > 0 ? Drives[0] : null;

                if (Drives.Count == 0)
                {
                    OverallHealth = "Unknown";
                    StatusText = "No storage devices detected.";
                }
                else if (Drives.Any(x => string.Equals(x.Overall, "Fail", StringComparison.OrdinalIgnoreCase)))
                {
                    OverallHealth = "Critical";
                }
                else if (Drives.Any(x => string.Equals(x.Overall, "Warn", StringComparison.OrdinalIgnoreCase)))
                {
                    OverallHealth = "Warning";
                }
                else if (Drives.Any(x => x.Supported))
                {
                    OverallHealth = "Healthy";
                }
                else
                {
                    OverallHealth = "Unknown";
                }

                if (Drives.Count > 0)
                {
                    int supported = Drives.Count(x => x.Supported);
                    StatusText = $"Scanned {Drives.Count} drive(s); {supported} reporting S.M.A.R.T. data.";
                }

                await EnsureSmartReportAsync();
            }
            finally
            {
                IsBusy = false;
            }
        }

        private async Task OpenReportAsync()
        {
            if (!CanOpenReport)
            {
                MessageBox.Show(
                    "Run a scan first, then open the report.",
                    "Open Report",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            try
            {
                ShellFileOpenHelper.OpenWithDefaultApplication(_reportPdfPath);
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    $"Unable to open the report:\n{ex.Message}",
                    "Open Report",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }

            await Task.CompletedTask;
        }

        private async Task EnsureSmartReportAsync()
        {
            var priorStatus = StatusText;
            StatusText = "Saving S.M.A.R.T. report\u2026";
            try
            {
                if (Drives.Count == 0)
                {
                    StatusText = priorStatus;
                    return;
                }

                // Build the operator PDF from the scan grid. A second powershell.exe
                // -Mode Report pass was leaving status stuck on "Saving..." and never
                // enabling Open Report when Write-Host markers were not captured or the
                // process hung on a SMART re-read.
                var report = BuildSmartWorkflowReportFromDrives();
                var jsonPath = await PersistSmartReportJsonAsync(report);
                var pdfPath = ReportPathHelper.GetOperatorPdfPathForInternalJson(jsonPath);
                if (string.IsNullOrWhiteSpace(pdfPath))
                {
                    StatusText = priorStatus;
                    return;
                }

                if (!File.Exists(pdfPath))
                {
                    string? exportError = null;
                    await Task.Run(() =>
                        WorkflowReportPdfService.TryGeneratePdf(report, pdfPath, out exportError));
                }

                if (File.Exists(pdfPath))
                {
                    _reportPdfPath = pdfPath;
                    OnPropertyChanged(nameof(CanOpenReport));
                }

                StatusText = priorStatus;
            }
            catch
            {
                StatusText = priorStatus;
            }
            finally
            {
                if (StatusText.StartsWith("Saving S.M.A.R.T. report", StringComparison.Ordinal))
                    StatusText = priorStatus;
            }
        }

        private WorkflowExecutionReport BuildSmartWorkflowReportFromDrives()
        {
            var now = DateTime.Now;
            var steps = Drives.Select(d =>
            {
                var status = !d.Supported
                    ? "Skip"
                    : d.Overall.Equals("Fail", StringComparison.OrdinalIgnoreCase) ? "Fail"
                    : d.Overall.Equals("Warn", StringComparison.OrdinalIgnoreCase) ? "Warn"
                    : d.Overall.Equals("Pass", StringComparison.OrdinalIgnoreCase) ? "Pass"
                    : "Warn";
                var detail = d.Supported
                    ? $"{d.Model} [{d.Bus}] {d.SizeGB}GB - Health: {d.Overall}, Temp: {d.TempDisplay}"
                    : $"{d.Model} [{d.Bus}] - {d.Note}";
                return new WorkflowExecutionStep
                {
                    Name = $"Drive {d.Index}: {d.Model}",
                    Status = status,
                    Detail = detail,
                    Output = detail
                };
            }).ToList();

            return new WorkflowExecutionReport
            {
                WorkflowName = "SmartAnalyzer",
                StartTime = now,
                EndTime = now,
                Status = "Completed",
                EnvironmentMode = Environment.GetEnvironmentVariable("SystemDrive")?.Equals("X:", StringComparison.OrdinalIgnoreCase) == true
                    ? "WinPE"
                    : "Windows",
                OverallHealth = OverallHealth,
                Steps = steps
            };
        }

        private static async Task<string> PersistSmartReportJsonAsync(WorkflowExecutionReport report)
        {
            var jsonPath = Path.Combine(
                ReportPathHelper.GetWorkflowDataRoot(),
                $"{WorkflowReportExportHelper.BuildReportBaseName(report)}.json");
            var json = JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true });
            await File.WriteAllTextAsync(jsonPath, json);
            return jsonPath;
        }

        public event PropertyChangedEventHandler? PropertyChanged;
        private void OnPropertyChanged([CallerMemberName] string? name = null) =>
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

        private sealed class SmartQueryDto
        {
            public List<SmartDriveDto>? Drives { get; set; }
        }

        private sealed class SmartDriveDto
        {
            public int Index { get; set; }
            public string? Model { get; set; }
            public string? Serial { get; set; }
            public string? Bus { get; set; }
            public string? Protocol { get; set; }
            public double SizeGB { get; set; }
            public string? Overall { get; set; }
            public int TemperatureC { get; set; }
            public bool Supported { get; set; }
            public string? Note { get; set; }
            public List<SmartAttrDto>? Attributes { get; set; }
        }

        private sealed class SmartAttrDto
        {
            public int Id { get; set; }
            public string? Name { get; set; }
            public int Current { get; set; }
            public int Worst { get; set; }
            public int Threshold { get; set; }
            public long Raw { get; set; }
            public string? Status { get; set; }
        }
    }

    // ── Hardware Diagnostics ──────────────────────────────────────────────────

    public sealed class HwTestItemViewModel : INotifyPropertyChanged
    {
        private string _status = "Queued";
        private string _detail = string.Empty;
        private string _category;
        private string _durationText = string.Empty;
        private bool _isHighlighted;

        public string CategoryKey { get; }
        public string CatalogId { get; }
        public string TestName { get; }
        public string LookupKey { get; }
        public bool IsHeader { get; }
        public bool IsTest => !IsHeader;

        public string Category
        {
            get => _category;
            private set { _category = value; OnPropertyChanged(); OnPropertyChanged(nameof(DisplayName)); }
        }

        public string DisplayName => IsHeader ? Category : TestName;

        public string Status
        {
            get => _status;
            set
            {
                _status = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(StatusLabel));
                OnPropertyChanged(nameof(StatusBrush));
                OnPropertyChanged(nameof(RowBackground));
                OnPropertyChanged(nameof(IsRunningRow));
            }
        }

        public string StatusLabel => Status.ToUpperInvariant() switch
        {
            "PASSED" => "Pass",
            "FAILED" => "Fail",
            "RUNNING" => "Running",
            "QUEUED" => "Queued",
            "WARN" => "Warn",
            "SKIPPED" => "N/A",
            "CANCELLED" => "Cancelled",
            _ => string.Empty
        };

        public string Detail
        {
            get => _detail;
            set
            {
                _detail = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(HasDetail));
            }
        }

        public bool HasDetail => !string.IsNullOrWhiteSpace(Detail);

        public string DurationText
        {
            get => _durationText;
            set { _durationText = value; OnPropertyChanged(); }
        }

        public bool IsRunningRow => string.Equals(Status, "Running", StringComparison.OrdinalIgnoreCase);

        public bool IsHighlighted
        {
            get => _isHighlighted;
            set
            {
                _isHighlighted = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(RowBackground));
            }
        }

        public Brush StatusBrush => Status.ToUpperInvariant() switch
        {
            "PASSED" => new SolidColorBrush(Color.FromRgb(0x0D, 0x7A, 0x3E)),
            "FAILED" => new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C)),
            "RUNNING" => new SolidColorBrush(Color.FromRgb(0x00, 0x78, 0xD4)),
            "QUEUED" => new SolidColorBrush(Color.FromRgb(0x88, 0x88, 0x88)),
            "WARN" => new SolidColorBrush(Color.FromRgb(0x92, 0x68, 0x00)),
            "SKIPPED" => new SolidColorBrush(Color.FromRgb(0x92, 0x68, 0x00)),
            "CANCELLED" => new SolidColorBrush(Color.FromRgb(0x92, 0x68, 0x00)),
            _ => Brushes.Transparent
        };

        public Brush ForegroundBrush => IsHeader
            ? new SolidColorBrush(Color.FromRgb(0x1A, 0x1A, 0x1A))
            : new SolidColorBrush(Color.FromRgb(0x33, 0x33, 0x33));

        public Brush RowBackground
        {
            get
            {
                if (IsHeader)
                    return new SolidColorBrush(Color.FromRgb(0xD6, 0xE4, 0xF0));
                if (IsHighlighted)
                    return new SolidColorBrush(Color.FromRgb(0xFF, 0xF3, 0xCD));
                if (IsRunningRow)
                    return new SolidColorBrush(Color.FromRgb(0xE8, 0xF4, 0xFC));
                return Brushes.White;
            }
        }

        public Thickness RowMargin => IsHeader
            ? new Thickness(0, 10, 0, 2)
            : new Thickness(28, 1, 0, 1);

        public double FontSize => IsHeader ? 13.5 : 12.5;
        public FontWeight FontWeight => IsHeader ? FontWeights.SemiBold : FontWeights.Normal;

        public HwTestItemViewModel(string categoryKey, string testName, bool isHeader, string? lookupKey = null, string? catalogId = null)
        {
            CategoryKey = categoryKey;
            _category = categoryKey;
            TestName = testName;
            CatalogId = catalogId ?? string.Empty;
            IsHeader = isHeader;
            LookupKey = lookupKey ?? (isHeader ? categoryKey : testName);
            if (isHeader) _status = string.Empty;
        }

        public void SetDeviceTitle(string deviceTitle)
        {
            if (!IsHeader) return;
            Category = deviceTitle;
        }

        public event PropertyChangedEventHandler? PropertyChanged;
        private void OnPropertyChanged([CallerMemberName] string? n = null)
            => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
    }

    // ── Diag & Repair (hardware + CST) ────────────────────────────────────────

    public class DiagAndRepairViewModel : WorkflowViewModelBase
    {
        private static readonly Regex HwTaggedPayloadRegex = new(
            @"^\[HW:(?<kind>[A-Z_]+)\]\s*(?<json>\{.*\})$",
            RegexOptions.Compiled | RegexOptions.IgnoreCase);

        private static readonly Regex CstTaggedPayloadRegex = new(
            @"^\[CST:(?<kind>[A-Z]+)\]\s*(?<json>\{.*\})$",
            RegexOptions.Compiled | RegexOptions.IgnoreCase);

        private const string CstCategoryKey = "Security Scan";
        private const string CstTestName = "Core Security Tool";

        private string[] _cpuTestNames = Array.Empty<string>();
        private string[] _memoryTestNames = Array.Empty<string>();
        private string[] _storageTestNames = Array.Empty<string>();
        private int _baseHardwareSubTestCount;

        private DispatcherTimer? _elapsedTimer;
        private DateTime _runStartUtc;
        private int _testsCompleted;
        private int _activeScheduledCount;
        private HashSet<string> _activeTestNames = new(StringComparer.OrdinalIgnoreCase);

        private string _elapsedDisplay = "00:00";
        private string _testsProgressDisplay = "0 / 0";
        private string _phaseDisplay = "Ready";
        private string _summaryBanner = "Select a run to begin hardware and security diagnostics.";
        private string _testProfile = "Quick";
        private string _chuGuidanceBanner = string.Empty;
        private bool _showChuGuidance;

        public string TestProfile
        {
            get => _testProfile;
            set
            {
                if (string.IsNullOrWhiteSpace(value)) return;
                var normalized = value.Equals("Extended", StringComparison.OrdinalIgnoreCase)
                    ? "Extended"
                    : "Quick";
                if (_testProfile == normalized) return;
                _testProfile = normalized;
                OnPropertyChanged();
                OnPropertyChanged(nameof(IsQuickProfile));
                OnPropertyChanged(nameof(IsExtendedProfile));
                OnPropertyChanged(nameof(ProfileDescription));
                ReloadHardwareTestCatalog();
            }
        }

        public bool IsQuickProfile
        {
            get => _testProfile == "Quick";
            set { if (value) TestProfile = "Quick"; }
        }

        public bool IsExtendedProfile
        {
            get => _testProfile == "Extended";
            set { if (value) TestProfile = "Extended"; }
        }

        public string ProfileDescription => _testProfile == "Extended"
            ? "Extended: heavier CPU/memory/disk work, then CST FullScan (scan-only; remediate after). In WinPE, offline client scan requires boot-menu offline load."
            : "Quick: faster hardware triage, then CST ThreatScan (scan-only; remediate after; typically under ~12 min for CST in WinPE).";

        public string WinPeOfflineNote => IsWinPeMode()
            ? "WinPE: choose Offline CDE at boot to scan the client's offline Windows volume with CST."
            : string.Empty;

        public bool ShowWinPeOfflineNote => !string.IsNullOrEmpty(WinPeOfflineNote);

        private static bool IsWinPeMode()
        {
            try
            {
                using var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\MiniNT");
                if (key != null) return true;
            }
            catch
            {
                // Ignore registry lookup failures and continue with fallbacks.
            }

            var systemRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? string.Empty;
            return systemRoot.StartsWith(@"X:\\", StringComparison.OrdinalIgnoreCase);
        }

        public string ElapsedDisplay
        {
            get => _elapsedDisplay;
            set { _elapsedDisplay = value; OnPropertyChanged(); }
        }

        public string TestsProgressDisplay
        {
            get => _testsProgressDisplay;
            set { _testsProgressDisplay = value; OnPropertyChanged(); }
        }

        public string PhaseDisplay
        {
            get => _phaseDisplay;
            set { _phaseDisplay = value; OnPropertyChanged(); }
        }

        public string SummaryBanner
        {
            get => _summaryBanner;
            set { _summaryBanner = value; OnPropertyChanged(); }
        }

        public string ChuGuidanceBanner
        {
            get => _chuGuidanceBanner;
            private set { _chuGuidanceBanner = value; OnPropertyChanged(); }
        }

        public bool ShowChuGuidance
        {
            get => _showChuGuidance;
            private set { _showChuGuidance = value; OnPropertyChanged(); }
        }

        public RelayCommand OpenChuResultsCommand { get; }

        protected override bool ShowWorkflowExecutionWindow => false;

        public ObservableCollection<ToolItem> Tools { get; } = new();
        public ObservableCollection<ToolItem> HardwareTools { get; } = new();
        public ToolItem CstScanTool { get; private set; } = null!;
        public ObservableCollection<HwTestItemViewModel> TestTree { get; } = new();

        private readonly Dictionary<string, HwTestItemViewModel> _testIndex =
            new(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, HwTestItemViewModel> _catalogIdIndex =
            new(StringComparer.OrdinalIgnoreCase);

        public DiagAndRepairViewModel()
        {
            var script = GetScriptPath("HardwareDiagnostics.ps1");
            OpenChuResultsCommand = new RelayCommand(() =>
            {
                NavigationService.Request("ChuResults");
                return Task.CompletedTask;
            });

            Tools.Add(new ToolItem("Run All Tests",
                "Run CPU, Memory, Storage, then CST security scan",
                "All", item => RunToolAsync(item, script)));
            Tools.Add(new ToolItem("CPU Tests",
                "Run all processor sub-tests",
                "CpuTests", item => RunToolAsync(item, script)));
            Tools.Add(new ToolItem("Memory Tests",
                "Run all memory pattern sub-tests",
                "MemoryTests", item => RunToolAsync(item, script)));
            Tools.Add(new ToolItem("Storage Tests",
                "Run all storage / S.M.A.R.T. sub-tests",
                "StorageTests", item => RunToolAsync(item, script)));
            CstScanTool = new ToolItem("CST Scan",
                "Core Security Tool scan only (profile selects ThreatScan vs FullScan)",
                "CstScan", item => RunToolAsync(item, script));
            Tools.Add(CstScanTool);

            foreach (var tool in Tools)
            {
                if (!string.Equals(tool.ToolKey, "CstScan", StringComparison.OrdinalIgnoreCase))
                    HardwareTools.Add(tool);
            }

            ReloadHardwareTestCatalog();
        }

        private void ReloadHardwareTestCatalog()
        {
            _cpuTestNames = HardwareTestCatalogLoader.GetDisplayNames("CPU", _testProfile);
            _memoryTestNames = HardwareTestCatalogLoader.GetDisplayNames("Memory", _testProfile);
            _storageTestNames = HardwareTestCatalogLoader.GetDisplayNames("HardDrive", _testProfile);
            _baseHardwareSubTestCount = _cpuTestNames.Length + _memoryTestNames.Length + _storageTestNames.Length;
            BuildTestTree();
        }

        public void ApplyNavigationContext(string? context)
        {
            ClearTestHighlights();
            if (string.IsNullOrWhiteSpace(context) || !context.StartsWith("highlight:", StringComparison.OrdinalIgnoreCase))
                return;

            var catalogId = context["highlight:".Length..].Trim();
            if (string.IsNullOrWhiteSpace(catalogId))
                return;

            if (_catalogIdIndex.TryGetValue(catalogId, out var item))
                item.IsHighlighted = true;
        }

        private void ClearTestHighlights()
        {
            foreach (var item in TestTree)
                item.IsHighlighted = false;
        }

        private static int GetPhysicalDriveCount() => GetPhysicalDriveSlots().Count;

        private static List<(int Index, string Title)> GetPhysicalDriveSlots() =>
            PhysicalDiskCatalogHelper.GetTestableDriveSlots();

        private static string StorageTestKey(int driveIndex, string testName) =>
            $"{driveIndex}|{testName}";

        private static bool IsStorageCategoryKey(string categoryKey) =>
            categoryKey.StartsWith("Hard Drive|", StringComparison.OrdinalIgnoreCase)
            || string.Equals(categoryKey, "Hard Drive", StringComparison.OrdinalIgnoreCase);

        private int GetStorageScheduledCount()
        {
            var perDrive = _storageTestNames.Length;
            if (perDrive == 0) return 1;
            var drives = GetPhysicalDriveCount();
            return Math.Max(1, drives) * perDrive;
        }

        private int GetAllScheduledCount() =>
            _baseHardwareSubTestCount - _storageTestNames.Length + GetStorageScheduledCount() + 1;

        private void BuildTestTree()
        {
            TestTree.Clear();
            _testIndex.Clear();
            _catalogIdIndex.Clear();

            AddCategory("CPU", "CPU");
            AddCategory("Memory: System Memory", "Memory");
            RebuildStorageCategories();
            AddCategory(CstCategoryKey, CstCategoryKey, new[] { (string.Empty, CstTestName) });
        }

        private void RebuildStorageCategories()
        {
            for (var i = TestTree.Count - 1; i >= 0; i--)
            {
                var item = TestTree[i];
                if (!IsStorageCategoryKey(item.CategoryKey))
                    continue;

                if (!item.IsHeader)
                {
                    var staleKey = _testIndex.FirstOrDefault(kv => ReferenceEquals(kv.Value, item)).Key;
                    if (!string.IsNullOrEmpty(staleKey))
                        _testIndex.Remove(staleKey);
                }

                TestTree.RemoveAt(i);
            }

            foreach (var key in _testIndex.Keys.Where(k => k.Contains('|', StringComparison.Ordinal)).ToList())
                _testIndex.Remove(key);

            var insertAt = TestTree.Count;
            for (var i = 0; i < TestTree.Count; i++)
            {
                if (TestTree[i].IsHeader
                    && string.Equals(TestTree[i].CategoryKey, CstCategoryKey, StringComparison.OrdinalIgnoreCase))
                {
                    insertAt = i;
                    break;
                }
            }

            var at = insertAt;
            foreach (var (index, title) in GetPhysicalDriveSlots())
            {
                var categoryKey = $"Hard Drive|{index}";
                var header = new HwTestItemViewModel(categoryKey, string.Empty, isHeader: true);
                header.SetDeviceTitle($"Hard Drive: {title}");
                TestTree.Insert(at++, header);

                foreach (var (id, test) in HardwareTestCatalogLoader.GetTestsForCategory("HardDrive", _testProfile))
                {
                    var lookupKey = StorageTestKey(index, test);
                    var item = new HwTestItemViewModel(categoryKey, test, isHeader: false, lookupKey, id);
                    TestTree.Insert(at++, item);
                    _testIndex[lookupKey] = item;
                    if (!string.IsNullOrWhiteSpace(id))
                        _catalogIdIndex[id] = item;
                }
            }
        }

        private void AddCategory(string categoryKey, string catalogCategory)
        {
            AddCategory(categoryKey, catalogCategory,
                HardwareTestCatalogLoader.GetTestsForCategory(catalogCategory, _testProfile));
        }

        private void AddCategory(string categoryKey, string catalogCategory, IEnumerable<(string Id, string DisplayName)> tests)
        {
            TestTree.Add(new HwTestItemViewModel(categoryKey, string.Empty, isHeader: true));
            foreach (var (id, displayName) in tests)
            {
                var item = new HwTestItemViewModel(categoryKey, displayName, isHeader: false, lookupKey: displayName, catalogId: id);
                TestTree.Add(item);
                _testIndex[displayName] = item;
                if (!string.IsNullOrWhiteSpace(id))
                    _catalogIdIndex[id] = item;
            }
        }

        private void ResetTestTree(string? categoryFilter)
        {
            foreach (var item in TestTree)
            {
                if (item.IsHeader)
                {
                    if (categoryFilter == null || MatchesCategoryFilter(item.CategoryKey, categoryFilter))
                        RestoreHeaderTitle(item);
                    continue;
                }
                if (categoryFilter != null
                    && !MatchesCategoryFilter(item.CategoryKey, categoryFilter))
                    continue;
                item.Status = "Queued";
                item.Detail = string.Empty;
                item.DurationText = string.Empty;
            }
        }

        private static void RestoreHeaderTitle(HwTestItemViewModel header)
        {
            if (IsStorageCategoryKey(header.CategoryKey)
                && header.CategoryKey.Contains('|', StringComparison.Ordinal)
                && int.TryParse(header.CategoryKey.Split('|')[1], out var driveIndex))
            {
                var slot = GetPhysicalDriveSlots().FirstOrDefault(s => s.Index == driveIndex);
                header.SetDeviceTitle(!string.IsNullOrEmpty(slot.Title)
                    ? $"Hard Drive: {slot.Title}"
                    : header.CategoryKey);
            }
            else
            {
                header.SetDeviceTitle(header.CategoryKey);
            }
        }

        private static bool MatchesCategoryFilter(string categoryKey, string toolKey)
        {
            var prefix = CategoryPrefixForToolKey(toolKey);
            if (string.IsNullOrEmpty(prefix))
                return true;

            if (string.Equals(prefix, "Hard Drive", StringComparison.OrdinalIgnoreCase))
                return IsStorageCategoryKey(categoryKey);

            return categoryKey.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
        }

        private static HwTestItemViewModel? FindHeaderForCategory(
            ObservableCollection<HwTestItemViewModel> tree,
            string? category)
        {
            if (string.IsNullOrWhiteSpace(category)) return null;
            var key = category switch
            {
                "CPU" => "CPU",
                "Memory" => "Memory",
                "Hard Drive" => "Hard Drive",
                "Security Scan" => CstCategoryKey,
                _ => category
            };
            foreach (var item in tree)
            {
                if (!item.IsHeader) continue;
                if (item.CategoryKey.StartsWith(key, StringComparison.OrdinalIgnoreCase)
                    || key.StartsWith(item.CategoryKey, StringComparison.OrdinalIgnoreCase))
                    return item;
            }
            return null;
        }

        private static string CategoryPrefixForToolKey(string toolKey) => toolKey switch
        {
            "CpuTests" => "CPU",
            "MemoryTests" => "Memory",
            "StorageTests" => "Hard Drive",
            "CstScan" => CstCategoryKey,
            _ => string.Empty
        };

        private HwTestItemViewModel? GetCstTestItem() =>
            _testIndex.TryGetValue(CstTestName, out var item) ? item : null;

        private void ApplyDiagCstProgress(DiagCstProgressEvent progress)
        {
            var cstItem = GetCstTestItem();
            if (cstItem is not null
                && !string.Equals(cstItem.Status, "Passed", StringComparison.OrdinalIgnoreCase)
                && !string.Equals(cstItem.Status, "Failed", StringComparison.OrdinalIgnoreCase)
                && !string.Equals(cstItem.Status, "Skipped", StringComparison.OrdinalIgnoreCase))
            {
                cstItem.Status = "Running";
            }

            var effectivePercent = CstScanProgressHelper.ResolveDisplayPercent(
                progress.Phase,
                progress.Scanned,
                progress.ProgressTotal,
                progress.OverallPercent,
                progress.Percent);
            var percent = Math.Max(0.0, Math.Min(100.0, effectivePercent));
            if (percent > 0)
            {
                Progress = Math.Clamp((int)Math.Round(percent), 0, 100);
                ProgressPercentText = $"{percent:0.0}%";
            }

            var phase = (progress.Phase ?? string.Empty).Trim();
            var phaseUpper = phase.ToUpperInvariant();
            var detail = progress.Detail ?? string.Empty;
            var currentPath = string.IsNullOrWhiteSpace(progress.CurrentPath)
                ? string.Empty
                : progress.CurrentPath.Trim();

            string streamingLine;
            if (phaseUpper == "TARGETPREP")
            {
                streamingLine = string.IsNullOrWhiteSpace(detail)
                    ? "Preparing scan targets..."
                    : detail;
                PhaseDisplay = "Security Scan — preparing";
            }
            else if (phaseUpper == "ENUMERATING")
            {
                streamingLine = string.IsNullOrWhiteSpace(detail)
                    ? "Enumerating scan candidates..."
                    : detail;
                PhaseDisplay = "Security Scan — enumerating";
            }
            else if (phaseUpper == "COMPLETED")
            {
                streamingLine = string.IsNullOrWhiteSpace(detail)
                    ? "Finalizing results..."
                    : detail;
                PhaseDisplay = "Security Scan — finalizing";
            }
            else if (!string.IsNullOrWhiteSpace(currentPath))
            {
                streamingLine = currentPath;
                PhaseDisplay = "Security Scan";
            }
            else if (!string.IsNullOrWhiteSpace(detail))
            {
                streamingLine = detail;
                PhaseDisplay = string.IsNullOrWhiteSpace(phase) ? "Security Scan" : phase;
            }
            else
            {
                streamingLine = "Scanning...";
                PhaseDisplay = string.IsNullOrWhiteSpace(phase) ? "Security Scan" : phase;
            }

            if (cstItem is not null)
                cstItem.Detail = streamingLine;

            if (progress.ProgressTotal > 0 || progress.Scanned > 0)
            {
                var total = progress.ProgressTotal > 0 ? progress.ProgressTotal : progress.Scanned;
                TestsProgressDisplay = $"{progress.Scanned:N0} / {total:N0} files";
                StatusText = percent > 0
                    ? $"{ProgressPercentText} • {TestsProgressDisplay}"
                    : TestsProgressDisplay;
            }
            else if (percent > 0)
            {
                StatusText = ProgressPercentText;
            }
        }

        private void FinalizeCstTestFromReport(string? reportJsonPath)
        {
            var cstItem = GetCstTestItem();
            if (cstItem is null)
                return;

            var status = "Passed";
            var detail = string.Empty;
            if (!string.IsNullOrWhiteSpace(reportJsonPath) && File.Exists(reportJsonPath))
            {
                try
                {
                    var opts = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
                    var report = JsonSerializer.Deserialize<WorkflowExecutionReport>(
                        File.ReadAllText(reportJsonPath), opts);
                    var cstStep = report?.Steps?.FirstOrDefault(step =>
                        string.Equals(step.Name, "CoreSecurityTool", StringComparison.OrdinalIgnoreCase));
                    if (cstStep is not null)
                    {
                        detail = ExtractCstDetailFromStep(cstStep);
                        status = cstStep.Status?.ToUpperInvariant() switch
                        {
                            "FAIL" => "Failed",
                            "SKIP" => "Skipped",
                            "WARN" => LooksLikeCstNoTargetResult(cstStep) ? "Skipped" : "Warn",
                            _ => "Passed"
                        };
                    }
                }
                catch
                {
                    status = "Passed";
                }
            }

            cstItem.Status = status;
            cstItem.Detail = detail;
            RefreshTestsProgressDisplay();
        }

        private static bool LooksLikeCstNoTargetResult(WorkflowExecutionStep step)
        {
            if (string.Equals(step.Status, "Skip", StringComparison.OrdinalIgnoreCase))
                return true;

            var text = $"{step.Output}\n{step.Detail}";
            if (text.Contains("no offline Windows installation is available for CST", StringComparison.OrdinalIgnoreCase)
                || text.Contains("WinPE: no offline Windows installation is available", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            if (CstNoEligibleTargetsRegex.IsMatch(text))
                return true;

            return text.Contains("Coverage           : NoTargets", StringComparison.OrdinalIgnoreCase)
                || text.Contains("Coverage: NoTargets", StringComparison.OrdinalIgnoreCase);
        }

        private static readonly Regex CstNoEligibleTargetsRegex = new(
            @"No\s+Eligible\s+Targets\s*:\s*True\b",
            RegexOptions.Compiled | RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

        private static string ExtractCstDetailFromStep(WorkflowExecutionStep step)
        {
            var output = step.Output ?? step.Detail ?? string.Empty;
            if (string.IsNullOrWhiteSpace(output))
                return string.Empty;

            foreach (var line in output.Split('\n'))
            {
                var trimmed = line.Trim();
                if (trimmed.StartsWith("Warnings Found", StringComparison.OrdinalIgnoreCase))
                    return $"{trimmed[(trimmed.IndexOf(':') + 1)..].Trim()} warning(s)";
                if (trimmed.StartsWith("Threats Found", StringComparison.OrdinalIgnoreCase))
                    return $"{trimmed[(trimmed.IndexOf(':') + 1)..].Trim()} threat(s)";
                if (trimmed.StartsWith("Coverage Reason", StringComparison.OrdinalIgnoreCase))
                    return trimmed[(trimmed.IndexOf(':') + 1)..].Trim();
                if (trimmed.StartsWith("Offline Root", StringComparison.OrdinalIgnoreCase))
                    return $"Scan root: {trimmed[(trimmed.IndexOf(':') + 1)..].Trim()}";
            }

            if (LooksLikeCstNoTargetResult(step))
            {
                var firstLine = output.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim();
                return firstLine ?? "CST could not resolve scan targets in WinPE.";
            }

            return string.Empty;
        }

        private void RefreshTestsProgressDisplay()
        {
            var inScope = TestTree.Where(t => t.IsTest && _activeTestNames.Contains(t.LookupKey));
            var completed = inScope.Count(t => t.Status is "Passed" or "Failed" or "Skipped" or "Warn" or "Cancelled");
            _testsCompleted = completed;
            TestsProgressDisplay = $"{completed} / {_activeScheduledCount}";
        }

        private HashSet<string> BuildActiveTestNames(string toolKey) => toolKey switch
        {
            "CpuTests" => _cpuTestNames.ToHashSet(StringComparer.OrdinalIgnoreCase),
            "MemoryTests" => _memoryTestNames.ToHashSet(StringComparer.OrdinalIgnoreCase),
            "StorageTests" => BuildStorageLookupKeys().ToHashSet(StringComparer.OrdinalIgnoreCase),
            "CstScan" => new HashSet<string>(StringComparer.OrdinalIgnoreCase) { CstTestName },
            _ => _cpuTestNames
                .Concat(_memoryTestNames)
                .Concat(BuildStorageLookupKeys())
                .Append(CstTestName)
                .ToHashSet(StringComparer.OrdinalIgnoreCase)
        };

        private IEnumerable<string> BuildStorageLookupKeys()
        {
            foreach (var (index, _) in GetPhysicalDriveSlots())
            {
                foreach (var test in _storageTestNames)
                    yield return StorageTestKey(index, test);
            }
        }

        protected override bool HandleLiveWorkflowOutput(string line)
        {
            if (string.IsNullOrWhiteSpace(line))
                return false;

            var cstMatch = CstTaggedPayloadRegex.Match(line);
            if (cstMatch.Success)
            {
                var cstKind = cstMatch.Groups["kind"].Value.ToUpperInvariant();
                if (!string.Equals(cstKind, "PROGRESS", StringComparison.OrdinalIgnoreCase))
                    return true;

                var cstJson = cstMatch.Groups["json"].Value;
                try
                {
                    var progress = JsonSerializer.Deserialize<DiagCstProgressEvent>(cstJson,
                        new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
                    if (progress is null)
                        return true;

                    App.Current.Dispatcher.BeginInvoke(new Action(() =>
                        ApplyDiagCstProgress(progress)));
                }
                catch
                {
                    return true;
                }

                return true;
            }

            var match = HwTaggedPayloadRegex.Match(line);
            if (!match.Success)
                return false;

            var kind = match.Groups["kind"].Value.ToUpperInvariant();
            var json = match.Groups["json"].Value;

            try
            {
                if (kind == "GUIDANCE")
                {
                    var guidance = JsonSerializer.Deserialize<HwGuidanceEvent>(json,
                        new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
                    if (guidance is null) return true;

                    App.Current.Dispatcher.BeginInvoke(new Action(() =>
                    {
                        ApplyChuGuidance(guidance);
                    }));
                    return true;
                }

                if (kind == "TEST")
                {
                    var evt = JsonSerializer.Deserialize<HwTestEvent>(json,
                        new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
                    if (evt is null) return true;

                    App.Current.Dispatcher.BeginInvoke(new Action(() =>
                    {
                        if (string.Equals(evt.Status, "Header", StringComparison.OrdinalIgnoreCase)
                            && !string.IsNullOrWhiteSpace(evt.Detail))
                        {
                            if (evt.DriveIndex >= 0)
                            {
                                var driveHeader = TestTree.FirstOrDefault(t =>
                                    t.IsHeader
                                    && string.Equals(
                                        t.CategoryKey,
                                        $"Hard Drive|{evt.DriveIndex}",
                                        StringComparison.OrdinalIgnoreCase));
                                driveHeader?.SetDeviceTitle(evt.Detail!);
                            }
                            else
                            {
                                FindHeaderForCategory(TestTree, evt.Category)?.SetDeviceTitle(evt.Detail!);
                            }

                            return;
                        }

                        string? lookupKey = null;
                        if (evt.DriveIndex >= 0 && !string.IsNullOrWhiteSpace(evt.Test))
                            lookupKey = StorageTestKey(evt.DriveIndex, evt.Test!);
                        else if (!string.IsNullOrWhiteSpace(evt.Test))
                            lookupKey = evt.Test;

                        if (!string.IsNullOrWhiteSpace(lookupKey)
                            && _testIndex.TryGetValue(lookupKey, out var item))
                        {
                            item.Status = evt.Status ?? "Running";
                            if (!string.IsNullOrWhiteSpace(evt.Detail))
                                item.Detail = evt.Detail!;
                            if (evt.DurationSec > 0)
                                item.DurationText = $"{evt.DurationSec:0.0}s";

                            if (string.Equals(evt.Status, "Passed", StringComparison.OrdinalIgnoreCase)
                                || string.Equals(evt.Status, "Failed", StringComparison.OrdinalIgnoreCase)
                                || string.Equals(evt.Status, "Skipped", StringComparison.OrdinalIgnoreCase)
                                || string.Equals(evt.Status, "Warn", StringComparison.OrdinalIgnoreCase))
                            {
                                RefreshTestsProgressDisplay();
                            }
                        }
                    }));
                    return true;
                }

                if (kind == "PROGRESS")
                {
                    var evt = JsonSerializer.Deserialize<HwProgressEvent>(json,
                        new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
                    if (evt is null) return true;

                    App.Current.Dispatcher.BeginInvoke(new Action(() =>
                    {
                        Progress = Math.Clamp(evt.Percent, 0, 100);
                        ProgressPercentText = $"{evt.Percent}%";
                        StatusText = ProgressPercentText;
                        if (evt.Total > 0)
                            TestsProgressDisplay = $"{evt.Scanned} / {evt.Total}";
                        if (!string.IsNullOrWhiteSpace(evt.CurrentTest))
                            PhaseDisplay = evt.CurrentTest!;
                        if (!string.IsNullOrWhiteSpace(evt.Phase))
                            PhaseDisplay = evt.Phase!;

                        if (!string.IsNullOrWhiteSpace(evt.CurrentTest)
                            && evt.CurrentTest.Contains("Core Security Tool", StringComparison.OrdinalIgnoreCase))
                        {
                            var cstRow = GetCstTestItem();
                            if (cstRow is not null)
                                cstRow.Status = "Running";
                        }
                        else if (!string.IsNullOrWhiteSpace(evt.Phase)
                            && evt.Phase.Contains("Security Scan", StringComparison.OrdinalIgnoreCase))
                        {
                            var cstRow = GetCstTestItem();
                            if (cstRow is not null)
                                cstRow.Status = "Running";
                        }
                    }));
                    return true;
                }
            }
            catch
            {
                return false;
            }

            return false;
        }

        private void StartElapsedTimer()
        {
            _runStartUtc = DateTime.UtcNow;
            _elapsedTimer?.Stop();
            _elapsedTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            _elapsedTimer.Tick += (_, _) =>
            {
                var elapsed = DateTime.UtcNow - _runStartUtc;
                ElapsedDisplay = $"{(int)elapsed.TotalMinutes:D2}:{elapsed.Seconds:D2}";
            };
            _elapsedTimer.Start();
            ElapsedDisplay = "00:00";
        }

        private void StopElapsedTimer()
        {
            _elapsedTimer?.Stop();
            _elapsedTimer = null;
        }

        private int GetScheduledTestCount(string toolKey) => toolKey switch
        {
            "CpuTests" => _cpuTestNames.Length,
            "MemoryTests" => _memoryTestNames.Length,
            "StorageTests" => GetStorageScheduledCount(),
            "CstScan" => 1,
            _ => GetAllScheduledCount()
        };

        private static bool IncludesCstPhase(string toolKey) =>
            string.Equals(toolKey, "All", StringComparison.OrdinalIgnoreCase)
            || string.Equals(toolKey, "CstScan", StringComparison.OrdinalIgnoreCase);

        private async Task RunToolAsync(ToolItem item, string scriptPath)
        {
            if (IsRunning) return;

            var toolKey = item.ToolKey;
            if (string.Equals(toolKey, "All", StringComparison.OrdinalIgnoreCase)
                || string.Equals(toolKey, "StorageTests", StringComparison.OrdinalIgnoreCase))
            {
                RebuildStorageCategories();
            }

            var scheduled = GetScheduledTestCount(toolKey);
            _activeScheduledCount = scheduled;
            _activeTestNames = BuildActiveTestNames(toolKey);
            if (string.Equals(toolKey, "CstScan", StringComparison.OrdinalIgnoreCase))
                ResetTestTree("CstScan");
            else
                ResetTestTree(toolKey == "All" ? null : toolKey);

            _testsCompleted = 0;
            TestsProgressDisplay = $"0 / {scheduled}";
            SummaryBanner = $"Running {item.Name} ({TestProfile} profile)...";
            PhaseDisplay = "Initializing";
            ClearChuGuidance();
            StartElapsedTimer();

            item.IsRunning = true;
            item.StatusText = "Running...";
            var cancelled = false;
            try
            {
                cancelled = await RunWorkflowAsync(
                    scriptPath,
                    $"-ToolName {toolKey} -TestProfile {TestProfile}",
                    item.Name,
                    $"{item.Description} Profile: {TestProfile}.");

                if (cancelled)
                {
                    MarkRemainingHardwareTestsCancelled();
                    SummaryBanner = "Stopped by user.";
                    PhaseDisplay = "Stopped";
                    item.StatusText = "Cancelled";
                    return;
                }

                FinalizeStuckHardwareTests(ReportJsonPath);

                if (IncludesCstPhase(toolKey))
                {
                    FinalizeCstTestFromReport(ReportJsonPath);
                    await CstRemediationService.TryOpenFindingsOperatorDialogAsync(ReportJsonPath);
                }

                if (string.Equals(toolKey, "CstScan", StringComparison.OrdinalIgnoreCase))
                {
                    SummaryBanner = "CST scan completed. Review findings or remediate from the dialog if shown.";
                    item.StatusText = "Done \u2713";
                }
                else
                {
                    var failed = TestTree.Count(t => t.IsTest && t.Status == "Failed");
                    var warned = TestTree.Count(t => t.IsTest && t.Status == "Warn");
                    SummaryBanner = failed > 0
                        ? IncludesCstPhase(toolKey)
                            ? $"Hardware completed with {failed} failed sub-test(s); CST phase finished."
                            : $"Completed with {failed} failed sub-test(s)."
                        : warned > 0
                            ? IncludesCstPhase(toolKey)
                                ? $"Hardware completed with {warned} warning(s); CST phase finished."
                                : $"Completed with {warned} warning(s)."
                            : IncludesCstPhase(toolKey)
                                ? "Hardware and CST scan completed."
                                : "All scheduled sub-tests completed.";
                    if (ShowChuGuidance)
                        SummaryBanner += " " + ChuGuidanceBanner;
                    item.StatusText = failed > 0 ? "Done with errors" : "Done \u2713";
                }
            }
            catch (Exception ex)
            {
                SummaryBanner = $"Diag & Repair run ended with an error: {ex.Message}";
                PhaseDisplay = "Error";
                item.StatusText = "Error";
                if (IncludesCstPhase(toolKey))
                {
                    var cstItem = GetCstTestItem();
                    if (cstItem is not null
                        && string.Equals(cstItem.Status, "Running", StringComparison.OrdinalIgnoreCase))
                    {
                        cstItem.Status = "Failed";
                        cstItem.Detail = string.Empty;
                    }
                }
            }
            finally
            {
                item.IsRunning = false;
                StopElapsedTimer();
                if (!cancelled && PhaseDisplay != "Error")
                    PhaseDisplay = "Complete";
                if (IncludesCstPhase(toolKey))
                    RefreshTestsProgressDisplay();
            }
        }

        private void MarkRemainingHardwareTestsCancelled()
        {
            foreach (var test in TestTree.Where(t => t.IsTest
                && (string.Equals(t.Status, "Running", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(t.Status, "Queued", StringComparison.OrdinalIgnoreCase))))
            {
                test.Status = string.Equals(test.Status, "Running", StringComparison.OrdinalIgnoreCase)
                    ? "Cancelled"
                    : "Skipped";
                if (string.IsNullOrWhiteSpace(test.Detail))
                    test.Detail = "Cancelled by user.";
            }

            RefreshTestsProgressDisplay();
        }

        private void FinalizeStuckHardwareTests(string? reportJsonPath)
        {
            var stuck = TestTree
                .Where(t => t.IsTest
                    && _activeTestNames.Contains(t.LookupKey)
                    && (string.Equals(t.Status, "Running", StringComparison.OrdinalIgnoreCase)
                        || string.Equals(t.Status, "Queued", StringComparison.OrdinalIgnoreCase)))
                .ToList();
            if (stuck.Count == 0)
                return;

            Dictionary<string, WorkflowExecutionStep>? stepsByName = null;
            if (!string.IsNullOrWhiteSpace(reportJsonPath) && File.Exists(reportJsonPath))
            {
                try
                {
                    var opts = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
                    var report = JsonSerializer.Deserialize<WorkflowExecutionReport>(
                        File.ReadAllText(reportJsonPath), opts);
                    stepsByName = report?.Steps?
                        .Where(s => !string.IsNullOrWhiteSpace(s.Name))
                        .GroupBy(s => s.Name!, StringComparer.OrdinalIgnoreCase)
                        .ToDictionary(g => g.Key, g => g.Last(), StringComparer.OrdinalIgnoreCase);
                }
                catch
                {
                    stepsByName = null;
                }
            }

            foreach (var item in stuck)
            {
                if (stepsByName is not null
                    && stepsByName.TryGetValue(item.LookupKey, out var step))
                {
                    var detail = step.Detail ?? step.Output ?? string.Empty;
                    item.Status = step.Status?.ToUpperInvariant() switch
                    {
                        "FAIL" => "Failed",
                        "SKIP" => "Skipped",
                        "WARN" => "Warn",
                        _ => "Passed"
                    };
                    if (!string.IsNullOrWhiteSpace(detail))
                        item.Detail = detail;
                    continue;
                }

                item.Status = "Warn";
                if (string.IsNullOrWhiteSpace(item.Detail))
                    item.Detail = "Live status update was missed; see the workflow report for details.";
            }

            RefreshTestsProgressDisplay();
        }

        private void ClearChuGuidance()
        {
            ShowChuGuidance = false;
            ChuGuidanceBanner = string.Empty;
        }

        private void ApplyChuGuidance(HwGuidanceEvent guidance)
        {
            if (guidance.RecommendChu != true)
            {
                ClearChuGuidance();
                return;
            }

            var reasons = guidance.Reasons ?? Array.Empty<string>();
            var parts = new List<string>();
            if (reasons.Any(r => string.Equals(r, "memory_coverage", StringComparison.OrdinalIgnoreCase)))
                parts.Add("memory coverage is partial under Windows");
            if (reasons.Any(r => string.Equals(r, "cpu_stress", StringComparison.OrdinalIgnoreCase)))
                parts.Add("CPU timed stress reported a problem");
            if (reasons.Any(r => string.Equals(r, "storage_elevation", StringComparison.OrdinalIgnoreCase)))
                parts.Add("storage physical reads need Administrator");

            var detail = parts.Count > 0
                ? string.Join("; ", parts)
                : "hardware coverage under Windows is incomplete";

            ChuGuidanceBanner =
                $"Windows Diag & Repair note: {detail}. For intermittent faults, run CHU from the USB pre-boot menu, then open CHU Pre-Boot Results.";
            ShowChuGuidance = true;
        }

        private sealed class DiagCstProgressEvent
        {
            public int Scanned { get; set; }
            public int ProgressTotal { get; set; }
            public double Percent { get; set; }
            public string? Phase { get; set; }
            public double? OverallPercent { get; set; }
            public string? Detail { get; set; }
            public string? CurrentPath { get; set; }
        }

        private sealed class HwGuidanceEvent
        {
            public bool? RecommendChu { get; set; }
            public string[]? Reasons { get; set; }
        }

        private sealed class HwTestEvent
        {
            public string? Category { get; set; }
            public string? Test { get; set; }
            public string? Status { get; set; }
            public string? Detail { get; set; }
            public double DurationSec { get; set; }
            public int DriveIndex { get; set; } = -1;
        }

        private sealed class HwProgressEvent
        {
            public int Percent { get; set; }
            public int Scanned { get; set; }
            public int Total { get; set; }
            public string? CurrentTest { get; set; }
            public string? Phase { get; set; }
        }
    }
}

