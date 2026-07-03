using System;
using System.Windows;
using ToolkitGUI.Services;

namespace ToolkitGUI.Views
{
    public partial class AcquirePreflightWindow : Window
    {
        public AcquirePreflightWindow(string summary)
        {
            InitializeComponent();
            WindowSizingHelper.EnableAdaptiveDialog(this);
            SummaryTextBox.Text = summary ?? string.Empty;
        }

        private void CopyButton_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                Clipboard.SetText(SummaryTextBox.Text);
            }
            catch (Exception ex)
            {
                MessageBox.Show(
                    $"Unable to copy preflight summary:\n{ex.Message}",
                    "Copy Failed",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
            }
        }

        private void CancelButton_Click(object sender, RoutedEventArgs e)
        {
            DialogResult = false;
            Close();
        }

        private void ProceedButton_Click(object sender, RoutedEventArgs e)
        {
            DialogResult = true;
            Close();
        }
    }
}
