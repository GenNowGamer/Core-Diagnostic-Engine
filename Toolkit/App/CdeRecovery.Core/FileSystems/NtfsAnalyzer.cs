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
    public static class NtfsAnalyzer
    {
        public sealed class NtfsVbrFields
        {
            public bool IsValid { get; init; }
            public bool IsBitLocker { get; init; }
            public string OemId { get; init; } = string.Empty;
            public int BytesPerSector { get; init; }
            public int SectorsPerCluster { get; init; }
            public long TotalSectors { get; init; }
            public long MftCluster { get; init; }
            public long MftMirrorCluster { get; init; }
            public int FileRecordSizeBytes { get; init; }
            public ulong VolumeSerial { get; init; }
            public ushort Signature { get; init; }
            public string InvalidReason { get; init; } = string.Empty;
        }

        public static NtfsVbrFields ParseBootSector(ReadOnlySpan<byte> sector, long maxPartitionSectors = 0)
        {
            if (sector.Length < 512)
                return new NtfsVbrFields { IsValid = false, InvalidReason = "Sector buffer smaller than 512 bytes." };

            string oem = Encoding.ASCII.GetString(sector.Slice(3, 8));
            ushort sig = BinaryPrimitives.ReadUInt16LittleEndian(sector.Slice(510, 2));

            if (oem == "-FVE-FS-")
            {
                return new NtfsVbrFields
                {
                    IsValid = false,
                    IsBitLocker = true,
                    OemId = oem,
                    Signature = sig,
                    InvalidReason = "BitLocker encrypted volume (-FVE-FS-)."
                };
            }

            if (oem != "NTFS    ")
            {
                return new NtfsVbrFields
                {
                    IsValid = false,
                    OemId = oem,
                    Signature = sig,
                    InvalidReason = $"OEM ID is '{oem.Replace('\0', '.')}' instead of 'NTFS    '."
                };
            }

            if (sig != 0xAA55)
            {
                return new NtfsVbrFields
                {
                    IsValid = false,
                    OemId = oem,
                    Signature = sig,
                    InvalidReason = $"Boot sector signature is 0x{sig:X4} instead of 0xAA55."
                };
            }

            ushort bytesPerSector = BinaryPrimitives.ReadUInt16LittleEndian(sector.Slice(11, 2));
            byte spcCode = sector[13];
            int sectorsPerCluster = spcCode <= 128
                ? spcCode
                : (spcCode >= 240 ? (1 << (256 - spcCode)) : 0);

            if (bytesPerSector is not (512 or 1024 or 2048 or 4096) || sectorsPerCluster <= 0 || (sectorsPerCluster & (sectorsPerCluster - 1)) != 0)
            {
                return new NtfsVbrFields
                {
                    IsValid = false,
                    OemId = oem,
                    BytesPerSector = bytesPerSector,
                    SectorsPerCluster = sectorsPerCluster,
                    Signature = sig,
                    InvalidReason = $"Invalid BPB geometry (BytesPerSector={bytesPerSector}, SectorsPerCluster={sectorsPerCluster})."
                };
            }

            long totalSectors = (long)BinaryPrimitives.ReadUInt64LittleEndian(sector.Slice(40, 8));
            long mftCluster = (long)BinaryPrimitives.ReadUInt64LittleEndian(sector.Slice(48, 8));
            long mftMirrCluster = (long)BinaryPrimitives.ReadUInt64LittleEndian(sector.Slice(56, 8));
            sbyte clustersPerRecord = (sbyte)sector[64];
            ulong serial = BinaryPrimitives.ReadUInt64LittleEndian(sector.Slice(72, 8));

            int clusterSize = bytesPerSector * sectorsPerCluster;
            int recordSize = clustersPerRecord < 0
                ? (1 << (-clustersPerRecord))
                : clustersPerRecord * clusterSize;

            if (totalSectors <= 0 || mftCluster <= 0 || recordSize is < 512 or > 65536)
            {
                return new NtfsVbrFields
                {
                    IsValid = false,
                    OemId = oem,
                    BytesPerSector = bytesPerSector,
                    SectorsPerCluster = sectorsPerCluster,
                    TotalSectors = totalSectors,
                    MftCluster = mftCluster,
                    MftMirrorCluster = mftMirrCluster,
                    FileRecordSizeBytes = recordSize,
                    VolumeSerial = serial,
                    Signature = sig,
                    InvalidReason = $"Implausible NTFS metadata parameters (TotalSectors={totalSectors}, MftCluster={mftCluster}, RecordSize={recordSize})."
                };
            }

            long totalClusters = totalSectors / sectorsPerCluster;
            if (mftCluster >= totalClusters)
            {
                return new NtfsVbrFields
                {
                    IsValid = false,
                    OemId = oem,
                    BytesPerSector = bytesPerSector,
                    SectorsPerCluster = sectorsPerCluster,
                    TotalSectors = totalSectors,
                    MftCluster = mftCluster,
                    MftMirrorCluster = mftMirrCluster,
                    FileRecordSizeBytes = recordSize,
                    VolumeSerial = serial,
                    Signature = sig,
                    InvalidReason = $"$MFT cluster ({mftCluster}) exceeds volume cluster count ({totalClusters})."
                };
            }

            return new NtfsVbrFields
            {
                IsValid = true,
                OemId = oem,
                BytesPerSector = bytesPerSector,
                SectorsPerCluster = sectorsPerCluster,
                TotalSectors = totalSectors,
                MftCluster = mftCluster,
                MftMirrorCluster = mftMirrCluster,
                FileRecordSizeBytes = recordSize,
                VolumeSerial = serial,
                Signature = sig
            };
        }

        public static bool ValidateMftFileRecord(ReadOnlySpan<byte> record)
        {
            if (record.Length < 48) return false;
            // "FILE" = 0x454C4946
            uint magic = BinaryPrimitives.ReadUInt32LittleEndian(record.Slice(0, 4));
            if (magic != 0x454C4946u) return false;

            ushort usaOffset = BinaryPrimitives.ReadUInt16LittleEndian(record.Slice(4, 2));
            ushort usaCount = BinaryPrimitives.ReadUInt16LittleEndian(record.Slice(6, 2));
            uint bytesAllocated = BinaryPrimitives.ReadUInt32LittleEndian(record.Slice(28, 4));

            return usaOffset >= 40 && usaOffset < record.Length && usaCount >= 2 && bytesAllocated >= 512 && bytesAllocated <= 65536;
        }

        public static string TryExtractVolumeLabelFromMftRecord3(ReadOnlySpan<byte> record3)
        {
            if (!ValidateMftFileRecord(record3)) return string.Empty;

            ushort attrOffset = BinaryPrimitives.ReadUInt16LittleEndian(record3.Slice(20, 2));
            int pos = attrOffset;
            while (pos > 0 && pos + 24 <= record3.Length)
            {
                uint attrType = BinaryPrimitives.ReadUInt32LittleEndian(record3.Slice(pos, 4));
                if (attrType == 0xFFFFFFFFu || attrType == 0)
                    break;

                uint attrLen = BinaryPrimitives.ReadUInt32LittleEndian(record3.Slice(pos + 4, 4));
                if (attrLen < 24 || pos + (int)attrLen > record3.Length)
                    break;

                byte nonResident = record3[pos + 8];
                // 0x60 is $VOLUME_NAME
                if (attrType == 0x60u && nonResident == 0)
                {
                    uint valLen = BinaryPrimitives.ReadUInt32LittleEndian(record3.Slice(pos + 16, 4));
                    ushort valOff = BinaryPrimitives.ReadUInt16LittleEndian(record3.Slice(pos + 20, 2));
                    if (valLen > 0 && pos + valOff + (int)valLen <= record3.Length)
                    {
                        return Encoding.Unicode.GetString(record3.Slice(pos + valOff, (int)valLen)).TrimEnd('\0');
                    }
                }

                pos += (int)attrLen;
            }

            return string.Empty;
        }

        public static async Task<(FileSystemAnalysisResult Result, List<StorageDiagnosticFinding> Findings)> AnalyzePartitionAsync(
            IReadOnlyBlockSource source,
            int partitionIndex,
            string partitionName,
            long partitionStartOffset,
            long partitionSizeBytes,
            CancellationToken cancellationToken = default)
        {
            var findings = new List<StorageDiagnosticFinding>();
            int sectorSize = Math.Max(512, source.LogicalSectorSize);
            long startLba = partitionStartOffset / sectorSize;
            long endLba = (partitionStartOffset + partitionSizeBytes) / sectorSize - 1;

            byte[] primarySector = new byte[sectorSize];
            byte[] backupSector = new byte[sectorSize];
            long backupVbrOffset = partitionStartOffset + partitionSizeBytes - sectorSize;

            bool primaryReadOk = false;
            bool backupReadOk = false;

            try
            {
                int r1 = await source.ReadAtAsync(partitionStartOffset, primarySector, cancellationToken).ConfigureAwait(false);
                primaryReadOk = r1 >= 512;
            }
            catch
            {
                primaryReadOk = false;
            }

            var primaryVbr = primaryReadOk ? ParseBootSector(primarySector) : new NtfsVbrFields { IsValid = false, InvalidReason = "Primary VBR read failed." };

            // Only seek to the end of the partition for the Backup VBR on disk images or when the Primary VBR is damaged/unreadable.
            // This avoids end-of-disk UASPStor bridge timeouts on healthy multi-TB USB drives.
            if (!source.Identity.IsDiskImage && primaryVbr.IsValid)
            {
                Array.Copy(primarySector, backupSector, sectorSize);
                backupReadOk = true;
            }
            else if (backupVbrOffset > partitionStartOffset && backupVbrOffset + sectorSize <= source.Length)
            {
                try
                {
                    int r2 = await source.ReadAtAsync(backupVbrOffset, backupSector, cancellationToken).ConfigureAwait(false);
                    backupReadOk = r2 >= 512;
                }
                catch
                {
                    backupReadOk = false;
                }
            }

            var backupVbr = backupReadOk ? ParseBootSector(backupSector) : new NtfsVbrFields { IsValid = false, InvalidReason = "Backup VBR read failed." };

            if (primaryVbr.IsBitLocker || backupVbr.IsBitLocker)
            {
                findings.Add(new StorageDiagnosticFinding
                {
                    FindingId = $"fs.p{partitionIndex}.bitlocker",
                    Category = "FileSystem",
                    Title = $"Partition {partitionIndex} ({partitionName}) is BitLocker-encrypted (-FVE-FS-)",
                    Status = "Warn",
                    Severity = "Medium",
                    Confidence = 100,
                    Classification = RecoveryClassification.SafetyBlock,
                    EvidenceSummary = "BitLocker FVE header signature detected. Raw NTFS boot-sector modifications must not be applied to encrypted volumes.",
                    ByteOffset = partitionStartOffset,
                    ByteLength = sectorSize,
                    Recommendation = "Unlock the volume with its BitLocker recovery key (repair-bde) before attempting file system diagnostics."
                });

                return (new FileSystemAnalysisResult
                {
                    PartitionIndex = partitionIndex,
                    PartitionName = partitionName,
                    PartitionStartOffset = partitionStartOffset,
                    PartitionSizeBytes = partitionSizeBytes,
                    StartLba = startLba,
                    EndLba = endLba,
                    DetectedFileSystem = "BitLocker",
                    IsEncryptedBitLocker = true,
                    PrimaryBootSectorValid = false,
                    BackupBootSectorValid = false,
                    BackupBootSectorOffset = backupVbrOffset,
                    HealthStatus = "Encrypted",
                    DiagnosticSummary = "BitLocker encrypted volume (-FVE-FS-). Automatic boot-sector writes are disabled for safety.",
                    RawPrimaryBootSector = primarySector,
                    RawBackupBootSector = backupSector
                }, findings);
            }

            var activeVbr = primaryVbr.IsValid ? primaryVbr : (backupVbr.IsValid ? backupVbr : null);
            if (activeVbr == null)
            {
                return (new FileSystemAnalysisResult
                {
                    PartitionIndex = partitionIndex,
                    PartitionName = partitionName,
                    PartitionStartOffset = partitionStartOffset,
                    PartitionSizeBytes = partitionSizeBytes,
                    StartLba = startLba,
                    EndLba = endLba,
                    DetectedFileSystem = "RAW / Unknown",
                    PrimaryBootSectorValid = false,
                    BackupBootSectorValid = false,
                    BackupBootSectorOffset = backupVbrOffset,
                    HealthStatus = "Damaged",
                    DiagnosticSummary = $"Neither Primary VBR ({primaryVbr.InvalidReason}) nor Backup VBR ({backupVbr.InvalidReason}) is a valid NTFS boot sector.",
                    RawPrimaryBootSector = primarySector,
                    RawBackupBootSector = backupSector
                }, findings);
            }

            long clusterBytes = (long)activeVbr.BytesPerSector * activeVbr.SectorsPerCluster;
            long mftOffset = partitionStartOffset + (activeVbr.MftCluster * clusterBytes);
            long mftMirrorOffset = partitionStartOffset + (activeVbr.MftMirrorCluster * clusterBytes);
            int recordSize = Math.Max(1024, activeVbr.FileRecordSizeBytes);

            bool mft0Valid = false;
            bool mftMirr0Valid = false;
            string volumeLabel = string.Empty;

            if (mftOffset > partitionStartOffset && mftOffset + recordSize <= source.Length)
            {
                byte[] mftRecord0 = new byte[recordSize];
                try
                {
                    int readMft = await source.ReadAtAsync(mftOffset, mftRecord0, cancellationToken).ConfigureAwait(false);
                    if (readMft == recordSize)
                        mft0Valid = ValidateMftFileRecord(mftRecord0);

                    long record3Offset = mftOffset + (3L * recordSize);
                    if (mft0Valid && record3Offset + recordSize <= source.Length)
                    {
                        byte[] mftRecord3 = new byte[recordSize];
                        int r3 = await source.ReadAtAsync(record3Offset, mftRecord3, cancellationToken).ConfigureAwait(false);
                        if (r3 == recordSize)
                            volumeLabel = TryExtractVolumeLabelFromMftRecord3(mftRecord3);
                    }
                }
                catch
                {
                    mft0Valid = false;
                }
            }

            if (mftMirrorOffset > partitionStartOffset && mftMirrorOffset + recordSize <= source.Length)
            {
                byte[] mirrRecord0 = new byte[recordSize];
                try
                {
                    int readMirr = await source.ReadAtAsync(mftMirrorOffset, mirrRecord0, cancellationToken).ConfigureAwait(false);
                    if (readMirr == recordSize)
                        mftMirr0Valid = ValidateMftFileRecord(mirrRecord0);
                }
                catch
                {
                    mftMirr0Valid = false;
                }
            }

            string healthStatus;
            string diagSummary;

            if (primaryVbr.IsValid && backupVbr.IsValid && mft0Valid)
            {
                healthStatus = "Healthy";
                diagSummary = $"NTFS volume verified: Primary & Backup VBRs valid, $MFT (cluster {activeVbr.MftCluster}) and $MFTMirr (cluster {activeVbr.MftMirrorCluster}) intact.";
                findings.Add(new StorageDiagnosticFinding
                {
                    FindingId = $"fs.p{partitionIndex}.ntfs_healthy",
                    Category = "FileSystem",
                    Title = $"Partition {partitionIndex} ({partitionName}) NTFS metadata verified",
                    Status = "Pass",
                    Severity = "Info",
                    Confidence = 100,
                    Classification = RecoveryClassification.VerifiedIntact,
                    EvidenceSummary = diagSummary,
                    ByteOffset = partitionStartOffset,
                    ByteLength = sectorSize
                });
            }
            else if (!primaryVbr.IsValid && backupVbr.IsValid && (mft0Valid || mftMirr0Valid))
            {
                healthStatus = "Degraded (Repairable Boot Sector)";
                diagSummary = $"Primary NTFS Boot Sector at offset 0x{partitionStartOffset:X} is damaged ({primaryVbr.InvalidReason}), causing Windows to report RAW. Verified Backup NTFS Boot Sector at 0x{backupVbrOffset:X} and $MFT at 0x{mftOffset:X} are intact!";
                findings.Add(new StorageDiagnosticFinding
                {
                    FindingId = $"fs.p{partitionIndex}.ntfs_primary_vbr_damaged",
                    Category = "FileSystem",
                    Title = $"Partition {partitionIndex} ({partitionName}) Primary NTFS Boot Sector damaged; Backup VBR & $MFT intact",
                    Status = "Fail",
                    Severity = "Critical",
                    Confidence = 99,
                    Classification = RecoveryClassification.ConfirmedFault,
                    EvidenceSummary = diagSummary,
                    ByteOffset = partitionStartOffset,
                    ByteLength = sectorSize,
                    Recommendation = "Restore the Primary NTFS Boot Sector from the verified Backup NTFS Boot Sector."
                });
            }
            else if (primaryVbr.IsValid && !backupVbr.IsValid && mft0Valid)
            {
                healthStatus = "Degraded (Backup VBR Damaged)";
                diagSummary = $"Primary NTFS VBR and $MFT are valid, but Backup NTFS VBR at end of partition (0x{backupVbrOffset:X}) is damaged ({backupVbr.InvalidReason}).";
                findings.Add(new StorageDiagnosticFinding
                {
                    FindingId = $"fs.p{partitionIndex}.ntfs_backup_vbr_damaged",
                    Category = "FileSystem",
                    Title = $"Partition {partitionIndex} ({partitionName}) Backup NTFS Boot Sector damaged",
                    Status = "Warn",
                    Severity = "Medium",
                    Confidence = 95,
                    Classification = RecoveryClassification.ConfirmedFault,
                    EvidenceSummary = diagSummary,
                    ByteOffset = backupVbrOffset,
                    ByteLength = sectorSize,
                    Recommendation = "Restore Backup NTFS Boot Sector from the verified Primary Boot Sector."
                });
            }
            else if (!mft0Valid && mftMirr0Valid)
            {
                healthStatus = "Damaged ($MFT Record 0 Corrupt, $MFTMirr Intact)";
                diagSummary = $"NTFS VBR is readable, but primary $MFT Record 0 at 0x{mftOffset:X} failed FILE validation while $MFTMirr at 0x{mftMirrorOffset:X} is intact.";
                findings.Add(new StorageDiagnosticFinding
                {
                    FindingId = $"fs.p{partitionIndex}.ntfs_mft_damaged_mirror_valid",
                    Category = "FileSystem",
                    Title = $"Partition {partitionIndex} ({partitionName}) $MFT header damaged; $MFTMirr intact",
                    Status = "Fail",
                    Severity = "Critical",
                    Confidence = 96,
                    Classification = RecoveryClassification.ConfirmedFault,
                    EvidenceSummary = diagSummary,
                    ByteOffset = mftOffset,
                    ByteLength = recordSize,
                    Recommendation = "Extract files or restore $MFT records 0-3 from $MFTMirr on a cloned image."
                });
            }
            else
            {
                healthStatus = "Severely Damaged";
                diagSummary = $"NTFS VBR found, but both $MFT (0x{mftOffset:X}) and $MFTMirr (0x{mftMirrorOffset:X}) failed FILE header validation.";
                findings.Add(new StorageDiagnosticFinding
                {
                    FindingId = $"fs.p{partitionIndex}.ntfs_mft_both_damaged",
                    Category = "FileSystem",
                    Title = $"Partition {partitionIndex} ({partitionName}) NTFS $MFT and $MFTMirr are both unreadable",
                    Status = "Fail",
                    Severity = "Critical",
                    Confidence = 98,
                    Classification = RecoveryClassification.ConfirmedFault,
                    EvidenceSummary = diagSummary,
                    ByteOffset = mftOffset,
                    ByteLength = recordSize,
                    Recommendation = "Do not perform in-place metadata repairs; use file extraction / carving to a separate recovery drive."
                });
            }

            return (new FileSystemAnalysisResult
            {
                PartitionIndex = partitionIndex,
                PartitionName = partitionName,
                PartitionStartOffset = partitionStartOffset,
                PartitionSizeBytes = partitionSizeBytes,
                StartLba = startLba,
                EndLba = endLba,
                DetectedFileSystem = "NTFS",
                PrimaryBootSectorValid = primaryVbr.IsValid,
                BackupBootSectorValid = backupVbr.IsValid,
                BackupBootSectorOffset = backupVbrOffset,
                BytesPerSector = activeVbr.BytesPerSector,
                SectorsPerCluster = activeVbr.SectorsPerCluster,
                TotalSectors = activeVbr.TotalSectors,
                VolumeSerialOrUuid = $"{activeVbr.VolumeSerial:X16}",
                VolumeLabel = volumeLabel,
                NtfsMftCluster = activeVbr.MftCluster,
                NtfsMftMirrorCluster = activeVbr.MftMirrorCluster,
                NtfsMftByteOffset = mftOffset,
                NtfsMftMirrorByteOffset = mftMirrorOffset,
                NtfsMftRecord0Valid = mft0Valid,
                NtfsMftMirrorRecord0Valid = mftMirr0Valid,
                NtfsFileRecordSizeBytes = recordSize,
                MetadataChecksumValid = primaryVbr.IsValid && mft0Valid,
                HealthStatus = healthStatus,
                DiagnosticSummary = diagSummary,
                RawPrimaryBootSector = primarySector,
                RawBackupBootSector = backupSector
            }, findings);
        }
    }
}
