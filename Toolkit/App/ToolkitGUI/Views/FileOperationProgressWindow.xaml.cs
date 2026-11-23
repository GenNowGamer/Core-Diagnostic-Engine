using System;
using System.ComponentModel;
using System.Threading;
using System.Windows;
using ToolkitGUI.Services;

namespace ToolkitGUI.Views
{
    public partial class FileOperationProgressWindow : Window
    {
        private readonly FileOperationKind _kind;
        private readonly string? _sourceSummary;
        private readonly string? _destinationSummary;
        private readonly CancellationTokenSource _cts;
        private readonly FileOperationPauseToken _pauseToken;
        private bool _isFinished;
        private bool _isCancelling;

        public FileOperationProgressWindow(
            FileOperationKind kind,
            string? sourceSummary,
            string? destinationSummary,
            CancellationTokenSource cts,
            FileOperationPauseToken pauseToken)
        {
            InitializeComponent();
            WindowSizingHelper.EnableAdaptiveDialog(this);

            _kind = kind;
            _sourceSummary = sourceSummary;
            _destinationSummary = destinationSummary;
            _cts = cts;
            _pauseToken = pauseToken;

            Title = kind switch
            {
                FileOperationKind.Copy => "Copying Items",
                FileOperationKind.Move => "Moving Items",
                FileOperationKind.Delete => "Deleting Items",
                _ => "File Operation"
            };

            HeaderText.Text = kind switch
            {
                FileOperationKind.Copy => "Copying items...",
                FileOperationKind.Move => "Moving items...",
                FileOperationKind.Delete => "Deleting items...",
                _ => "Processing..."
            };

            if (kind == FileOperationKind.Delete)
            {
                TransferPathsPanel.Visibility = Visibility.Collapsed;
            }
            else
            {
                TransferPathsPanel.Visibility = Visibility.Visible;
                SourcePathText.Text = string.IsNullOrWhiteSpace(sourceSummary) ? string.Empty : $"From: {sourceSummary}";
                SourcePathText.ToolTip = sourceSummary;
                DestinationPathText.Text = string.IsNullOrWhiteSpace(destinationSummary) ? string.Empty : $"To: {destinationSummary}";
                DestinationPathText.ToolTip = destinationSummary;
            }

            Closing += OnWindowClosing;
        }

