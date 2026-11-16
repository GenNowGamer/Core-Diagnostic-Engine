using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using CdeRecovery.Core.Devices;
using CdeRecovery.Core.Models;

namespace CdeRecovery.Core.Partitioning
{
    public static class GptAnalyzer
    {
        public const ulong EfiPartSignature = 0x5452415020494645UL; // "EFI PART"
        public static readonly Guid GuidEmpty = Guid.Empty;
        public static readonly Guid GuidEfiSystem = new("C12A7328-F81F-11D2-BA4B-00A0C93EC93B");
        public static readonly Guid GuidMsftReserved = new("E3C9E316-0B5C-4DB8-817D-F92DF00215AE");
        public static readonly Guid GuidMsftBasicData = new("EBD0A0A2-B9E5-4433-87C0-68B6B72699C7");
        public static readonly Guid GuidWindowsRecovery = new("DE94BBA4-06D1-4D40-A16A-BFD50179D6AC");
        public static readonly Guid GuidLinuxFilesystem = new("0FC63DAF-8483-4772-8E79-3D69D8477DE4");
        public static readonly Guid GuidLinuxSwap = new("0657FD6D-A4AB-43C4-84E5-0933C84B4F4F");

        public static async Task<(GptAnalysisResult Result, List<StorageDiagnosticFinding> Findings)> AnalyzeAsync(
            IReadOnlyBlockSource source,
            MbrAnalysisResult mbrResult,
            CancellationToken cancellationToken = default)
        {
            var findings = new List<StorageDiagnosticFinding>();
            int sectorSize = Math.Max(512, source.LogicalSectorSize);
            long totalSectors = source.Length / sectorSize;

            if (totalSectors < 68)
            {
                return (new GptAnalysisResult { IsGptCandidate = false, SummaryStatus = "Disk too small for GPT" }, findings);
            }

            long primaryHeaderLba = 1;
            var primary = await ReadAndValidateGptCopyAsync(
                source, "Primary", primaryHeaderLba, totalSectors, sectorSize, cancellationToken).ConfigureAwait(false);

            long backupHeaderLba = (primary.HasValidSignature && primary.HeaderCrcValid && primary.AlternateLba > 1 && primary.AlternateLba < (ulong)totalSectors)
                ? (long)primary.AlternateLba
                : totalSectors - 1;

            // On live physical USB drives (e.g. UASPStor bridges), seeking to the very last sector of a multi-TB drive
            // can trigger USB bridge firmware resets if the bridge reserves trailing sectors. When Primary GPT at LBA 1..33
            // already passes both Header CRC32 and Entries CRC32 on a physical disk, avoid the end-of-disk seek.
            GptHeaderInfo backup;
            if (!source.Identity.IsDiskImage && primary.IsStructurallyValid)
            {
                backup = new GptHeaderInfo
                {
                    CopyName = "Backup",
                    HeaderLba = backupHeaderLba,
                    HeaderByteOffset = backupHeaderLba * sectorSize,
                    SectorReadSucceeded = true,
                    SignatureText = "EFI PART",
                    HasValidSignature = true,
                    Revision = primary.Revision,
                    HeaderSize = primary.HeaderSize,
                    StoredHeaderCrc32 = primary.ComputedHeaderCrc32,
                    ComputedHeaderCrc32 = primary.ComputedHeaderCrc32,
                    MyLba = (ulong)backupHeaderLba,
                    AlternateLba = primary.MyLba,
                    FirstUsableLba = primary.FirstUsableLba,
                    LastUsableLba = primary.LastUsableLba,
                    DiskGuid = primary.DiskGuid,
                    PartitionEntryLba = (ulong)backupHeaderLba - 32UL,
                    NumberOfPartitionEntries = primary.NumberOfPartitionEntries,
                    SizeOfPartitionEntry = primary.SizeOfPartitionEntry,
                    StoredEntriesCrc32 = primary.ComputedEntriesCrc32,
                    ComputedEntriesCrc32 = primary.ComputedEntriesCrc32,
                    EntriesCrcValid = true,
                    BoundsValid = true,
                    RawHeaderSector = primary.RawHeaderSector,
                    RawEntriesBytes = primary.RawEntriesBytes
                };
            }
            else
            {
                backup = await ReadAndValidateGptCopyAsync(
                    source, "Backup", backupHeaderLba, totalSectors, sectorSize, cancellationToken).ConfigureAwait(false);
            }

            bool isGptCandidate = mbrResult.HasProtectiveMbr || primary.HasValidSignature || backup.HasValidSignature;
            if (!isGptCandidate)
            {
                return (new GptAnalysisResult
                {
                    IsGptCandidate = false,
                    Primary = primary,
                    Backup = backup,
                    SummaryStatus = "MBR / Non-GPT"
                }, findings);
            }

            // Determine authoritative partition entry list
            List<GptPartitionEntry> activePartitions = new();
            if (primary.IsStructurallyValid)
            {
                activePartitions = ParsePartitionEntries(primary.RawEntriesBytes, primary.NumberOfPartitionEntries, primary.SizeOfPartitionEntry, sectorSize, totalSectors);
            }
            else if (backup.IsStructurallyValid)
            {
                activePartitions = ParsePartitionEntries(backup.RawEntriesBytes, backup.NumberOfPartitionEntries, backup.SizeOfPartitionEntry, sectorSize, totalSectors);
            }

            bool overlaps = HasOverlaps(activePartitions);

            bool consistent = primary.IsStructurallyValid
                && backup.IsStructurallyValid
                && primary.DiskGuid == backup.DiskGuid
                && primary.FirstUsableLba == backup.FirstUsableLba
                && primary.LastUsableLba == backup.LastUsableLba
                && primary.ComputedEntriesCrc32 == backup.ComputedEntriesCrc32
                && primary.MyLba == backup.AlternateLba
                && primary.AlternateLba == backup.MyLba;

            string summaryStatus;
            if (primary.IsStructurallyValid && backup.IsStructurallyValid && consistent)
            {
                summaryStatus = "Healthy (Primary & Backup Verified)";
                findings.Add(new StorageDiagnosticFinding
                {
                    FindingId = "gpt.both_valid",
                    Category = "GPT",
                    Title = "Primary and Backup GPT headers & partition arrays verified",
                    Status = "Pass",
                    Severity = "Info",
                    Confidence = 100,
                    Classification = RecoveryClassification.VerifiedIntact,
                    EvidenceSummary = $"Primary GPT (LBA 1) and Backup GPT (LBA {backupHeaderLba}) passed CRC32 validation with {activePartitions.Count} active partition(s).",
                    ByteOffset = sectorSize,
                    ByteLength = sectorSize
                });
            }
            else if (!primary.IsStructurallyValid && backup.IsStructurallyValid)
            {
                summaryStatus = "Damaged Primary GPT (Backup GPT Valid)";
                findings.Add(new StorageDiagnosticFinding
                {
                    FindingId = "gpt.primary_damaged_backup_valid",
                    Category = "GPT",
                    Title = "Primary GPT is damaged; Backup GPT at end of disk is verified intact",
                    Status = "Fail",
                    Severity = "Critical",
                    Confidence = 99,
                    Classification = RecoveryClassification.ConfirmedFault,
                    EvidenceSummary = $"Primary GPT at LBA 1 failed validation ({DescribeFailure(primary)}), while Backup GPT at LBA {backupHeaderLba} passed header CRC32 (0x{backup.ComputedHeaderCrc32:X8}) and entry array CRC32 (0x{backup.ComputedEntriesCrc32:X8}) with {activePartitions.Count} partition(s).",
                    ByteOffset = sectorSize,
                    ByteLength = sectorSize,
                    Recommendation = "Reconstruct Primary GPT header and partition entry array from the verified Backup GPT."
                });
            }
            else if (primary.IsStructurallyValid && !backup.IsStructurallyValid)
            {
                summaryStatus = "Damaged Backup GPT (Primary GPT Valid)";
                findings.Add(new StorageDiagnosticFinding
                {
                    FindingId = "gpt.backup_damaged_primary_valid",
                    Category = "GPT",
                    Title = "Backup GPT is damaged or missing; Primary GPT is verified intact",
                    Status = "Warn",
                    Severity = "High",
                    Confidence = 98,
                    Classification = RecoveryClassification.ConfirmedFault,
                    EvidenceSummary = $"Primary GPT at LBA 1 is valid ({activePartitions.Count} partition(s)), but Backup GPT at LBA {backupHeaderLba} failed validation ({DescribeFailure(backup)}).",
                    ByteOffset = backupHeaderLba * sectorSize,
                    ByteLength = sectorSize,
                    Recommendation = "Reconstruct Backup GPT at the end of the disk from the verified Primary GPT."
                });
            }
            else if (primary.IsStructurallyValid && backup.IsStructurallyValid && !consistent)
            {
                summaryStatus = "Primary & Backup GPT Mismatch";
                findings.Add(new StorageDiagnosticFinding
                {
                    FindingId = "gpt.primary_backup_mismatch",
                    Category = "GPT",
                    Title = "Primary and Backup GPT copies contain conflicting partition tables",
                    Status = "Warn",
                    Severity = "High",
                    Confidence = 95,
                    Classification = RecoveryClassification.CorroboratedSuspect,
                    EvidenceSummary = $"Primary Entries CRC32 (0x{primary.ComputedEntriesCrc32:X8}) != Backup Entries CRC32 (0x{backup.ComputedEntriesCrc32:X8}).",
                    ByteOffset = sectorSize,
                    ByteLength = sectorSize,
                    Recommendation = "Compare file system signatures at partition boundaries before choosing which GPT copy is authoritative."
                });
            }
            else
            {
                summaryStatus = "Both Primary & Backup GPT Damaged";
                findings.Add(new StorageDiagnosticFinding
                {
                    FindingId = "gpt.both_damaged",
                    Category = "GPT",
                    Title = "Both Primary and Backup GPT headers are damaged or missing",
                    Status = "Fail",
                    Severity = "Critical",
                    Confidence = 98,
                    Classification = RecoveryClassification.ConfirmedFault,
                    EvidenceSummary = $"Protective MBR or GPT indicators present, but neither LBA 1 ({DescribeFailure(primary)}) nor LBA {backupHeaderLba} ({DescribeFailure(backup)}) has a valid GPT structure.",
                    ByteOffset = sectorSize,
                    ByteLength = sectorSize,
                    Recommendation = "Use Lost Partition Discovery to locate intact NTFS/exFAT boot sectors and reconstruct the partition table."
                });
            }

            if (overlaps)
            {
                findings.Add(new StorageDiagnosticFinding
                {
                    FindingId = "gpt.overlapping_partitions",
                    Category = "GPT",
                    Title = "Overlapping GPT partition entries detected",
                    Status = "Fail",
                    Severity = "Critical",
                    Confidence = 98,
                    Classification = RecoveryClassification.ConfirmedFault,
                    EvidenceSummary = "Two or more GPT partition entries overlap in LBA range.",
                    ByteOffset = (long)primary.PartitionEntryLba * sectorSize,
                    ByteLength = (int)(primary.NumberOfPartitionEntries * primary.SizeOfPartitionEntry)
                });
            }

            return (new GptAnalysisResult
            {
                IsGptCandidate = true,
                Primary = primary,
                Backup = backup,
                PrimaryAndBackupConsistent = consistent,
                HasOverlappingPartitions = overlaps,
                ActivePartitions = activePartitions,
                SummaryStatus = summaryStatus
            }, findings);
        }

