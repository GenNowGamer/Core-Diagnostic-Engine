using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using ToolkitGUI.Models;
using ToolkitGUI.Services;

namespace ToolkitGUI.Views
{
    public partial class DashboardView : UserControl
    {
        private readonly List<SymptomFlowDefinition> _symptomFlows = new();
        private SymptomFlowDefinition? _selectedFlow;
        private readonly Dictionary<string, Button> _symptomButtons = new();
        private string? _suggestedFlowId;
        private bool _symptomExplicitlyChosen;

        public DashboardView()
        {
            InitializeComponent();
            LoadGuidance();
            RefreshWorkOrderUi();
            RefreshRecentWorkOrders();
            RefreshCaseTimeline();
            WorkOrderService.ActiveWorkOrderChanged += () => Dispatcher.Invoke(() =>
            {
                RefreshWorkOrderUi();
                RefreshRecentWorkOrders();
                RefreshCaseTimeline();
            });
        }

        private void LoadGuidance()
        {
            EnvironmentModeText.Text = DashboardGuidanceHelper.GetEnvironmentModeLabel();
            BootGuidanceText.Text = DashboardGuidanceHelper.GetBootGuidanceText();

            _symptomFlows.Clear();
            _symptomFlows.AddRange(DashboardGuidanceHelper.LoadSymptomFlows());
            SymptomButtonsPanel.Children.Clear();
            _symptomButtons.Clear();

            if (_symptomFlows.Count == 0)
            {
                SymptomUnavailableText.Visibility = Visibility.Visible;
                SelectedSymptomPanel.Visibility = Visibility.Collapsed;
                return;
            }

            SymptomUnavailableText.Visibility = Visibility.Collapsed;
            foreach (var flow in _symptomFlows)
            {
                var button = new Button
                {
                    Content = flow.Label,
                    Tag = flow.Id,
                    Height = 34,
                    MinWidth = 140,
                    Margin = new Thickness(0, 0, 8, 8),
                    Padding = new Thickness(14, 6, 14, 6),
                    Cursor = System.Windows.Input.Cursors.Hand
                };
                button.Click += SymptomButton_Click;
                ApplySymptomButtonStyle(button, selected: false, suggested: false);
                _symptomButtons[flow.Id] = button;
                SymptomButtonsPanel.Children.Add(button);
            }
        }

        private void SymptomButton_Click(object sender, RoutedEventArgs e)
        {
            if (sender is not Button button || button.Tag is not string flowId)
                return;

            SelectSymptomFlow(flowId, persistGuidance: true);
            _symptomExplicitlyChosen = true;
        }

        private void SelectSymptomFlow(string flowId, bool persistGuidance)
        {
            _selectedFlow = _symptomFlows.Find(f => string.Equals(f.Id, flowId, System.StringComparison.OrdinalIgnoreCase));
            RefreshSymptomButtonStyles();

            if (_selectedFlow == null)
            {
                SelectedSymptomPanel.Visibility = Visibility.Collapsed;
                return;
            }

            SelectedSymptomTitle.Text = _selectedFlow.Label;
            SelectedSymptomSummary.Text = _selectedFlow.Summary;
            FollowUpButtonsPanel.Children.Clear();

            foreach (var followUp in _selectedFlow.FollowUps)
            {
                var navButton = new Button
                {
                    Content = followUp.Label,
                    Tag = followUp.Target,
                    Height = 32,
                    MinWidth = 120,
                    Margin = new Thickness(0, 0, 8, 8),
                    Padding = new Thickness(12, 4, 12, 4),
                    Cursor = System.Windows.Input.Cursors.Hand
                };
                navButton.Click += FollowUpButton_Click;
                ApplyFollowUpButtonStyle(navButton);
                FollowUpButtonsPanel.Children.Add(navButton);
            }

            SelectedSymptomPanel.Visibility = Visibility.Visible;
            if (persistGuidance)
            {
                WorkOrderService.TryUpdateGuidanceContext(_selectedFlow.Id, _selectedFlow.HealthPreset);
            }
            else if (WorkOrderService.GetActiveWorkOrder() == null &&
                     string.IsNullOrWhiteSpace(WorkOrderNotesTextBox.Text?.Trim()))
            {
                WorkOrderNotesTextBox.Text = _selectedFlow.Label;
            }
        }

