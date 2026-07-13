using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;
using ToolkitGUI.Services;

namespace ToolkitGUI.Views
{
    public partial class ProcessAnalyzerCstResultDialog : Window
    {
        private ProcessAnalyzerCstScanPresentation? _presentation;
        private CancellationTokenSource? _scanCts;
        private bool _scanCompleted;
        private bool _isStartupEntryScan;
        private readonly bool _showMalwareCleanupButton;
        private bool _remediationBusy;
        private bool _pendingResultsApply;
        private string _reportPdfPath = string.Empty;
        private DispatcherTimer? _progressHeartbeatTimer;
        private DateTime _lastProgressUtc = DateTime.MinValue;
        private string _lastProgressDetail = string.Empty;
        private string _lastProgressPhaseText = string.Empty;
        private bool _isPreScanPhase;

        public ProcessAnalyzerCstResultDialog(ProcessAnalyzerCstScanPresentation presentation)
        {
            InitializeComponent();
            WindowSizingHelper.EnableAdaptiveDialog(this);
            _presentation = presentation;
            _scanCompleted = true;
            _showMalwareCleanupButton = false;
            Loaded += OnWindowLoaded;
            EnterResultsState(presentation);
        }

        public ProcessAnalyzerCstResultDialog(
            string displayName,
            string targetPath,
            string scanSubtitle,
            bool isStartupEntryScan,
            bool showMalwareCleanupButton = false)
        {
            InitializeComponent();
            WindowSizingHelper.EnableAdaptiveDialog(this);
            _isStartupEntryScan = isStartupEntryScan;
            _showMalwareCleanupButton = showMalwareCleanupButton;
            ProcessNameText.Text = displayName;
            TargetPathText.Text = targetPath;
            ScanKindSubtitle.Text = scanSubtitle;
            TitleText.Text = "CST Scan";
            Title = "CST Scan";
            Loaded += OnWindowLoaded;
            EnterScanningState();
            ApplyMalwareCleanupButtonVisibility();
        }

        private void OnWindowLoaded(object sender, RoutedEventArgs e)
        {
            if (!_pendingResultsApply || _presentation is null)
                return;

            _pendingResultsApply = false;
            EnterResultsState(_presentation);
        }

        private void ApplyMalwareCleanupButtonVisibility()
        {
            MalwareCleanupButton.Visibility = _showMalwareCleanupButton
                ? Visibility.Visible
                : Visibility.Collapsed;
        }

        public async Task ExecuteScanAsync(
            Func<IProgress<CstScanProgressUpdate>, CancellationToken, Task<CstScanRunOutcome>> scanRunner)
        {
            _scanCts = new CancellationTokenSource();
            var progress = new Progress<CstScanProgressUpdate>(ApplyProgressUpdate);

            try
            {
                var outcome = await scanRunner(progress, _scanCts.Token).ConfigureAwait(true);
                if (_scanCts.IsCancellationRequested)
                {
                    ShowFailure("Scan cancelled.", incomplete: true);
                    return;
                }

                if (!outcome.Success)
                {
                    ShowFailure(outcome.ErrorMessage ?? "CST scan failed.", incomplete: true);
                    return;
                }

                if (ProcessAnalyzerCstResultService.TryBuildPresentation(
                        outcome.RawOutput,
                        TargetPathText.Text,
                        ProcessNameText.Text,
                        out var presentation,
                        out var parseError))
                {
                    // Populate UI + operator PDF before onSuccess so work-order hooks see ReportPdfPath.
                    EnterResultsState(presentation);
                    outcome.OnSuccess?.Invoke(presentation, outcome.RawOutput);
                }
                else
                {
                    ShowFailure(parseError ?? "Could not parse CST scan results.", incomplete: true);
                }
            }
            catch (OperationCanceledException)
            {
                ShowFailure("Scan cancelled.", incomplete: true);
            }
            catch (Exception ex)
            {
                ShowFailure(ex.Message, incomplete: true);
            }
            finally
            {
                _scanCompleted = true;
                PrimaryButton.Content = "OK";
                if (_presentation?.CanRemediate == true)
                {
                    FooterHintText.Text =
                        "Select findings above, then Quarantine or Remove. Restore uses a CST rollback manifest.";
                }
            }
        }

