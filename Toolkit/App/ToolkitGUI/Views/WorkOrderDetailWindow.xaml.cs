using System.Windows;
using System.Windows.Controls;
using ToolkitGUI.Models;
using ToolkitGUI.Services;

namespace ToolkitGUI.Views
{
    public partial class WorkOrderDetailWindow : Window
    {
        public WorkOrderDetailWindow(string caseId)
        {
            InitializeComponent();
            WindowSizingHelper.EnableAdaptiveDialog(this);
            LoadDetail(caseId);
        }

        private void LoadDetail(string caseId)
        {
            var detail = WorkOrderService.LoadWorkOrderDetail(caseId);
            Title = $"Work Order {detail.CaseId}";
            CaseIdText.Text = detail.CaseId;
            StatusText.Text = $"Status: {detail.Status}   |   Opened: {detail.CreatedAt}   |   Closed: {detail.ClosedAt}";
            ClientNameText.Text = string.IsNullOrWhiteSpace(detail.ClientName) ? "(not set)" : detail.ClientName;
            ClientPhoneText.Text = string.IsNullOrWhiteSpace(detail.ClientPhone) ? "(not set)" : detail.ClientPhone;
            NotesText.Text = string.IsNullOrWhiteSpace(detail.TechnicianNotes) ? "(none)" : detail.TechnicianNotes;
            RunsItems.ItemsSource = detail.Runs;
            OpenFinalReportButton.Visibility = detail.HasFinalReportPdf ? Visibility.Visible : Visibility.Collapsed;
            OpenFinalReportButton.Tag = detail.FinalReportPdf;
        }

        private void OpenFinalReport_Click(object sender, RoutedEventArgs e)
        {
            if (sender is Button { Tag: string path } && !string.IsNullOrWhiteSpace(path))
            {
                try { ShellFileOpenHelper.OpenWithDefaultApplication(path); }
                catch { /* ignore missing files */ }
            }
        }

        private void OpenTimelineLink_Click(object sender, RoutedEventArgs e)
        {
            if (sender is Button { Tag: string path })
            {
                try { ShellFileOpenHelper.OpenWithDefaultApplication(path); }
                catch { /* ignore missing files */ }
            }
        }

        private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();
    }
}
