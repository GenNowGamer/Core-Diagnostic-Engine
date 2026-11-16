using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using CdeRecovery.Core.Devices;
using CdeRecovery.Core.Evidence;
using CdeRecovery.Core.Models;
using CdeRecovery.Core.Partitioning;

namespace CdeRecovery.Core.Recovery
{
    public static class RecoveryPlanner
    {
        public static async Task<List<VerifiedRepairPlan>> GeneratePlansAsync(
            IReadOnlyBlockSource source,
            MbrAnalysisResult mbr,
            GptAnalysisResult gpt,
            List<FileSystemAnalysisResult> fileSystems,
            List<DiscoveredPartitionCandidate> discoveredPartitions,
            List<StorageDiagnosticFinding> findings,
            CancellationToken cancellationToken = default)
        {
            var plans = new List<VerifiedRepairPlan>();
            int sectorSize = Math.Max(512, source.LogicalSectorSize);
            long totalSectors = source.Length / sectorSize;

            bool hasHardwareTrouble = source.ReadErrors.Count > 0
                || string.Equals(source.Identity.SmartHealthStatus, "Critical", StringComparison.OrdinalIgnoreCase)
                || string.Equals(source.Identity.SmartHealthStatus, "Fail", StringComparison.OrdinalIgnoreCase);

            if (hasHardwareTrouble)
            {
                findings.Add(new StorageDiagnosticFinding
                {
                    FindingId = "safety.hardware_trouble_stop",
                    Category = "Safety",
                    Title = "S.M.A.R.T. failure or physical sector read errors detected — in-place writes blocked",
                    Status = "Fail",
                    Severity = "Critical",
                    Confidence = 100,
                    Classification = RecoveryClassification.SafetyBlock,
                    EvidenceSummary = $"ReadErrors={source.ReadErrors.Count}, SmartHealthStatus={source.Identity.SmartHealthStatus}. Writing metadata to a failing drive risks permanent data loss.",
                    Recommendation = "Stop repair path; clone the drive with bad-sector mapfile recovery or extract critical files immediately."
                });

                plans.Add(new VerifiedRepairPlan
                {
                    PlanId = "plan.blocked.hardware",
                    Title = "STOP: Hardware / Read Error Safety Gate Active",
                    ActionType = "SafetyStop",
                    RiskLevel = "Blocked",
                    IsExecutable = false,
                    DetectedCondition = $"S.M.A.R.T. status is '{source.Identity.SmartHealthStatus}' and {source.ReadErrors.Count} sector read error(s) occurred.",
                    WhyOfferedExplanation = "CDE blocks all metadata write plans when physical read errors or S.M.A.R.T. failures are observed.",
                    RecommendedNextStep = "Do not attempt in-place partition or file system repairs. Back up readable files to a separate drive first.",
                    SourceIdentity = source.Identity
                });
                return plans;
            }

            if (source.Identity.IsSystemDisk || source.Identity.IsBootDisk)
            {
                findings.Add(new StorageDiagnosticFinding
                {
                    FindingId = "safety.system_disk_gate",
                    Category = "Safety",
                    Title = "Running System / Boot Disk Protection Active",
                    Status = "Info",
                    Severity = "Info",
                    Confidence = 100,
                    Classification = RecoveryClassification.SafetyBlock,
                    EvidenceSummary = "Selected disk hosts the active Windows boot/system volume. Automatic partition-table writes are disabled on the running OS disk."
                });
            }

            bool canExecuteOnTarget = !source.Identity.IsSystemDisk && !source.Identity.IsBootDisk;

            // 1. Primary GPT damaged, Backup GPT verified intact
            if (gpt.IsGptCandidate && !gpt.Primary.IsStructurallyValid && gpt.Backup.IsStructurallyValid)
            {
                var (primHeader, primHeaderOff, primEntries, primEntriesOff) =
                    GptAnalyzer.BuildPrimaryGptFromBackup(gpt.Backup, sectorSize, totalSectors);

                var patches = new List<RepairBytePatch>();

                // Also repair Protective MBR at LBA 0 if damaged
                if (!mbr.HasValidSignature || !mbr.HasProtectiveMbr || mbr.HasProtectiveMbrMismatch)
                {
                    byte[] newMbr = MbrAnalyzer.BuildProtectiveMbrSector(totalSectors, sectorSize);
                    patches.Add(BuildPatch(
                        "Protective MBR (LBA 0)",
                        0,
                        mbr.RawSector0,
                        newMbr,
                        sectorSize,
                        "Restore standard 0xEE GPT Protective MBR and 0xAA55 signature at Sector 0."));
                }

                patches.Add(BuildPatch(
                    "Primary GPT Header (LBA 1)",
                    primHeaderOff,
                    gpt.Primary.RawHeaderSector,
                    primHeader,
                    sectorSize,
                    $"Reconstruct Primary GPT Header at LBA 1 from verified Backup GPT (DiskGUID {gpt.Backup.DiskGuid}, HeaderCRC32 Recalculated)."));

                byte[] currentPrimaryEntries = new byte[primEntries.Length];
                try
                {
                    await source.ReadAtAsync(primEntriesOff, currentPrimaryEntries, cancellationToken).ConfigureAwait(false);
                }
                catch { }

                patches.Add(BuildPatch(
                    "Primary GPT Partition Entry Array",
                    primEntriesOff,
                    currentPrimaryEntries,
                    primEntries,
                    sectorSize,
                    $"Restore {gpt.ActivePartitions.Count} partition entry(s) ({primEntries.Length} bytes, EntriesCRC32 0x{gpt.Backup.ComputedEntriesCrc32:X8}) from verified Backup GPT."));

                plans.Add(new VerifiedRepairPlan
                {
                    PlanId = "plan.reconstruct_primary_gpt",
                    Title = "Reconstruct Primary GPT from Verified Backup GPT",
                    ActionType = "ReconstructPrimaryGpt",
                    RiskLevel = "Low",
                    IsExecutable = canExecuteOnTarget,
                    DetectedCondition = "Primary GPT failed validation; Backup GPT at end of disk passed all CRC32 and boundary checks.",
                    WhyOfferedExplanation =
                        $"The Primary GPT at LBA 1 is corrupted, which causes Windows to see the drive as RAW or uninitialized. " +
                        $"However, the redundant Backup GPT at LBA {gpt.Backup.HeaderLba} passed both Header CRC32 (0x{gpt.Backup.ComputedHeaderCrc32:X8}) " +
                        $"and Partition Entry Array CRC32 (0x{gpt.Backup.ComputedEntriesCrc32:X8}), and its {gpt.ActivePartitions.Count} partition(s) align with valid file system structures.",
                    RecommendedNextStep = "Capture a Metadata Snapshot (automatic during execution), apply the Primary GPT reconstruction, and verify partition mounting.",
                    SourceIdentity = source.Identity,
                    Patches = patches
                });
            }

            // 2. Backup GPT damaged, Primary GPT verified intact
            if (gpt.IsGptCandidate && gpt.Primary.IsStructurallyValid && !gpt.Backup.IsStructurallyValid)
            {
                var (bakHeader, bakHeaderOff, bakEntries, bakEntriesOff) =
                    GptAnalyzer.BuildBackupGptFromPrimary(gpt.Primary, sectorSize, totalSectors);

                byte[] currentBakEntries = new byte[bakEntries.Length];
                try
                {
                    await source.ReadAtAsync(bakEntriesOff, currentBakEntries, cancellationToken).ConfigureAwait(false);
                }
                catch { }

                var patches = new List<RepairBytePatch>
                {
                    BuildPatch(
                        "Backup GPT Partition Entry Array",
                        bakEntriesOff,
                        currentBakEntries,
                        bakEntries,
                        sectorSize,
                        $"Restore Backup GPT Partition Entry Array ({bakEntries.Length} bytes, CRC32 0x{gpt.Primary.ComputedEntriesCrc32:X8}) from verified Primary GPT."),
                    BuildPatch(
                        $"Backup GPT Header (LBA {bakHeaderOff / sectorSize})",
                        bakHeaderOff,
                        gpt.Backup.RawHeaderSector,
                        bakHeader,
                        sectorSize,
                        "Reconstruct Backup GPT Header at the end of the disk with recalculated MyLBA, PartitionEntryLBA, and HeaderCRC32.")
                };

                plans.Add(new VerifiedRepairPlan
                {
                    PlanId = "plan.reconstruct_backup_gpt",
                    Title = "Reconstruct Backup GPT from Verified Primary GPT",
                    ActionType = "ReconstructBackupGpt",
                    RiskLevel = "Low",
                    IsExecutable = canExecuteOnTarget,
                    DetectedCondition = "Primary GPT is valid; Backup GPT at end of disk is damaged or missing.",
                    WhyOfferedExplanation =
                        $"Primary GPT at LBA 1 passed all CRC32 checks, but the redundant Backup GPT at LBA {gpt.Backup.HeaderLba} failed validation. " +
                        "Restoring the Backup GPT ensures disk tools and OS partition managers do not flag the drive as corrupt.",
                    RecommendedNextStep = "Apply Backup GPT reconstruction and verify both GPT copies match.",
                    SourceIdentity = source.Identity,
                    Patches = patches
                });
            }

            // 3. Protective MBR damaged/mismatched while GPT is valid
            if (gpt.IsGptCandidate && gpt.Primary.IsStructurallyValid && (!mbr.HasValidSignature || !mbr.HasProtectiveMbr || mbr.HasProtectiveMbrMismatch))
            {
                byte[] newMbr = MbrAnalyzer.BuildProtectiveMbrSector(totalSectors, sectorSize);
                plans.Add(new VerifiedRepairPlan
                {
                    PlanId = "plan.restore_protective_mbr",
                    Title = "Restore GPT Protective MBR (Sector 0)",
                    ActionType = "RestoreProtectiveMbr",
                    RiskLevel = "Low",
                    IsExecutable = canExecuteOnTarget,
                    DetectedCondition = "GPT structures are valid, but LBA 0 Protective MBR signature or 0xEE guard entry is malformed.",
                    WhyOfferedExplanation =
                        "A damaged Sector 0 (missing 0xAA55 signature or missing 0xEE protective partition entry) prevents Windows from recognizing a valid GPT disk.",
                    RecommendedNextStep = "Restore the 512-byte Protective MBR at LBA 0.",
                    SourceIdentity = source.Identity,
                    Patches = new List<RepairBytePatch>
                    {
                        BuildPatch(
                            "Protective MBR (LBA 0)",
                            0,
                            mbr.RawSector0,
                            newMbr,
                            sectorSize,
                            "Write standard 0xEE GPT Protective MBR guard entry and 0xAA55 boot signature at LBA 0.")
                    }
                });
            }

            // 4. NTFS Boot Sector restorations (Primary VBR damaged + Backup VBR valid + $MFT verified)
            foreach (var fs in fileSystems)
            {
                if (fs.IsEncryptedBitLocker)
                    continue;

                if (fs.DetectedFileSystem == "NTFS"
                    && !fs.PrimaryBootSectorValid
                    && fs.BackupBootSectorValid
                    && (fs.NtfsMftRecord0Valid || fs.NtfsMftMirrorRecord0Valid)
                    && fs.RawBackupBootSector.Length >= 512)
                {
                    plans.Add(new VerifiedRepairPlan
                    {
                        PlanId = $"plan.restore_ntfs_vbr.p{fs.PartitionIndex}",
                        Title = $"Restore Partition {fs.PartitionIndex} ({fs.PartitionName}) NTFS Boot Sector from Verified Backup",
                        ActionType = "RestoreNtfsBootSector",
                        RiskLevel = "Low",
                        IsExecutable = canExecuteOnTarget,
                        DetectedCondition = $"Partition {fs.PartitionIndex} Primary NTFS Boot Sector is damaged; Backup NTFS Boot Sector and $MFT are verified intact.",
                        WhyOfferedExplanation =
                            $"Windows reports Partition {fs.PartitionIndex} as RAW because the Primary NTFS Boot Sector at offset 0x{fs.PartitionStartOffset:X} is corrupted. " +
                            $"CDE verified that the Backup NTFS Boot Sector at the end of the partition (0x{fs.BackupBootSectorOffset:X}) is structurally valid and points to an intact Master File Table ($MFT) at offset 0x{fs.NtfsMftByteOffset:X}.",
                        RecommendedNextStep = "Copy the verified Backup NTFS Boot Sector to the Primary Boot Sector offset and re-verify volume metadata.",
                        SourceIdentity = source.Identity,
                        Patches = new List<RepairBytePatch>
                        {
                            BuildPatch(
                                $"Partition {fs.PartitionIndex} Primary NTFS Boot Sector",
                                fs.PartitionStartOffset,
                                fs.RawPrimaryBootSector,
                                fs.RawBackupBootSector,
                                sectorSize,
                                $"Copy verified {sectorSize}-byte NTFS Backup VBR from 0x{fs.BackupBootSectorOffset:X} to Primary VBR at 0x{fs.PartitionStartOffset:X}.")
                        }
                    });
                }
                else if (fs.DetectedFileSystem == "NTFS" && !fs.NtfsMftRecord0Valid && !fs.NtfsMftMirrorRecord0Valid)
                {
                    plans.Add(new VerifiedRepairPlan
                    {
                        PlanId = $"plan.guidance.extract_files.p{fs.PartitionIndex}",
                        Title = $"Partition {fs.PartitionIndex}: Recommend File Extraction Instead of In-Place Repair",
                        ActionType = "GuidanceFileExtraction",
                        RiskLevel = "High",
                        IsExecutable = false,
                        DetectedCondition = $"Partition {fs.PartitionIndex} file system metadata ($MFT and $MFTMirr) is severely damaged.",
                        WhyOfferedExplanation =
                            "In-place partition table or boot-sector writes cannot reconstruct a severely damaged Master File Table, and running CHKDSK on a corrupted MFT can orphan user files.",
                        RecommendedNextStep = "Recover files to your separate backup drive first, then reformat this drive as NTFS and copy the recovered data back.",
                        SourceIdentity = source.Identity
                    });
                }
            }

            // 5. Lost Partition Discovery -> Reconstruct missing GPT partition table when both GPTs are missing/empty
            var lostNtfs = discoveredPartitions
                .Where(c => !c.InActivePartitionTable && c.FileSystemType == "NTFS" && c.Confidence >= 95)
                .OrderBy(c => c.StartLba)
                .FirstOrDefault();

            bool noActivePartitions = (!gpt.IsGptCandidate || gpt.ActivePartitions.Count == 0)
                && mbr.Entries.All(e => !e.IsAllocated || e.IsProtectiveGptEntry);

            if (lostNtfs != null && noActivePartitions && totalSectors >= 100)
            {
                Guid diskGuid = gpt.Primary.DiskGuid != Guid.Empty
                    ? gpt.Primary.DiskGuid
                    : (gpt.Backup.DiskGuid != Guid.Empty ? gpt.Backup.DiskGuid : Guid.NewGuid());

                var (primHdr, primHdrOff, primEnt, primEntOff, bakHdr, bakHdrOff, bakEnt, bakEntOff) =
                    GptAnalyzer.BuildGptForDiscoveredPartition(
                        diskGuid,
                        GptAnalyzer.GuidMsftBasicData,
                        Guid.NewGuid(),
                        (ulong)lostNtfs.StartLba,
                        (ulong)lostNtfs.EndLba,
                        "Recovered NTFS Volume",
                        sectorSize,
                        totalSectors);

                byte[] newMbr = MbrAnalyzer.BuildProtectiveMbrSector(totalSectors, sectorSize);
                byte[] curPrimEnt = new byte[primEnt.Length];
                byte[] curBakEnt = new byte[bakEnt.Length];
                try { await source.ReadAtAsync(primEntOff, curPrimEnt, cancellationToken).ConfigureAwait(false); } catch { }
                try { await source.ReadAtAsync(bakEntOff, curBakEnt, cancellationToken).ConfigureAwait(false); } catch { }

                var patches = new List<RepairBytePatch>
                {
                    BuildPatch("Protective MBR (LBA 0)", 0, mbr.RawSector0, newMbr, sectorSize, "Write Protective MBR (0xEE) at LBA 0."),
                    BuildPatch("Primary GPT Header (LBA 1)", primHdrOff, gpt.Primary.RawHeaderSector, primHdr, sectorSize, "Write new Primary GPT Header at LBA 1."),
                    BuildPatch("Primary GPT Entries", primEntOff, curPrimEnt, primEnt, sectorSize, $"Write GPT Partition Entry 0 spanning LBA {lostNtfs.StartLba}..{lostNtfs.EndLba} ({lostNtfs.DisplaySize})."),
                    BuildPatch("Backup GPT Entries", bakEntOff, curBakEnt, bakEnt, sectorSize, "Write matching Backup GPT Partition Entry Array."),
                    BuildPatch($"Backup GPT Header (LBA {bakHdrOff / sectorSize})", bakHdrOff, gpt.Backup.RawHeaderSector, bakHdr, sectorSize, "Write matching Backup GPT Header at end of disk.")
                };

                plans.Add(new VerifiedRepairPlan
                {
                    PlanId = "plan.reconstruct_lost_partition_gpt",
                    Title = $"Reconstruct Missing GPT Partition Entry for Discovered NTFS Volume ({lostNtfs.DisplaySize})",
                    ActionType = "ReconstructGptPartitionEntry",
                    RiskLevel = "Medium",
                    IsExecutable = canExecuteOnTarget,
                    DetectedCondition = $"Partition table has no active entries, but a verified NTFS volume with intact $MFT was discovered at LBA {lostNtfs.StartLba}..{lostNtfs.EndLba}.",
                    WhyOfferedExplanation =
                        $"Although the partition table was wiped or corrupted, CDE discovered an intact NTFS boot sector at LBA {lostNtfs.StartLba} (0x{lostNtfs.StartByteOffset:X}) " +
                        $"with a verified $MFT header. Reconstructing the GPT entry maps LBA {lostNtfs.StartLba}..{lostNtfs.EndLba} without touching any file system sectors.",
                    RecommendedNextStep = "Capture a Metadata Snapshot and apply the GPT partition entry reconstruction.",
                    SourceIdentity = source.Identity,
                    Patches = patches
                });
            }

            return plans;
        }

