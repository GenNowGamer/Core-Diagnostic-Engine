using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using CdeRecovery.Core.Devices;
using CdeRecovery.Core.Evidence;
using CdeRecovery.Core.FileSystems;
using CdeRecovery.Core.Imaging;
using CdeRecovery.Core.Models;
using CdeRecovery.Core.Recovery;
using Xunit;

namespace ToolkitGUI.Tests;

public class StorageRecoveryTests : IDisposable
{
    private readonly string _tempDir;

    public StorageRecoveryTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), $"CdeRecoveryTests_{Guid.NewGuid():N}");
        Directory.CreateDirectory(_tempDir);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_tempDir))
                Directory.Delete(_tempDir, recursive: true);
        }
        catch
        {
            // Ignore cleanup locks
        }
    }

    [Theory]
    [InlineData(512)]
    [InlineData(4096)]
    public async Task Healthy10TbSparseGptNtfs_PassesAllChecks_AndNeverModifiesSource(int sectorSize)
    {
        string imgPath = Path.Combine(_tempDir, $"healthy_10tb_{sectorSize}.img");
        const long tenTb = 10L * 1024 * 1024 * 1024 * 1024;
        DiskFixtureBuilder.CreateFixtureImage(imgPath, DiskFixtureScenario.HealthyGptNtfs, tenTb, sectorSize, "Server10TB");

        using var reader = new DiskImageReader(imgPath, sectorSize, sectorSize);
        var assessment = await StorageRecoveryEngine.InspectAsync(reader);

        Assert.Equal("Healthy", assessment.OverallVerdict);
        Assert.True(assessment.Mbr.HasValidSignature);
        Assert.True(assessment.Mbr.HasProtectiveMbr);
        Assert.True(assessment.Gpt.IsGptCandidate);
        Assert.True(assessment.Gpt.Primary.IsStructurallyValid);
        Assert.True(assessment.Gpt.Backup.IsStructurallyValid);
        Assert.True(assessment.Gpt.PrimaryAndBackupConsistent);
        Assert.Single(assessment.FileSystems);
        Assert.Equal("NTFS", assessment.FileSystems[0].DetectedFileSystem);
        Assert.True(assessment.FileSystems[0].PrimaryBootSectorValid);
        Assert.True(assessment.FileSystems[0].BackupBootSectorValid);
        Assert.True(assessment.FileSystems[0].NtfsMftRecord0Valid);
        Assert.Equal("Server10TB", assessment.FileSystems[0].VolumeLabel);
        Assert.Empty(assessment.ProposedRepairs);
    }

    [Fact]
    public async Task Scenario1_10TbDamagedPrimaryGpt_ValidBackupGpt_DiagnosesAndReconstructsCleanly()
    {
        string imgPath = Path.Combine(_tempDir, "damaged_primary_gpt_10tb.img");
        string snapDir = Path.Combine(_tempDir, "snapshots");
        const long tenTb = 10L * 1024 * 1024 * 1024 * 1024;
        DiskFixtureBuilder.CreateFixtureImage(imgPath, DiskFixtureScenario.DamagedPrimaryGpt_ValidBackupGpt, tenTb, 512, "Friend10TB");

        StorageRecoveryAssessment initial;
        using (var reader = new DiskImageReader(imgPath, 512, 512))
        {
            initial = await StorageRecoveryEngine.InspectAsync(reader);
        }

        Assert.False(initial.Gpt.Primary.IsStructurallyValid);
        Assert.True(initial.Gpt.Backup.IsStructurallyValid);
        Assert.Contains(initial.Findings, f => f.FindingId == "gpt.primary_damaged_backup_valid");

        var plan = Assert.Single(initial.ProposedRepairs, p => p.ActionType == "ReconstructPrimaryGpt");
        Assert.True(plan.IsExecutable);

        var executor = new RepairExecutor();
        var repairResult = await executor.ApplyToImageAsync(plan, imgPath, snapDir);
        Assert.True(repairResult.Succeeded);
        Assert.True(repairResult.PostWriteVerificationPassed);
        Assert.True(File.Exists(repairResult.PreRepairSnapshotManifestPath));

        // Re-inspect after repair: must now be 100% Healthy!
        using (var postReader = new DiskImageReader(imgPath, 512, 512))
        {
            var post = await StorageRecoveryEngine.InspectAsync(postReader);
            Assert.Equal("Healthy", post.OverallVerdict);
            Assert.True(post.Gpt.Primary.IsStructurallyValid);
            Assert.True(post.Gpt.Backup.IsStructurallyValid);
            Assert.True(post.Gpt.PrimaryAndBackupConsistent);
            Assert.Empty(post.ProposedRepairs);
        }
    }

    [Fact]
    public async Task Scenario2_10TbDamagedNtfsPrimaryVbr_ValidBackupVbr_DiagnosesAndRestoresBootSector()
    {
        string imgPath = Path.Combine(_tempDir, "damaged_ntfs_vbr_10tb.img");
        string snapDir = Path.Combine(_tempDir, "snapshots_vbr");
        const long tenTb = 10L * 1024 * 1024 * 1024 * 1024;
        DiskFixtureBuilder.CreateFixtureImage(imgPath, DiskFixtureScenario.DamagedNtfsPrimaryVbr_ValidBackupVbr, tenTb, 512, "Friend10TB");

        StorageRecoveryAssessment initial;
        using (var reader = new DiskImageReader(imgPath, 512, 512))
        {
            initial = await StorageRecoveryEngine.InspectAsync(reader);
        }

        // Partition table is healthy, Primary NTFS VBR is damaged, Backup VBR & $MFT are valid
        Assert.True(initial.Gpt.PrimaryAndBackupConsistent);
        var fs = Assert.Single(initial.FileSystems);
        Assert.Equal("NTFS", fs.DetectedFileSystem);
        Assert.False(fs.PrimaryBootSectorValid);
        Assert.True(fs.BackupBootSectorValid);
        Assert.True(fs.NtfsMftRecord0Valid);

        var plan = Assert.Single(initial.ProposedRepairs, p => p.ActionType == "RestoreNtfsBootSector");
        Assert.True(plan.IsExecutable);

        var executor = new RepairExecutor();
        var repairResult = await executor.ApplyToImageAsync(plan, imgPath, snapDir);
        Assert.True(repairResult.Succeeded);
        Assert.True(repairResult.PostWriteVerificationPassed);

        using (var postReader = new DiskImageReader(imgPath, 512, 512))
        {
            var post = await StorageRecoveryEngine.InspectAsync(postReader);
            Assert.Equal("Healthy", post.OverallVerdict);
            Assert.True(post.FileSystems[0].PrimaryBootSectorValid);
        }
    }

    [Fact]
    public async Task Scenario3_SeverelyDamagedMft_RecommendsFileExtractionInsteadOfInPlaceRepair()
    {
        string imgPath = Path.Combine(_tempDir, "damaged_mft.img");
        DiskFixtureBuilder.CreateFixtureImage(imgPath, DiskFixtureScenario.SeverelyDamagedNtfsMft, 64L * 1024 * 1024, 512);

        using var reader = new DiskImageReader(imgPath, 512, 512);
        var assessment = await StorageRecoveryEngine.InspectAsync(reader);

        Assert.Equal("Critical Damage — Extract Files", assessment.OverallVerdict);
        var guidancePlan = Assert.Single(assessment.ProposedRepairs, p => p.ActionType == "GuidanceFileExtraction");
        Assert.False(guidancePlan.IsExecutable);
    }

    [Fact]
    public async Task WipedPartitionTable_DiscoversLostNtfsVolume_AndReconstructsGpt()
    {
        string imgPath = Path.Combine(_tempDir, "wiped_pt.img");
        string snapDir = Path.Combine(_tempDir, "snapshots_lost");
        DiskFixtureBuilder.CreateFixtureImage(imgPath, DiskFixtureScenario.WipedPartitionTable_LostNtfsPartition, 64L * 1024 * 1024, 512);

        StorageRecoveryAssessment initial;
        using (var reader = new DiskImageReader(imgPath, 512, 512))
        {
            initial = await StorageRecoveryEngine.InspectAsync(reader);
        }

        Assert.Contains(initial.DiscoveredPartitions, d => !d.InActivePartitionTable && d.FileSystemType == "NTFS");
        var plan = Assert.Single(initial.ProposedRepairs, p => p.ActionType == "ReconstructGptPartitionEntry");
        Assert.True(plan.IsExecutable);

        var executor = new RepairExecutor();
        var res = await executor.ApplyToImageAsync(plan, imgPath, snapDir);
        Assert.True(res.Succeeded);

        using (var postReader = new DiskImageReader(imgPath, 512, 512))
        {
            var post = await StorageRecoveryEngine.InspectAsync(postReader);
            Assert.Equal("Healthy", post.OverallVerdict);
            Assert.Single(post.Gpt.ActivePartitions);
        }
    }

    [Fact]
    public async Task BenchLab_S20_And_S21_DetectedAndRepaired()
    {
        string s20Path = Path.Combine(_tempDir, "s20.img");
        string s21Path = Path.Combine(_tempDir, "s21.img");
        DiskFixtureBuilder.CreateFixtureImage(s20Path, DiskFixtureScenario.MalformedMbrSignature_S20, 64L * 1024 * 1024, 512);
        DiskFixtureBuilder.CreateFixtureImage(s21Path, DiskFixtureScenario.ProtectiveMbrMismatch_S21, 64L * 1024 * 1024, 512);

        using (var r20 = new DiskImageReader(s20Path, 512, 512))
        {
            var a20 = await StorageRecoveryEngine.InspectAsync(r20);
            Assert.Contains(a20.Findings, f => f.FindingId == "mbr.signature_invalid");
            Assert.Contains(a20.ProposedRepairs, p => p.ActionType == "RestoreProtectiveMbr");
        }

        using (var r21 = new DiskImageReader(s21Path, 512, 512))
        {
            var a21 = await StorageRecoveryEngine.InspectAsync(r21);
            Assert.Contains(a21.Findings, f => f.FindingId == "mbr.protective_mismatch");
            Assert.Contains(a21.ProposedRepairs, p => p.ActionType == "RestoreProtectiveMbr");
        }
    }

    [Fact]
    public async Task BitLockerVolume_IsDetectedAndBlocksAutomaticBootSectorWrites()
    {
        string imgPath = Path.Combine(_tempDir, "bitlocker.img");
        DiskFixtureBuilder.CreateFixtureImage(imgPath, DiskFixtureScenario.BitLockerEncryptedPartition, 64L * 1024 * 1024, 512);

        using var reader = new DiskImageReader(imgPath, 512, 512);
        var assessment = await StorageRecoveryEngine.InspectAsync(reader);

        var fs = Assert.Single(assessment.FileSystems);
        Assert.Equal("BitLocker", fs.DetectedFileSystem);
        Assert.True(fs.IsEncryptedBitLocker);
        Assert.Empty(assessment.ProposedRepairs);
    }

    [Fact]
    public async Task HardwareReadError_Or_SmartCritical_BlocksAllRepairPlans()
    {
        string imgPath = Path.Combine(_tempDir, "bad_sector.img");
        DiskFixtureBuilder.CreateFixtureImage(imgPath, DiskFixtureScenario.DamagedPrimaryGpt_ValidBackupGpt, 64L * 1024 * 1024, 512);

        using var reader = new DiskImageReader(imgPath, 512, 512, smartHealthStatus: "Critical");
        reader.AddSimulatedErrorRange(512, 512, "Simulated physical sector CRC failure at LBA 1");
        var assessment = await StorageRecoveryEngine.InspectAsync(reader);

        Assert.NotEmpty(assessment.ReadErrors);
        var stopPlan = Assert.Single(assessment.ProposedRepairs);
        Assert.Equal("SafetyStop", stopPlan.ActionType);
        Assert.False(stopPlan.IsExecutable);
    }

    [Fact]
    public async Task StaleRepairPlan_IsRejectedWhenTargetBytesChangeAfterScan()
    {
        string imgPath = Path.Combine(_tempDir, "stale_test.img");
        string snapDir = Path.Combine(_tempDir, "snapshots_stale");
        DiskFixtureBuilder.CreateFixtureImage(imgPath, DiskFixtureScenario.DamagedPrimaryGpt_ValidBackupGpt, 64L * 1024 * 1024, 512);

        VerifiedRepairPlan plan;
        using (var reader = new DiskImageReader(imgPath, 512, 512))
        {
            var assessment = await StorageRecoveryEngine.InspectAsync(reader);
            plan = assessment.ProposedRepairs.First(p => p.IsExecutable);
        }

        // Mutate LBA 1 after scan so plan becomes stale
        await using (var fs = new FileStream(imgPath, FileMode.Open, FileAccess.ReadWrite, FileShare.Read))
        {
            fs.Seek(512, SeekOrigin.Begin);
            fs.WriteByte(0xAB);
        }

        var executor = new RepairExecutor();
        var result = await executor.ApplyToImageAsync(plan, imgPath, snapDir);
        Assert.False(result.Succeeded);
        Assert.Contains("Stale repair plan rejected", result.SummaryMessage);
    }

    // ═══ RELEASE 4 TESTS: NTFS FILE RECOVERY & RESUMABLE IMAGING ═══

    [Fact]
    public void Release4_UsaMultiSectorFixup_ValidatesAndRestoresSectorTails_AndFlagsTornWrites()
    {
        byte[] rec = DiskFixtureBuilder.BuildUserFileMftRecord(
            fileName: "fixup_test.txt",
            parentRecordNumber: 5,
            isDirectory: false,
            isDeleted: false,
            residentData: Encoding.UTF8.GetBytes("Fixup verification payload"),
            nonResidentRunlist: null,
            realFileSize: 26,
            usnValue: 0xBEEF);

        // Verify USN 0xBEEF is stamped at sector tails 510 and 1022
        Assert.Equal(0xEF, rec[510]);
        Assert.Equal(0xBE, rec[511]);

        byte[] cleanCopy = (byte[])rec.Clone();
        Assert.True(NtfsMftRecordParser.ApplyMultiSectorFixup(cleanCopy, out bool tornClean));
        Assert.False(tornClean);
        Assert.Equal(0, cleanCopy[510]);
        Assert.Equal(0, cleanCopy[511]);

        // Corrupt sector 1 tail to simulate a torn write
        byte[] tornCopy = (byte[])rec.Clone();
        tornCopy[1022] = 0xFF;
        Assert.True(NtfsMftRecordParser.ApplyMultiSectorFixup(tornCopy, out bool tornFlag));
        Assert.True(tornFlag);
    }

    [Fact]
    public void Release4_RunlistDecoder_HandlesFragmentedSignedDeltas_AndSparseRuns()
    {
        // Run 1: 0x11 -> len=4 clusters, LCN=+100 (0x64)
        // Run 2: 0x11 -> len=2 clusters, LCN delta=-20 (0xEC in signed 8-bit two's complement -> LCN 80)
        // Run 3: 0x01 -> len=3 clusters, offsetSize=0 (Sparse run!)
        // End: 0x00
        byte[] runlist = new byte[] { 0x11, 0x04, 0x64, 0x11, 0x02, 0xEC, 0x01, 0x03, 0x00 };

        var runs = NtfsMftRecordParser.DecodeDataRuns(runlist);
        Assert.Equal(3, runs.Count);

        Assert.Equal(0, runs[0].VcnStart);
        Assert.Equal(4, runs[0].ClusterCount);
        Assert.Equal(100, runs[0].LcnStart);
        Assert.False(runs[0].IsSparse);

        Assert.Equal(4, runs[1].VcnStart);
        Assert.Equal(2, runs[1].ClusterCount);
        Assert.Equal(80, runs[1].LcnStart);
        Assert.False(runs[1].IsSparse);

        Assert.Equal(6, runs[2].VcnStart);
        Assert.Equal(3, runs[2].ClusterCount);
        Assert.Equal(-1, runs[2].LcnStart);
        Assert.True(runs[2].IsSparse);
    }

    [Fact]
    public async Task Release4_NtfsFileRecovery_FromRawDamagedVbrVolume_RecoversResidentContiguousFragmentedAndSubfolderFiles()
    {
        string imgPath = Path.Combine(_tempDir, "raw_vbr_recovery.img");
        string exportDir = Path.Combine(_tempDir, "exported_files");

        // Create a volume where Primary NTFS VBR is wiped (RAW in Windows), Backup VBR & $MFT are intact
        DiskFixtureBuilder.CreateFixtureImage(
            imgPath,
            DiskFixtureScenario.DamagedNtfsPrimaryVbr_ValidBackupVbr,
            64L * 1024 * 1024,
            512,
            "RawRecoveryTest");

        using var reader = new DiskImageReader(imgPath, 512, 512);
        var assessment = await StorageRecoveryEngine.InspectAsync(reader);
        var part = Assert.Single(assessment.FileSystems);
        Assert.False(part.PrimaryBootSectorValid);
        Assert.True(part.BackupBootSectorValid);

        // Scan $MFT (excluding deleted files first)
        var activeFiles = await NtfsFileRecoveryEngine.ScanRecoverableFilesAsync(reader, part, includeDeleted: false);
        Assert.Equal(4, activeFiles.Count);
        Assert.Contains(activeFiles, f => f.ReconstructedPath == "readme.txt" && f.IsResident);
        Assert.Contains(activeFiles, f => f.ReconstructedPath == "report.csv" && !f.IsResident && !f.IsFragmented);
        Assert.Contains(activeFiles, f => f.ReconstructedPath == "archive.bin" && f.IsFragmented && f.DataRuns.Count == 2);
        Assert.Contains(activeFiles, f => f.ReconstructedPath == Path.Combine("Documents", "invoice.pdf"));

        // Export all 4 active files and verify their exact contents & manifest
        var manifest = await FileExportEngine.ExportFilesAsync(reader, activeFiles, exportDir);
        Assert.Equal(4, manifest.VerifiedFilesCount);
        Assert.Equal(0, manifest.PartialFilesCount);
        Assert.Equal(0, manifest.FailedFilesCount);
        Assert.True(File.Exists(manifest.ManifestFilePath));

        Assert.Equal(
            "Hello from CDE resident NTFS file recovery!",
            await File.ReadAllTextAsync(Path.Combine(exportDir, "readme.txt")));

        Assert.Equal(
            "ID,Name,Status\n1,Drive10TB,Recovered\n2,Partition,Intact\n",
            await File.ReadAllTextAsync(Path.Combine(exportDir, "report.csv")));

        Assert.Equal(
            "%PDF-1.7 CDE Recovered Invoice #2026",
            await File.ReadAllTextAsync(Path.Combine(exportDir, "Documents", "invoice.pdf")));

        // Verify fragmented 2-run file (4096 bytes of 0xA5 followed by 512 bytes of 0x5A)
        byte[] fragExported = await File.ReadAllBytesAsync(Path.Combine(exportDir, "archive.bin"));
        Assert.Equal(4096 + 512, fragExported.Length);
        Assert.All(fragExported.Take(4096), b => Assert.Equal(0xA5, b));
        Assert.All(fragExported.Skip(4096), b => Assert.Equal(0x5A, b));
    }

    [Fact]
    public async Task Release4_NtfsFileRecovery_IncludeDeletedToggle_RecoversDeletedFiles()
    {
        string imgPath = Path.Combine(_tempDir, "deleted_recovery.img");
        DiskFixtureBuilder.CreateFixtureImage(imgPath, DiskFixtureScenario.HealthyGptNtfs, 64L * 1024 * 1024, 512);

        using var reader = new DiskImageReader(imgPath, 512, 512);
        var assessment = await StorageRecoveryEngine.InspectAsync(reader);
        var part = Assert.Single(assessment.FileSystems);

        var withDeleted = await NtfsFileRecoveryEngine.ScanRecoverableFilesAsync(reader, part, includeDeleted: true);
        Assert.Equal(5, withDeleted.Count);
        var delFile = Assert.Single(withDeleted, f => f.FileName == "deleted_notes.txt");
        Assert.True(delFile.IsDeleted);

        string exportDir = Path.Combine(_tempDir, "exported_deleted");
        var manifest = await FileExportEngine.ExportFilesAsync(reader, new[] { delFile }, exportDir);
        Assert.Equal(1, manifest.VerifiedFilesCount);
        Assert.Equal("Recovered deleted note content!", await File.ReadAllTextAsync(Path.Combine(exportDir, "deleted_notes.txt")));
    }

    [Fact]
    public async Task Release4_FileExport_GracefullyHandlesBadSectorInFile_ZeroFillsAndMarksPartialInManifest()
    {
        string imgPath = Path.Combine(_tempDir, "partial_bad_sector.img");
        string exportDir = Path.Combine(_tempDir, "exported_partial");
        DiskFixtureBuilder.CreateFixtureImage(imgPath, DiskFixtureScenario.HealthyGptNtfs, 64L * 1024 * 1024, 512);

        using var reader = new DiskImageReader(imgPath, 512, 512);
        var assessment = await StorageRecoveryEngine.InspectAsync(reader);
        var part = Assert.Single(assessment.FileSystems);
        var files = await NtfsFileRecoveryEngine.ScanRecoverableFilesAsync(reader, part, includeDeleted: false);
        var fragFile = files.First(f => f.FileName == "archive.bin");

        // Inject a bad sector in Run 2 (LCN 64) of archive.bin while Run 1 (LCN 48) stays readable
        long badOffset = part.PartitionStartOffset + (64L * 4096);
        reader.AddSimulatedErrorRange(badOffset, 512, "Simulated bad sector in fragment 2");

        var manifest = await FileExportEngine.ExportFilesAsync(reader, new[] { fragFile }, exportDir);
        Assert.Equal(0, manifest.VerifiedFilesCount);
        Assert.Equal(1, manifest.PartialFilesCount);

        var itemResult = Assert.Single(manifest.Results);
        Assert.Equal("Partial (Unreadable Sectors)", itemResult.Status);
        Assert.Equal(1, itemResult.UnreadableSectorCount);

        // Run 1 (first 4096 bytes) must still be intact (0xA5), and only the bad sector (last 512 bytes) is zero-filled!
        byte[] exportedBytes = await File.ReadAllBytesAsync(itemResult.DestinationFullPath);
        Assert.Equal(4096 + 512, exportedBytes.Length);
        Assert.All(exportedBytes.Take(4096), b => Assert.Equal(0xA5, b));
        Assert.All(exportedBytes.Skip(4096), b => Assert.Equal(0x00, b));
    }

    [Fact]
    public async Task Release4_ImagingJobEngine_CopiesHealthyBlocks_SkipsAndScrapesBadSectors_AndResumesFromMapfile()
    {
        string srcImgPath = Path.Combine(_tempDir, "source_disk.img");
        string dstImgPath = Path.Combine(_tempDir, "cloned_disk.img");
        DiskFixtureBuilder.CreateFixtureImage(srcImgPath, DiskFixtureScenario.HealthyGptNtfs, 8L * 1024 * 1024, 512, "ImagingTest");

        // Simulate a 4096-byte bad sector at offset 512 KiB (0x80000)
        using var reader = new DiskImageReader(srcImgPath, 512, 512);
        reader.AddSimulatedErrorRange(512 * 1024, 4096, "Simulated bad 4K sector at 512 KiB");

        // 1. Run Phase 1 only (scrapeFailedBlocks: false) first
        var phase1Manifest = await ImagingJobEngine.RunOrResumeImagingJobAsync(
            reader,
            dstImgPath,
            sourceStartOffset: 0,
            lengthBytes: 2 * 1024 * 1024, // Image first 2 MiB
            scrapeFailedBlocks: false,
            useSparseOutput: false,
            copyBlockSizeBytes: 256 * 1024);

        Assert.Equal("Completed", phase1Manifest.CurrentPhase);
        // 1 block of 256 KiB failed in Phase 1, 7 blocks of 256 KiB succeeded
        Assert.Equal(7 * 256 * 1024, phase1Manifest.BytesRescued);
        Assert.Equal(256 * 1024, phase1Manifest.BytesBad);
        Assert.True(File.Exists(phase1Manifest.MapFilePath));

        // 2. Resume from .cdemap with scrapeFailedBlocks: true -> Phase 2 salvages 252 KiB of the 256 KiB failed block, leaving only the 4 KiB bad sector!
        var phase2Manifest = await ImagingJobEngine.RunOrResumeImagingJobAsync(
            reader,
            dstImgPath,
            sourceStartOffset: 0,
            lengthBytes: 2 * 1024 * 1024,
            scrapeFailedBlocks: true,
            useSparseOutput: false,
            copyBlockSizeBytes: 256 * 1024);

        Assert.Equal("Completed", phase2Manifest.CurrentPhase);
        Assert.Equal((2 * 1024 * 1024) - 4096, phase2Manifest.BytesRescued);
        Assert.Equal(4096, phase2Manifest.BytesBad);
    }
}