        private void EnterScanningState()
        {
            _scanCompleted = false;
            _lastProgressUtc = DateTime.UtcNow;
            _lastProgressDetail = string.Empty;
            _lastProgressPhaseText = string.Empty;
            _isPreScanPhase = true;
            ProgressPanel.Visibility = Visibility.Visible;
            ScanningPlaceholderPanel.Visibility = Visibility.Visible;
            MetricsPanel.Visibility = Visibility.Collapsed;
            StartupAxisPanel.Visibility = Visibility.Collapsed;
            FindingsPanel.Visibility = Visibility.Collapsed;
            RemediationToolbar.Visibility = Visibility.Collapsed;
            SetRemediationButtonsVisible(false);
            CopySummaryButton.IsEnabled = false;
            OpenReportButton.IsEnabled = false;
            MalwareCleanupButton.IsEnabled = false;
            PrimaryButton.Content = "Cancel";
            VerdictText.Text = "Scanning...";
            VerdictBadge.Background = new SolidColorBrush(Color.FromRgb(0x00, 0x78, 0xD4));
            VerdictDetailText.Text = "Core Security Tool is preparing targets and pre-scan checks.";
            FooterHintText.Text = "You can cancel the scan if needed. Results appear here when finished.";
            ProgressPhaseText.Text = "Preparing scan...";
            ProgressDetailText.Text = "Starting Core Security Tool pre-checks (targets, known-good, path discovery)...";
            ProgressPathText.Text = string.Empty;
            ProgressPercentText.Text = "…";
            ScanProgressBar.Value = 0;
            ScanProgressBar.IsIndeterminate = true;
            StartProgressHeartbeat();
        }

        private void StartProgressHeartbeat()
        {
            StopProgressHeartbeat();
            _progressHeartbeatTimer = new DispatcherTimer
            {
                Interval = TimeSpan.FromSeconds(1)
            };
            _progressHeartbeatTimer.Tick += ProgressHeartbeatTimer_Tick;
            _progressHeartbeatTimer.Start();
        }

        private void StopProgressHeartbeat()
        {
            if (_progressHeartbeatTimer is null)
                return;

            _progressHeartbeatTimer.Tick -= ProgressHeartbeatTimer_Tick;
            _progressHeartbeatTimer.Stop();
            _progressHeartbeatTimer = null;
        }

        private void ProgressHeartbeatTimer_Tick(object? sender, EventArgs e)
        {
            if (_scanCompleted || !IsLoaded)
            {
                StopProgressHeartbeat();
                return;
            }

            var silentFor = DateTime.UtcNow - _lastProgressUtc;
            if (silentFor < TimeSpan.FromSeconds(2))
                return;

            // Keep the UI alive during long silent prep stretches (known-good load, huge roots).
            if (ScanProgressBar.IsIndeterminate == false && _isPreScanPhase && ScanProgressBar.Value < 1)
                ScanProgressBar.IsIndeterminate = true;

            var waitText = silentFor.TotalMinutes >= 1
                ? $"Still working… {silentFor:mm\\:ss} since last update"
                : $"Still working… {silentFor.Seconds}s since last update";

            if (!string.IsNullOrWhiteSpace(_lastProgressDetail)
                && !_lastProgressDetail.Contains("Still working", StringComparison.OrdinalIgnoreCase))
            {
                ProgressDetailText.Text = $"{_lastProgressDetail} • {waitText}";
            }
            else if (!string.IsNullOrWhiteSpace(_lastProgressPhaseText))
            {
                ProgressDetailText.Text = $"{_lastProgressPhaseText} • {waitText}";
            }
            else
            {
                ProgressDetailText.Text = waitText;
            }

            if (_isPreScanPhase)
            {
                VerdictDetailText.Text =
                    "Pre-scan checks are still running (path discovery / known-good). Progress resumes as soon as the next update arrives.";
            }
        }

