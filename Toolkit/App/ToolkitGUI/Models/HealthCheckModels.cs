using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Input;
using System.Windows.Media;
using ToolkitGUI.Services;

namespace ToolkitGUI.Models
{
    public enum SystemHealthViewState
    {
        Picker,
        Running,
        Results
    }

    public sealed class HealthCheckItemViewModel : INotifyPropertyChanged
    {
        private bool _isSelected;
        private bool _isAvailable = true;
        private string _unavailableReason = string.Empty;

        public string CheckId { get; init; } = string.Empty;
        public string CategoryId { get; init; } = string.Empty;
        public string Label { get; init; } = string.Empty;
        public string Description { get; init; } = string.Empty;
        public double EstimatedMinutes { get; init; }

        public bool IsSelected
        {
            get => _isSelected;
            set { _isSelected = value; OnPropertyChanged(); }
        }

        public bool IsAvailable
        {
            get => _isAvailable;
            set { _isAvailable = value; OnPropertyChanged(); OnPropertyChanged(nameof(IsUnavailable)); }
        }

        public bool IsUnavailable => !IsAvailable;

        public string UnavailableReason
        {
            get => _unavailableReason;
            set { _unavailableReason = value; OnPropertyChanged(); }
        }

        public event PropertyChangedEventHandler? PropertyChanged;
        private void OnPropertyChanged([CallerMemberName] string? name = null)
            => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    public sealed class HealthCheckCategoryViewModel
    {
        public string Id { get; init; } = string.Empty;
        public string Label { get; init; } = string.Empty;
        public IList<HealthCheckItemViewModel> Checks { get; } = new List<HealthCheckItemViewModel>();
    }

    public sealed class HealthFindingViewModel
    {
        public string CheckId { get; init; } = string.Empty;
        public string StepName { get; init; } = string.Empty;
        public string CategoryLabel { get; init; } = string.Empty;
        public string CheckLabel { get; init; } = string.Empty;
        public string Status { get; init; } = string.Empty;
        public string Detail { get; init; } = string.Empty;
        public string DetailOverview { get; init; } = string.Empty;
        public IReadOnlyList<StructuredResultItemViewModel> FormattedItems { get; init; } = new List<StructuredResultItemViewModel>();
        public IReadOnlyList<FormattedResultSectionViewModel> FormattedSections { get; init; } = new List<FormattedResultSectionViewModel>();
        public Brush StatusBrush { get; init; } = Brushes.Gray;
    }

    public sealed class HealthRecommendationViewModel
    {
        public string CheckId { get; init; } = string.Empty;
        public string Title { get; init; } = string.Empty;
        public string Reason { get; init; } = string.Empty;
        public string NavTarget { get; init; } = string.Empty;
        public string NavTargetLabel { get; init; } = string.Empty;
        public ICommand? OpenToolCommand { get; init; }
    }

    public sealed class HealthActionViewModel
    {
        public string Label { get; init; } = string.Empty;
        public bool IsExternal { get; init; }
        public ICommand? Command { get; init; }
    }

    public sealed class HealthCheckCatalogDto
    {
        public int Version { get; set; }
        public List<HealthCheckCategoryDto> Categories { get; set; } = new();
        public Dictionary<string, List<string>> Presets { get; set; } = new();
        public List<HealthCheckRecommendationDto> Recommendations { get; set; } = new();
    }

    public sealed class HealthCheckRecommendationDto
    {
        public string WhenCheckId { get; set; } = string.Empty;
        public List<string> WhenStatus { get; set; } = new();
        public string NavTarget { get; set; } = string.Empty;
        public string Title { get; set; } = string.Empty;
        public string ReasonTemplate { get; set; } = string.Empty;
        public List<HealthCheckActionDto> Actions { get; set; } = new();
    }

    public sealed class HealthCheckActionDto
    {
        public string Type { get; set; } = string.Empty;
        public string Target { get; set; } = string.Empty;
        public string Label { get; set; } = string.Empty;
    }

    public sealed class HealthCheckCategoryDto
    {
        public string Id { get; set; } = string.Empty;
        public string Label { get; set; } = string.Empty;
        public List<HealthCheckEntryDto> Checks { get; set; } = new();
    }

    public sealed class HealthCheckEntryDto
    {
        public string Id { get; set; } = string.Empty;
        public string Label { get; set; } = string.Empty;
        public string Description { get; set; } = string.Empty;
        public double EstimatedMinutes { get; set; }
        public string WinPe { get; set; } = "available";
    }
}