        private void RefreshSymptomButtonStyles()
        {
            foreach (var pair in _symptomButtons)
            {
                var isSelected = _selectedFlow != null &&
                    string.Equals(pair.Key, _selectedFlow.Id, System.StringComparison.OrdinalIgnoreCase);
                var isSuggested = !string.IsNullOrWhiteSpace(_suggestedFlowId) &&
                    string.Equals(pair.Key, _suggestedFlowId, System.StringComparison.OrdinalIgnoreCase);
                ApplySymptomButtonStyle(pair.Value, isSelected, isSuggested);
            }
        }

        private void RefreshSuggestedSymptomGuidance()
        {
            _suggestedFlowId = ResolveSuggestedSymptomFlowId();

            if (string.IsNullOrWhiteSpace(_suggestedFlowId))
            {
                SuggestedSymptomHintText.Visibility = Visibility.Collapsed;
                RefreshSymptomButtonStyles();
                return;
            }

            var flow = _symptomFlows.Find(f =>
                string.Equals(f.Id, _suggestedFlowId, System.StringComparison.OrdinalIgnoreCase));
            if (flow == null)
            {
                SuggestedSymptomHintText.Visibility = Visibility.Collapsed;
                RefreshSymptomButtonStyles();
                return;
            }

            SuggestedSymptomHintText.Text =
                $"Suggested path for this case: {flow.Label} — select it to re-run health checks or open the next tools.";
            SuggestedSymptomHintText.Visibility = Visibility.Visible;

            if (_selectedFlow == null ||
                string.Equals(_selectedFlow.Id, _suggestedFlowId, System.StringComparison.OrdinalIgnoreCase))
            {
                SelectSymptomFlow(_suggestedFlowId, persistGuidance: false);
            }
            else
            {
                RefreshSymptomButtonStyles();
            }
        }