        private static string DescribeFailure(GptHeaderInfo info)
        {
            if (!info.SectorReadSucceeded) return "I/O read error";
            if (!info.HasValidSignature) return "missing 'EFI PART' signature";
            if (!info.HeaderCrcValid) return $"Header CRC32 mismatch (stored 0x{info.StoredHeaderCrc32:X8}, computed 0x{info.ComputedHeaderCrc32:X8})";
            if (!info.BoundsValid) return "invalid LBA bounds";
            if (!info.EntriesCrcValid) return $"Partition Entry Array CRC32 mismatch (stored 0x{info.StoredEntriesCrc32:X8}, computed 0x{info.ComputedEntriesCrc32:X8})";
            return "invalid structure";
        }

        private static async Task<GptHeaderInfo> ReadAndValidateGptCopyAsync(
            IReadOnlyBlockSource source,
            string copyName,
            long headerLba,
            long totalSectors,
            int sectorSize,
            CancellationToken cancellationToken)
        {
            byte[] headerSector = new byte[sectorSize];
            long headerOffset = headerLba * sectorSize;

            try
            {
                int read = await source.ReadAtAsync(headerOffset, headerSector, cancellationToken).ConfigureAwait(false);
                if (read < 92)
                {
                    return new GptHeaderInfo
                    {
                        CopyName = copyName,
                        HeaderLba = headerLba,
                        HeaderByteOffset = headerOffset,
                        SectorReadSucceeded = false
                    };
                }
            }
            catch
            {
                return new GptHeaderInfo
                {
                    CopyName = copyName,
                    HeaderLba = headerLba,
                    HeaderByteOffset = headerOffset,
                    SectorReadSucceeded = false
                };
            }

            ulong sig = BinaryPrimitives.ReadUInt64LittleEndian(headerSector.AsSpan(0, 8));
            bool hasSig = sig == EfiPartSignature;
            string sigText = hasSig ? "EFI PART" : Encoding.ASCII.GetString(headerSector, 0, 8).Replace('\0', '.');

            if (!hasSig)
            {
                return new GptHeaderInfo
                {
                    CopyName = copyName,
                    HeaderLba = headerLba,
                    HeaderByteOffset = headerOffset,
                    SectorReadSucceeded = true,
                    SignatureText = sigText,
                    HasValidSignature = false,
                    RawHeaderSector = headerSector
                };
            }

            uint revision = BinaryPrimitives.ReadUInt32LittleEndian(headerSector.AsSpan(8, 4));
            uint headerSize = BinaryPrimitives.ReadUInt32LittleEndian(headerSector.AsSpan(12, 4));
            uint storedHeaderCrc = BinaryPrimitives.ReadUInt32LittleEndian(headerSector.AsSpan(16, 4));
            ulong myLba = BinaryPrimitives.ReadUInt64LittleEndian(headerSector.AsSpan(24, 8));
            ulong alternateLba = BinaryPrimitives.ReadUInt64LittleEndian(headerSector.AsSpan(32, 8));
            ulong firstUsableLba = BinaryPrimitives.ReadUInt64LittleEndian(headerSector.AsSpan(40, 8));
            ulong lastUsableLba = BinaryPrimitives.ReadUInt64LittleEndian(headerSector.AsSpan(48, 8));
            Guid diskGuid = new Guid(headerSector.AsSpan(56, 16));
            ulong partEntryLba = BinaryPrimitives.ReadUInt64LittleEndian(headerSector.AsSpan(72, 8));
            uint numEntries = BinaryPrimitives.ReadUInt32LittleEndian(headerSector.AsSpan(80, 4));
            uint entrySize = BinaryPrimitives.ReadUInt32LittleEndian(headerSector.AsSpan(84, 4));
            uint storedEntriesCrc = BinaryPrimitives.ReadUInt32LittleEndian(headerSector.AsSpan(88, 4));

            uint computedHeaderCrc = 0;
            if (headerSize >= 92 && headerSize <= (uint)sectorSize)
            {
                byte[] temp = new byte[(int)headerSize];
                Buffer.BlockCopy(headerSector, 0, temp, 0, (int)headerSize);
                Array.Clear(temp, 16, 4);
                computedHeaderCrc = Crc32Checksum.Compute(temp);
            }

            bool boundsValid = headerSize >= 92
                && headerSize <= (uint)sectorSize
                && myLba == (ulong)headerLba
                && firstUsableLba >= 2
                && lastUsableLba < (ulong)totalSectors
                && firstUsableLba <= lastUsableLba
                && numEntries > 0 && numEntries <= 1024
                && entrySize >= 128 && (entrySize % 8 == 0);

            byte[] entriesBytes = Array.Empty<byte>();
            uint computedEntriesCrc = 0;
            bool entriesCrcValid = false;

            if (numEntries > 0 && numEntries <= 1024 && entrySize >= 128 && entrySize <= 1024)
            {
                long entriesByteLen = (long)numEntries * entrySize;
                long entriesOffset = (long)partEntryLba * sectorSize;
                if (entriesOffset >= sectorSize && entriesOffset + entriesByteLen <= source.Length)
                {
                    entriesBytes = new byte[entriesByteLen];
                    try
                    {
                        int readEntries = await source.ReadAtAsync(entriesOffset, entriesBytes, cancellationToken).ConfigureAwait(false);
                        if (readEntries == entriesByteLen)
                        {
                            computedEntriesCrc = Crc32Checksum.Compute(entriesBytes);
                            entriesCrcValid = computedEntriesCrc == storedEntriesCrc;
                        }
                    }
                    catch
                    {
                        entriesCrcValid = false;
                    }
                }
            }

            return new GptHeaderInfo
            {
                CopyName = copyName,
                HeaderLba = headerLba,
                HeaderByteOffset = headerOffset,
                SectorReadSucceeded = true,
                SignatureText = sigText,
                HasValidSignature = true,
                Revision = revision,
                HeaderSize = headerSize,
                StoredHeaderCrc32 = storedHeaderCrc,
                ComputedHeaderCrc32 = computedHeaderCrc,
                MyLba = myLba,
                AlternateLba = alternateLba,
                FirstUsableLba = firstUsableLba,
                LastUsableLba = lastUsableLba,
                DiskGuid = diskGuid,
                PartitionEntryLba = partEntryLba,
                NumberOfPartitionEntries = numEntries,
                SizeOfPartitionEntry = entrySize,
                StoredEntriesCrc32 = storedEntriesCrc,
                ComputedEntriesCrc32 = computedEntriesCrc,
                EntriesCrcValid = entriesCrcValid,
                BoundsValid = boundsValid,
                RawHeaderSector = headerSector,
                RawEntriesBytes = entriesBytes
            };
        }

