using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using CdeRecovery.Core.Models;
using ToolkitGUI.Models;
using ToolkitGUI.ViewModels;

namespace ToolkitGUI.Services
{
    public static class DiskLayoutService
    {
        private static string DiskLayoutModulePath =>
            Path.Combine(ToolkitPaths.GetScriptsRoot(), "Core", "DiskLayout.psm1");

        public static CdePhysicalDiskModel BuildMapModelFromAssessment(StorageRecoveryAssessment assessment)
        {
            ArgumentNullException.ThrowIfNull(assessment);
            var disk = new CdePhysicalDiskModel
            {
                DiskNumber = assessment.Device.DiskNumber >= 0 ? assessment.Device.DiskNumber : 0,
                FriendlyName = assessment.Device.FriendlyName,
                SerialNumber = assessment.Device.SerialNumber,
                Size = assessment.Device.CapacityBytes,
                PartitionStyle = assessment.PartitionTableBadge,
                IsBoot = assessment.Device.IsBootDisk,
                IsSystem = assessment.Device.IsSystemDisk,
                IsRemovable = assessment.Device.IsRemovable,
                BusType = assessment.Device.BusType,
                RawSectorIntegrityStatus = assessment.OverallVerdict,
                PrimaryGptValid = assessment.Gpt.IsGptCandidate ? assessment.Gpt.Primary.IsStructurallyValid : null,
                BackupGptValid = assessment.Gpt.IsGptCandidate ? assessment.Gpt.Backup.IsStructurallyValid : null
            };

            int idx = 1;
            foreach (var cand in assessment.DiscoveredPartitions.OrderBy(c => c.StartByteOffset))
            {
                var fsMatch = assessment.FileSystems.FirstOrDefault(f => f.PartitionStartOffset == cand.StartByteOffset);
                string typeText = fsMatch != null
                    ? $"{fsMatch.DetectedFileSystem} ({fsMatch.HealthStatus})"
                    : $"{cand.FileSystemType} ({cand.Source})";

                if (!cand.InActivePartitionTable)
                    typeText = $"[LOST] {typeText}";

                disk.Partitions.Add(new CdePartitionModel
                {
                    PartitionNumber = idx,
                    DriveLetter = string.Empty,
                    DriveRoot = $"0x{cand.StartByteOffset:X}",
                    Size = cand.SizeBytes,
                    Type = typeText,
                    IsSystem = cand.FileSystemType.Contains("EFI", StringComparison.OrdinalIgnoreCase),
                    IsBoot = cand.InActivePartitionTable,
                    HasWindows = fsMatch?.DetectedFileSystem == "NTFS" && fsMatch.PrimaryBootSectorValid && fsMatch.NtfsMftRecord0Valid
                });
                idx++;
            }

            return disk;
        }

        public static async Task<CdeDiskLayoutDocument?> LoadLayoutAsync(CancellationToken cancellationToken = default)
        {
            var modulePath = DiskLayoutModulePath;
            if (!File.Exists(modulePath))
                return null;

            var command = $"Import-Module '{modulePath.Replace("'", "''")}' -Force; Export-CdeDiskLayoutJson -Compress";
            var (json, error) = await PowerShellService.QueryAsync(command);
            if (string.IsNullOrWhiteSpace(json))
            {
                if (!string.IsNullOrWhiteSpace(error))
                    throw new InvalidOperationException(error.Trim());
                return null;
            }

            try
            {
                return JsonSerializer.Deserialize<CdeDiskLayoutDocument>(json, new JsonSerializerOptions
                {
                    PropertyNameCaseInsensitive = true
                });
            }
            catch (JsonException ex)
            {
                throw new InvalidOperationException($"Failed to parse disk layout JSON: {ex.Message}", ex);
            }
        }
    }
}
