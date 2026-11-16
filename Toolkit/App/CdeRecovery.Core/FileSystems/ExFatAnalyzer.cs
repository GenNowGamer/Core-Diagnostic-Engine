using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using CdeRecovery.Core.Devices;
using CdeRecovery.Core.Models;

namespace CdeRecovery.Core.FileSystems
{
    public static class ExFatAnalyzer
    {
        public static uint ComputeBootRegionChecksum(ReadOnlySpan<byte> elevenSectors)
        {
            uint checksum = 0;
            for (int index = 0; index < elevenSectors.Length; index++)
            {
                // Skip VolumeFlags (offset 106, 107) and PercentInUse (offset 112)
                if (index == 106 || index == 107 || index == 112)
                    continue;

                checksum = ((checksum & 1) != 0 ? 0x80000000u : 0u) + (checksum >> 1) + elevenSectors[index];
            }
            return checksum;
        }

        public static bool IsExFatBootSector(ReadOnlySpan<byte> sector)
        {
            if (sector.Length < 512) return false;
            string oem = Encoding.ASCII.GetString(sector.Slice(3, 8));
            ushort sig = BinaryPrimitives.ReadUInt16LittleEndian(sector.Slice(510, 2));
            return oem == "EXFAT   " && sig == 0xAA55;
        }

        public static async Task<(FileSystemAnalysisResult? Result, List<StorageDiagnosticFinding> Findings)> TryAnalyzePartitionAsync(
            IReadOnlyBlockSource source,
            int partitionIndex,
            string partitionName,
            long partitionStartOffset,
            long partitionSizeBytes,
            CancellationToken cancellationToken = default)
        {
            var findings = new List<StorageDiagnosticFinding>();
            int sectorSize = Math.Max(512, source.LogicalSectorSize);
            int bootRegionBytes = 12 * sectorSize;

            if (partitionSizeBytes < bootRegionBytes * 2)
                return (null, findings);

            byte[] primaryRegion = new byte[bootRegionBytes];
            byte[] backupRegion = new byte[bootRegionBytes];

            bool primaryRead = false;
            bool backupRead = false;

            try
            {
                primaryRead = await source.ReadAtAsync(partitionStartOffset, primaryRegion, cancellationToken).ConfigureAwait(false) == bootRegionBytes;
            }
            catch { }

            try
            {
                backupRead = await source.ReadAtAsync(partitionStartOffset + bootRegionBytes, backupRegion, cancellationToken).ConfigureAwait(false) == bootRegionBytes;
            }
            catch { }

            bool primaryIsExFat = primaryRead && IsExFatBootSector(primaryRegion.AsSpan(0, sectorSize));
            bool backupIsExFat = backupRead && IsExFatBootSector(backupRegion.AsSpan(0, sectorSize));

            if (!primaryIsExFat && !backupIsExFat)
                return (null, findings);

            bool primaryCrcValid = false;
            bool backupCrcValid = false;

            if (primaryIsExFat)
            {
                uint computed = ComputeBootRegionChecksum(primaryRegion.AsSpan(0, 11 * sectorSize));
                uint stored = BinaryPrimitives.ReadUInt32LittleEndian(primaryRegion.AsSpan(11 * sectorSize, 4));
                primaryCrcValid = computed == stored;
            }

            if (backupIsExFat)
            {
                uint computed = ComputeBootRegionChecksum(backupRegion.AsSpan(0, 11 * sectorSize));
                uint stored = BinaryPrimitives.ReadUInt32LittleEndian(backupRegion.AsSpan(11 * sectorSize, 4));
                backupCrcValid = computed == stored;
            }

            var active = primaryIsExFat && primaryCrcValid ? primaryRegion : (backupIsExFat ? backupRegion : primaryRegion);
            long volLen = (long)BinaryPrimitives.ReadUInt64LittleEndian(active.AsSpan(72, 8));
            uint serial = BinaryPrimitives.ReadUInt32LittleEndian(active.AsSpan(100, 4));
            byte bpsShift = active[108];
            byte spcShift = active[109];
            int bps = bpsShift is >= 9 and <= 12 ? (1 << bpsShift) : sectorSize;
            int spc = spcShift <= 25 ? (1 << spcShift) : 1;

            string health = (primaryCrcValid && backupCrcValid)
                ? "Healthy"
                : (!primaryCrcValid && backupCrcValid)
                    ? "Degraded (Primary Boot Region Damaged, Backup Valid)"
                    : (primaryCrcValid && !backupCrcValid)
                        ? "Degraded (Backup Boot Region Damaged)"
                        : "Damaged";

            string summary = $"exFAT volume: Primary Boot Region Valid={primaryCrcValid}, Backup Boot Region (Sectors 12-23) Valid={backupCrcValid}, Serial={serial:X8}.";

            findings.Add(new StorageDiagnosticFinding
            {
                FindingId = $"fs.p{partitionIndex}.exfat",
                Category = "FileSystem",
                Title = $"Partition {partitionIndex} ({partitionName}) exFAT analysis: {health}",
                Status = primaryCrcValid ? "Pass" : (backupCrcValid ? "Fail" : "Fail"),
                Severity = primaryCrcValid ? "Info" : "High",
                Confidence = 98,
                Classification = primaryCrcValid ? RecoveryClassification.VerifiedIntact : RecoveryClassification.ConfirmedFault,
                EvidenceSummary = summary,
                ByteOffset = partitionStartOffset,
                ByteLength = bootRegionBytes,
                Recommendation = (!primaryCrcValid && backupCrcValid)
                    ? "Restore Primary exFAT Boot Region (Sectors 0-11) from verified Backup Boot Region (Sectors 12-23)."
                    : string.Empty
            });

            return (new FileSystemAnalysisResult
            {
                PartitionIndex = partitionIndex,
                PartitionName = partitionName,
                PartitionStartOffset = partitionStartOffset,
                PartitionSizeBytes = partitionSizeBytes,
                StartLba = partitionStartOffset / sectorSize,
                EndLba = (partitionStartOffset + partitionSizeBytes) / sectorSize - 1,
                DetectedFileSystem = "exFAT",
                PrimaryBootSectorValid = primaryCrcValid,
                BackupBootSectorValid = backupCrcValid,
                BackupBootSectorOffset = partitionStartOffset + bootRegionBytes,
                BytesPerSector = bps,
                SectorsPerCluster = spc,
                TotalSectors = volLen,
                VolumeSerialOrUuid = $"{serial:X8}",
                MetadataChecksumValid = primaryCrcValid,
                HealthStatus = health,
                DiagnosticSummary = summary,
                RawPrimaryBootSector = primaryRegion.AsSpan(0, sectorSize).ToArray(),
                RawBackupBootSector = backupRegion.AsSpan(0, sectorSize).ToArray()
            }, findings);
        }
    }
}
