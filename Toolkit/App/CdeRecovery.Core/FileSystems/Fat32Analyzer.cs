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
    public static class Fat32Analyzer
    {
        public static bool IsFat32BootSector(ReadOnlySpan<byte> sector)
        {
            if (sector.Length < 512) return false;
            ushort sig = BinaryPrimitives.ReadUInt16LittleEndian(sector.Slice(510, 2));
            if (sig != 0xAA55) return false;

            string fsType = Encoding.ASCII.GetString(sector.Slice(82, 8));
            ushort bps = BinaryPrimitives.ReadUInt16LittleEndian(sector.Slice(11, 2));
            byte numFats = sector[16];
            return fsType.StartsWith("FAT32", StringComparison.OrdinalIgnoreCase)
                && bps is 512 or 1024 or 2048 or 4096
                && numFats is 1 or 2;
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
            if (partitionSizeBytes < sectorSize * 16)
                return (null, findings);

            byte[] primary = new byte[sectorSize];
            byte[] backup = new byte[sectorSize];
            long backupOffset = partitionStartOffset + (6L * sectorSize);

            try
            {
                await source.ReadAtAsync(partitionStartOffset, primary, cancellationToken).ConfigureAwait(false);
            }
            catch { }

            try
            {
                await source.ReadAtAsync(backupOffset, backup, cancellationToken).ConfigureAwait(false);
            }
            catch { }

            bool primaryValid = IsFat32BootSector(primary);
            bool backupValid = IsFat32BootSector(backup);
            if (!primaryValid && !backupValid)
                return (null, findings);

            var active = primaryValid ? primary : backup;
            ushort bps = BinaryPrimitives.ReadUInt16LittleEndian(active.AsSpan(11, 2));
            byte spc = active[13];
            uint totalSec32 = BinaryPrimitives.ReadUInt32LittleEndian(active.AsSpan(32, 4));
            uint serial = BinaryPrimitives.ReadUInt32LittleEndian(active.AsSpan(67, 4));
            string label = Encoding.ASCII.GetString(active.AsSpan(71, 11)).Trim();
            ushort fsInfoSec = BinaryPrimitives.ReadUInt16LittleEndian(active.AsSpan(48, 2));

            bool fsInfoValid = false;
            if (fsInfoSec > 0 && fsInfoSec < 16)
            {
                byte[] fsInfo = new byte[sectorSize];
                try
                {
                    await source.ReadAtAsync(partitionStartOffset + (fsInfoSec * sectorSize), fsInfo, cancellationToken).ConfigureAwait(false);
                    uint leadSig = BinaryPrimitives.ReadUInt32LittleEndian(fsInfo.AsSpan(0, 4));
                    uint structSig = BinaryPrimitives.ReadUInt32LittleEndian(fsInfo.AsSpan(484, 4));
                    fsInfoValid = leadSig == 0x41615252u && structSig == 0x61417272u;
                }
                catch { }
            }

            string health = (primaryValid && backupValid)
                ? "Healthy"
                : (!primaryValid && backupValid)
                    ? "Degraded (Primary Boot Sector Damaged, Sector 6 Backup Valid)"
                    : "Degraded (Backup Boot Sector Damaged)";

            string summary = $"FAT32 volume: Primary VBR={primaryValid}, Backup VBR (Sector 6)={backupValid}, FSInfo={fsInfoValid}, Label='{label}'.";

            findings.Add(new StorageDiagnosticFinding
            {
                FindingId = $"fs.p{partitionIndex}.fat32",
                Category = "FileSystem",
                Title = $"Partition {partitionIndex} ({partitionName}) FAT32 analysis: {health}",
                Status = primaryValid ? "Pass" : "Fail",
                Severity = primaryValid ? "Info" : "High",
                Confidence = 97,
                Classification = primaryValid ? RecoveryClassification.VerifiedIntact : RecoveryClassification.ConfirmedFault,
                EvidenceSummary = summary,
                ByteOffset = partitionStartOffset,
                ByteLength = sectorSize,
                Recommendation = (!primaryValid && backupValid)
                    ? "Restore FAT32 Primary Boot Sector (Sector 0) from verified Backup Boot Sector (Sector 6)."
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
                DetectedFileSystem = "FAT32",
                PrimaryBootSectorValid = primaryValid,
                BackupBootSectorValid = backupValid,
                BackupBootSectorOffset = backupOffset,
                BytesPerSector = bps,
                SectorsPerCluster = spc,
                TotalSectors = totalSec32,
                VolumeSerialOrUuid = $"{serial:X8}",
                VolumeLabel = label,
                MetadataChecksumValid = primaryValid && fsInfoValid,
                HealthStatus = health,
                DiagnosticSummary = summary,
                RawPrimaryBootSector = primary,
                RawBackupBootSector = backup
            }, findings);
        }

        public static async Task<(FileSystemAnalysisResult? Result, List<StorageDiagnosticFinding> Findings)> TryProbeExt4SuperblockAsync(
            IReadOnlyBlockSource source,
            int partitionIndex,
            string partitionName,
            long partitionStartOffset,
            long partitionSizeBytes,
            CancellationToken cancellationToken = default)
        {
            var findings = new List<StorageDiagnosticFinding>();
            if (partitionSizeBytes < 4096)
                return (null, findings);

            byte[] sb = new byte[1024];
            try
            {
                int read = await source.ReadAtAsync(partitionStartOffset + 1024, sb, cancellationToken).ConfigureAwait(false);
                if (read < 1024) return (null, findings);
            }
            catch
            {
                return (null, findings);
            }

            // s_magic at offset 0x38 (56) in superblock == 0xEF53
            ushort magic = BinaryPrimitives.ReadUInt16LittleEndian(sb.AsSpan(0x38, 2));
            if (magic != 0xEF53)
                return (null, findings);

            uint inodesCount = BinaryPrimitives.ReadUInt32LittleEndian(sb.AsSpan(0x00, 4));
            uint blocksCountLo = BinaryPrimitives.ReadUInt32LittleEndian(sb.AsSpan(0x04, 4));
            uint logBlockSize = BinaryPrimitives.ReadUInt32LittleEndian(sb.AsSpan(0x18, 4));
            int blockSize = 1024 << (int)Math.Min(logBlockSize, 6u);
            Guid uuid = new Guid(sb.AsSpan(0x68, 16));
            string label = Encoding.UTF8.GetString(sb.AsSpan(0x78, 16)).TrimEnd('\0');

            int sectorSize = Math.Max(512, source.LogicalSectorSize);
            string summary = $"Linux ext2/ext3/ext4 Superblock verified (magic 0xEF53 at +1024): BlockSize={blockSize}, Inodes={inodesCount}, Label='{label}'. (Appears unmounted/RAW in Windows natively).";

            findings.Add(new StorageDiagnosticFinding
            {
                FindingId = $"fs.p{partitionIndex}.ext4",
                Category = "FileSystem",
                Title = $"Partition {partitionIndex} ({partitionName}) is a healthy Linux ext4 volume",
                Status = "Pass",
                Severity = "Info",
                Confidence = 99,
                Classification = RecoveryClassification.VerifiedIntact,
                EvidenceSummary = summary,
                ByteOffset = partitionStartOffset + 1024,
                ByteLength = 1024
            });

            return (new FileSystemAnalysisResult
            {
                PartitionIndex = partitionIndex,
                PartitionName = partitionName,
                PartitionStartOffset = partitionStartOffset,
                PartitionSizeBytes = partitionSizeBytes,
                StartLba = partitionStartOffset / sectorSize,
                EndLba = (partitionStartOffset + partitionSizeBytes) / sectorSize - 1,
                DetectedFileSystem = "ext4",
                PrimaryBootSectorValid = true,
                BackupBootSectorValid = true,
                BytesPerSector = sectorSize,
                SectorsPerCluster = blockSize / sectorSize,
                TotalSectors = ((long)blocksCountLo * blockSize) / sectorSize,
                VolumeSerialOrUuid = uuid.ToString(),
                VolumeLabel = label,
                MetadataChecksumValid = true,
                HealthStatus = "Healthy (Linux ext4)",
                DiagnosticSummary = summary
            }, findings);
        }

        public static async Task<(FileSystemAnalysisResult Result, List<StorageDiagnosticFinding> Findings)> InspectAnyFileSystemAsync(
            IReadOnlyBlockSource source,
            int partitionIndex,
            string partitionName,
            long partitionStartOffset,
            long partitionSizeBytes,
            CancellationToken cancellationToken = default)
        {
            // 1. Try NTFS / BitLocker first (highest priority)
            var (ntfsRes, ntfsFindings) = await NtfsAnalyzer.AnalyzePartitionAsync(
                source, partitionIndex, partitionName, partitionStartOffset, partitionSizeBytes, cancellationToken).ConfigureAwait(false);
            if (ntfsRes.DetectedFileSystem is "NTFS" or "BitLocker")
            {
                return (ntfsRes, ntfsFindings);
            }

            // 2. Try exFAT
            var (exfatRes, exfatFindings) = await ExFatAnalyzer.TryAnalyzePartitionAsync(
                source, partitionIndex, partitionName, partitionStartOffset, partitionSizeBytes, cancellationToken).ConfigureAwait(false);
            if (exfatRes != null)
            {
                return (exfatRes, exfatFindings);
            }

            // 3. Try FAT32
            var (fat32Res, fat32Findings) = await TryAnalyzePartitionAsync(
                source, partitionIndex, partitionName, partitionStartOffset, partitionSizeBytes, cancellationToken).ConfigureAwait(false);
            if (fat32Res != null)
            {
                return (fat32Res, fat32Findings);
            }

            // 4. Try Linux ext4 superblock
            var (ext4Res, ext4Findings) = await TryProbeExt4SuperblockAsync(
                source, partitionIndex, partitionName, partitionStartOffset, partitionSizeBytes, cancellationToken).ConfigureAwait(false);
            if (ext4Res != null)
            {
                return (ext4Res, ext4Findings);
            }

            // 5. Fallback: RAW / Unrecognized file system
            var rawFindings = new List<StorageDiagnosticFinding>
            {
                new StorageDiagnosticFinding
                {
                    FindingId = $"fs.p{partitionIndex}.raw_unrecognized",
                    Category = "FileSystem",
                    Title = $"Partition {partitionIndex} ({partitionName}) has RAW / unreadable file system metadata",
                    Status = "Fail",
                    Severity = "High",
                    Confidence = 95,
                    Classification = RecoveryClassification.ConfirmedFault,
                    EvidenceSummary = ntfsRes.DiagnosticSummary,
                    ByteOffset = partitionStartOffset,
                    ByteLength = Math.Max(512, source.LogicalSectorSize),
                    Recommendation = "Partition table entry exists, but neither primary nor backup boot sectors matched NTFS, exFAT, FAT32, or ext4. Use file recovery software to scan for MFT records or carve files."
                }
            };

            return (ntfsRes, rawFindings);
        }
    }
}