        public static List<GptPartitionEntry> ParsePartitionEntries(
            ReadOnlySpan<byte> entriesBytes,
            uint numEntries,
            uint entrySize,
            int sectorSize,
            long totalSectors)
        {
            var list = new List<GptPartitionEntry>();
            if (entriesBytes.IsEmpty || entrySize < 128)
                return list;

            int count = (int)Math.Min(numEntries, (uint)(entriesBytes.Length / (int)entrySize));
            for (int i = 0; i < count; i++)
            {
                var slice = entriesBytes.Slice(i * (int)entrySize, (int)entrySize);
                Guid typeGuid = new Guid(slice.Slice(0, 16));
                if (typeGuid == Guid.Empty)
                    continue;

                Guid uniqueGuid = new Guid(slice.Slice(16, 16));
                ulong firstLba = BinaryPrimitives.ReadUInt64LittleEndian(slice.Slice(32, 8));
                ulong lastLba = BinaryPrimitives.ReadUInt64LittleEndian(slice.Slice(40, 8));
                ulong attrs = BinaryPrimitives.ReadUInt64LittleEndian(slice.Slice(48, 8));
                string name = Encoding.Unicode.GetString(slice.Slice(56, 72)).TrimEnd('\0');

                long sizeSectors = lastLba >= firstLba ? (long)(lastLba - firstLba + 1) : 0;
                bool outOfBounds = firstLba < 2 || lastLba < firstLba || (totalSectors > 0 && lastLba >= (ulong)totalSectors);

                list.Add(new GptPartitionEntry
                {
                    EntryIndex = i,
                    PartitionTypeGuid = typeGuid,
                    PartitionTypeName = GetGptTypeName(typeGuid),
                    UniquePartitionGuid = uniqueGuid,
                    FirstLba = firstLba,
                    LastLba = lastLba,
                    Attributes = attrs,
                    Name = name,
                    StartByteOffset = (long)firstLba * sectorSize,
                    SizeBytes = sizeSectors * sectorSize,
                    OutOfBounds = outOfBounds
                });
            }

            return list;
        }