        private string? ResolveSuggestedSymptomFlowId()
        {
            var active = WorkOrderService.GetActiveWorkOrder();
            if (active == null)
                return null;

            var ctx = WorkOrderTimelineService.LoadGuidanceContext(active.CaseId);
            if (!string.IsNullOrWhiteSpace(ctx?.LastSymptomId) &&
                _symptomButtons.ContainsKey(ctx.LastSymptomId))
            {
                return ctx.LastSymptomId;
            }

            var preset = ctx?.LastHealthPreset;
            if (!string.IsNullOrWhiteSpace(preset))
            {
                var flowFromPreset = _symptomFlows.Find(f =>
                    string.Equals(f.HealthPreset, preset, System.StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(f.Id, preset, System.StringComparison.OrdinalIgnoreCase));
                if (flowFromPreset != null)
                    return flowFromPreset.Id;
            }

            var flow = DashboardGuidanceHelper.InferSymptomFlowFromNotes(_symptomFlows, active.TechnicianNotes);
            if (flow != null)
                return flow.Id;

            if (_selectedFlow != null)
                return _selectedFlow.Id;

            return null;
        }

        private void SeedGuidanceFromNotes(WorkOrderFormData form)
        {
            var flow = _symptomExplicitlyChosen
                ? _selectedFlow
                : _selectedFlow ?? DashboardGuidanceHelper.InferSymptomFlowFromNotes(_symptomFlows, form.TechnicianNotes);
            if (flow == null)
                return;

            WorkOrderService.TryUpdateGuidanceContext(flow.Id, flow.HealthPreset);
        }

        private void FollowUpButton_Click(object sender, RoutedEventArgs e)
        {
            if (sender is Button { Tag: string target } && !string.IsNullOrWhiteSpace(target))
                NavigationService.Request(target);
        }

        private void RunHealthChecks_Click(object sender, RoutedEventArgs e)
        {
            if (_selectedFlow == null || string.IsNullOrWhiteSpace(_selectedFlow.HealthPreset))
                return;

            NavigationService.Request("SystemHealth", $"preset:{_selectedFlow.HealthPreset}");
        }

        private void RefreshCaseTimeline()
        {
            var active = WorkOrderService.GetActiveWorkOrder();
            if (active == null)
            {
                CaseTimelineBorder.Visibility = Visibility.Collapsed;
                return;
            }

            var entries = WorkOrderTimelineService.LoadActiveTimeline();
            CaseTimelineBorder.Visibility = Visibility.Visible;
            NoTimelineText.Visibility = entries.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            CaseTimelineList.Items.Clear();

            foreach (var entry in entries)
            {
                var row = new StackPanel { Margin = new Thickness(0, 0, 0, 10) };
                var header = new TextBlock
                {
                    FontWeight = FontWeights.SemiBold,
                    FontSize = 13,
                    Foreground = FindThemeBrush("TextPrimaryBrush"),
                    Text = $"{entry.TimelineLabel}  ({entry.EventKind})  —  {entry.OverallHealth}"
                };
                row.Children.Add(header);
                var meta = new TextBlock
                {
                    FontSize = 11,
                    Foreground = FindThemeBrush("TextSecondaryBrush"),
                    Text = entry.CompletedAt
                };
                row.Children.Add(meta);

                var actions = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0) };
                if (!string.IsNullOrWhiteSpace(entry.ReportPdf) && File.Exists(entry.ReportPdf))
                    actions.Children.Add(CreateTimelineLinkButton("Open Report", entry.ReportPdf));

                if (actions.Children.Count > 0)
                    row.Children.Add(actions);

                CaseTimelineList.Items.Add(new Border
                {
                    Padding = new Thickness(12),
                    Background = FindThemeBrush("BackgroundMidBrush"),
                    BorderBrush = FindThemeBrush("BorderBrush"),
                    BorderThickness = new Thickness(1),
                    CornerRadius = new CornerRadius(6),
                    Child = row
                });
            }
        }

        private static Brush FindThemeBrush(string resourceKey)
        {
            if (Application.Current?.TryFindResource(resourceKey) is Brush brush)
                return brush;

            return resourceKey switch
            {
                "BackgroundMidBrush" => Brushes.White,
                "AccentBlueBrush" => new SolidColorBrush(Color.FromRgb(0x00, 0x78, 0xD4)),
                "TextSecondaryBrush" => new SolidColorBrush(Color.FromRgb(0x5A, 0x6B, 0x80)),
                "BorderBrush" => new SolidColorBrush(Color.FromRgb(0xD0, 0xD6, 0xE0)),
                _ => new SolidColorBrush(Color.FromRgb(0x1A, 0x28, 0x40))
            };
        }

        private static Button CreateTimelineLinkButton(string label, string path)
        {
            var button = new Button
            {
                Content = label,
                Tag = path,
                Margin = new Thickness(0, 0, 8, 0),
                Padding = new Thickness(10, 4, 10, 4),
                Cursor = System.Windows.Input.Cursors.Hand
            };
            if (Application.Current?.TryFindResource("ActionButtonStyle") is Style style)
                button.Style = style;
            button.Click += (_, _) =>
            {
                try { ShellFileOpenHelper.OpenWithDefaultApplication(path); }
                catch (System.Exception ex)
                {
                    MessageBox.Show(ex.Message, "Open file", MessageBoxButton.OK, MessageBoxImage.Warning);
                }
            };
            return button;
        }

