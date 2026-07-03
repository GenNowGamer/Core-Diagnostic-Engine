using System.Windows;
using System.Windows.Media;
using ToolkitGUI.Services;

namespace ToolkitGUI.Views
{
    public partial class ProcessAnalyzerCstResultDialog : Window
    {
        private readonly ProcessAnalyzerCstScanPresentation _presentation;

        public ProcessAnalyzerCstResultDialog(ProcessAnalyzerCstScanPresentation presentation)
        {
            InitializeComponent();
            WindowSizingHelper.EnableAdaptiveDialog(this);
            _presentation = presentation;
            BindPresentation();
        }

        private void BindPresentation()
        {
            ProcessNameText.Text = _presentation.ProcessName;
            TargetPathText.Text = _presentation.TargetPath;
            VerdictDetailText.Text = _presentation.VerdictDetail;
            ItemsScannedText.Text = _presentation.ItemsScanned.ToString();
            ThreatsText.Text = _presentation.ThreatsFound.ToString();
            WarningsText.Text = _presentation.WarningsFound.ToString();
            ScanErrorsText.Text = _presentation.ScanErrors.ToString();

            VerdictText.Text = _presentation.Verdict switch
            {
                "Threat" => "Threats detected",
                "Incomplete" => "Incomplete scan",
                "Review" => "Review recommended",
                _ => "No threats found"
            };

            VerdictBadge.Background = _presentation.Verdict switch
            {
                "Threat" => new SolidColorBrush(Color.FromRgb(0xDC, 0x26, 0x26)),
                "Incomplete" => new SolidColorBrush(Color.FromRgb(0xD9, 0x77, 0x06)),
                "Review" => new SolidColorBrush(Color.FromRgb(0xD9, 0x77, 0x06)),
                _ => new SolidColorBrush(Color.FromRgb(0x16, 0xA3, 0x4A))
            };

            FindingsGrid.ItemsSource = _presentation.Findings;

            if (_presentation.HasSuppressedFindings)
            {
                SuppressedHeader.Visibility = Visibility.Visible;
                SuppressedGrid.Visibility = Visibility.Visible;
                SuppressedGrid.ItemsSource = _presentation.SuppressedFindings;
            }

            if (_presentation.HasActionSummary)
            {
                ActionSummaryText.Visibility = Visibility.Visible;
                ActionSummaryText.Text = _presentation.ActionSummary;
            }

            if (_presentation.HasCoverageReason)
            {
                CoverageReasonText.Visibility = Visibility.Visible;
                CoverageReasonText.Text = $"Coverage: {_presentation.CoverageReason}";
            }

            if (_presentation.HasErrorDetails)
            {
                ErrorDetailsList.Visibility = Visibility.Visible;
                ErrorDetailsList.ItemsSource = _presentation.ErrorDetails;
            }
        }

        private void CopySummaryButton_Click(object sender, RoutedEventArgs e)
        {
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

        private void MalwareCleanupButton_Click(object sender, RoutedEventArgs e)
        {
            NavigationService.Request("MalwareCleanup");
            Close();
        }

        private void OkButton_Click(object sender, RoutedEventArgs e)
        {
            Close();
        }
    }
}
