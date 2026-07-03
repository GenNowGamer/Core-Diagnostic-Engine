using System.Windows;
using System.Windows.Controls;
using ToolkitGUI.Services;

namespace ToolkitGUI.Views
{
    public partial class CstFindingsExpander : UserControl
    {
        private string? _artifactPath;

        public CstFindingsExpander()
        {
            InitializeComponent();
        }

        public void LoadArtifact(string? artifactPath)
        {
            _artifactPath = artifactPath;
            ExpandedPanel.Visibility = Visibility.Collapsed;
            ExpandToggle.IsChecked = false;

            if (string.IsNullOrWhiteSpace(artifactPath))
            {
                Visibility = Visibility.Collapsed;
                return;
            }

            Visibility = Visibility.Visible;
        }

        private void ExpandToggle_Click(object sender, RoutedEventArgs e)
        {
            if (ExpandToggle.IsChecked == true)
            {
                ExpandedPanel.Visibility = Visibility.Visible;
                var meta = CstStructuredResultsService.LoadScanMetadata(_artifactPath ?? string.Empty);
                MetadataText.Text = meta == null
                    ? "Scan metadata unavailable."
                    : $"Mode: {meta.ScanMode}   |   Scope: {meta.DetectionScope}   |   Items scanned: {meta.ItemsScanned}   |   Threats: {meta.ThreatCount}   |   Warnings: {meta.WarningCount}";
                FindingsGrid.ItemsSource = CstStructuredResultsService.LoadAllFindings(_artifactPath ?? string.Empty);
            }
            else
            {
                ExpandedPanel.Visibility = Visibility.Collapsed;
            }
        }

        private void OpenReport_Click(object sender, RoutedEventArgs e)
        {
            if (string.IsNullOrWhiteSpace(_artifactPath))
                return;

            try
            {
                ShellFileOpenHelper.OpenWithDefaultApplication(_artifactPath);
            }
            catch
            {
                MessageBox.Show("Could not open CST report.", "CST Report", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }
    }
}
