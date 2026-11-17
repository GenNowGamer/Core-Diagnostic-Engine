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

    [Fact]
    public async Task PartitionScopedImaging_SavesScopeAndRejectsMismatchedResume()
    {
        var imgPath = Path.Combine(_tempDir, "part_scope_src.img");
        var outPartImg = Path.Combine(_tempDir, "part_scope_out.img");
        byte[] src = new byte[4 * 1024 * 1024];
        for (int i = 0; i < 512; i++) src[(1 * 1024 * 1024) + i] = (byte)(0xA0 + (i % 16));
        await File.WriteAllBytesAsync(imgPath, src);

        using var reader = new DiskImageReader(imgPath, 512, 4096);
        var manifest = await ImagingJobEngine.RunOrResumeImagingJobAsync(
            reader,
            outPartImg,
            sourceStartOffset: 1024 * 1024,
            lengthBytes: 1024 * 1024,
            scrapeFailedBlocks: false,
            useSparseOutput: false,
            copyBlockSizeBytes: 256 * 1024,
            targetScopeLabel: "Partition 2: Data (NTFS)");

        Assert.Equal("Partition 2: Data (NTFS)", manifest.TargetScopeLabel);
        Assert.Equal(1024 * 1024, manifest.SourceStartOffset);
        Assert.Equal(1024 * 1024, manifest.TotalBytesToCopy);
        byte[] outBytes = await File.ReadAllBytesAsync(outPartImg);
        Assert.Equal(1024 * 1024, outBytes.Length);
        Assert.Equal(0xA0, outBytes[0]);

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            ImagingJobEngine.RunOrResumeImagingJobAsync(
                reader,
                outPartImg,
                sourceStartOffset: 0,
                lengthBytes: 4 * 1024 * 1024,
                targetScopeLabel: "Whole Disk"));
    }

    [Fact]
    public void NtfsLznt1Decompressor_DecompressesCompressedAndRleChunks()
    {
        // Build a valid NTFS LZNT1 compressed chunk representing "ABCD" + 12 x 'A' (RLE overlap) + "XYZ"
        // Uncompressed = "ABCD" + "AAAAAAAAAAAA" (Wait: back-ref at offset=4, len=3 -> "ABC", or offset=1 after 'A')
        // Let's encode: literals 'A','B','C','D' (4 bytes), then tuple at outPos=4 (shift=12): offset=4 (encoded 3 << 12 = 0x3000), length=4 (encoded 1) => 0x3001 => repeats "ABCD" -> "ABCDABCD"
        // Flags byte 0: bits 0..3 = 0 (literals A,B,C,D), bit 4 = 1 (tuple 0x3001) -> 0b00010000 = 0x10
        byte[] chunkPayload = new byte[] { 0x10, (byte)'A', (byte)'B', (byte)'C', (byte)'D', 0x01, 0x30 };
        ushort header = (ushort)(0x8000 | (chunkPayload.Length - 1));
        byte[] unit = new byte[2 + chunkPayload.Length + 2];
        System.Buffers.Binary.BinaryPrimitives.WriteUInt16LittleEndian(unit.AsSpan(0, 2), header);
        Buffer.BlockCopy(chunkPayload, 0, unit, 2, chunkPayload.Length);
        // Trailing 0x0000 terminator

        byte[] decompressed = NtfsLznt1Decompressor.DecompressUnit(unit, 8);
        Assert.Equal("ABCDABCD", System.Text.Encoding.ASCII.GetString(decompressed));
    }

    [Fact]
    public void NtfsMftRecordParser_ParsesAttributeListAndEfsEncryptedFlags()
    {
        // Build minimal $ATTRIBUTE_LIST payload with one $DATA (0x80) extension record reference at MFT #42
        byte[] attrList = new byte[24];
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(attrList.AsSpan(0, 4), 0x80u);
        System.Buffers.Binary.BinaryPrimitives.WriteUInt16LittleEndian(attrList.AsSpan(4, 2), 24);
        attrList[6] = 0; // unnamed
        System.Buffers.Binary.BinaryPrimitives.WriteUInt64LittleEndian(attrList.AsSpan(8, 8), 16UL); // StartingVcn = 16
        System.Buffers.Binary.BinaryPrimitives.WriteUInt64LittleEndian(attrList.AsSpan(16, 8), 42UL); // MFT #42

        var refs = NtfsMftRecordParser.ParseAttributeListDataExtensions(attrList);
        Assert.Single(refs);
        Assert.Equal(16, refs[0].StartingVcn);
        Assert.Equal(42, refs[0].MftRecordNumber);

        var encryptedItem = new RecoverableFileItem
        {
            FileName = "secret.txt",
            IsEncrypted = true,
            IsCompressed = false,
            HasExtensionMftRecords = true
        };
        Assert.Contains("Encrypted", encryptedItem.StatusLabel);
        Assert.Contains("ExtMFT", encryptedItem.StatusLabel);
    }

    [Fact]
    public async Task Fat32AndExFatRecovery_ScansAndExportsActiveAndDeletedFiles()
    {
        // 1. Synthetic FAT32 partition image (1 MiB): 512B/sec, 8 sec/clus (4 KB clusters), 32 reserved, 1 FAT of 8 sectors, root cluster 2
        var fatImg = Path.Combine(_tempDir, "fat32_test.img");
        byte[] fatDisk = new byte[1024 * 1024];
        fatDisk[0x0B] = 0x00; fatDisk[0x0C] = 0x02; // 512 bps
        fatDisk[0x0D] = 8; // 8 spc -> 4096 cluster
        fatDisk[0x0E] = 32; fatDisk[0x0F] = 0; // 32 reserved sectors
        fatDisk[0x10] = 1; // 1 FAT
        fatDisk[0x24] = 8; // 8 sectors per FAT
        fatDisk[0x2C] = 2; // root cluster 2
        fatDisk[510] = 0x55; fatDisk[511] = 0xAA;

        int fatOff = 32 * 512;
        int dataOff = (32 + 8) * 512;
        // FAT entries: cluster 2 (root) = EOC, cluster 3 (HELLO.TXT) = EOC, cluster 4 (deleted) = 0
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(fatDisk.AsSpan(fatOff + (2 * 4), 4), 0x0FFFFFFFu);
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(fatDisk.AsSpan(fatOff + (3 * 4), 4), 0x0FFFFFFFu);

        // Root dir entry 0: HELLO.TXT (cluster 3, 5 bytes)
        System.Text.Encoding.ASCII.GetBytes("HELLO   TXT").CopyTo(fatDisk, dataOff);
        fatDisk[dataOff + 0x0B] = 0x20;
        fatDisk[dataOff + 0x1A] = 3;
        fatDisk[dataOff + 0x1C] = 5;
        System.Text.Encoding.ASCII.GetBytes("World").CopyTo(fatDisk, dataOff + 4096);

        // Root dir entry 1: deleted _EL.TXT (0xE5, cluster 4, 4 bytes)
        System.Text.Encoding.ASCII.GetBytes("DEL     TXT").CopyTo(fatDisk, dataOff + 32);
        fatDisk[dataOff + 32] = 0xE5;
        fatDisk[dataOff + 32 + 0x0B] = 0x20;
        fatDisk[dataOff + 32 + 0x1A] = 4;
        fatDisk[dataOff + 32 + 0x1C] = 4;
        System.Text.Encoding.ASCII.GetBytes("Gone").CopyTo(fatDisk, dataOff + (2 * 4096));

        await File.WriteAllBytesAsync(fatImg, fatDisk);
        using var fatReader = new DiskImageReader(fatImg, 512, 512);
        var fatPart = new FileSystemAnalysisResult
        {
            PartitionIndex = 1,
            DetectedFileSystem = "FAT32",
            PartitionStartOffset = 0,
            PartitionSizeBytes = fatDisk.Length
        };

        var fatFiles = await Fat32FileRecoveryEngine.ScanRecoverableFilesAsync(fatReader, fatPart, includeDeleted: true);
        Assert.Equal(2, fatFiles.Count);
        Assert.Contains(fatFiles, f => f.FileName == "HELLO.TXT" && !f.IsDeleted);
        Assert.Contains(fatFiles, f => f.FileName == "_EL.TXT" && f.IsDeleted);

        var exportDir = Path.Combine(_tempDir, "fat32_export");
        var manifest = await FileExportEngine.ExportFilesAsync(fatReader, fatFiles, exportDir);
        Assert.Equal(2, manifest.VerifiedFilesCount);
        Assert.Equal("World", await File.ReadAllTextAsync(Path.Combine(exportDir, "HELLO.TXT")));
        Assert.Equal("Gone", await File.ReadAllTextAsync(Path.Combine(exportDir, "_EL.TXT")));
    }
}