        private static RepairBytePatch BuildPatch(
            string regionName,
            long offset,
            byte[] originalBytes,
            byte[] replacementBytes,
            int sectorSize,
            string summary)
        {
            byte[] orig = originalBytes.Length == replacementBytes.Length
                ? originalBytes
                : ResizeOrPad(originalBytes, replacementBytes.Length);

            return new RepairBytePatch
            {
                RegionName = regionName,
                TargetByteOffset = offset,
                ByteLength = replacementBytes.Length,
                StartLba = offset / Math.Max(512, sectorSize),
                SectorCount = (replacementBytes.Length + Math.Max(512, sectorSize) - 1) / Math.Max(512, sectorSize),
                ExpectedOriginalBytes = orig,
                ExpectedOriginalSha256 = MetadataSnapshotService.ComputeSha256Hex(orig),
                ReplacementBytes = replacementBytes,
                ReplacementSha256 = MetadataSnapshotService.ComputeSha256Hex(replacementBytes),
                ChangeSummary = summary,
                PreviewHexBefore = MetadataSnapshotService.FormatHexPreview(orig, 48),
                PreviewHexAfter = MetadataSnapshotService.FormatHexPreview(replacementBytes, 48)
            };
        }

        private static byte[] ResizeOrPad(byte[] input, int length)
        {
            byte[] result = new byte[length];
            if (input != null && input.Length > 0)
                Buffer.BlockCopy(input, 0, result, 0, Math.Min(input.Length, length));
            return result;
        }
    }
}
