using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using ToolkitGUI;
using ToolkitGUI.Models;
using ToolkitGUI.Services;
using ToolkitGUI.Views;

namespace ToolkitGUI.ViewModels
{
    /// <summary>Base ViewModel shared by all workflow views.</summary>
    public abstract class WorkflowViewModelBase : INotifyPropertyChanged
    {
        private static readonly Regex StructuredResultLineRegex = new(@"^\[(?<source>[^\]]+)\]\s*(?<name>.+)$", RegexOptions.Compiled);
        private static readonly Regex PostOpStartupPayloadRegex = new(
            @"\[POSTOP:STARTUP\]\s*(?<json>\{.*\})\s*$",
            RegexOptions.Compiled);
        private static readonly Regex AuditEventPayloadRegex = new(
            @"\[AUDIT:EVENT\]\s*(?<json>\{.*\})\s*$",
            RegexOptions.Compiled);

        private bool _isRunning;
        private int _progress;
        private string _statusText = "Ready";
        private string _resultJson = string.Empty;
        private string _logText = string.Empty;
        private string _operationTitle = "Workflow";
        private string _operationDescription = "Execute a workflow task and review the results here.";
        private string _phaseText = "Waiting to start";
        private string _progressCaption = "Ready";
        private string _progressPercentText = "0%";
        private string _resultSummary = "No results yet";
        private string _resultDetails = "Run a workflow to view structured results.";
        private string _resultStatusLabel = "Ready";
        private Brush _resultStatusBrush = new SolidColorBrush(Color.FromRgb(0x00, 0x78, 0xD4));
        private string _reportJsonPath = string.Empty;
        private string _reportHtmlPath = string.Empty;
        private string _reportPdfPath = string.Empty;
        private string _cstResultArtifactPath = string.Empty;
        private string _lastPdfExportError = string.Empty;
        private string _footerText = "Logs and results remain available in this window after the operation finishes.";
        private bool _hasStructuredResult;
        private bool _hasResultErrors;
        private bool _hasWarnings;
        private bool _hasErrors;
        private bool _stopRequested;
        private CancellationTokenSource? _runCancellationTokenSource;
        private readonly HashSet<string> _structuredResultItemIndex = new(StringComparer.OrdinalIgnoreCase);
        private const int MaxVisibleLogLines = 3000;

        public bool IsRunning
        {
            get => _isRunning;
            set { _isRunning = value; OnPropertyChanged(); OnPropertyChanged(nameof(IsIdle)); }
        }

        public bool IsIdle => !_isRunning;

        public int Progress
        {
            get => _progress;
            set { _progress = value; OnPropertyChanged(); }
        }

        public string StatusText
        {
            get => _statusText;
            set { _statusText = value; OnPropertyChanged(); }
        }

        public string ResultJson
        {
            get => _resultJson;
            set { _resultJson = value; OnPropertyChanged(); }
        }

        public string LogText
        {
            get => _logText;
            set { _logText = value; OnPropertyChanged(); }
        }

        public string OperationTitle
        {
            get => _operationTitle;
            set { _operationTitle = value; OnPropertyChanged(); }
        }

        public string OperationDescription
        {
            get => _operationDescription;
            set { _operationDescription = value; OnPropertyChanged(); }
        }

        public string PhaseText
        {
            get => _phaseText;
            set { _phaseText = value; OnPropertyChanged(); }
        }

        public string ProgressCaption
        {
            get => _progressCaption;
            set { _progressCaption = value; OnPropertyChanged(); }
        }

        public string ProgressPercentText
        {
            get => _progressPercentText;
            set { _progressPercentText = value; OnPropertyChanged(); }
        }

        public string ResultSummary
        {
            get => _resultSummary;
            set { _resultSummary = value; OnPropertyChanged(); }
        }

        public string ResultDetails
        {
            get => _resultDetails;
            set { _resultDetails = value; OnPropertyChanged(); }
        }

        public string ResultStatusLabel
        {
            get => _resultStatusLabel;
            set { _resultStatusLabel = value; OnPropertyChanged(); }
        }

        public Brush ResultStatusBrush
        {
            get => _resultStatusBrush;
            set { _resultStatusBrush = value; OnPropertyChanged(); }
        }

        public string ReportJsonPath
        {
            get => _reportJsonPath;
            set
            {
                _reportJsonPath = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(HasJsonReport));
            }
        }

