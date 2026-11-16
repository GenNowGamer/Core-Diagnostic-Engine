using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using CdeRecovery.Core.Devices;
using CdeRecovery.Core.FileSystems;
using CdeRecovery.Core.Models;

namespace CdeRecovery.Core.Partitioning
{
    public static class PartitionDiscovery
    {
        public static async Task<(List<DiscoveredPartitionCandidate> Candidates, List<StorageDiagnosticFinding> Findings)> DiscoverAsync(
            IReadOnlyBlockSource source,
            MbrAnalysisResult mbr,
            GptAnalysisResult gpt,
            CancellationToken cancellationToken = default)
        {
            var candidates = new List<DiscoveredPartitionCandidate>();
            var findings = new List<StorageDiagnosticFinding>();
            int sectorSize = Math.Max(512, source.LogicalSectorSize);
            long totalSectors = source.Length / sectorSize;

            // 1. Record active GPT partitions
            if (gpt.IsGptCandidate && gpt.ActivePartitions.Count > 0)
            {
                foreach (var p in gpt.ActivePartitions)
                {
                    candidates.Add(new DiscoveredPartitionCandidate
                    {
                        StartByteOffset = p.StartByteOffset,
                        SizeBytes = p.SizeBytes,
                        StartLba = (long)p.FirstLba,
                        EndLba = (long)p.LastLba,
                        FileSystemType = p.PartitionTypeName,
                        Source = gpt.Primary.IsStructurallyValid ? "GPT Primary" : "GPT Backup",
                        Confidence = 100,
                        InActivePartitionTable = true,
                        Description = $"GPT Partition {p.EntryIndex + 1}: {p.Name} ({p.PartitionTypeName})",
                        SuggestedGptTypeGuid = p.PartitionTypeGuid
                    });
                }
            }
            else if (!gpt.IsGptCandidate)
            {
                foreach (var m in mbr.Entries.Where(e => e.IsAllocated && !e.IsProtectiveGptEntry))
                {
                    candidates.Add(new DiscoveredPartitionCandidate
                    {
                        StartByteOffset = m.StartByteOffset,
                        SizeBytes = m.SizeBytes,
                        StartLba = m.StartLba,
                        EndLba = m.StartLba + m.SectorCount - 1,
                        FileSystemType = m.PartitionTypeName,
                        Source = "MBR Partition Table",
                        Confidence = 100,
                        InActivePartitionTable = true,
                        Description = $"MBR Slot {m.SlotIndex + 1}: {m.PartitionTypeName}",
                        SuggestedGptTypeGuid = GptAnalyzer.GuidMsftBasicData
                    });
                }
            }

            // 2. Only probe well-known partition boundary offsets for lost/unreferenced partitions
            // when the active partition table is empty or damaged.
            bool hasValidActiveTable = (gpt.IsGptCandidate && (gpt.Primary.IsStructurallyValid || gpt.Backup.IsStructurallyValid) && candidates.Count > 0)
                || (!gpt.IsGptCandidate && mbr.HasValidSignature && candidates.Count > 0);
            if (hasValidActiveTable)
            {
                return (candidates, findings);
            }

            var probeByteOffsets = new SortedSet<long>
            {
                1024L * 1024L,               // 1 MiB standard alignment (LBA 2048 @ 512B, LBA 256 @ 4Kn)
                17L * 1024L * 1024L,         // 1 MiB + 16 MiB Windows MSR
                129L * 1024L * 1024L,        // 1 MiB + 128 MiB Windows MSR
                117L * 1024L * 1024L,        // 1 MiB + 100 MiB EFI + 16 MiB MSR
                277L * 1024L * 1024L,        // 1 MiB + 260 MiB EFI + 16 MiB MSR
                (long)sectorSize * 34L,      // First usable LBA on 512B GPT
                (long)sectorSize * 40L,      // First usable LBA on 4Kn / macOS GPT
                (long)sectorSize * 63L,      // Legacy MBR cylinder alignment
                (long)sectorSize * 2048L,
                (long)sectorSize * 4096L
            };

            byte[] sectorBuf = new byte[sectorSize];

            foreach (long probeOffset in probeByteOffsets)
            {
                if (probeOffset <= 0 || probeOffset + sectorSize > source.Length)
                    continue;
                if (probeOffset % sectorSize != 0)
                    continue;
                if (candidates.Any(c => c.StartByteOffset == probeOffset))
                    continue;

                int read;
                try
                {
                    read = await source.ReadAtAsync(probeOffset, sectorBuf, cancellationToken).ConfigureAwait(false);
                }
                catch
                {
                    continue;
                }

                if (read < 512)
                    continue;

                var ntfsVbr = NtfsAnalyzer.ParseBootSector(sectorBuf);
                if (ntfsVbr.IsValid)
                {
                    long startLba = probeOffset / sectorSize;
                    // In Windows NTFS, VBR TotalSectors is either (partitionSectors - 1) where the last sector is the Backup VBR, or partitionSectors.
                    long vbrSectorsInDeviceUnits = (ntfsVbr.TotalSectors * ntfsVbr.BytesPerSector) / sectorSize;
                    long candidateSectors = vbrSectorsInDeviceUnits + 1;
                    if (startLba + candidateSectors > totalSectors)
                        candidateSectors = vbrSectorsInDeviceUnits;

                    long endLba = startLba + candidateSectors - 1;
                    long sizeBytes = candidateSectors * sectorSize;

                    // Check if $MFT Record 0 is valid
                    long clusterBytes = (long)ntfsVbr.BytesPerSector * ntfsVbr.SectorsPerCluster;
                    long mftOffset = probeOffset + (ntfsVbr.MftCluster * clusterBytes);
                    bool mftValid = false;
                    if (mftOffset > probeOffset && mftOffset + 1024 <= source.Length)
                    {
                        byte[] mftRec = new byte[1024];
                        try
                        {
                            if (await source.ReadAtAsync(mftOffset, mftRec, cancellationToken).ConfigureAwait(false) == 1024)
                                mftValid = NtfsAnalyzer.ValidateMftFileRecord(mftRec);
                        }
                        catch { }
                    }

                    int confidence = mftValid ? 98 : 85;
                    var lost = new DiscoveredPartitionCandidate
                    {
                        StartByteOffset = probeOffset,
                        SizeBytes = sizeBytes,
                        StartLba = startLba,
                        EndLba = endLba,
                        FileSystemType = "NTFS",
                        Source = mftValid ? "Lost Partition Scan (Verified VBR + $MFT)" : "Lost Partition Scan (VBR Signature)",
                        Confidence = confidence,
                        InActivePartitionTable = false,
                        Description = $"Unreferenced NTFS volume at LBA {startLba} (0x{probeOffset:X}), Serial {ntfsVbr.VolumeSerial:X16}, $MFT Valid={mftValid}",
                        SuggestedGptTypeGuid = GptAnalyzer.GuidMsftBasicData
                    };
                    candidates.Add(lost);

                    findings.Add(new StorageDiagnosticFinding
                    {
                        FindingId = $"discovery.lost_ntfs.lba_{startLba}",
                        Category = "Discovery",
                        Title = $"Discovered lost/unreferenced NTFS partition at LBA {startLba} ({lost.DisplaySize})",
                        Status = "Warn",
                        Severity = "High",
                        Confidence = confidence,
                        Classification = mftValid ? RecoveryClassification.ConfirmedFault : RecoveryClassification.HeuristicCandidate,
                        EvidenceSummary = lost.Description,
                        ByteOffset = probeOffset,
                        ByteLength = sectorSize,
                        Recommendation = "Reconstruct missing partition table entry pointing to LBA " + startLba + ".." + endLba + "."
                    });
                }
                else if (ExFatAnalyzer.IsExFatBootSector(sectorBuf))
                {
                    long startLba = probeOffset / sectorSize;
                    long remainingSectors = Math.Max(1, totalSectors - 34 - startLba);
                    var lost = new DiscoveredPartitionCandidate
                    {
                        StartByteOffset = probeOffset,
                        SizeBytes = remainingSectors * sectorSize,
                        StartLba = startLba,
                        EndLba = startLba + remainingSectors - 1,
                        FileSystemType = "exFAT",
                        Source = "Lost Partition Scan (exFAT VBR)",
                        Confidence = 90,
                        InActivePartitionTable = false,
                        Description = $"Unreferenced exFAT volume at LBA {startLba} (0x{probeOffset:X})",
                        SuggestedGptTypeGuid = GptAnalyzer.GuidMsftBasicData
                    };
                    candidates.Add(lost);
                }
            }

            return (candidates, findings);
        }
    }
}