        private static void ApplySymptomButtonStyle(Button button, bool selected, bool suggested)
        {
            if (Application.Current?.TryFindResource("ActionButtonStyle") is Style actionStyle)
                button.Style = actionStyle;

            if (selected)
            {
                button.Background = new SolidColorBrush(Color.FromRgb(0x1E, 0x4D, 0x80));
                button.Foreground = Brushes.White;
                button.BorderBrush = new SolidColorBrush(Color.FromRgb(0x1E, 0x4D, 0x80));
            }
            else if (suggested)
            {
                button.Background = FindThemeBrush("AccentBlueBrush");
                button.Foreground = Brushes.White;
                button.BorderBrush = FindThemeBrush("AccentBlueBrush");
                button.FontWeight = FontWeights.SemiBold;
            }
            else
            {
                button.Background = Brushes.White;
                button.Foreground = new SolidColorBrush(Color.FromRgb(0x1A, 0x2B, 0x42));
                button.BorderBrush = new SolidColorBrush(Color.FromRgb(0xD8, 0xDE, 0xE6));
                button.FontWeight = FontWeights.Normal;
            }

            button.BorderThickness = suggested && !selected ? new Thickness(2) : new Thickness(1);
        }

        private static void ApplyFollowUpButtonStyle(Button button)
        {
            button.Background = Brushes.Transparent;
            button.Foreground = new SolidColorBrush(Color.FromRgb(0x1F, 0x6F, 0xEB));
            button.BorderBrush = new SolidColorBrush(Color.FromRgb(0xD8, 0xDE, 0xE6));
            button.BorderThickness = new Thickness(1);
        }

        private WorkOrderFormData ReadFormFromUi() => new()
        {
            ClientName = ClientNameTextBox.Text?.Trim() ?? string.Empty,
            ClientPhone = ClientPhoneTextBox.Text?.Trim() ?? string.Empty,
            TechnicianNotes = WorkOrderNotesTextBox.Text ?? string.Empty
        };

        private void RefreshWorkOrderUi()
        {
            var active = WorkOrderService.GetActiveWorkOrder();
            if (active == null)
            {
                WorkOrderStatusText.Text = "No active work order.";
                GenerateWorkOrderButton.IsEnabled = true;
                SaveWorkOrderButton.IsEnabled = false;
                CloseWorkOrderButton.IsEnabled = false;
                WorkOrderHintText.Text = "Tip: Generate a work order to attach workflow runs and notes to this job.";
                WorkOrderHintText.Visibility = Visibility.Visible;
                _suggestedFlowId = null;
                SuggestedSymptomHintText.Visibility = Visibility.Collapsed;
                _selectedFlow = null;
                _symptomExplicitlyChosen = false;
                SelectedSymptomPanel.Visibility = Visibility.Collapsed;
                RefreshSymptomButtonStyles();
                CaseTimelineBorder.Visibility = Visibility.Collapsed;
                return;
            }

            WorkOrderStatusText.Text = $"Active: {active.CaseId} ({active.RunCount} run{(active.RunCount == 1 ? string.Empty : "s")})";
            ClientNameTextBox.Text = active.ClientName;
            ClientPhoneTextBox.Text = active.ClientPhone;
            WorkOrderNotesTextBox.Text = active.TechnicianNotes;
            GenerateWorkOrderButton.IsEnabled = false;
            SaveWorkOrderButton.IsEnabled = true;
            CloseWorkOrderButton.IsEnabled = true;
            WorkOrderHintText.Visibility = Visibility.Collapsed;
            RefreshSuggestedSymptomGuidance();
            RefreshCaseTimeline();
        }

        private void RefreshRecentWorkOrders()
        {
            var items = WorkOrderService.GetRecentWorkOrders(5);
            RecentWorkOrdersList.ItemsSource = items;
            NoRecentWorkOrdersText.Visibility = items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            RecentWorkOrdersList.Visibility = items.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        }