        public void UpdateProgress(FileOperationProgress progress)
        {
            if (_isFinished)
                return;

            if (progress.Phase == FileOperationPhase.Preparing)
            {
                OperationProgressBar.IsIndeterminate = true;
                PercentText.Text = string.Empty;
                HeaderText.Text = _kind switch
                {
                    FileOperationKind.Copy => "Preparing to copy...",
                    FileOperationKind.Move => "Preparing to move...",
                    FileOperationKind.Delete => "Preparing to delete...",
                    _ => "Preparing..."
                };
                CurrentItemText.Text = string.IsNullOrWhiteSpace(progress.CurrentItemName)
                    ? "Discovering items..."
                    : $"Name: {progress.CurrentItemName}";
                CurrentItemText.ToolTip = progress.CurrentSourcePath;
                ItemsRemainingText.Text = progress.TotalItems > 0
                    ? $"Discovered {progress.TotalItems:N0} item(s) ({SizeDisplayFormatter.FormatBytes(progress.TotalBytes)})"
                    : "Discovering items...";
                TimeRemainingText.Text = "Time remaining: Calculating...";
                SpeedText.Text = string.Empty;
                return;
            }

            OperationProgressBar.IsIndeterminate = false;
            var pct = Math.Clamp(progress.PercentComplete, 0, 100);
            OperationProgressBar.Value = pct;
            PercentText.Text = $"{(int)Math.Round(pct)}%";

            if (_isCancelling)
            {
                HeaderText.Text = "Cancelling...";
            }
            else if (progress.Phase == FileOperationPhase.Paused || _pauseToken.IsPaused)
            {
                HeaderText.Text = _kind switch
                {
                    FileOperationKind.Copy => "Copying paused",
                    FileOperationKind.Move => "Moving paused",
                    FileOperationKind.Delete => "Deleting paused",
                    _ => "Paused"
                };
            }
            else
            {
                HeaderText.Text = _kind switch
                {
                    FileOperationKind.Copy => "Copying items...",
                    FileOperationKind.Move => "Moving items...",
                    FileOperationKind.Delete => "Deleting items...",
                    _ => "Processing..."
                };
            }

            if (!string.IsNullOrWhiteSpace(progress.CurrentItemName))
            {
                CurrentItemText.Text = $"Name: {progress.CurrentItemName}";
                CurrentItemText.ToolTip = progress.CurrentSourcePath;
            }

            var remainingItems = Math.Max(0, progress.TotalItems - progress.ItemsCompleted);
            var remainingBytes = Math.Max(0L, progress.TotalBytes - progress.BytesCompleted);
            ItemsRemainingText.Text = progress.TotalBytes > 0
                ? $"Items remaining: {remainingItems:N0} of {progress.TotalItems:N0} ({SizeDisplayFormatter.FormatBytes(remainingBytes)})"
                : $"Items remaining: {remainingItems:N0} of {progress.TotalItems:N0}";

            SpeedText.Text = progress.BytesPerSecond > 1024 && !_pauseToken.IsPaused
                ? $"{SizeDisplayFormatter.FormatBytes((long)progress.BytesPerSecond)}/s"
                : string.Empty;

            if (_pauseToken.IsPaused)
            {
                TimeRemainingText.Text = "Time remaining: Paused";
            }
            else if (progress.EstimatedRemaining.HasValue)
            {
                TimeRemainingText.Text = $"Time remaining: {FormatDuration(progress.EstimatedRemaining.Value)}";
            }
            else
            {
                TimeRemainingText.Text = "Time remaining: Calculating...";
            }
        }

        public void MarkFinished()
        {
            _isFinished = true;
            PauseResumeButton.IsEnabled = false;
            CancelButton.IsEnabled = false;
        }

        private void PauseResumeButton_Click(object sender, RoutedEventArgs e)
        {
            if (_isFinished || _isCancelling)
                return;

            if (_pauseToken.IsPaused)
            {
                _pauseToken.Resume();
                PauseResumeButton.Content = "Pause";
                TimeRemainingText.Text = "Time remaining: Calculating...";
            }
            else
            {
                _pauseToken.Pause();
                PauseResumeButton.Content = "Resume";
                SpeedText.Text = string.Empty;
                TimeRemainingText.Text = "Time remaining: Paused";
            }
        }

        private void CancelButton_Click(object sender, RoutedEventArgs e)
        {
            RequestCancel();
        }

        private void OnWindowClosing(object? sender, CancelEventArgs e)
        {
            if (_isFinished)
                return;

            e.Cancel = true;
            RequestCancel();
        }

        private void RequestCancel()
        {
            if (_isFinished || _isCancelling)
                return;

            _isCancelling = true;
            PauseResumeButton.IsEnabled = false;
            CancelButton.IsEnabled = false;
            CancelButton.Content = "Cancelling...";
            HeaderText.Text = "Cancelling...";
            _pauseToken.Resume();
            _cts.Cancel();
        }

        private static string FormatDuration(TimeSpan remaining)
        {
            if (remaining.TotalSeconds < 5)
                return "About 5 seconds";
            if (remaining.TotalSeconds < 60)
                return $"About {(int)Math.Ceiling(remaining.TotalSeconds)} seconds";
            if (remaining.TotalMinutes < 60)
            {
                var mins = (int)Math.Ceiling(remaining.TotalMinutes);
                return mins == 1 ? "About 1 minute" : $"About {mins} minutes";
            }

            var hours = (int)Math.Floor(remaining.TotalHours);
            var remMins = remaining.Minutes;
            return remMins > 0
                ? $"About {hours} hr {remMins} min"
                : $"About {hours} hr";
        }
    }
}
