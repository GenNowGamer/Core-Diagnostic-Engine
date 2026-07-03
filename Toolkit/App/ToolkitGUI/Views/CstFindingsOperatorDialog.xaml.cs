using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using ToolkitGUI.Services;

namespace ToolkitGUI.Views
{
    public sealed class CstFindingSelectionItem : INotifyPropertyChanged
    {
        private bool _isSelected;
        private string _remediationState = "None";

        public string Id { get; init; } = string.Empty;
        public string Type { get; init; } = string.Empty;
        public string Severity { get; init; } = string.Empty;
        public string Name { get; init; } = string.Empty;
        public string Location { get; init; } = string.Empty;
        public string Evidence { get; init; } = string.Empty;
        public bool CanRemediate { get; init; }
        public bool IsSuppressedByScope { get; init; }
        public string SelectionNote { get; init; } = string.Empty;
        public string WarningBadge { get; init; } = string.Empty;
        public string Detector { get; init; } = string.Empty;
        public double Confidence { get; init; }
        public string ObjectType { get; init; } = string.Empty;

        public bool IsSelected
        {
            get => _isSelected;
            set
            {
                if (value && !CanRemediate)
                {
                    return;
                }

                if (_isSelected == value) return;
                _isSelected = value;
                OnPropertyChanged();
            }
        }

        public string RemediationState
        {
            get => _remediationState;
            set
            {
                if (_remediationState == value) return;
                _remediationState = value;
                OnPropertyChanged();
            }
        }

        public event PropertyChangedEventHandler? PropertyChanged;

        private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        }
    }

    public partial class CstFindingsOperatorDialog : Window
    {
        public ObservableCollection<CstFindingSelectionItem> Findings { get; } = new();
        public string? RequestedAction { get; private set; }
        public string? RollbackManifestPath { get; private set; }

        public CstFindingsOperatorDialog(System.Collections.Generic.IEnumerable<CstFindingSelectionItem> findings)
        {
            InitializeComponent();
            WindowSizingHelper.EnableAdaptiveDialog(this);
            DataContext = this;

            foreach (var finding in findings)
            {
                Findings.Add(finding);
            }

            RefreshSelectionSummary();
            var suppressed = Findings.Count(f => f.IsSuppressedByScope);
            SummaryText.Text = suppressed > 0
                ? $"Loaded {Findings.Count} findings. {suppressed} were outside the selected Detection Scope, but concrete file traces can still be selected for operator remediation."
                : $"Loaded {Findings.Count} findings. Select concrete file traces and execute Remove or Quarantine.";
        }

        private void SelectActionableButton_Click(object sender, RoutedEventArgs e)
        {
            foreach (var finding in Findings)
            {
                finding.IsSelected = finding.CanRemediate;
            }
            RefreshSelectionSummary();
        }

        private void ClearSelectionButton_Click(object sender, RoutedEventArgs e)
        {
            foreach (var finding in Findings)
            {
                finding.IsSelected = false;
            }
            RefreshSelectionSummary();
        }

        private void QuarantineButton_Click(object sender, RoutedEventArgs e)
        {
            if (!EnsureValidSelection()) return;
            RequestedAction = "Quarantine";
            DialogResult = true;
            Close();
        }

        private void RemoveButton_Click(object sender, RoutedEventArgs e)
        {
            if (!EnsureValidSelection()) return;

            var result = MessageBox.Show(
                "Remove permanently deletes the selected files. Continue?",
                "Confirm Remove",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning);

            if (result != MessageBoxResult.Yes)
                return;

            RequestedAction = "Remove";
            DialogResult = true;
            Close();
        }

        private bool EnsureValidSelection()
        {
            var selected = Findings.Where(f => f.IsSelected).ToList();
            if (selected.Count == 0)
            {
                MessageBox.Show("Select at least one finding before running a remediation action.", "Core Security Tool", MessageBoxButton.OK, MessageBoxImage.Information);
                return false;
            }

            if (selected.Any(f => !f.CanRemediate))
            {
                MessageBox.Show("One or more selected findings are not actionable. Clear selection or choose actionable rows only.", "Core Security Tool", MessageBoxButton.OK, MessageBoxImage.Warning);
                return false;
            }

            return true;
        }

        private void CloseButton_Click(object sender, RoutedEventArgs e)
        {
            DialogResult = false;
            Close();
        }

        private void RestoreFromManifestButton_Click(object sender, RoutedEventArgs e)
        {
            var defaultRollbackFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "CoreSecurityTool", "Rollback");
            var dialog = new OpenFileDialog
            {
                Title = "Select CST Rollback Manifest",
                Filter = "Rollback Manifests (rollback_*.json)|rollback_*.json|JSON Files (*.json)|*.json|All Files (*.*)|*.*",
                InitialDirectory = Directory.Exists(defaultRollbackFolder) ? defaultRollbackFolder : Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                CheckFileExists = true,
                Multiselect = false
            };

            if (dialog.ShowDialog(this) != true)
                return;

            RollbackManifestPath = dialog.FileName;
            RequestedAction = "Rollback";
            DialogResult = true;
            Close();
        }

        private void FindingsGrid_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            RefreshSelectionSummary();
        }

        private void FindingsGrid_CellEditEnding(object sender, DataGridCellEditEndingEventArgs e)
        {
            Dispatcher.BeginInvoke(new System.Action(RefreshSelectionSummary));
        }

        private void RefreshSelectionSummary()
        {
            var selected = Findings.Count(f => f.IsSelected);
            var actionable = Findings.Count(f => f.CanRemediate);
            var reviewOnly = Findings.Count - actionable;
            SelectionText.Text = $"Selected: {selected} | Actionable: {actionable} | Review Only: {reviewOnly} | Total: {Findings.Count}";
        }
    }
}
