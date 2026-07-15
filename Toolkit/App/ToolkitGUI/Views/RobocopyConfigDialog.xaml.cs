using System;
using System.Windows;
using WinForms = System.Windows.Forms;
using ToolkitGUI.Services;

namespace ToolkitGUI.Views
{
    public partial class RobocopyConfigDialog : Window
    {
        public string? SourcePath { get; private set; }
        public string? DestinationPath { get; private set; }
        public bool DryRun { get; private set; }
        public bool MirrorMode { get; private set; }

        public RobocopyConfigDialog()
        {
            InitializeComponent();
            WindowSizingHelper.EnableAdaptiveDialog(this);
        }

        private void BrowseSourceButton_Click(object sender, RoutedEventArgs e)
        {
            var path = BrowseFolder("Select source folder to back up");
            if (path != null)
            {
                SourcePath = path;
                SourcePathText.Text = path;
            }
        }

        private void BrowseDestButton_Click(object sender, RoutedEventArgs e)
        {
            var path = BrowseFolder("Select destination folder for backup");
            if (path != null)
            {
                DestinationPath = path;
                DestPathText.Text = path;
            }
        }

        private void CancelButton_Click(object sender, RoutedEventArgs e)
        {
            DialogResult = false;
            Close();
        }

        private void PreviewButton_Click(object sender, RoutedEventArgs e)
        {
            if (!ValidatePaths()) return;

            DryRun = true;
            MirrorMode = MirrorCheckBox.IsChecked ?? false;
            DialogResult = true;
            Close();
        }

        private void StartButton_Click(object sender, RoutedEventArgs e)
        {
            if (!ValidatePaths()) return;

            DryRun = DryRunCheckBox.IsChecked ?? false;
            MirrorMode = MirrorCheckBox.IsChecked ?? false;
            DialogResult = true;
            Close();
        }

        private bool ValidatePaths()
        {
            if (string.IsNullOrWhiteSpace(SourcePath))
            {
                MessageBox.Show("Please select a source folder.", "Robocopy Configuration", MessageBoxButton.OK, MessageBoxImage.Warning);
                return false;
            }

            if (string.IsNullOrWhiteSpace(DestinationPath))
            {
                MessageBox.Show("Please select a destination folder.", "Robocopy Configuration", MessageBoxButton.OK, MessageBoxImage.Warning);
                return false;
            }

            return true;
        }

        private static string? BrowseFolder(string description)
        {
            using var dialog = new WinForms.FolderBrowserDialog
            {
                Description = description,
                ShowNewFolderButton = true
            };

            return dialog.ShowDialog() == WinForms.DialogResult.OK ? dialog.SelectedPath : null;
        }
    }
}