        private void EnterResultsState(ProcessAnalyzerCstScanPresentation presentation)
        {
            if (!IsLoaded)
            {
                _presentation = presentation;
                _scanCompleted = true;
                _pendingResultsApply = true;
                return;
            }

            _presentation = presentation;
            _scanCompleted = true;
            _isStartupEntryScan = presentation.IsStartupEntryScan;
            _pendingResultsApply = false;
            StopProgressHeartbeat();

            ProgressPanel.Visibility = Visibility.Collapsed;
            ScanningPlaceholderPanel.Visibility = Visibility.Collapsed;
            FindingsPanel.Visibility = Visibility.Visible;
            CopySummaryButton.IsEnabled = true;
            MalwareCleanupButton.IsEnabled = _showMalwareCleanupButton;
            ApplyMalwareCleanupButtonVisibility();
            PrimaryButton.Content = "OK";
            TitleText.Text = "CST Scan Results";
            Title = "CST Scan Results";

            ProcessNameText.Text = presentation.ProcessName;
            TargetPathText.Text = presentation.TargetPath;
            VerdictDetailText.Text = presentation.VerdictDetail;
            ItemsScannedText.Text = presentation.ItemsScanned.ToString();
            ThreatsText.Text = presentation.ThreatsFound.ToString();
            WarningsText.Text = presentation.WarningsFound.ToString();
            ScanErrorsText.Text = presentation.ScanErrors.ToString();

            if (presentation.IsStartupEntryScan)
            {
                ScanKindSubtitle.Text = "Startup entry scan — File / Command line / Persistence";
                MetricsPanel.Visibility = Visibility.Collapsed;
                StartupAxisPanel.Visibility = Visibility.Visible;
                FileVerdictText.Text = presentation.FileVerdict;
                FileVerdictDetailText.Text = presentation.FileVerdictDetail;
                CommandLineVerdictText.Text = presentation.CommandLineVerdict;
                CommandLineVerdictDetailText.Text = presentation.CommandLineVerdictDetail;
                PersistenceVerdictText.Text = presentation.PersistenceVerdict;
                PersistenceVerdictDetailText.Text = presentation.PersistenceVerdictDetail;
            }
            else
            {
                ScanKindSubtitle.Text = FormatScanModeSubtitle(presentation.ScanMode);
                MetricsPanel.Visibility = Visibility.Visible;
                StartupAxisPanel.Visibility = Visibility.Collapsed;
            }

            VerdictText.Text = presentation.Verdict switch
            {
                "Threat" => "Threats detected",
                "Incomplete" => "Incomplete scan",
                "Review" => "Review recommended",
                "Suspicious" => "Suspicious signals",
                _ => "No threats found"
            };

            VerdictBadge.Background = presentation.Verdict switch
            {
                "Threat" => new SolidColorBrush(Color.FromRgb(0xDC, 0x26, 0x26)),
                "Incomplete" => new SolidColorBrush(Color.FromRgb(0xD9, 0x77, 0x06)),
                "Review" => new SolidColorBrush(Color.FromRgb(0xD9, 0x77, 0x06)),
                "Suspicious" => new SolidColorBrush(Color.FromRgb(0xD9, 0x77, 0x06)),
                _ => new SolidColorBrush(Color.FromRgb(0x16, 0xA3, 0x4A))
            };

            FindingsGrid.ItemsSource = presentation.Findings;
            FindingsHeaderText.Text = presentation.HasFindings
                ? $"Findings ({presentation.Findings.Count})"
                : "Findings";
            FindingsSubtitleText.Text = presentation.CanRemediate
                ? "Select concrete file/archive traces to quarantine or remove. Archive entry rows are review-only — use the parent archive row."
                : (presentation.IsStartupEntryScan
                    ? "File, command-line, and persistence findings for this startup entry."
                    : "Review severity, detector, and evidence for the scanned path.");

            SetRemediationButtonsVisible(presentation.CanRemediate);
            RemediationToolbar.Visibility = presentation.CanRemediate ? Visibility.Visible : Visibility.Collapsed;
            RefreshSelectionSummary();
            FooterHintText.Text = presentation.CanRemediate
                ? "Select findings above, then Quarantine or Remove. Archive hits remediate the .zip/.jar file. Restore uses a CST rollback manifest."
                : "Scan completed in detect-only mode.";

            if (presentation.HasSuppressedFindings)
            {
                SuppressedHeader.Visibility = Visibility.Visible;
                SuppressedScrollHost.Visibility = Visibility.Visible;
                SuppressedGrid.ItemsSource = presentation.SuppressedFindings;
                SuppressedGridRow.Height = new GridLength(160);
            }
            else
            {
                SuppressedHeader.Visibility = Visibility.Collapsed;
                SuppressedScrollHost.Visibility = Visibility.Collapsed;
                SuppressedGrid.ItemsSource = null;
                SuppressedGridRow.Height = new GridLength(0);
            }

            if (presentation.HasActionSummary)
            {
                ActionSummaryText.Visibility = Visibility.Visible;
                ActionSummaryText.Text = presentation.ActionSummary;
            }
            else
            {
                ActionSummaryText.Visibility = Visibility.Collapsed;
            }

            if (presentation.HasCoverageReason)
            {
                CoverageReasonText.Visibility = Visibility.Visible;
                CoverageReasonText.Text = $"Coverage: {presentation.CoverageReason}";
            }
            else
            {
                CoverageReasonText.Visibility = Visibility.Collapsed;
            }

            if (presentation.HasErrorDetails)
            {
                ErrorDetailsList.Visibility = Visibility.Visible;
                ErrorDetailsList.ItemsSource = presentation.ErrorDetails;
            }
            else
            {
                ErrorDetailsList.Visibility = Visibility.Collapsed;
                ErrorDetailsList.ItemsSource = null;
            }

            EnsureOperatorPdf(presentation);
        }

