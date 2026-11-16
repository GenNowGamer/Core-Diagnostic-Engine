using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using CdeRecovery.Core.Devices;
using CdeRecovery.Core.Models;

namespace CdeRecovery.Core.Partitioning
{
    public static class MbrAnalyzer
    {
        public static async Task<(MbrAnalysisResult Result, List<StorageDiagnosticFinding> Findings)> AnalyzeAsync(
            IReadOnlyBlockSource source,
            CancellationToken cancellationToken = default)
        {
            var findings = new List<StorageDiagnosticFinding>();
            int sectorSize = Math.Max(512, source.LogicalSectorSize);
            byte[] sector0 = new byte[sectorSize];

            int bytesRead;
            try
            {
                bytesRead = await source.ReadAtAsync(0, sector0, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                findings.Add(new StorageDiagnosticFinding
                {
                    FindingId = "mbr.read_error",
                    Category = "MBR",
                    Title = "Failed to read Sector 0 (MBR)",
                    Status = "Fail",
                    Severity = "Critical",
                    Confidence = 100,
                    Classification = RecoveryClassification.ConfirmedFault,
                    EvidenceSummary = $"Hardware or I/O error reading LBA 0: {ex.Message}",
                    ByteOffset = 0,
                    ByteLength = sectorSize,
                    Recommendation = "Check USB cable/enclosure or S.M.A.R.T. health before attempting any recovery."
                });

                return (new MbrAnalysisResult { SectorReadSucceeded = false }, findings);
            }

            if (bytesRead < 512)
            {
                findings.Add(new StorageDiagnosticFinding
                {
                    FindingId = "mbr.short_read",
                    Category = "MBR",
                    Title = "Incomplete Sector 0 read",
                    Status = "Fail",
                    Severity = "High",
                    Confidence = 100,
                    Classification = RecoveryClassification.ConfirmedFault,
                    EvidenceSummary = $"Expected at least 512 bytes at LBA 0, read {bytesRead} bytes.",
                    ByteOffset = 0,
                    ByteLength = bytesRead
                });
                return (new MbrAnalysisResult { SectorReadSucceeded = false }, findings);
            }

            ushort signature = BinaryPrimitives.ReadUInt16LittleEndian(sector0.AsSpan(510, 2));
            uint diskSignature = BinaryPrimitives.ReadUInt32LittleEndian(sector0.AsSpan(440, 4));
            long totalSectors = source.Length / sectorSize;

            var entries = new List<MbrPartitionEntry>(4);
            for (int i = 0; i < 4; i++)
            {
                int entryOffset = 446 + (i * 16);
                byte bootInd = sector0[entryOffset];
                byte partType = sector0[entryOffset + 4];
                uint startLba = BinaryPrimitives.ReadUInt32LittleEndian(sector0.AsSpan(entryOffset + 8, 4));
                uint sectorCount = BinaryPrimitives.ReadUInt32LittleEndian(sector0.AsSpan(entryOffset + 12, 4));

                bool outOfBounds = false;
                if (partType != 0 && sectorCount > 0 && partType != 0xEE)
                {
                    long endLba = (long)startLba + sectorCount;
                    if (totalSectors > 0 && endLba > totalSectors)
                        outOfBounds = true;
                }

                entries.Add(new MbrPartitionEntry
                {
                    SlotIndex = i,
                    BootIndicator = bootInd,
                    PartitionType = partType,
                    PartitionTypeName = GetPartitionTypeName(partType),
                    StartLba = startLba,
                    SectorCount = sectorCount,
                    StartByteOffset = (long)startLba * sectorSize,
                    SizeBytes = (long)sectorCount * sectorSize,
                    OutOfBounds = outOfBounds
                });
            }

            bool hasProtective = entries.Any(e => e.IsProtectiveGptEntry);
            bool protectiveMismatch = false;
            string protectiveNote = string.Empty;

            if (hasProtective)
            {
                var prot = entries.First(e => e.IsProtectiveGptEntry);
                int allocatedCount = entries.Count(e => e.IsAllocated);
                if (prot.StartLba != 1)
                {
                    protectiveMismatch = true;
                    protectiveNote = $"Protective MBR entry (0xEE) starts at LBA {prot.StartLba} instead of LBA 1.";
                }
                else if (allocatedCount > 1)
                {
                    protectiveMismatch = true;
                    protectiveNote = $"Hybrid/non-standard MBR detected: 0xEE Protective entry coexists with {allocatedCount - 1} other MBR entry(s).";
                }
                else
                {
                    ulong expectedMaxSectors = totalSectors > 1
                        ? (ulong)Math.Min(totalSectors - 1, (long)uint.MaxValue)
                        : 0;
                    if (expectedMaxSectors > 0 && prot.SectorCount != expectedMaxSectors && prot.SectorCount != uint.MaxValue)
                    {
                        protectiveMismatch = true;
                        protectiveNote = $"Protective MBR span ({prot.SectorCount} sectors) does not match expected GPT guard span ({expectedMaxSectors} or 0xFFFFFFFF).";
                    }
                    else
                    {
                        protectiveNote = "Valid GPT Protective MBR (0xEE) guarding disk.";
                    }
                }
            }

            // Check overlaps among non-empty MBR entries
            bool overlaps = false;
            var allocated = entries.Where(e => e.IsAllocated).OrderBy(e => e.StartLba).ToList();
            for (int i = 0; i < allocated.Count - 1; i++)
            {
                long endCurrent = (long)allocated[i].StartLba + allocated[i].SectorCount;
                if (endCurrent > allocated[i + 1].StartLba)
                {
                    overlaps = true;
                    break;
                }
            }

            bool anyOutOfBounds = entries.Any(e => e.OutOfBounds);

            if (signature != 0xAA55)
            {
                findings.Add(new StorageDiagnosticFinding
                {
                    FindingId = "mbr.signature_invalid",
                    Category = "MBR",
                    Title = "Malformed or missing MBR signature (S20)",
                    Status = "Fail",
                    Severity = "High",
                    Confidence = 98,
                    Classification = RecoveryClassification.ConfirmedFault,
                    EvidenceSummary = $"Sector 0 bytes 510-511 are 0x{signature:X4} instead of 0xAA55.",
                    ByteOffset = 510,
                    ByteLength = 2,
                    Recommendation = "Verify whether GPT headers at LBA 1 or end-of-disk are intact; if GPT is valid, reconstruct LBA 0 Protective MBR."
                });
            }
            else if (hasProtective && !protectiveMismatch)
            {
                findings.Add(new StorageDiagnosticFinding
                {
                    FindingId = "mbr.protective_valid",
                    Category = "MBR",
                    Title = "GPT Protective MBR verified",
                    Status = "Pass",
                    Severity = "Info",
                    Confidence = 100,
                    Classification = RecoveryClassification.VerifiedIntact,
                    EvidenceSummary = protectiveNote,
                    ByteOffset = 0,
                    ByteLength = 512
                });
            }
            else if (protectiveMismatch)
            {
                findings.Add(new StorageDiagnosticFinding
                {
                    FindingId = "mbr.protective_mismatch",
                    Category = "MBR",
                    Title = "Protective MBR geometry or hybrid mismatch (S21)",
                    Status = "Warn",
                    Severity = "Medium",
                    Confidence = 92,
                    Classification = RecoveryClassification.CorroboratedSuspect,
                    EvidenceSummary = protectiveNote,
                    ByteOffset = 446,
                    ByteLength = 64,
                    Recommendation = "Inspect primary and backup GPT structures; restore standard 0xEE Protective MBR if GPT is authoritative."
                });
            }

            if (overlaps)
            {
                findings.Add(new StorageDiagnosticFinding
                {
                    FindingId = "mbr.overlapping_entries",
                    Category = "MBR",
                    Title = "Overlapping MBR partition entries",
                    Status = "Fail",
                    Severity = "High",
                    Confidence = 96,
                    Classification = RecoveryClassification.ConfirmedFault,
                    EvidenceSummary = "Two or more MBR partition slots claim overlapping LBA ranges.",
                    ByteOffset = 446,
                    ByteLength = 64
                });
            }

            if (anyOutOfBounds)
            {
                findings.Add(new StorageDiagnosticFinding
                {
                    FindingId = "mbr.out_of_bounds",
                    Category = "MBR",
                    Title = "MBR partition entry exceeds physical disk capacity",
                    Status = "Fail",
                    Severity = "High",
                    Confidence = 96,
                    Classification = RecoveryClassification.ConfirmedFault,
                    EvidenceSummary = "One or more MBR partition entries extend beyond total disk sectors.",
                    ByteOffset = 446,
                    ByteLength = 64
                });
            }

            var result = new MbrAnalysisResult
            {
                SectorReadSucceeded = true,
                Signature = signature,
                DiskSignature = diskSignature,
                HasProtectiveMbr = hasProtective,
                HasProtectiveMbrMismatch = protectiveMismatch,
                ProtectiveMbrNote = protectiveNote,
                HasOverlappingEntries = overlaps,
                HasOutOfBoundsEntries = anyOutOfBounds,
                RawSector0 = sector0,
                Entries = entries
            };

            return (result, findings);
        }

        public static byte[] BuildProtectiveMbrSector(long totalSectors, int logicalSectorSize)
        {
            int sectorSize = Math.Max(512, logicalSectorSize);
            byte[] sector = new byte[sectorSize];

            // Entry 0 at offset 446: Protective GPT (0xEE) starting at LBA 1
            int offset = 446;
            sector[offset + 0] = 0x00; // non-bootable
            sector[offset + 1] = 0x00; // starting head
            sector[offset + 2] = 0x02; // starting sector/cylinder (LBA 1)
            sector[offset + 3] = 0x00;
            sector[offset + 4] = 0xEE; // GPT Protective type
            sector[offset + 5] = 0xFF;
            sector[offset + 6] = 0xFF;
            sector[offset + 7] = 0xFF;
            BinaryPrimitives.WriteUInt32LittleEndian(sector.AsSpan(offset + 8, 4), 1u);

            uint spanSectors = totalSectors > 1
                ? (uint)Math.Min(totalSectors - 1, (long)uint.MaxValue)
                : uint.MaxValue;
            BinaryPrimitives.WriteUInt32LittleEndian(sector.AsSpan(offset + 12, 4), spanSectors);

            // Signature 0x55 0xAA at 510..511
            BinaryPrimitives.WriteUInt16LittleEndian(sector.AsSpan(510, 2), 0xAA55);
            return sector;
        }

        public static string GetPartitionTypeName(byte type) => type switch
        {
            0x00 => "Empty",
            0x01 => "FAT12",
            0x04 or 0x06 or 0x0E => "FAT16",
            0x05 or 0x0F => "Extended Container",
            0x07 => "NTFS / exFAT",
            0x0B or 0x0C => "FAT32",
            0x27 => "Windows RE Hidden",
            0x82 => "Linux Swap",
            0x83 => "Linux Native (ext4/XFS)",
            0x8E => "Linux LVM",
            0xEE => "GPT Protective (0xEE)",
            0xEF => "EFI System Partition",
            _ => $"Type 0x{type:X2}"
        };
    }
}