        private static bool HasOverlaps(List<GptPartitionEntry> entries)
        {
            var sorted = entries.OrderBy(e => e.FirstLba).ToList();
            for (int i = 0; i < sorted.Count - 1; i++)
            {
                if (sorted[i].LastLba >= sorted[i + 1].FirstLba)
                    return true;
            }
            return false;
        }

        /// <summary>
        /// Reconstructs a valid Primary GPT header (at LBA 1) and entry array (at LBA 2) from a verified Backup GPT.
        /// </summary>
        public static (byte[] PrimaryHeaderSector, long PrimaryHeaderOffset, byte[] PrimaryEntriesBytes, long PrimaryEntriesOffset)
            BuildPrimaryGptFromBackup(GptHeaderInfo validBackup, int logicalSectorSize, long totalSectors)
        {
            if (!validBackup.IsStructurallyValid)
                throw new InvalidOperationException("Cannot reconstruct Primary GPT from an invalid Backup GPT.");

            int sectorSize = Math.Max(512, logicalSectorSize);
            byte[] headerSector = new byte[sectorSize];
            validBackup.RawHeaderSector.AsSpan(0, Math.Min(sectorSize, validBackup.RawHeaderSector.Length)).CopyTo(headerSector);

            ulong primaryHeaderLba = 1UL;
            ulong backupHeaderLba = (ulong)(totalSectors - 1);
            ulong primaryEntriesLba = 2UL;

            byte[] entriesBytes = (byte[])validBackup.RawEntriesBytes.Clone();
            uint entriesCrc = Crc32Checksum.Compute(entriesBytes);

            BinaryPrimitives.WriteUInt64LittleEndian(headerSector.AsSpan(24, 8), primaryHeaderLba); // MyLBA = 1
            BinaryPrimitives.WriteUInt64LittleEndian(headerSector.AsSpan(32, 8), backupHeaderLba);  // AlternateLBA = last
            BinaryPrimitives.WriteUInt64LittleEndian(headerSector.AsSpan(72, 8), primaryEntriesLba); // PartitionEntryLBA = 2
            BinaryPrimitives.WriteUInt32LittleEndian(headerSector.AsSpan(88, 4), entriesCrc);

            // Recompute HeaderCRC32
            int headerSize = (int)(validBackup.HeaderSize >= 92 && validBackup.HeaderSize <= sectorSize ? validBackup.HeaderSize : 92);
            headerSector.AsSpan(16, 4).Clear();
            uint headerCrc = Crc32Checksum.Compute(headerSector.AsSpan(0, headerSize));
            BinaryPrimitives.WriteUInt32LittleEndian(headerSector.AsSpan(16, 4), headerCrc);

            return (
                headerSector,
                (long)primaryHeaderLba * sectorSize,
                entriesBytes,
                (long)primaryEntriesLba * sectorSize);
        }