        private void EnsureOperatorPdf(ProcessAnalyzerCstScanPresentation presentation)
        {
            OpenReportButton.IsEnabled = false;
            _reportPdfPath = string.Empty;

            if (!string.IsNullOrWhiteSpace(presentation.ReportPdfPath) && File.Exists(presentation.ReportPdfPath))
            {
                _reportPdfPath = presentation.ReportPdfPath;
                OpenReportButton.IsEnabled = true;
                return;
            }

            if (ProcessAnalyzerCstResultService.TryEnsureOperatorPdf(presentation, out var pdfPath, out _))
            {
                _reportPdfPath = pdfPath;
                OpenReportButton.IsEnabled = true;
            }
        }

        private void SetRemediationButtonsVisible(bool visible)
        {
            var vis = visible ? Visibility.Visible : Visibility.Collapsed;
            QuarantineButton.Visibility = vis;
            RemoveButton.Visibility = vis;
            RestoreButton.Visibility = vis;
        }

        private void ShowFailure(string message, bool incomplete)
        {
            _scanCompleted = true;
            StopProgressHeartbeat();
            if (!IsLoaded)
                return;

            ProgressPanel.Visibility = Visibility.Collapsed;
            ScanningPlaceholderPanel.Visibility = Visibility.Collapsed;
            MetricsPanel.Visibility = Visibility.Collapsed;
            StartupAxisPanel.Visibility = Visibility.Collapsed;
            FindingsPanel.Visibility = Visibility.Collapsed;
            RemediationToolbar.Visibility = Visibility.Collapsed;
            SetRemediationButtonsVisible(false);
            CopySummaryButton.IsEnabled = false;
            OpenReportButton.IsEnabled = false;
            MalwareCleanupButton.IsEnabled = false;
            PrimaryButton.Content = "OK";
            TitleText.Text = "CST Scan";
            VerdictText.Text = incomplete ? "Incomplete" : "Failed";
            VerdictBadge.Background = new SolidColorBrush(Color.FromRgb(0xD9, 0x77, 0x06));
            VerdictDetailText.Text = message;
            ActionSummaryText.Visibility = Visibility.Visible;
            ActionSummaryText.Text = message;
        }

