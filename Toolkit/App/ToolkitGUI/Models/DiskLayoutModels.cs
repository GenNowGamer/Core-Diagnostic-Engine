using System.Collections.Generic;
using System.ComponentModel;
using System.Text.Json.Serialization;

namespace ToolkitGUI.Models
{
    public sealed class CdeDiskLayoutDocument
    {
        [JsonPropertyName("SchemaVersion")]
        public int SchemaVersion { get; set; }

        [JsonPropertyName("GeneratedAtUtc")]
        public string GeneratedAtUtc { get; set; } = string.Empty;

        [JsonPropertyName("Disks")]
        public List<CdePhysicalDiskModel> Disks { get; set; } = new();

        [JsonPropertyName("WindowsInstalls")]
        public List<CdeWindowsInstallModel> WindowsInstalls { get; set; } = new();

        [JsonPropertyName("EfiVolumes")]
        public List<CdeEfiVolumeModel> EfiVolumes { get; set; } = new();
    }

    public sealed class CdePhysicalDiskModel
    {
        [JsonPropertyName("DiskNumber")]
        public int DiskNumber { get; set; }

        [JsonPropertyName("FriendlyName")]
        public string FriendlyName { get; set; } = string.Empty;

        [JsonPropertyName("SerialNumber")]
        public string SerialNumber { get; set; } = string.Empty;

        [JsonPropertyName("Size")]
        public long Size { get; set; }

        [JsonPropertyName("PartitionStyle")]
        public string PartitionStyle { get; set; } = string.Empty;

        [JsonPropertyName("IsBoot")]
        public bool IsBoot { get; set; }

        [JsonPropertyName("IsSystem")]
        public bool IsSystem { get; set; }

        [JsonPropertyName("IsRemovable")]
        public bool IsRemovable { get; set; }

        [JsonPropertyName("BusType")]
        public string BusType { get; set; } = string.Empty;

        [JsonPropertyName("Partitions")]
        public List<CdePartitionModel> Partitions { get; set; } = new();
    }

    public sealed class CdePartitionModel
    {
        [JsonPropertyName("PartitionNumber")]
        public int PartitionNumber { get; set; }

        [JsonPropertyName("DriveLetter")]
        public string DriveLetter { get; set; } = string.Empty;

        [JsonPropertyName("DriveRoot")]
        public string DriveRoot { get; set; } = string.Empty;

        [JsonPropertyName("Size")]
        public long Size { get; set; }

        [JsonPropertyName("Type")]
        public string Type { get; set; } = string.Empty;

        [JsonPropertyName("IsSystem")]
        public bool IsSystem { get; set; }

        [JsonPropertyName("IsBoot")]
        public bool IsBoot { get; set; }

        [JsonPropertyName("IsHidden")]
        public bool IsHidden { get; set; }

        [JsonPropertyName("GptType")]
        public string GptType { get; set; } = string.Empty;

        [JsonPropertyName("HasWindows")]
        public bool HasWindows { get; set; }

        [JsonPropertyName("WindowsDir")]
        public string WindowsDir { get; set; } = string.Empty;

        [JsonPropertyName("EfiBcdPath")]
        public string EfiBcdPath { get; set; } = string.Empty;

        [JsonPropertyName("BiosBcdPath")]
        public string BiosBcdPath { get; set; } = string.Empty;

        [JsonPropertyName("BootScore")]
        public int BootScore { get; set; }

        public string DisplayLabel
        {
            get
            {
                var letter = string.IsNullOrWhiteSpace(DriveLetter) ? "(none)" : $"{DriveLetter}:";
                return $"Part {PartitionNumber}  {letter}  {FormatSize(Size)}  {Type}";
            }
        }

        public static string FormatSize(long bytes)
        {
            if (bytes <= 0) return "0 B";
            double gb = bytes / (1024.0 * 1024.0 * 1024.0);
            if (gb >= 1) return $"{gb:0.##} GB";
            double mb = bytes / (1024.0 * 1024.0);
            return $"{mb:0.#} MB";
        }
    }

    public sealed class CdeWindowsInstallModel
    {
        [JsonPropertyName("DriveRoot")]
        public string DriveRoot { get; set; } = string.Empty;

        [JsonPropertyName("WindowsDir")]
        public string WindowsDir { get; set; } = string.Empty;

        [JsonPropertyName("EfiBcdPath")]
        public string EfiBcdPath { get; set; } = string.Empty;

        [JsonPropertyName("EfiDriveRoot")]
        public string EfiDriveRoot { get; set; } = string.Empty;

        [JsonPropertyName("BiosBcdPath")]
        public string BiosBcdPath { get; set; } = string.Empty;

        [JsonPropertyName("Score")]
        public int Score { get; set; }
    }

    public sealed class CdeEfiVolumeModel
    {
        [JsonPropertyName("DriveRoot")]
        public string DriveRoot { get; set; } = string.Empty;

        [JsonPropertyName("EfiBcdPath")]
        public string EfiBcdPath { get; set; } = string.Empty;

        [JsonPropertyName("HasWindows")]
        public bool HasWindows { get; set; }

        [JsonPropertyName("WindowsDir")]
        public string WindowsDir { get; set; } = string.Empty;
    }

    public sealed class BcdBackupFileItem : INotifyPropertyChanged
    {
        private bool _isSelected;

        public string FullPath { get; set; } = string.Empty;
        public string FileName { get; set; } = string.Empty;
        public string Kind { get; set; } = string.Empty;
        public string DisplayTime { get; set; } = string.Empty;

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

        public event PropertyChangedEventHandler? PropertyChanged;
    }
}
