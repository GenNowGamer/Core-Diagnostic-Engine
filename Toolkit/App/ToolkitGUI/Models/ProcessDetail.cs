using System.Collections.ObjectModel;
using System.Globalization;
using Newtonsoft.Json;

namespace ToolkitGUI.Models
{
    public class ProcessDetail
    {
        public int Pid { get; set; }
        public string Name { get; set; } = string.Empty;
        public string FilePath { get; set; } = string.Empty;

        [JsonProperty("CommandLine")]
        public string StartupCommandLine { get; set; } = string.Empty;
        [JsonProperty("ParentPid")]
        public int ParentPid { get; set; }
        [JsonProperty("SessionId")]
        public int SessionId { get; set; }
        public string StartTime { get; set; } = string.Empty;
        public string UserName { get; set; } = string.Empty;
        public bool? IsSigned { get; set; }
        public bool SignatureChecked { get; set; }
        public string Arch { get; set; } = string.Empty;
        public double RamMB { get; set; }
        public string Status { get; set; } = string.Empty;
        public int RiskScore { get; set; }
        public string RiskBand { get; set; } = string.Empty;
        public string RiskFlags { get; set; } = string.Empty;
        public bool InStartup { get; set; }
        public string Sha256 { get; set; } = string.Empty;
        public ObservableCollection<ProcessParentLink> ParentChain { get; set; } = new();
        public ObservableCollection<string> Services { get; set; } = new();
        public ObservableCollection<string> Modules { get; set; } = new();

        public string SignedDisplay => SignatureChecked
            ? (IsSigned == true ? "Yes" : "No")
            : "—";

        public string RamDisplay => SizeDisplayFormatter.FormatMegabytes(RamMB);

        public string CommandLineDisplay => string.IsNullOrWhiteSpace(StartupCommandLine) ? "—" : StartupCommandLine;

        public string SessionDisplay => SessionId.ToString(CultureInfo.InvariantCulture);

        public string ParentPidDisplay => ParentPid.ToString(CultureInfo.InvariantCulture);

        public string StartTimeDisplay => string.IsNullOrWhiteSpace(StartTime) ? "—" : StartTime;
    }

    public class ProcessParentLink
    {
        public int Pid { get; set; }
        public int ParentPid { get; set; }
        public string Name { get; set; } = string.Empty;
        public string FilePath { get; set; } = string.Empty;
        public string CommandLine { get; set; } = string.Empty;
        public string DisplayLine => string.IsNullOrWhiteSpace(Name)
            ? $"PID {Pid}"
            : $"{Name} (PID {Pid})";
    }
}