        private void ApplyProgressUpdate(CstScanProgressUpdate progress)
        {
            if (!Dispatcher.CheckAccess())
            {
                Dispatcher.BeginInvoke(() => ApplyProgressUpdate(progress), DispatcherPriority.Background);
                return;
            }

            if (_scanCompleted || !IsLoaded)
                return;

            _lastProgressUtc = DateTime.UtcNow;
            _isPreScanPhase = progress.IsPreScanPhase;
            if (!string.IsNullOrWhiteSpace(progress.Detail))
                _lastProgressDetail = progress.Detail;
            if (!string.IsNullOrWhiteSpace(progress.PhaseText))
                _lastProgressPhaseText = progress.PhaseText;

            // Pre-scan: keep a determinate bar when we have percent, otherwise pulse indeterminate
            // so technicians always see motion during known-good / path discovery.
            if (progress.IsPreScanPhase && progress.Percent <= 0.5)
            {
                ScanProgressBar.IsIndeterminate = true;
                ProgressPercentText.Text = "…";
            }
            else if (progress.Percent > 0)
            {
                ScanProgressBar.IsIndeterminate = false;
                ScanProgressBar.Value = Math.Max(0, Math.Min(100, progress.Percent));
                ProgressPercentText.Text = $"{progress.Percent:0.#}%";
            }
            else if (!string.IsNullOrWhiteSpace(progress.Phase))
            {
                ScanProgressBar.IsIndeterminate = true;
                ProgressPercentText.Text = "…";
            }

            if (!string.IsNullOrWhiteSpace(progress.PhaseText))
                ProgressPhaseText.Text = progress.PhaseText;

            if (!string.IsNullOrWhiteSpace(progress.Detail))
                ProgressDetailText.Text = progress.Detail;

            ProgressPathText.Text = string.IsNullOrWhiteSpace(progress.CurrentPath)
                ? string.Empty
                : progress.CurrentPath;

            if (!string.IsNullOrWhiteSpace(progress.VerdictDetail))
                VerdictDetailText.Text = progress.VerdictDetail;
        }

        private void RefreshSelectionSummary()
        {
            var findings = _presentation?.Findings ?? Array.Empty<ProcessAnalyzerCstFindingRow>();
            var selected = findings.Count(f => f.IsSelected);
            var actionable = findings.Count(f => f.CanRemediate);
            var reviewOnly = findings.Count - actionable;
            SelectionSummaryText.Text =
                $"Selected: {selected} | Actionable: {actionable} | Review Only: {reviewOnly} | Total: {findings.Count}";
        }

        private void SelectActionableButton_Click(object sender, RoutedEventArgs e)
        {
            if (_presentation is null)
                return;
            foreach (var finding in _presentation.Findings)
                finding.IsSelected = finding.CanRemediate;
            RefreshSelectionSummary();
        }

        private void ClearSelectionButton_Click(object sender, RoutedEventArgs e)
        {
            if (_presentation is null)
                return;
            foreach (var finding in _presentation.Findings)
                finding.IsSelected = false;
            RefreshSelectionSummary();
        }

        private void FindingsGrid_CellEditEnding(object sender, DataGridCellEditEndingEventArgs e)
        {
            Dispatcher.BeginInvoke(new Action(RefreshSelectionSummary));
        }

        private async void QuarantineButton_Click(object sender, RoutedEventArgs e)
            => await RunRemediationAsync("Quarantine");

        private async void RemoveButton_Click(object sender, RoutedEventArgs e)
        {
            var confirm = MessageBox.Show(
                "Remove permanently deletes the selected files. Continue?",
                "Confirm Remove",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);
            if (confirm != MessageBoxResult.Yes)
                return;

            await RunRemediationAsync("Remove");
        }

        private async void RestoreButton_Click(object sender, RoutedEventArgs e)
        {
            if (_remediationBusy)
                return;

            var defaultRollbackFolder = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                "CoreSecurityTool",
                "Rollback");
            var dialog = new OpenFileDialog
            {
                Title = "Select CST Rollback Manifest",
                Filter = "Rollback Manifests (rollback_*.json)|rollback_*.json|JSON Files (*.json)|*.json|All Files (*.*)|*.*",
                InitialDirectory = Directory.Exists(defaultRollbackFolder)
                    ? defaultRollbackFolder
                    : Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                CheckFileExists = true,
                Multiselect = false
            };

            if (dialog.ShowDialog(this) != true)
                return;

            _remediationBusy = true;
            SetRemediationEnabled(false);
            try
            {
                await CstRemediationService.ExecuteRollbackFromManifestAsync(dialog.FileName);
            }
            finally
            {
                _remediationBusy = false;
                SetRemediationEnabled(true);
            }
        }