        public string ReportHtmlPath
        {
            get => _reportHtmlPath;
            set
            {
                _reportHtmlPath = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(HasHtmlReport));
            }
        }

        public string ReportPdfPath
        {
            get => _reportPdfPath;
            set
            {
                _reportPdfPath = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(HasPdfReport));
            }
        }

        public string FooterText
        {
            get => _footerText;
            set { _footerText = value; OnPropertyChanged(); }
        }

        public bool HasStructuredResult
        {
            get => _hasStructuredResult;
            set { _hasStructuredResult = value; OnPropertyChanged(); }
        }

        public bool HasResultErrors
        {
            get => _hasResultErrors;
            set { _hasResultErrors = value; OnPropertyChanged(); }
        }

        public bool StopRequested
        {
            get => _stopRequested;
            private set { _stopRequested = value; OnPropertyChanged(); }
        }

        public bool HasJsonReport => !string.IsNullOrWhiteSpace(ReportJsonPath) && File.Exists(ReportJsonPath);

        public bool HasHtmlReport => !string.IsNullOrWhiteSpace(ReportHtmlPath) && File.Exists(ReportHtmlPath);

        public bool HasPdfReport => !string.IsNullOrWhiteSpace(ReportPdfPath) && File.Exists(ReportPdfPath);

        public string CstResultArtifactPath
        {
            get => _cstResultArtifactPath;
            protected set
            {
                _cstResultArtifactPath = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(HasCstResultArtifact));
            }
        }

        public bool HasCstResultArtifact =>
            !string.IsNullOrWhiteSpace(CstResultArtifactPath) && File.Exists(CstResultArtifactPath);

        public bool CanOpenReport =>
            HasPdfReport
            || !string.IsNullOrWhiteSpace(ReportJsonPath)
            || !string.IsNullOrWhiteSpace(WorkflowReportExportHelper.TryExtractWorkflowJson(ResultJson));

        public bool CanOpenHtmlReport => false;

        public bool CanOpenPdfReport => CanOpenReport;

        public ObservableCollection<string> LogLines { get; } = new();
        public ObservableCollection<WorkflowExecutionStepViewModel> ResultSteps { get; } = new();
        public ObservableCollection<string> ResultErrors { get; } = new();
        public ObservableCollection<StructuredResultItemViewModel> StructuredResultItems { get; } = new();

        protected void AppendLog(string line)
        {
            var entry = $"[{DateTime.Now:HH:mm:ss}] {line}";
            App.Current.Dispatcher.BeginInvoke(new Action(() =>
            {
                LogLines.Add(entry);
                var removed = TrimLogLinesIfNeeded();
                if (removed > 0)
                {
                    OnLogLinesTrimmed(removed);
                }
                RebuildLogTextFromLines();
            }));
        }

        protected virtual void OnLogLinesTrimmed(int removedCount)
        {
            // Derived classes can adjust cached log indices when retention trimming occurs.
        }

        protected int TrimLogLinesIfNeeded()
        {
            if (LogLines.Count <= MaxVisibleLogLines)
            {
                return 0;
            }

            var removeCount = LogLines.Count - MaxVisibleLogLines;
            for (var i = 0; i < removeCount; i++)
            {
                LogLines.RemoveAt(0);
            }

            return removeCount;
        }

        protected void RebuildLogTextFromLines()
        {
            LogText = LogLines.Count == 0
                ? string.Empty
                : string.Join(Environment.NewLine, LogLines);
        }

        public virtual void RequestStop()
        {
            if (!IsRunning || StopRequested)
            {
                return;
            }

            StopRequested = true;
            StatusText = "Stopping...";
            ProgressCaption = "Stop requested. Cancelling active scan...";
            AppendLog("Stop requested by user.");
            _runCancellationTokenSource?.Cancel();
        }

        protected async Task RunWorkflowAsync(
            string scriptPath,
            string? parameters = null,
            string? operationTitle = null,
            string? operationDescription = null)
        {
            ResetExecutionState(scriptPath, operationTitle, operationDescription);

            if (ShowWorkflowExecutionWindow)
            {
                var executionWindow = new WorkflowExecutionWindow
                {
                    DataContext = this,
                    Owner = Application.Current?.Windows.OfType<Window>().FirstOrDefault(window => window.IsActive)
                };
                executionWindow.Show();
                executionWindow.Activate();
            }

            IsRunning = true;
            StopRequested = false;
            _runCancellationTokenSource = new CancellationTokenSource();
            Progress = 0;
            StatusText = "Running...";
            ProgressCaption = "Launching workflow";
            PhaseText = "Preparing execution environment";

            try
            {
                AppendLog($"Starting workflow: {Path.GetFileName(scriptPath)}");

                var result = await PowerShellService.RunWorkflowAsync(
                    scriptPath,
                    parameters,
                    _runCancellationTokenSource.Token,
                    line =>
                    {
                        if (!HandleLiveWorkflowOutput(line))
                        {
                            AppendLog(line);
                            UpdateExecutionStateFromOutput(line);
                            Progress = Math.Min(Progress + 2, 92);
                            ProgressPercentText = $"{Progress}%";
                        }
                    });

                ResultJson = result.Stdout;
                Progress = 100;
                ProgressPercentText = "100%";
                await LoadStructuredResultAsync();

                // A non-zero exit code is the script's automation backstop. Surface it
                // as an error even when the structured report did not flag a failure,
                // and include any stderr so the cause is visible.
                if (result.ExitCode != 0)
                {
                    _hasErrors = true;
                    var detail = string.IsNullOrWhiteSpace(result.Stderr)
                        ? $"Workflow exited with code {result.ExitCode}."
                        : result.Stderr.Trim();
                    if (ResultErrors.Count == 0)
                    {
                        ResultErrors.Add(detail);
                        HasResultErrors = true;
                    }
                    ResultSummary = "Completed with issues that need attention";
                    AppendLog($"Workflow exited with code {result.ExitCode}.");
                }

                CompleteExecutionState();
                AppendLog(_hasErrors
                    ? "Workflow completed with errors."
                    : _hasWarnings
                        ? "Workflow completed with warnings."
                        : "Workflow completed successfully.");
            }
            catch (OperationCanceledException)
            {
                StatusText = "Stopped";
                ResultStatusLabel = "Stopped";
                ResultStatusBrush = new SolidColorBrush(Color.FromRgb(0x92, 0x68, 0x00));
                ResultSummary = "The operation was stopped by the user.";
                ResultDetails = "Scan execution was cancelled before completion.";
                FooterText = "You can start a new scan when ready.";
                ProgressCaption = "Execution stopped by user.";
                AppendLog("Execution stopped by user.");
            }
            catch (Exception ex)
            {
                _hasErrors = true;
                StatusText = "Error";
                ResultStatusLabel = "Error";
                ResultStatusBrush = new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C));
                ResultSummary = "The workflow did not complete successfully.";
                ResultDetails = ex.Message;
                FooterText = "Review the live execution stream for the exact failure point.";
                AppendLog($"ERROR: {ex.Message}");
            }
            finally
            {
                IsRunning = false;
                _runCancellationTokenSource?.Dispose();
                _runCancellationTokenSource = null;
            }
        }

        private void ResetExecutionState(string scriptPath, string? operationTitle, string? operationDescription)
        {
            Progress = 0;
            LogLines.Clear();
            ResultSteps.Clear();
            ResultErrors.Clear();
            StructuredResultItems.Clear();
            _structuredResultItemIndex.Clear();
            LogText = string.Empty;
            ResultJson = string.Empty;
            StatusText = "Ready";
            OperationTitle = string.IsNullOrWhiteSpace(operationTitle)
                ? Path.GetFileNameWithoutExtension(scriptPath)
                : operationTitle;
            OperationDescription = string.IsNullOrWhiteSpace(operationDescription)
                ? "A dedicated execution window shows live progress and a structured result summary."
                : operationDescription;
            PhaseText = "Waiting to start";
            ProgressCaption = "Ready";
            ProgressPercentText = "0%";
            ResultSummary = "No results yet";
            ResultDetails = "Structured results will appear here when the workflow completes.";
            ResultStatusLabel = "Running";
            ResultStatusBrush = new SolidColorBrush(Color.FromRgb(0x00, 0x78, 0xD4));
            ReportJsonPath = string.Empty;
            ReportHtmlPath = string.Empty;
            ReportPdfPath = string.Empty;
            CstResultArtifactPath = string.Empty;
            _lastPdfExportError = string.Empty;
            OnPropertyChanged(nameof(CanOpenReport));
            FooterText = "Logs and results remain available in this window after the operation finishes.";
            HasStructuredResult = false;
            HasResultErrors = false;
            StopRequested = false;
            _hasWarnings = false;
            _hasErrors = false;
        }

        private void UpdateExecutionStateFromOutput(string line)
        {
            if (string.IsNullOrWhiteSpace(line))
            {
                return;
            }

            CaptureReportPaths(line);
            var simplified = SimplifyOutputLine(line);
            if (!string.IsNullOrWhiteSpace(simplified))
            {
                PhaseText = simplified;
            }

            if (line.Contains("[WARN]", StringComparison.OrdinalIgnoreCase))
            {
                _hasWarnings = true;
            }
            else if (line.Contains("[ERR]", StringComparison.OrdinalIgnoreCase) || line.Contains("ERROR:", StringComparison.OrdinalIgnoreCase))
            {
                _hasErrors = true;
            }

            ProgressCaption = _hasErrors
                ? "Execution reported errors"
                : _hasWarnings
                    ? "Execution reported warnings"
                    : "Execution is in progress";
        }

        private void CaptureReportPaths(string line)
        {
            if (WorkflowReportExportHelper.TryExtractArtifactPath(line, "Report saved", ".json", out var jsonPath))
            {
                ReportJsonPath = jsonPath;
                OnPropertyChanged(nameof(CanOpenReport));
            }
        }

        private async Task LoadStructuredResultAsync()
        {
            string? json = null;
            if (!string.IsNullOrWhiteSpace(ReportJsonPath) && File.Exists(ReportJsonPath))
            {
                json = await File.ReadAllTextAsync(ReportJsonPath);
            }

            if (string.IsNullOrWhiteSpace(json))
            {
                json = WorkflowReportExportHelper.TryExtractWorkflowJson(ResultJson);
            }

            if (string.IsNullOrWhiteSpace(json))
            {
                BuildFallbackResult();
                return;
            }

            try
            {
                var report = JsonSerializer.Deserialize<WorkflowExecutionReport>(json, new JsonSerializerOptions
                {
                    PropertyNameCaseInsensitive = true
                });

                if (report == null)
                {
                    BuildFallbackResult();
                    return;
                }

                ResultJson = json;
                ResultSteps.Clear();
                foreach (var step in report.Steps ?? Enumerable.Empty<WorkflowExecutionStep>())
                {
                    ResultSteps.Add(new WorkflowExecutionStepViewModel(step));
                }

                var steps = report.Steps ?? Enumerable.Empty<WorkflowExecutionStep>();
                if (IsDiagnosticWorkflow(report.WorkflowName))
                {
                    PopulateDiagnosticStructuredResults(steps);
                }
                else
                {
                    PopulateStructuredResultItems(steps);
                }

                ResultErrors.Clear();
                foreach (var error in report.Errors ?? Enumerable.Empty<string>())
                {
                    if (!string.IsNullOrWhiteSpace(error))
                    {
                        ResultErrors.Add(error);
                    }
                }

                HasResultErrors = ResultErrors.Count > 0;
                HasStructuredResult = true;

                var passCount = (report.Steps ?? new()).Count(step => string.Equals(step.Status, "Pass", StringComparison.OrdinalIgnoreCase));
                var warnCount = (report.Steps ?? new()).Count(step => string.Equals(step.Status, "Warn", StringComparison.OrdinalIgnoreCase));
                var failCount = (report.Steps ?? new()).Count(step => string.Equals(step.Status, "Fail", StringComparison.OrdinalIgnoreCase));
                var workflowFailed = string.Equals(report.Status, "Failed", StringComparison.OrdinalIgnoreCase);
                _hasWarnings |= warnCount > 0;
                _hasErrors |= failCount > 0 || ResultErrors.Count > 0 || workflowFailed;

                ResultSummary = _hasErrors
                    ? "Completed with issues that need attention"
                    : _hasWarnings
                        ? "Completed with warnings"
                        : "Completed successfully";

                var healthText = !string.IsNullOrWhiteSpace(report.OverallHealth)
                    ? report.OverallHealth
                    : (failCount > 0 ? "Critical" : warnCount > 0 ? "Warning" : "Healthy");
                ResultDetails = $"Environment: {report.EnvironmentMode}   |   Health: {healthText}   |   Duration: {report.DurationSec:0.0}s   |   Steps: {report.Steps?.Count ?? 0}   |   Pass: {passCount}   |   Warn: {warnCount}   |   Fail: {failCount}";

                await EnsurePdfReportAsync(report);
                WorkOrderService.TryRecordWorkflowReport(report, ReportJsonPath, reportPdfPath: ReportPdfPath);
                OnPropertyChanged(nameof(CanOpenReport));
                OnPropertyChanged(nameof(CanOpenPdfReport));
            }
            catch (Exception ex)
            {
                _hasWarnings = true;
                ResultSummary = "The workflow completed, but structured results could not be loaded.";
                ResultDetails = ex.Message;
                BuildFallbackResult();
            }
        }

        protected void AddStructuredResultItem(string? itemName)
        {
            var name = itemName ?? string.Empty;
            AddStructuredResultItem(() => StructuredResultItemViewModel.CreatePlain(name));
        }

        protected void AddStructuredResultItem(Func<StructuredResultItemViewModel?> factory)
        {
            if (factory is null)
            {
                return;
            }

            void Apply()
            {
                StructuredResultItemViewModel item;
                try
                {
                    item = factory() ?? new StructuredResultItemViewModel();
                }
                catch
                {
                    return;
                }

                if (string.IsNullOrWhiteSpace(item.Name))
                {
                    return;
                }

                if (_structuredResultItemIndex.Add(item.DedupKey))
                {
                    StructuredResultItems.Add(item);
                    HasStructuredResult = true;
                }
            }

            var dispatcher = Application.Current?.Dispatcher;
            if (dispatcher is null || dispatcher.CheckAccess())
            {
                Apply();
            }
            else
            {
                dispatcher.BeginInvoke(Apply);
            }
        }

        protected void AddStructuredResultItem(StructuredResultItemViewModel? item)
        {
            if (item is null || string.IsNullOrWhiteSpace(item.Name))
            {
                return;
            }

            AddStructuredResultItem(() => item);
        }

        private static bool IsDiagnosticWorkflow(string? workflowName) =>
            string.Equals(workflowName, "SystemHealthCheck", StringComparison.OrdinalIgnoreCase);

        private void PopulateDiagnosticStructuredResults(IEnumerable<WorkflowExecutionStep> steps)
        {
            var issueCount = 0;
            foreach (var step in steps)
            {
                if (!StructuredResultItemViewModel.IsDiagnosticIssueStatus(step.Status))
                {
                    continue;
                }

                var detail = !string.IsNullOrWhiteSpace(step.Output)
                    ? step.Output
                    : (step.Detail ?? string.Empty);
                AddStructuredResultItem(() =>
                    StructuredResultItemViewModel.FromDiagnosticFinding(step.Name, detail, step.Status));
                issueCount++;
            }

            if (issueCount == 0)
            {
                AddStructuredResultItem("No warnings or failures detected in this scan.");
            }
        }

        private void PopulateStructuredResultItems(IEnumerable<WorkflowExecutionStep> steps)
        {
            StructuredResultItems.Clear();
            _structuredResultItemIndex.Clear();

            foreach (var step in steps)
            {
                if (string.Equals(step.Name, "CoreSecurityTool", StringComparison.OrdinalIgnoreCase))
                {
                    PopulateCoreSecurityToolStructuredResults(step);
                    continue;
                }

                var output = !string.IsNullOrWhiteSpace(step.Output)
                    ? step.Output
                    : (step.Detail ?? string.Empty);
                var items = ExtractStructuredResultItems(step.Name, output).ToList();
                if (items.Count == 0)
                {
                    if (string.Equals(step.Name, "EventLogs", StringComparison.OrdinalIgnoreCase))
                    {
                        AddStructuredResultItem("No errors in the last 24 hours.");
                    }
                    else
                    {
                        AddStructuredResultItem(step.Name);
                    }

                    continue;
                }

                foreach (var item in items)
                {
                    AddStructuredResultItem(item);
                }
            }
        }

        private void PopulateCoreSecurityToolStructuredResults(WorkflowExecutionStep step)
        {
            var output = !string.IsNullOrWhiteSpace(step.Output)
                ? step.Output
                : (step.Detail ?? string.Empty);
            var artifactPath = CstStructuredResultsService.ResolveArtifactPathFromStepOutput(output);
            if (string.IsNullOrWhiteSpace(artifactPath))
            {
                CstResultArtifactPath = string.Empty;
                AddStructuredResultItem(CstStructuredResultsService.NoActionableFindingsMessage);
                return;
            }

            CstResultArtifactPath = artifactPath;
            var findings = CstStructuredResultsService.LoadActionableFindings(artifactPath);
            if (findings.Count == 0)
            {
                AddStructuredResultItem(CstStructuredResultsService.NoActionableFindingsMessage);
                return;
            }

            foreach (var finding in findings)
            {
                AddStructuredResultItem(() => StructuredResultItemViewModel.FromCstFinding(
                    finding.Name,
                    finding.Severity,
                    finding.Type,
                    finding.Detector,
                    finding.Evidence,
                    finding.Location));
            }
        }

        private static readonly Regex CstStructuredSeverityLineRegex = new(
            @"^\s*Severity\s*:\s*(?<severity>.+?)\s*$",
            RegexOptions.Compiled | RegexOptions.IgnoreCase);

        private static readonly Regex CstStructuredLocationLineRegex = new(
            @"^\s*Location\s*:\s*(?<location>.+?)\s*$",
            RegexOptions.Compiled | RegexOptions.IgnoreCase);

        internal static IEnumerable<StructuredResultItemViewModel> ExtractStructuredResultItems(string? stepName, string? output)
        {
            if (string.IsNullOrWhiteSpace(output))
            {
                yield break;
            }

            var formatted = WorkflowResultFormatter.Format(stepName, output);
            if (formatted.AllItems.Count > 0)
            {
                foreach (var item in formatted.AllItems)
                {
                    var vm = StructuredResultItemViewModel.FromFormattedItem(item);
                    if (!string.IsNullOrWhiteSpace(vm.Name))
                    {
                        yield return vm;
                    }
                }

                if (!string.Equals(stepName, "CoreSecurityTool", StringComparison.OrdinalIgnoreCase))
                {
                    yield break;
                }
            }

            var isCstStep = string.Equals(stepName, "CoreSecurityTool", StringComparison.OrdinalIgnoreCase);
            var isInstalledSoftwareStep = string.Equals(stepName, "InstalledSoftware", StringComparison.OrdinalIgnoreCase);
            var isServicesStep = string.Equals(stepName, "Services", StringComparison.OrdinalIgnoreCase);
            var isSfcStep = !string.IsNullOrWhiteSpace(stepName)
                && stepName.IndexOf("SFC", StringComparison.OrdinalIgnoreCase) >= 0;

            var lines = output.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
            for (var lineIndex = 0; lineIndex < lines.Length; lineIndex++)
            {
                var line = lines[lineIndex].Trim();
                if (string.Equals(stepName, "StartupAudit", StringComparison.OrdinalIgnoreCase)
                    && TryParsePostOpStartupStructuredLine(line, out var startupItem)
                    && startupItem is not null)
                {
                    yield return startupItem;
                    continue;
                }

                if (string.Equals(stepName, "EventLogs", StringComparison.OrdinalIgnoreCase)
                    && TryParseAuditEventStructuredLine(line, out var eventItem)
                    && eventItem is not null)
                {
                    yield return eventItem;
                    continue;
                }

                var match = StructuredResultLineRegex.Match(line);
                if (!match.Success)
                {
                    if (isInstalledSoftwareStep && TryExtractInstalledSoftwareName(line, out var softwareName))
                    {
                        yield return StructuredResultItemViewModel.CreatePlain(softwareName);
                    }
                    else if (isServicesStep && TryExtractServiceName(line, out var serviceName))
                    {
                        yield return StructuredResultItemViewModel.CreatePlain(serviceName);
                    }
                    else if (isSfcStep && TryExtractSfcResultItem(line, out var sfcItem))
                    {
                        yield return StructuredResultItemViewModel.CreatePlain(sfcItem);
                    }

                    continue;
                }

                var sourceToken = match.Groups["source"].Value.Trim();
                var itemName = match.Groups["name"].Value.Trim();
                if (string.IsNullOrWhiteSpace(itemName))
                {
                    continue;
                }

                if (isCstStep && StructuredResultItemViewModel.IsCstFindingTypeToken(sourceToken))
                {
                    var severity = string.Empty;
                    var location = string.Empty;
                    for (var detailIndex = lineIndex + 1; detailIndex < lines.Length; detailIndex++)
                    {
                        var detailLine = lines[detailIndex].Trim();
                        if (detailLine.StartsWith('[') && StructuredResultLineRegex.IsMatch(detailLine))
                        {
                            break;
                        }

                        var severityMatch = CstStructuredSeverityLineRegex.Match(detailLine);
                        if (severityMatch.Success)
                        {
                            severity = severityMatch.Groups["severity"].Value.Trim();
                            continue;
                        }

                        var locationMatch = CstStructuredLocationLineRegex.Match(detailLine);
                        if (locationMatch.Success)
                        {
                            location = locationMatch.Groups["location"].Value.Trim();
                        }
                    }

                    yield return StructuredResultItemViewModel.FromCstFinding(
                        itemName,
                        severity,
                        sourceToken,
                        location: location);
                    continue;
                }

                if (!isSfcStep && (itemName.Contains('\\') || itemName.Contains('/') || Regex.IsMatch(itemName, @"^[A-Za-z]:\\")))
                {
                    continue;
                }

                yield return StructuredResultItemViewModel.CreatePlain(itemName);
            }
        }

        private static bool TryExtractInstalledSoftwareName(string line, out string softwareName)
        {
            softwareName = string.Empty;
            if (string.IsNullOrWhiteSpace(line))
            {
                return false;
            }

            if (line.StartsWith("INSTALLED APPLICATIONS", StringComparison.OrdinalIgnoreCase)
                || line.StartsWith("Total Programs:", StringComparison.OrdinalIgnoreCase)
                || line.StartsWith("Program Name", StringComparison.OrdinalIgnoreCase)
                || line.All(ch => ch == '-' || char.IsWhiteSpace(ch)))
            {
                return false;
            }

            var columns = Regex.Split(line.TrimEnd(), @"\s{2,}");
            if (columns.Length < 3)
            {
                return false;
            }

            var name = columns[0].Trim();
            if (string.IsNullOrWhiteSpace(name)
                || string.Equals(name, "Program Name", StringComparison.OrdinalIgnoreCase)
                || name.All(ch => ch == '-'))
            {
                return false;
            }

            softwareName = name;
            return true;
        }

        private static bool TryExtractServiceName(string line, out string serviceName)
        {
            serviceName = string.Empty;
            if (string.IsNullOrWhiteSpace(line))
            {
                return false;
            }

            if (line.StartsWith("WINDOWS SERVICES", StringComparison.OrdinalIgnoreCase)
                || line.StartsWith("OFFLINE WINDOWS SERVICES", StringComparison.OrdinalIgnoreCase)
                || line.StartsWith("Total Auto-Start Services:", StringComparison.OrdinalIgnoreCase)
                || line.StartsWith("Currently Stopped:", StringComparison.OrdinalIgnoreCase)
                || line.StartsWith("Control Set:", StringComparison.OrdinalIgnoreCase)
                || line.StartsWith("Service Name", StringComparison.OrdinalIgnoreCase)
                || line.All(ch => ch == '-' || char.IsWhiteSpace(ch)))
            {
                return false;
            }

            var columns = Regex.Split(line.TrimEnd(), @"\s{2,}");
            if (columns.Length < 2)
            {
                return false;
            }

            var name = columns[0].Trim();
            if (string.IsNullOrWhiteSpace(name)
                || string.Equals(name, "Service Name", StringComparison.OrdinalIgnoreCase)
                || name.All(ch => ch == '-'))
            {
                return false;
            }

            serviceName = name;
            return true;
        }

        private static bool TryExtractSfcResultItem(string line, out string item)
        {
            item = string.Empty;
            if (string.IsNullOrWhiteSpace(line))
            {
                return false;
            }

            var normalized = Regex.Replace(line, @"(?<=\p{L})\s+(?=\p{L})", string.Empty);
            normalized = Regex.Replace(normalized, @"\s+", " ").Trim();

            if (normalized.StartsWith("Verification", StringComparison.OrdinalIgnoreCase)
                || normalized.StartsWith("Beginning system scan", StringComparison.OrdinalIgnoreCase)
                || normalized.StartsWith("Beginning verification phase", StringComparison.OrdinalIgnoreCase)
                || normalized.StartsWith("This process will take", StringComparison.OrdinalIgnoreCase)
                || normalized.StartsWith("Windows Resource Protection could not perform", StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            if (normalized.IndexOf("did not find any integrity violations", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                item = "No integrity violations found.";
                return true;
            }

            if (normalized.IndexOf("found corrupt files and successfully repaired", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                item = "Integrity violations found and repaired.";
                return true;
            }

            if (normalized.IndexOf("found corrupt files but was unable to fix", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                item = "Integrity violations found; some could not be repaired.";
                return true;
            }

            if (normalized.IndexOf("CBS.Log", StringComparison.OrdinalIgnoreCase) >= 0
                || normalized.IndexOf("Logs\\CBS", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                item = "Review details: C:\\Windows\\Logs\\CBS\\CBS.log";
                return true;
            }

            if (normalized.StartsWith("[SR]", StringComparison.OrdinalIgnoreCase)
                || normalized.IndexOf("Cannot repair member file", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                item = normalized;
                return true;
            }

            return false;
        }

        private void BuildFallbackResult()
        {
            HasStructuredResult = ResultSteps.Count > 0 || ResultErrors.Count > 0 || !string.IsNullOrWhiteSpace(ResultSummary);
            if (ResultSteps.Count == 0)
            {
                ResultSteps.Clear();
                ResultSteps.Add(new WorkflowExecutionStepViewModel(new WorkflowExecutionStep
                {
                    Name = "Execution Summary",
                    Status = _hasErrors ? "Fail" : _hasWarnings ? "Warn" : "Pass",
                    Output = string.IsNullOrWhiteSpace(LogText)
                        ? "No additional detail was produced by the workflow."
                        : "The workflow finished without a structured report payload. Review the live execution stream on the right for details."
                }));
            }

            HasStructuredResult = true;
        }

        private void CompleteExecutionState()
        {
            ResultStatusLabel = _hasErrors
                ? "Completed with Errors"
                : _hasWarnings
                    ? "Completed with Warnings"
                    : "Completed";
            ResultStatusBrush = _hasErrors
                ? new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C))
                : _hasWarnings
                    ? new SolidColorBrush(Color.FromRgb(0x92, 0x68, 0x00))
                    : new SolidColorBrush(Color.FromRgb(0x0D, 0x7A, 0x3E));
            StatusText = ResultStatusLabel;
            ProgressCaption = "Execution finished";
            FooterText = HasPdfReport
                ? "A PDF report is available in the Logs folder for review or sharing with the customer."
                : CanOpenReport
                    ? "Click Open Report to view the PDF deliverable."
                    : "The structured result summary above is the primary completion view for this workflow.";
            OnPropertyChanged(nameof(CanOpenReport));
            OnPropertyChanged(nameof(CanOpenPdfReport));
        }

        public Task OpenHtmlReportAsync() => OpenPdfReportAsync();

        public async Task OpenPdfReportAsync()
        {
            _lastPdfExportError = string.Empty;
            WorkflowExecutionReport? report = null;

            if (!string.IsNullOrWhiteSpace(ReportJsonPath) && File.Exists(ReportJsonPath))
            {
                try
                {
                    var json = await File.ReadAllTextAsync(ReportJsonPath);
                    report = JsonSerializer.Deserialize<WorkflowExecutionReport>(json, new JsonSerializerOptions
                    {
                        PropertyNameCaseInsensitive = true
                    });
                }
                catch (Exception ex)
                {
                    _lastPdfExportError = ex.Message;
                }
            }

            if (report == null)
            {
                var extracted = WorkflowReportExportHelper.TryExtractWorkflowJson(ResultJson);
                if (!string.IsNullOrWhiteSpace(extracted))
                {
                    try
                    {
                        report = JsonSerializer.Deserialize<WorkflowExecutionReport>(extracted, new JsonSerializerOptions
                        {
                            PropertyNameCaseInsensitive = true
                        });
                    }
                    catch (Exception ex)
                    {
                        _lastPdfExportError = ex.Message;
                    }
                }
            }

            if (report != null)
            {
                await EnsurePdfReportAsync(report);
            }

            if (HasPdfReport)
            {
                ShellFileOpenHelper.OpenWithDefaultApplication(ReportPdfPath);
                return;
            }

            var detail = string.IsNullOrWhiteSpace(_lastPdfExportError)
                ? "The PDF report could not be generated. Ensure the workflow completed and try again."
                : $"The PDF report could not be generated: {_lastPdfExportError}";
            throw new InvalidOperationException(detail);
        }

        private async Task EnsurePdfReportAsync(WorkflowExecutionReport report)
        {
            _lastPdfExportError = string.Empty;
            var jsonPath = await ResolveJsonReportPathAsync(report);
            if (!string.IsNullOrWhiteSpace(jsonPath))
            {
                ReportJsonPath = jsonPath;
                OnPropertyChanged(nameof(HasJsonReport));
                OnPropertyChanged(nameof(CanOpenReport));
            }

            var pdfPath = ReportPathHelper.GetOperatorPdfPathForInternalJson(jsonPath);
            if (string.IsNullOrWhiteSpace(pdfPath))
            {
                _lastPdfExportError = "Could not resolve a PDF output path.";
                return;
            }

            if (File.Exists(pdfPath))
            {
                SetReportPdfPath(pdfPath);
                return;
            }

            string? exportError = null;
            var generated = await Task.Run(() =>
                WorkflowReportPdfService.TryGeneratePdf(report, pdfPath, out exportError));

            if (generated)
            {
                SetReportPdfPath(pdfPath);
                return;
            }

            _lastPdfExportError = exportError ?? "Unknown PDF generation error.";
        }

        private async Task<string> ResolveJsonReportPathAsync(WorkflowExecutionReport report)
        {
            if (!string.IsNullOrWhiteSpace(ReportJsonPath) && File.Exists(ReportJsonPath))
            {
                return ReportJsonPath;
            }

            var logsDir = ReportPathHelper.GetWorkflowDataRoot();
            var baseName = WorkflowReportExportHelper.BuildReportBaseName(report);
            var jsonPath = Path.Combine(logsDir, $"{baseName}.json");

            if (!File.Exists(jsonPath))
            {
                var json = JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true });
                await File.WriteAllTextAsync(jsonPath, json);
            }

            return jsonPath;
        }

        private void SetReportPdfPath(string pdfPath)
        {
            ReportPdfPath = pdfPath;
            OnPropertyChanged(nameof(HasPdfReport));
            OnPropertyChanged(nameof(CanOpenReport));
            if (HasPdfReport)
            {
                FooterText = "A PDF report is available for review or sharing with the customer.";
            }
        }

        protected virtual bool ShowWorkflowExecutionWindow => true;

        protected virtual bool HandleLiveWorkflowOutput(string line)
        {
            return false;
        }

        internal static bool TryGetPostOpStartupFields(
            string? line,
            out string name,
            out string location,
            out string risk,
            out string reasons)
        {
            name = string.Empty;
            location = string.Empty;
            risk = string.Empty;
            reasons = string.Empty;

            if (string.IsNullOrWhiteSpace(line))
            {
                return false;
            }

            var match = PostOpStartupPayloadRegex.Match(line.Trim());
            if (!match.Success)
            {
                return false;
            }

            try
            {
                using var doc = JsonDocument.Parse(match.Groups["json"].Value);
                var root = doc.RootElement;
                name = root.TryGetProperty("name", out var nameEl) ? nameEl.GetString() ?? string.Empty : string.Empty;
                if (string.IsNullOrWhiteSpace(name))
                {
                    return false;
                }

                location = root.TryGetProperty("location", out var locEl) ? locEl.GetString() ?? string.Empty : string.Empty;
                risk = root.TryGetProperty("risk", out var riskEl) ? riskEl.GetString() ?? string.Empty : string.Empty;
                reasons = root.TryGetProperty("reasons", out var reasonsEl) ? reasonsEl.GetString() ?? string.Empty : string.Empty;
                return true;
            }
            catch
            {
                return false;
            }
        }

        internal static bool TryParsePostOpStartupStructuredLine(
            string? line,
            out StructuredResultItemViewModel? item)
        {
            item = null;
            if (!TryGetPostOpStartupFields(line, out var name, out var location, out var risk, out var reasons))
            {
                return false;
            }

            item = StructuredResultItemViewModel.FromStartupAudit(name, location, risk, reasons);
            return !string.IsNullOrWhiteSpace(item.Name);
        }

        internal static bool TryGetAuditEventFields(
            string? line,
            out string logName,
            out string source,
            out int eventId,
            out string message,
            out int occurrenceCount)
        {
            logName = string.Empty;
            source = string.Empty;
            eventId = 0;
            message = string.Empty;
            occurrenceCount = 1;

            if (string.IsNullOrWhiteSpace(line))
            {
                return false;
            }

            var match = AuditEventPayloadRegex.Match(line.Trim());
            if (!match.Success)
            {
                return false;
            }

            try
            {
                using var doc = JsonDocument.Parse(match.Groups["json"].Value);
                var root = doc.RootElement;
                logName = root.TryGetProperty("log", out var logEl) ? logEl.GetString() ?? string.Empty : string.Empty;
                source = root.TryGetProperty("source", out var sourceEl) ? sourceEl.GetString() ?? string.Empty : string.Empty;
                if (root.TryGetProperty("eventId", out var idEl) && idEl.TryGetInt32(out var parsedId))
                {
                    eventId = parsedId;
                }

                message = root.TryGetProperty("message", out var msgEl) ? msgEl.GetString() ?? string.Empty : string.Empty;
                if (root.TryGetProperty("count", out var countEl) && countEl.TryGetInt32(out var parsedCount) && parsedCount > 0)
                {
                    occurrenceCount = parsedCount;
                }

                return !string.IsNullOrWhiteSpace(source) || !string.IsNullOrWhiteSpace(message);
            }
            catch
            {
                return false;
            }
        }

        internal static bool TryParseAuditEventStructuredLine(
            string? line,
            out StructuredResultItemViewModel? item)
        {
            item = null;
            if (!TryGetAuditEventFields(line, out var logName, out var source, out var eventId, out var message, out var occurrenceCount))
            {
                return false;
            }

            item = StructuredResultItemViewModel.FromEventLogEntry(logName, source, eventId, message, occurrenceCount);
            return !string.IsNullOrWhiteSpace(item.Name);
        }

        private static string SimplifyOutputLine(string line)
        {
            var simplified = line.Trim();
            simplified = Regex.Replace(simplified, @"^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]\s*", string.Empty);
            simplified = Regex.Replace(simplified, @"^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]\[(Info|Success|Warn|Error)\]\s*", string.Empty, RegexOptions.IgnoreCase);
            return simplified.Trim();
        }

        internal static string GetScriptPath(string name) => ToolkitPaths.GetWorkflowScriptPath(name);

        public event PropertyChangedEventHandler? PropertyChanged;
        protected void OnPropertyChanged([CallerMemberName] string? name = null)
            => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
