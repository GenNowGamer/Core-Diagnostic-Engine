using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace CdeRecovery.Core.Devices
{
    public sealed class StorageDeviceIdentity
    {
        public int DiskNumber { get; init; } = -1;
        public string DevicePath { get; init; } = string.Empty;
        public string FriendlyName { get; init; } = string.Empty;
        public string Model { get; init; } = string.Empty;
        public string SerialNumber { get; init; } = string.Empty;
        public string BusType { get; init; } = string.Empty;
        public long CapacityBytes { get; init; }
        public int LogicalSectorSize { get; init; } = 512;
        public int PhysicalSectorSize { get; init; } = 512;
        public bool IsSystemDisk { get; init; }
        public bool IsBootDisk { get; init; }
        public bool IsRemovable { get; init; }
        public bool IsDiskImage { get; init; }
        public string WindowsReportedPartitionStyle { get; init; } = "Unknown";
        public string SmartHealthStatus { get; init; } = "Unknown";
        public List<string> MountedDriveLetters { get; init; } = new();

        public long TotalSectors => LogicalSectorSize > 0 ? CapacityBytes / LogicalSectorSize : 0;

        public string DisplayCapacity
        {
            get
            {
                if (CapacityBytes <= 0) return "0 B";
                double tb = CapacityBytes / (1024.0 * 1024.0 * 1024.0 * 1024.0);
                if (tb >= 0.95) return $"{tb:0.##} TB";
                double gb = CapacityBytes / (1024.0 * 1024.0 * 1024.0);
                if (gb >= 1.0) return $"{gb:0.##} GB";
                double mb = CapacityBytes / (1024.0 * 1024.0);
                return $"{mb:0.#} MB";
            }
        }

        public bool MatchesIdentity(StorageDeviceIdentity other)
        {
            if (other == null) return false;
            if (IsDiskImage != other.IsDiskImage) return false;
            if (CapacityBytes != other.CapacityBytes) return false;
            if (LogicalSectorSize != other.LogicalSectorSize) return false;

            if (IsDiskImage)
            {
                return string.Equals(DevicePath, other.DevicePath, StringComparison.OrdinalIgnoreCase);
            }

            if (DiskNumber != other.DiskNumber) return false;
            if (!string.IsNullOrWhiteSpace(SerialNumber) && !string.IsNullOrWhiteSpace(other.SerialNumber))
            {
                if (!string.Equals(SerialNumber.Trim(), other.SerialNumber.Trim(), StringComparison.OrdinalIgnoreCase))
                    return false;
            }
            if (!string.IsNullOrWhiteSpace(Model) && !string.IsNullOrWhiteSpace(other.Model))
            {
                if (!string.Equals(Model.Trim(), other.Model.Trim(), StringComparison.OrdinalIgnoreCase))
                    return false;
            }

            return true;
        }
    }

    public sealed class SectorReadError
    {
        public long ByteOffset { get; init; }
        public int ByteLength { get; init; }
        public long StartLba { get; init; }
        public string RegionDescription { get; init; } = string.Empty;
        public string ErrorMessage { get; init; } = string.Empty;
        public int Win32ErrorCode { get; init; }
        public DateTime TimestampUtc { get; init; } = DateTime.UtcNow;
    }

    /// <summary>
    /// Strictly read-only block/sector source. Diagnostic components only ever receive this interface.
    /// </summary>
    public interface IReadOnlyBlockSource : IDisposable
    {
        StorageDeviceIdentity Identity { get; }
        long Length { get; }
        int LogicalSectorSize { get; }
        int PhysicalSectorSize { get; }
        IReadOnlyList<SectorReadError> ReadErrors { get; }

        Task<int> ReadAtAsync(
            long offset,
            Memory<byte> buffer,
            CancellationToken cancellationToken = default);
    }
}