        private async Task RunRemediationAsync(string action)
        {
            if (_remediationBusy || _presentation is null)
                return;

            if (!_presentation.CanRemediate)
            {
                MessageBox.Show(
                    "Remediation is unavailable for this scan result (missing CST artifact).",
                    "CST Scan",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            var selected = _presentation.Findings.Where(f => f.IsSelected).ToList();
            if (selected.Count == 0)
            {
                MessageBox.Show(
                    "Select at least one finding before running a remediation action.",
                    "CST Scan",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            if (selected.Any(f => !f.CanRemediate))
            {
                MessageBox.Show(
                    "One or more selected findings are not actionable. Clear selection or choose actionable rows only.",
                    "CST Scan",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return;
            }

            _remediationBusy = true;
            SetRemediationEnabled(false);
            try
            {
                await CstRemediationService.ExecuteRemediationAsync(
                    _presentation.ArtifactPath,
                    action,
                    selected.Select(f => f.Id));
            }
            finally
            {
                _remediationBusy = false;
                SetRemediationEnabled(true);
                RefreshSelectionSummary();
            }
        }

        private void SetRemediationEnabled(bool enabled)
        {
            QuarantineButton.IsEnabled = enabled;
            RemoveButton.IsEnabled = enabled;
            RestoreButton.IsEnabled = enabled;
            RemediationToolbar.IsEnabled = enabled;
        }

        private void CopySummaryButton_Click(object sender, RoutedEventArgs e)
        {
            if (_presentation is null)
                return;

            try
            {
                Clipboard.SetText(_presentation.CopySummary);
                MessageBox.Show(
                    "Scan summary copied to the clipboard.",
                    "CST Scan",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
            }
            catch
            {
                MessageBox.Show(
                    "Could not copy the scan summary.",
                    "CST Scan",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }

        private void OpenReportButton_Click(object sender, RoutedEventArgs e)
        {
            if (_presentation is null)
                return;

            if (string.IsNullOrWhiteSpace(_reportPdfPath) || !File.Exists(_reportPdfPath))
                EnsureOperatorPdf(_presentation);

            if (string.IsNullOrWhiteSpace(_reportPdfPath) || !File.Exists(_reportPdfPath))
            {
                MessageBox.Show(
                    "The PDF report could not be generated for this scan.",
                    "Open Report",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
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
        }

        private void MalwareCleanupButton_Click(object sender, RoutedEventArgs e)
        {
            NavigationService.Request("MalwareCleanup");
            Close();
        }

        private void PrimaryButton_Click(object sender, RoutedEventArgs e)
        {
            if (!_scanCompleted)
            {
                try { _scanCts?.Cancel(); } catch { }
                PrimaryButton.IsEnabled = false;
                ProgressDetailText.Text = "Cancelling scan...";
                return;
            }

            Close();
        }

        private static string FormatScanModeSubtitle(string? scanMode)
        {
            if (string.IsNullOrWhiteSpace(scanMode))
                return "Process / file CustomScan";

            return scanMode switch
            {
                "ThreatScan" => "ThreatScan — quick high-risk paths only",
                "FullScan" => "FullScan — broad system coverage",
                "CustomScan" => "CustomScan — selected targets",
                _ => scanMode
            };
        }

        protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
        {
            StopProgressHeartbeat();
            if (!_scanCompleted)
            {
                try { _scanCts?.Cancel(); } catch { }
            }

            base.OnClosing(e);
        }
    }

    public sealed class CstScanProgressUpdate
    {
        public double Percent { get; init; }
        public string? Phase { get; init; }
        public string? PhaseText { get; init; }
        public string? Detail { get; init; }
        public string? CurrentPath { get; init; }
        public string? VerdictDetail { get; init; }
        public bool IsPreScanPhase { get; init; }
    }

    public sealed class CstScanRunOutcome
    {
        public bool Success { get; init; }
        public string RawOutput { get; init; } = string.Empty;
        public string? ErrorMessage { get; init; }
        public Action<ProcessAnalyzerCstScanPresentation, string>? OnSuccess { get; init; }

        public static CstScanRunOutcome Failed(string message) => new()
        {
            Success = false,
            ErrorMessage = message
        };

        public static CstScanRunOutcome FromOutput(
            string rawOutput,
            Action<ProcessAnalyzerCstScanPresentation, string>? onSuccess = null) => new()
        {
            Success = true,
            RawOutput = rawOutput ?? string.Empty,
            OnSuccess = onSuccess
        };
    }
}
