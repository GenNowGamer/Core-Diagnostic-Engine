using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Windows.Controls;
using System.Windows;
using ToolkitGUI.Services;
using ToolkitGUI.ViewModels;

namespace ToolkitGUI.Views
{
    public partial class WorkflowExecutionWindow : Window
    {
        private readonly TimeSpan _autoScrollInterval = TimeSpan.FromMilliseconds(120);
        private DateTime _lastAutoScrollUtc = DateTime.MinValue;
        private WorkflowViewModelBase? _hookedViewModel;

        public WorkflowExecutionWindow()
        {
            InitializeComponent();
            WindowSizingHelper.EnableAdaptiveDialog(this);
            LiveLogTextBox.TextChanged += LiveLogTextBox_TextChanged;
            DataContextChanged += (_, _) => HookViewModel();
        }

        private void HookViewModel()
        {
            if (_hookedViewModel != null)
                _hookedViewModel.PropertyChanged -= ViewModel_PropertyChanged;

            _hookedViewModel = ViewModel;
            if (_hookedViewModel != null)
                _hookedViewModel.PropertyChanged += ViewModel_PropertyChanged;

            UpdateCstExpander();
        }

        private void ViewModel_PropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
        {
            if (e.PropertyName is nameof(WorkflowViewModelBase.HasCstResultArtifact)
                or nameof(WorkflowViewModelBase.CstResultArtifactPath))
            {
                UpdateCstExpander();
            }
        }

        private void UpdateCstExpander()
        {
            if (ViewModel?.HasCstResultArtifact == true)
            {
                CstExpander.Visibility = Visibility.Visible;
                CstExpander.LoadArtifact(ViewModel.CstResultArtifactPath);
            }
            else
            {
                CstExpander.Visibility = Visibility.Collapsed;
            }
        }

        private WorkflowViewModelBase? ViewModel => DataContext as WorkflowViewModelBase;

        private void CloseButton_Click(object sender, RoutedEventArgs e)
        {
            if (ViewModel?.IsRunning == true)
            {
                var shouldClose = MessageBox.Show(
                    "This scan is still running. Stop it now and close this window?",
                    "Stop Running Scan",
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Question) == MessageBoxResult.Yes;

                if (!shouldClose)
                {
                    return;
                }

                ViewModel.RequestStop();
            }

            Close();
        }

        private void StopButton_Click(object sender, RoutedEventArgs e)
        {
            ViewModel?.RequestStop();
        }

        private void CopyLogButton_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                Clipboard.SetText(ViewModel?.LogText ?? string.Empty);
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    $"Unable to copy execution log:\n{ex.Message}",
                    "Copy Failed",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }

        private async void OpenHtmlReportButton_Click(object sender, RoutedEventArgs e)
        {
            if (ViewModel == null)
            {
                return;
            }

            try
            {
                await ViewModel.OpenHtmlReportAsync();
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    $"Unable to open the HTML report:\n{ex.Message}",
                    "Open Failed",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }

        private async void OpenPdfReportButton_Click(object sender, RoutedEventArgs e)
        {
            if (ViewModel == null)
            {
                return;
            }

            try
            {
                await ViewModel.OpenPdfReportAsync();
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    $"Unable to open the PDF report:\n{ex.Message}",
                    "Open Failed",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }

        protected override void OnClosing(CancelEventArgs e)
        {
            if (ViewModel?.IsRunning == true)
            {
                var shouldClose = MessageBox.Show(
                    "This scan is still running. Stop it now and close this window?",
                    "Stop Running Scan",
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Question) == MessageBoxResult.Yes;

                if (!shouldClose)
                {
                    e.Cancel = true;
                    return;
                }

                ViewModel.RequestStop();
            }

            base.OnClosing(e);
        }

        private void LiveLogTextBox_TextChanged(object sender, TextChangedEventArgs e)
        {
            var now = DateTime.UtcNow;
            if ((now - _lastAutoScrollUtc) < _autoScrollInterval)
            {
                return;
            }

            _lastAutoScrollUtc = now;
            LiveLogTextBox.CaretIndex = LiveLogTextBox.Text.Length;
            LiveLogTextBox.ScrollToEnd();
        }

        private static void OpenPath(string? path, string label)
        {
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            {
                MessageBox.Show(
                    $"The {label} is not available.",
                    "File Not Found",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return;
            }

            try
            {
                Process.Start(new ProcessStartInfo(path)
                {
                    UseShellExecute = true
                });
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    $"Unable to open the {label}:\n{ex.Message}",
                    "Open Failed",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }
    }
}
