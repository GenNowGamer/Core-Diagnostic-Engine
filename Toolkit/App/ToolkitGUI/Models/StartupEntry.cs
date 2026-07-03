using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace ToolkitGUI.Models
{
    public class StartupEntry : INotifyPropertyChanged
    {
        private bool _isEnabled;

        public string Name        { get; set; } = string.Empty;
        public string Publisher   { get; set; } = string.Empty;
        public string FilePath    { get; set; } = string.Empty;
        public string Source      { get; set; } = string.Empty;   // registry hive or Folder
        public string Category    { get; set; } = string.Empty;
        public string RowType     { get; set; } = string.Empty;
        public string SourceGroup { get; set; } = string.Empty;
        public string RegistryHive { get; set; } = string.Empty;
        public string RegistryPath { get; set; } = string.Empty;
        public string ValueName    { get; set; } = string.Empty;
        public string OriginalData { get; set; } = string.Empty;
        public string ServiceName  { get; set; } = string.Empty;
        public string Clsid        { get; set; } = string.Empty;
        public bool   IsCritical   { get; set; }
        public bool   SupportsEnable  { get; set; } = true;
        public bool   SupportsDisable { get; set; } = true;
        public bool   SupportsDelete  { get; set; } = true;
        public bool   SupportsReset   { get; set; }
        public bool   SupportsUndo    { get; set; }
        public bool   IsDeviated      { get; set; }
        public string DeviationReason { get; set; } = string.Empty;
        public string ActionStatePayload { get; set; } = string.Empty;
        public string CorrelationGroupId { get; set; } = string.Empty;
        public string CorrelationSummary { get; set; } = string.Empty;
        public int    ReputationScore { get; set; }
        public string ReputationBand { get; set; } = string.Empty;
        public string RegistryKey { get; set; } = string.Empty;
        public string RiskLevel   { get; set; } = "Unknown";      // Safe | Caution | Warning
        public bool   IsSigned    { get; set; }
        public string User            { get; set; } = string.Empty;
        public string SignedBy        { get; set; } = string.Empty;
        public string SignedDisplay   { get; set; } = string.Empty;
        public string SignatureStatus { get; set; } = string.Empty;
        public string AnalysisLevel   { get; set; } = string.Empty;
        public string AnalysisDetail  { get; set; } = string.Empty;
        public bool   HasAnalysisWarning { get; set; }
        public bool   IsHijackSuspicious { get; set; }

        public bool IsEnabled
        {
            get => _isEnabled;
            set { _isEnabled = value; OnPropertyChanged(); }
        }

        public event PropertyChangedEventHandler? PropertyChanged;
        protected void OnPropertyChanged([CallerMemberName] string? n = null)
            => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
    }

    public class ServiceEntry : INotifyPropertyChanged
    {
        private string _status      = string.Empty;
        private string _startupType = string.Empty;

        public string ServiceName  { get; set; } = string.Empty;
        public string DisplayName  { get; set; } = string.Empty;
        public string Description  { get; set; } = string.Empty;

        public string Status
        {
            get => _status;
            set { _status = value; OnPropertyChanged(); }
        }

        public string StartupType
        {
            get => _startupType;
            set { _startupType = value; OnPropertyChanged(); }
        }

        public string FilePath           { get; set; } = string.Empty;
        public string User               { get; set; } = string.Empty;
        public string SignedBy           { get; set; } = string.Empty;
        public string SignedDisplay      { get; set; } = string.Empty;
        public string SignatureStatus    { get; set; } = string.Empty;
        public bool   IsSigned           { get; set; }
        public string AnalysisLevel      { get; set; } = string.Empty;
        public string AnalysisDetail     { get; set; } = string.Empty;
        public bool   HasAnalysisWarning { get; set; }

        public event PropertyChangedEventHandler? PropertyChanged;
        protected void OnPropertyChanged([CallerMemberName] string? n = null)
            => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
    }
}
