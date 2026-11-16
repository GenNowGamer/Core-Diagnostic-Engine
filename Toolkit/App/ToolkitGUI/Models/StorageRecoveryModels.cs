using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Media;
using CdeRecovery.Core.Devices;
using CdeRecovery.Core.Models;

namespace ToolkitGUI.Models
{
    public sealed class StorageTargetChoice
    {
        public string DisplayTitle { get; init; } = string.Empty;
        public string Subtitle { get; init; } = string.Empty;
        public bool IsDiskImage { get; init; }
        public string ImagePath { get; init; } = string.Empty;
        public StorageDeviceIdentity Device { get; init; } = new();
    }

    public sealed class StorageWorkflowStageItem : INotifyPropertyChanged
    {
        private string _state = "Pending"; // Pending, Active, Completed, Blocked

        public int StageNumber { get; init; }
        public string Title { get; init; } = string.Empty;
        public string Description { get; init; } = string.Empty;

        public string State
        {
            get => _state;
            set
            {
                if (_state == value) return;
                _state = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(BadgeBackground));
                OnPropertyChanged(nameof(StateLabel));
            }
        }

        public string StateLabel => State switch
        {
            "Completed" => "✓ Done",
            "Active" => "● Active",
            "Blocked" => "⚠ Blocked",
            _ => $"Stage {StageNumber}"
        };

        public Brush BadgeBackground => State switch
        {
            "Completed" => new SolidColorBrush(Color.FromRgb(0x0D, 0x7A, 0x3E)),
            "Active" => new SolidColorBrush(Color.FromRgb(0x00, 0x78, 0xD4)),
            "Blocked" => new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C)),
            _ => new SolidColorBrush(Color.FromRgb(0x5A, 0x6B, 0x80))
        };

        public event PropertyChangedEventHandler? PropertyChanged;
        private void OnPropertyChanged([CallerMemberName] string? name = null) =>
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    public sealed class StorageFindingRowViewModel
    {
        public string FindingId { get; init; } = string.Empty;
        public string Category { get; init; } = string.Empty;
        public string Title { get; init; } = string.Empty;
        public string Status { get; init; } = string.Empty;
        public string Severity { get; init; } = string.Empty;
        public int Confidence { get; init; }
        public string Classification { get; init; } = string.Empty;
        public string OffsetDisplay { get; init; } = string.Empty;
        public string EvidenceSummary { get; init; } = string.Empty;
        public string Recommendation { get; init; } = string.Empty;
        public Brush StatusBrush { get; init; } = Brushes.Gray;

        public static StorageFindingRowViewModel FromModel(StorageDiagnosticFinding f)
        {
            var brush = (f.Status ?? string.Empty).ToUpperInvariant() switch
            {
                "PASS" => new SolidColorBrush(Color.FromRgb(0x0D, 0x7A, 0x3E)),
                "WARN" => new SolidColorBrush(Color.FromRgb(0xD2, 0x99, 0x22)),
                "FAIL" => new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C)),
                _ => new SolidColorBrush(Color.FromRgb(0x00, 0x78, 0xD4))
            };
            brush.Freeze();

            return new StorageFindingRowViewModel
            {
                FindingId = f.FindingId ?? string.Empty,
                Category = f.Category ?? string.Empty,
                Title = f.Title ?? string.Empty,
                Status = f.Status ?? string.Empty,
                Severity = f.Severity ?? string.Empty,
                Confidence = f.Confidence,
                Classification = f.Classification ?? string.Empty,
                OffsetDisplay = f.ByteLength > 0 ? $"0x{f.ByteOffset:X} ({f.ByteLength} B)" : $"0x{f.ByteOffset:X}",
                EvidenceSummary = f.EvidenceSummary ?? string.Empty,
                Recommendation = f.Recommendation ?? string.Empty,
                StatusBrush = brush
            };
        }
    }

    public sealed class RecoverableFileRowViewModel : INotifyPropertyChanged
    {
        private bool _isSelected = true;

        public RecoverableFileItem Model { get; init; } = new();

        public bool IsSelected
        {
            get => _isSelected;
            set
            {
                if (_isSelected == value) return;
                _isSelected = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsSelected)));
            }
        }

        public long MftRecordNumber => Model.MftRecordNumber;
        public string FileName => Model.FileName;
        public string ReconstructedPath => Model.ReconstructedPath;
        public string DisplaySize => Model.DisplaySize;
        public string StatusLabel => Model.StatusLabel;
        public string ModifiedDisplay => Model.ModifiedUtc.ToString("yyyy-MM-dd HH:mm");

        public event PropertyChangedEventHandler? PropertyChanged;
    }
}