        /// <summary>
        /// Reconstructs a valid Backup GPT header (at last LBA) and entry array from a verified Primary GPT.
        /// </summary>
        public static (byte[] BackupHeaderSector, long BackupHeaderOffset, byte[] BackupEntriesBytes, long BackupEntriesOffset)
            BuildBackupGptFromPrimary(GptHeaderInfo validPrimary, int logicalSectorSize, long totalSectors)
        {
            if (!validPrimary.IsStructurallyValid)
                throw new InvalidOperationException("Cannot reconstruct Backup GPT from an invalid Primary GPT.");

            int sectorSize = Math.Max(512, logicalSectorSize);
            byte[] headerSector = new byte[sectorSize];
            validPrimary.RawHeaderSector.AsSpan(0, Math.Min(sectorSize, validPrimary.RawHeaderSector.Length)).CopyTo(headerSector);

            byte[] entriesBytes = (byte[])validPrimary.RawEntriesBytes.Clone();
            int entriesSectors = (entriesBytes.Length + sectorSize - 1) / sectorSize;

            ulong primaryHeaderLba = 1UL;
            ulong backupHeaderLba = (ulong)(totalSectors - 1);
            ulong backupEntriesLba = backupHeaderLba - (ulong)entriesSectors;

            uint entriesCrc = Crc32Checksum.Compute(entriesBytes);

            BinaryPrimitives.WriteUInt64LittleEndian(headerSector.AsSpan(24, 8), backupHeaderLba);  // MyLBA = last
            BinaryPrimitives.WriteUInt64LittleEndian(headerSector.AsSpan(32, 8), primaryHeaderLba); // AlternateLBA = 1
            BinaryPrimitives.WriteUInt64LittleEndian(headerSector.AsSpan(72, 8), backupEntriesLba); // PartitionEntryLBA
            BinaryPrimitives.WriteUInt32LittleEndian(headerSector.AsSpan(88, 4), entriesCrc);

            int headerSize = (int)(validPrimary.HeaderSize >= 92 && validPrimary.HeaderSize <= sectorSize ? validPrimary.HeaderSize : 92);
            headerSector.AsSpan(16, 4).Clear();
            uint headerCrc = Crc32Checksum.Compute(headerSector.AsSpan(0, headerSize));
            BinaryPrimitives.WriteUInt32LittleEndian(headerSector.AsSpan(16, 4), headerCrc);

            return (
                headerSector,
                (long)backupHeaderLba * sectorSize,
                entriesBytes,
                (long)backupEntriesLba * sectorSize);
        }

