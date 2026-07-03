using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Collections.ObjectModel;

namespace ToolkitGUI.Models
{
    public class TempFolder : INotifyPropertyChanged
    {
        private bool _isSelected;

        public string Path        { get; set; } = string.Empty;
        public string Category    { get; set; } = string.Empty;
        public string UserAccount { get; set; } = string.Empty;
        public string DriveLetter { get; set; } = string.Empty;
        public string ProfileGroup { get; set; } = string.Empty;
        public string DiscoverySource { get; set; } = string.Empty;
        public bool IsProtected { get; set; }
        public string ProtectionReason { get; set; } = string.Empty;
        public int    FileCount   { get; set; }
        public long   Bytes       { get; set; }

        public string SizeDisplay => SizeDisplayFormatter.FormatBytes(Bytes);

        public bool IsSelected
        {
            get => _isSelected;
            set { _isSelected = value; OnPropertyChanged(); }
        }

        public event PropertyChangedEventHandler? PropertyChanged;
        protected void OnPropertyChanged([CallerMemberName] string? n = null)
            => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
    }

    public class TempFolderNode : INotifyPropertyChanged
    {
        private bool _isSelected;
        private bool _isExpanded;

        public string DisplayName  { get; set; } = string.Empty;
        public string Path         { get; set; } = string.Empty;
        public string Category     { get; set; } = string.Empty;
        public string UserAccount  { get; set; } = string.Empty;
        public string DriveLetter  { get; set; } = string.Empty;
        public string DiscoverySource { get; set; } = string.Empty;
        public bool   IsProtected  { get; set; }
        public string ProtectionReason { get; set; } = string.Empty;
        public int    FileCount    { get; set; }
        public long   Bytes        { get; set; }
        public bool   IsParent     { get; set; }

        public ObservableCollection<TempFolderNode> Children { get; } = new();

        public string SizeDisplay => SizeDisplayFormatter.FormatBytes(Bytes);

        public bool IsExpanded
        {
            get => _isExpanded;
            set { _isExpanded = value; OnPropertyChanged(); }
        }

        public bool IsSelected
        {
            get => _isSelected;
            set
            {
                if (_isSelected == value) return;
                _isSelected = value;
                OnPropertyChanged();
                // Propagate to all children when a parent node is toggled
                if (IsParent)
                {
                    foreach (var child in Children)
                        child.IsSelected = value;
                }
            }
        }

        /// <summary>Sets the initial checked state without propagating to children.</summary>
        public void SetInitialSelected(bool value)
        {
            _isSelected = value;
            OnPropertyChanged(nameof(IsSelected));
        }

        public event PropertyChangedEventHandler? PropertyChanged;
        protected void OnPropertyChanged([CallerMemberName] string? n = null)
            => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
    }

    public class DriveSelectionItem : INotifyPropertyChanged
    {
        private bool _isSelected;

        public string RootPath { get; set; } = string.Empty;
        public string DisplayName { get; set; } = string.Empty;

        public bool IsSelected
        {
            get => _isSelected;
            set { _isSelected = value; OnPropertyChanged(); }
        }

        public event PropertyChangedEventHandler? PropertyChanged;
        protected void OnPropertyChanged([CallerMemberName] string? n = null)
            => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
    }

    public class InstalledProgram
    {
        public string Name         { get; set; } = string.Empty;
        public string Publisher    { get; set; } = string.Empty;
        public string Version      { get; set; } = string.Empty;
        public string InstallDate  { get; set; } = string.Empty;
        public string SizeDisplay  { get; set; } = string.Empty;
        public string UninstallKey { get; set; } = string.Empty;
        public string UninstallStr { get; set; } = string.Empty;
        public string Arch         { get; set; } = string.Empty;
    }

    public class FastFix
    {
        public string Key         { get; set; } = string.Empty;
        public string Name        { get; set; } = string.Empty;
        public string Description { get; set; } = string.Empty;
        public string Category    { get; set; } = string.Empty;
        public string Risk        { get; set; } = "Safe";   // Safe | Caution
        public bool IsApplicable  { get; set; } = true;
        public string ActionLabel { get; set; } = "Apply";
        public string AvailabilityNote { get; set; } = string.Empty;
    }
}
