using System.ComponentModel;
using System.Runtime.CompilerServices;
using Newtonsoft.Json;

namespace ToolkitGUI.Models
{
    public class ProcessEntry : INotifyPropertyChanged
    {
        private double _cpuPercent;
        private double _ram;
        private string _status = string.Empty;
        private bool _isNew;

        public int    Pid         { get; set; }
        public string Name        { get; set; } = string.Empty;
        public string Company     { get; set; } = string.Empty;
        public string FilePath    { get; set; } = string.Empty;
        public string Arch        { get; set; } = string.Empty;
        public string UserName    { get; set; } = string.Empty;
        public bool?  IsSigned    { get; set; }
        public bool   SignatureChecked { get; set; }
        [JsonProperty("CommandLine")]
        public string CommandLine { get; set; } = string.Empty;
        [JsonProperty("ParentPid")]
        public int    ParentPid   { get; set; }
        [JsonProperty("SessionId")]
        public int    SessionId   { get; set; }
        public string StartTime   { get; set; } = string.Empty;
        public int    RiskScore   { get; set; }
        public string RiskBand    { get; set; } = "Safe";
        public string RiskFlags   { get; set; } = string.Empty;
        public bool   InStartup   { get; set; }

        public double CpuPercent
        {
            get => _cpuPercent;
            set { _cpuPercent = value; OnPropertyChanged(); OnPropertyChanged(nameof(CpuDisplay)); }
        }

        public double RamMB
        {
            get => _ram;
            set
            {
                _ram = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(RamDisplay));
            }
        }

        public string RamDisplay => SizeDisplayFormatter.FormatMegabytes(RamMB);
        public string CpuDisplay => $"{CpuPercent:0.0}%";

        public string SignedDisplay => SignatureChecked
            ? (IsSigned == true ? "Yes" : "No")
            : "—";

        public string Status
        {
            get => _status;
            set { _status = value; OnPropertyChanged(); }
        }

        public string NewDisplay => IsNew ? "NEW" : string.Empty;

        public bool IsNew
        {
            get => _isNew;
            set
            {
                _isNew = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(NewDisplay));
            }
        }

        public event PropertyChangedEventHandler? PropertyChanged;
        protected void OnPropertyChanged([CallerMemberName] string? n = null)
            => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
    }
}