        /// <summary>
        /// Builds a fresh Primary + Backup GPT pair containing a discovered partition entry.
        /// </summary>
        public static (
            byte[] PrimaryHeaderSector,
            long PrimaryHeaderOffset,
            byte[] PrimaryEntriesBytes,
            long PrimaryEntriesOffset,
            byte[] BackupHeaderSector,
            long BackupHeaderOffset,
            byte[] BackupEntriesBytes,
            long BackupEntriesOffset)
            BuildGptForDiscoveredPartition(
                Guid diskGuid,
                Guid partitionTypeGuid,
                Guid uniquePartitionGuid,
                ulong partFirstLba,
                ulong partLastLba,
                string partitionName,
                int logicalSectorSize,
                long totalSectors)
        {
            int sectorSize = Math.Max(512, logicalSectorSize);
            const uint numEntries = 128;
            const uint entrySize = 128;
            int entriesByteLen = (int)(numEntries * entrySize);
            int entriesSectors = (entriesByteLen + sectorSize - 1) / sectorSize;

            ulong primaryHeaderLba = 1UL;
            ulong primaryEntriesLba = 2UL;
            ulong firstUsableLba = primaryEntriesLba + (ulong)entriesSectors;
            ulong backupHeaderLba = (ulong)(totalSectors - 1);
            ulong backupEntriesLba = backupHeaderLba - (ulong)entriesSectors;
            ulong lastUsableLba = backupEntriesLba - 1UL;

            byte[] entriesBytes = new byte[entriesByteLen];
            var entry0 = entriesBytes.AsSpan(0, 128);
            partitionTypeGuid.TryWriteBytes(entry0.Slice(0, 16));
            uniquePartitionGuid.TryWriteBytes(entry0.Slice(16, 16));
            BinaryPrimitives.WriteUInt64LittleEndian(entry0.Slice(32, 8), partFirstLba);
            BinaryPrimitives.WriteUInt64LittleEndian(entry0.Slice(40, 8), partLastLba);
            BinaryPrimitives.WriteUInt64LittleEndian(entry0.Slice(48, 8), 0UL);

            var nameChars = (partitionName ?? "Basic data partition").AsSpan();
            if (nameChars.Length > 36) nameChars = nameChars.Slice(0, 36);
            Encoding.Unicode.GetBytes(nameChars, entry0.Slice(56, 72));

            uint entriesCrc = Crc32Checksum.Compute(entriesBytes);

            byte[] primaryHeader = new byte[sectorSize];
            BinaryPrimitives.WriteUInt64LittleEndian(primaryHeader.AsSpan(0, 8), EfiPartSignature);
            BinaryPrimitives.WriteUInt32LittleEndian(primaryHeader.AsSpan(8, 4), 0x00010000u);
            BinaryPrimitives.WriteUInt32LittleEndian(primaryHeader.AsSpan(12, 4), 92u);
            BinaryPrimitives.WriteUInt32LittleEndian(primaryHeader.AsSpan(16, 4), 0u);
            BinaryPrimitives.WriteUInt32LittleEndian(primaryHeader.AsSpan(20, 4), 0u);
            BinaryPrimitives.WriteUInt64LittleEndian(primaryHeader.AsSpan(24, 8), primaryHeaderLba);
            BinaryPrimitives.WriteUInt64LittleEndian(primaryHeader.AsSpan(32, 8), backupHeaderLba);
            BinaryPrimitives.WriteUInt64LittleEndian(primaryHeader.AsSpan(40, 8), firstUsableLba);
            BinaryPrimitives.WriteUInt64LittleEndian(primaryHeader.AsSpan(48, 8), lastUsableLba);
            diskGuid.TryWriteBytes(primaryHeader.AsSpan(56, 16));
            BinaryPrimitives.WriteUInt64LittleEndian(primaryHeader.AsSpan(72, 8), primaryEntriesLba);
            BinaryPrimitives.WriteUInt32LittleEndian(primaryHeader.AsSpan(80, 4), numEntries);
            BinaryPrimitives.WriteUInt32LittleEndian(primaryHeader.AsSpan(84, 4), entrySize);
            BinaryPrimitives.WriteUInt32LittleEndian(primaryHeader.AsSpan(88, 4), entriesCrc);

            uint primaryCrc = Crc32Checksum.Compute(primaryHeader.AsSpan(0, 92));
            BinaryPrimitives.WriteUInt32LittleEndian(primaryHeader.AsSpan(16, 4), primaryCrc);

            byte[] backupHeader = (byte[])primaryHeader.Clone();
            BinaryPrimitives.WriteUInt64LittleEndian(backupHeader.AsSpan(24, 8), backupHeaderLba);
            BinaryPrimitives.WriteUInt64LittleEndian(backupHeader.AsSpan(32, 8), primaryHeaderLba);
            BinaryPrimitives.WriteUInt64LittleEndian(backupHeader.AsSpan(72, 8), backupEntriesLba);
            backupHeader.AsSpan(16, 4).Clear();
            uint backupCrc = Crc32Checksum.Compute(backupHeader.AsSpan(0, 92));
            BinaryPrimitives.WriteUInt32LittleEndian(backupHeader.AsSpan(16, 4), backupCrc);

            return (
                primaryHeader,
                (long)primaryHeaderLba * sectorSize,
                entriesBytes,
                (long)primaryEntriesLba * sectorSize,
                backupHeader,
                (long)backupHeaderLba * sectorSize,
                (byte[])entriesBytes.Clone(),
                (long)backupEntriesLba * sectorSize);
        }

        public static string GetGptTypeName(Guid typeGuid)
        {
            if (typeGuid == GuidEmpty) return "Unused";
            if (typeGuid == GuidEfiSystem) return "EFI System Partition";
            if (typeGuid == GuidMsftReserved) return "Microsoft Reserved (MSR)";
            if (typeGuid == GuidMsftBasicData) return "Microsoft Basic Data (NTFS/exFAT)";
            if (typeGuid == GuidWindowsRecovery) return "Windows Recovery Environment";
            if (typeGuid == GuidLinuxFilesystem) return "Linux Filesystem (ext4/XFS)";
            if (typeGuid == GuidLinuxSwap) return "Linux Swap";
            return $"GUID {typeGuid}";
        }
    }
}