        private void GenerateWorkOrder_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                var form = ReadFormFromUi();
                var created = WorkOrderService.CreateWorkOrder(form);
                SeedGuidanceFromNotes(form);
                RefreshWorkOrderUi();
                RefreshRecentWorkOrders();
                MessageBox.Show(
                    $"Work order opened:\n{created.CaseId}\n\nWorkflow results will attach to this case until you close it.",
                    "Work Order",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
            }
            catch (System.Exception ex)
            {
                MessageBox.Show($"Unable to create work order:\n\n{ex.Message}", "Work Order", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private void SaveWorkOrder_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                var form = ReadFormFromUi();
                WorkOrderService.UpdateActiveWorkOrder(form);
                if (!_symptomExplicitlyChosen)
                    SeedGuidanceFromNotes(form);
                RefreshWorkOrderUi();
                MessageBox.Show("Work order saved.", "Work Order", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            catch (System.Exception ex)
            {
                MessageBox.Show($"Unable to save work order:\n\n{ex.Message}", "Work Order", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private void CloseWorkOrder_Click(object sender, RoutedEventArgs e)
        {
            var active = WorkOrderService.GetActiveWorkOrder();
            if (active == null)
            {
                RefreshWorkOrderUi();
                return;
            }

            var confirm = MessageBox.Show(
                $"Close work order {active.CaseId} and export the final PDF report?",
                "Close Work Order",
                MessageBoxButton.YesNo,
                MessageBoxImage.Question);
            if (confirm != MessageBoxResult.Yes)
                return;

            try
            {
                var pdfPath = WorkOrderService.CloseActiveWorkOrder(ReadFormFromUi());
                ClientNameTextBox.Clear();
                ClientPhoneTextBox.Clear();
                WorkOrderNotesTextBox.Clear();
                RefreshWorkOrderUi();
                RefreshRecentWorkOrders();

                if (!string.IsNullOrWhiteSpace(pdfPath) && File.Exists(pdfPath))
                {
                    ShellFileOpenHelper.OpenWithDefaultApplication(pdfPath);
                }

                MessageBox.Show(
                    $"Work order closed.\n\nFinal report:\n{pdfPath}",
                    "Work Order",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
            }
            catch (System.Exception ex)
            {
                MessageBox.Show($"Unable to close work order:\n\n{ex.Message}", "Work Order", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private void RecentWorkOrderLink_Click(object sender, RoutedEventArgs e)
        {
            if (sender is not Button button || button.Tag is not string caseId || string.IsNullOrWhiteSpace(caseId))
                return;

            var owner = Window.GetWindow(this);
            var window = new WorkOrderDetailWindow(caseId) { Owner = owner };
            window.ShowDialog();
        }

        private void ExportFeedbackBundle_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                var zipPath = WorkOrderService.ExportFieldFeedbackBundle();
                MessageBox.Show(
                    $"Field feedback bundle created:\n\n{zipPath}",
                    "Export Feedback",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
            }
            catch (System.Exception ex)
            {
                MessageBox.Show(ex.Message, "Export Feedback", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private void ClearRecentWorkOrders_Click(object sender, RoutedEventArgs e)
        {
            var runtimeDir = WorkOrderPathHelper.GetInternalWorkOrdersDirectory();
            var confirm = MessageBox.Show(
                $"Delete all saved work order records in:\n\n{runtimeDir}\n\n" +
                "Closed-case PDFs in WorkOrders\\ are not removed. " +
                "If a work order is still open, its active pointer will be cleared too.\n\n" +
                "This cannot be undone.",
                "Clear Recent Work Orders",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning,
                MessageBoxResult.No);

            if (confirm != MessageBoxResult.Yes)
                return;

            var result = WorkOrderService.ClearRecentInternalWorkOrderRecords();
            RefreshWorkOrderUi();
            RefreshRecentWorkOrders();
            RefreshCaseTimeline();

            var message = result.FilesDeleted == 0
                ? "No work order JSON files were found to delete."
                : $"Removed {result.FilesDeleted} work order record(s).";

            if (result.ActiveWorkOrderCleared)
                message += "\n\nThe active work order pointer was cleared because its case file was removed.";

            if (result.Errors.Count > 0)
            {
                message += "\n\nSome files could not be deleted:";
                foreach (var error in result.Errors.Take(5))
                    message += $"\n  • {error}";
                if (result.Errors.Count > 5)
                    message += $"\n  • ... and {result.Errors.Count - 5} more";
            }

            MessageBox.Show(
                message,
                result.Errors.Count > 0 ? "Clear Recent — Partial" : "Clear Recent",
                MessageBoxButton.OK,
                result.Errors.Count > 0 ? MessageBoxImage.Warning : MessageBoxImage.Information);
        }
    }
}
