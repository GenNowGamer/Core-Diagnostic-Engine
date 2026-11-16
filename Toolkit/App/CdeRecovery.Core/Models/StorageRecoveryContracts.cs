using System;
using System.Collections.Generic;
using CdeRecovery.Core.Devices;

namespace CdeRecovery.Core.Models
{
    public static class RecoveryClassification
    {
        public const string ConfirmedFault = "Confirmed fault";
        public const string CorroboratedSuspect = "Corroborated suspect";
        public const string SingleSignal = "Single signal";
        public const string HeuristicCandidate = "Heuristic candidate";
        public const string VerifiedIntact = "Verified intact";
        public const string SafetyBlock = "Safety block";
    }

    public sealed class StorageDiagnosticFinding
    {
        public string FindingId { get; init; } = string.Empty;
        public string Category { get; init; } = string.Empty; // Hardware, MBR, GPT, FileSystem, Discovery, Safety
        public string Title { get; init; } = string.Empty;
        public string Status { get; init; } = "Info"; // Pass, Warn, Fail, Info
        public string Severity { get; init; } = "Info"; // Info, Low, Medium, High, Critical
        public int Confidence { get; init; } = 100;
        public string Classification { get; init; } = RecoveryClassification.VerifiedIntact;
        public string EvidenceSummary { get; init; } = string.Empty;
        public long ByteOffset { get; init; }
        public int ByteLength { get; init; }
        public string Recommendation { get; init; } = string.Empty;
    }

    public sealed class MbrPartitionEntry
    {
        public int SlotIndex { get; init; } // 0..3
        public byte BootIndicator { get; init; }
        public byte PartitionType { get; init; }
        public string PartitionTypeName { get; init; } = string.Empty;
        public uint StartLba { get; init; }
        public uint SectorCount { get; init; }
        public long StartByteOffset { get; init; }
        public long SizeBytes { get; init; }
        public bool IsAllocated => PartitionType != 0 && SectorCount > 0;
        public bool IsProtectiveGptEntry => PartitionType == 0xEE;
        public bool OutOfBounds { get; init; }
    }

    public sealed class MbrAnalysisResult
    {
        public bool SectorReadSucceeded { get; init; }
        public ushort Signature { get; init; }
        public bool HasValidSignature => Signature == 0xAA55;
        public uint DiskSignature { get; init; }
        public bool HasProtectiveMbr { get; init; }
        public bool HasProtectiveMbrMismatch { get; init; }
        public string ProtectiveMbrNote { get; init; } = string.Empty;
        public bool HasOverlappingEntries { get; init; }
        public bool HasOutOfBoundsEntries { get; init; }
        public byte[] RawSector0 { get; init; } = Array.Empty<byte>();
        public List<MbrPartitionEntry> Entries { get; init; } = new();
    }

    public sealed class GptHeaderInfo
    {
        public string CopyName { get; init; } = "Primary"; // Primary or Backup
        public long HeaderLba { get; init; }
        public long HeaderByteOffset { get; init; }
        public bool SectorReadSucceeded { get; init; }
        public string SignatureText { get; init; } = string.Empty;
        public bool HasValidSignature { get; init; }
        public uint Revision { get; init; }
        public uint HeaderSize { get; init; }
        public uint StoredHeaderCrc32 { get; init; }
        public uint ComputedHeaderCrc32 { get; init; }
        public bool HeaderCrcValid => HasValidSignature && StoredHeaderCrc32 == ComputedHeaderCrc32;
        public ulong MyLba { get; init; }
        public ulong AlternateLba { get; init; }
        public ulong FirstUsableLba { get; init; }
        public ulong LastUsableLba { get; init; }
        public Guid DiskGuid { get; init; }
        public ulong PartitionEntryLba { get; init; }
        public uint NumberOfPartitionEntries { get; init; }
        public uint SizeOfPartitionEntry { get; init; }
        public uint StoredEntriesCrc32 { get; init; }
        public uint ComputedEntriesCrc32 { get; init; }
        public bool EntriesCrcValid { get; init; }
        public bool BoundsValid { get; init; }
        public bool IsStructurallyValid => HasValidSignature && HeaderCrcValid && EntriesCrcValid && BoundsValid;
        public byte[] RawHeaderSector { get; init; } = Array.Empty<byte>();
        public byte[] RawEntriesBytes { get; init; } = Array.Empty<byte>();
    }

    public sealed class GptPartitionEntry
    {
        public int EntryIndex { get; init; }
        public Guid PartitionTypeGuid { get; init; }
        public string PartitionTypeName { get; init; } = string.Empty;
        public Guid UniquePartitionGuid { get; init; }
        public ulong FirstLba { get; init; }
        public ulong LastLba { get; init; }
        public ulong Attributes { get; init; }
        public string Name { get; init; } = string.Empty;
        public long StartByteOffset { get; init; }
        public long SizeBytes { get; init; }
        public bool OutOfBounds { get; init; }

        public string DisplaySize
        {
            get
            {
                double tb = SizeBytes / (1024.0 * 1024.0 * 1024.0 * 1024.0);
                if (tb >= 0.95) return $"{tb:0.##} TB";
                double gb = SizeBytes / (1024.0 * 1024.0 * 1024.0);
                if (gb >= 1.0) return $"{gb:0.##} GB";
                double mb = SizeBytes / (1024.0 * 1024.0);
                return $"{mb:0.#} MB";
            }
        }
    }

    public sealed class GptAnalysisResult
    {
        public bool IsGptCandidate { get; init; }
        public GptHeaderInfo Primary { get; init; } = new() { CopyName = "Primary" };
        public GptHeaderInfo Backup { get; init; } = new() { CopyName = "Backup" };
        public bool PrimaryAndBackupConsistent { get; init; }
        public bool HasOverlappingPartitions { get; init; }
        public List<GptPartitionEntry> ActivePartitions { get; init; } = new();
        public string SummaryStatus { get; init; } = "Not GPT";
    }

    public sealed class FileSystemAnalysisResult
    {
        public int PartitionIndex { get; init; }
        public string PartitionName { get; init; } = string.Empty;
        public long PartitionStartOffset { get; init; }
        public long PartitionSizeBytes { get; init; }
        public long StartLba { get; init; }
        public long EndLba { get; init; }
        public string DetectedFileSystem { get; init; } = "RAW / Unknown"; // NTFS, exFAT, FAT32, ext4, BitLocker, RAW
        public bool IsEncryptedBitLocker { get; init; }
        public bool PrimaryBootSectorValid { get; init; }
        public bool BackupBootSectorValid { get; init; }
        public long BackupBootSectorOffset { get; init; }
        public int BytesPerSector { get; init; }
        public int SectorsPerCluster { get; init; }
        public long TotalSectors { get; init; }
        public string VolumeSerialOrUuid { get; init; } = string.Empty;
        public string VolumeLabel { get; init; } = string.Empty;

        // NTFS specific
        public long NtfsMftCluster { get; init; }
        public long NtfsMftMirrorCluster { get; init; }
        public long NtfsMftByteOffset { get; init; }
        public long NtfsMftMirrorByteOffset { get; init; }
        public bool NtfsMftRecord0Valid { get; init; }
        public bool NtfsMftMirrorRecord0Valid { get; init; }
        public int NtfsFileRecordSizeBytes { get; init; }

        // exFAT / FAT32 / ext4 checksum & superblock notes
        public bool MetadataChecksumValid { get; init; }
        public string HealthStatus { get; init; } = "Unknown"; // Healthy, Degraded, Damaged, Encrypted, Unformatted
        public string DiagnosticSummary { get; init; } = string.Empty;

        public byte[] RawPrimaryBootSector { get; init; } = Array.Empty<byte>();
        public byte[] RawBackupBootSector { get; init; } = Array.Empty<byte>();
    }

    public sealed class DiscoveredPartitionCandidate
    {
        public long StartByteOffset { get; init; }
        public long SizeBytes { get; init; }
        public long StartLba { get; init; }
        public long EndLba { get; init; }
        public string FileSystemType { get; init; } = string.Empty;
        public string Source { get; init; } = string.Empty; // GPT Primary, GPT Backup, MBR, Signature Scan (VBR), Backup VBR
        public int Confidence { get; init; }
        public bool InActivePartitionTable { get; init; }
        public string Description { get; init; } = string.Empty;
        public Guid SuggestedGptTypeGuid { get; init; }

        public string DisplaySize
        {
            get
            {
                double tb = SizeBytes / (1024.0 * 1024.0 * 1024.0 * 1024.0);
                if (tb >= 0.95) return $"{tb:0.##} TB";
                double gb = SizeBytes / (1024.0 * 1024.0 * 1024.0);
                if (gb >= 1.0) return $"{gb:0.##} GB";
                double mb = SizeBytes / (1024.0 * 1024.0);
                return $"{mb:0.#} MB";
            }
        }
    }

    public sealed class RepairBytePatch
    {
        public string RegionName { get; init; } = string.Empty;
        public long TargetByteOffset { get; init; }
        public int ByteLength { get; init; }
        public long StartLba { get; init; }
        public long SectorCount { get; init; }
        public string ExpectedOriginalSha256 { get; init; } = string.Empty;
        public string ReplacementSha256 { get; init; } = string.Empty;
        public byte[] ExpectedOriginalBytes { get; init; } = Array.Empty<byte>();
        public byte[] ReplacementBytes { get; init; } = Array.Empty<byte>();
        public string ChangeSummary { get; init; } = string.Empty;
        public string PreviewHexBefore { get; init; } = string.Empty;
        public string PreviewHexAfter { get; init; } = string.Empty;
    }

    public sealed class VerifiedRepairPlan
    {
        public string PlanId { get; init; } = string.Empty;
        public string Title { get; init; } = string.Empty;
        public string ActionType { get; init; } = string.Empty; // ReconstructPrimaryGpt, ReconstructBackupGpt, RestoreProtectiveMbr, RestoreNtfsBootSector, ReconstructGptPartitionEntry
        public string RiskLevel { get; init; } = "Medium"; // Low, Medium, High, Blocked
        public bool IsExecutable { get; init; }
        public string DetectedCondition { get; init; } = string.Empty;
        public string WhyOfferedExplanation { get; init; } = string.Empty;
        public string RecommendedNextStep { get; init; } = string.Empty;
        public StorageDeviceIdentity SourceIdentity { get; init; } = new();
        public DateTime CreatedAtUtc { get; init; } = DateTime.UtcNow;
        public List<RepairBytePatch> Patches { get; init; } = new();
    }

    public sealed class PhysicalDiskRepairAuthorization
    {
        public bool OperatorConfirmedInPlaceWrite { get; init; }
        public string MandatorySnapshotDirectory { get; init; } = string.Empty;
        public string OperatorConfirmationPhrase { get; init; } = string.Empty;
        public string ReasonForInPlaceRepair { get; init; } = "No spare drive of equal capacity available for full disk clone.";
    }

    public sealed class RepairResult
    {
        public bool Succeeded { get; init; }
        public string PlanId { get; init; } = string.Empty;
        public string TargetDescription { get; init; } = string.Empty;
        public bool WasPhysicalDiskInPlace { get; init; }
        public string PreRepairSnapshotManifestPath { get; init; } = string.Empty;
        public bool PostWriteVerificationPassed { get; init; }
        public string SummaryMessage { get; init; } = string.Empty;
        public List<string> AuditLogEntries { get; init; } = new();
        public DateTime CompletedAtUtc { get; init; } = DateTime.UtcNow;
    }

    public sealed class MetadataSnapshotRegion
    {
        public string RegionId { get; init; } = string.Empty;
        public string Description { get; init; } = string.Empty;
        public long ByteOffset { get; init; }
        public int ByteLength { get; init; }
        public long StartLba { get; init; }
        public string FileName { get; init; } = string.Empty;
        public string Sha256 { get; init; } = string.Empty;
    }

    public sealed class MetadataSnapshotManifest
    {
        public int SchemaVersion { get; init; } = 1;
        public string SnapshotId { get; init; } = string.Empty;
        public DateTime CapturedAtUtc { get; init; } = DateTime.UtcNow;
        public StorageDeviceIdentity SourceIdentity { get; init; } = new();
        public string SnapshotDirectory { get; init; } = string.Empty;
        public string Notice { get; init; } = "Metadata snapshot only (partition tables & boot sectors). Not a full backup of user files.";
        public List<MetadataSnapshotRegion> Regions { get; init; } = new();
    }

    public sealed class StorageRecoveryAssessment
    {
        public int SchemaVersion { get; init; } = 1;
        public DateTime AssessedAtUtc { get; init; } = DateTime.UtcNow;
        public StorageDeviceIdentity Device { get; init; } = new();
        public string ScanMode { get; init; } = "ReadOnlyMetadataScan";
        public string HardwareHealthBadge { get; init; } = "Unknown";
        public string PartitionTableBadge { get; init; } = "Unknown";
        public string FileSystemBadge { get; init; } = "Unknown";
        public string OverallVerdict { get; init; } = "Unknown";
        public string ExecutiveSummary { get; init; } = string.Empty;
        public MbrAnalysisResult Mbr { get; init; } = new();
        public GptAnalysisResult Gpt { get; init; } = new();
        public List<FileSystemAnalysisResult> FileSystems { get; init; } = new();
        public List<DiscoveredPartitionCandidate> DiscoveredPartitions { get; init; } = new();
        public List<SectorReadError> ReadErrors { get; init; } = new();
        public List<StorageDiagnosticFinding> Findings { get; init; } = new();
        public List<VerifiedRepairPlan> ProposedRepairs { get; init; } = new();
    }

    // ═══ RELEASE 4: NTFS FILE RECOVERY & RESUMABLE IMAGING CONTRACTS ═══

    public sealed class NtfsDataRun
    {
        public long VcnStart { get; init; }
        public long ClusterCount { get; init; }
        public long LcnStart { get; init; } // -1 when IsSparse == true
        public bool IsSparse { get; init; }
    }

    public sealed class RecoverableFileItem
    {
        public long MftRecordNumber { get; init; }
        public ushort SequenceNumber { get; init; }
        public long ParentMftRecordNumber { get; init; }
        public string FileName { get; init; } = string.Empty;
        public string ReconstructedPath { get; set; } = string.Empty;
        public long SizeBytes { get; init; }
        public long AllocatedSizeBytes { get; init; }
        public bool IsDirectory { get; init; }
        public bool IsDeleted { get; init; }
        public bool IsResident { get; init; }
        public bool IsFragmented => !IsResident && DataRuns.Count > 1;
        public bool HasTornWriteWarning { get; init; }
        public DateTime ModifiedUtc { get; init; }
        public long PartitionStartOffset { get; init; }
        public int ClusterSizeBytes { get; init; }
        public byte[] ResidentData { get; init; } = Array.Empty<byte>();
        public List<NtfsDataRun> DataRuns { get; init; } = new();

        public string StatusLabel
        {
            get
            {
                if (HasTornWriteWarning) return "Torn MFT Record";
                if (IsDeleted) return "Deleted (Recoverable)";
                if (IsFragmented) return $"Intact ({DataRuns.Count} fragments)";
                return IsResident ? "Intact (Resident)" : "Intact";
            }
        }

        public string DisplaySize
        {
            get
            {
                if (IsDirectory) return "<DIR>";
                if (SizeBytes <= 0) return "0 B";
                double gb = SizeBytes / (1024.0 * 1024.0 * 1024.0);
                if (gb >= 1.0) return $"{gb:0.##} GB";
                double mb = SizeBytes / (1024.0 * 1024.0);
                if (mb >= 1.0) return $"{mb:0.#} MB";
                double kb = SizeBytes / 1024.0;
                if (kb >= 1.0) return $"{kb:0.#} KB";
                return $"{SizeBytes} B";
            }
        }
    }

    public sealed class FileExportItemResult
    {
        public long MftRecordNumber { get; init; }
        public string RelativePath { get; init; } = string.Empty;
        public string DestinationFullPath { get; init; } = string.Empty;
        public long BytesWritten { get; init; }
        public long ExpectedBytes { get; init; }
        public string Status { get; init; } = "Verified"; // Verified, Partial (Unreadable Sectors), Failed
        public string Sha256 { get; init; } = string.Empty;
        public int UnreadableSectorCount { get; init; }
        public string ErrorDetail { get; init; } = string.Empty;
    }

    public sealed class FileExportManifest
    {
        public int SchemaVersion { get; init; } = 1;
        public DateTime ExportedAtUtc { get; init; } = DateTime.UtcNow;
        public StorageDeviceIdentity SourceIdentity { get; init; } = new();
        public string DestinationRoot { get; init; } = string.Empty;
        public int TotalFilesRequested { get; init; }
        public int VerifiedFilesCount { get; init; }
        public int PartialFilesCount { get; init; }
        public int FailedFilesCount { get; init; }
        public long TotalBytesWritten { get; init; }
        public string ManifestFilePath { get; set; } = string.Empty;
        public List<FileExportItemResult> Results { get; init; } = new();
    }

    public enum ImagingBlockState
    {
        NonTried = 0,     // '?'
        Finished = 1,     // '+'
        FailedBlock = 2,  // '*'
        BadSector = 3     // '-'
    }

    public sealed class ImagingMapExtent
    {
        public long Offset { get; set; }
        public long Length { get; set; }
        public ImagingBlockState State { get; set; }
    }

    public sealed class ImagingJobManifest
    {
        public int SchemaVersion { get; init; } = 1;
        public string JobId { get; init; } = string.Empty;
        public DateTime CreatedAtUtc { get; init; } = DateTime.UtcNow;
        public DateTime UpdatedAtUtc { get; set; } = DateTime.UtcNow;
        public StorageDeviceIdentity SourceIdentity { get; init; } = new();
        public string OutputImagePath { get; init; } = string.Empty;
        public string MapFilePath { get; init; } = string.Empty;
        public long SourceStartOffset { get; init; }
        public long TotalBytesToCopy { get; init; }
        public int CopyBlockSizeBytes { get; init; } = 262144; // 256 KiB
        public int ScrapeSectorSizeBytes { get; init; } = 4096;
        public long BytesRescued { get; set; }
        public long BytesBad { get; set; }
        public string CurrentPhase { get; set; } = "Copying"; // Copying, Scraping, Completed, Paused, AbortedDeviceDisconnected
        public string LastStatusMessage { get; set; } = string.Empty;
        public List<ImagingMapExtent> Extents { get; set; } = new();
    }

    public sealed class ImagingProgressReport
    {
        public string Phase { get; init; } = string.Empty;
        public long CurrentOffset { get; init; }
        public long TotalBytes { get; init; }
        public long BytesRescued { get; init; }
        public long BytesBad { get; init; }
        public int BadRangeCount { get; init; }
        public double PercentComplete => TotalBytes > 0 ? Math.Clamp((BytesRescued + BytesBad) * 100.0 / TotalBytes, 0, 100) : 0;
        public string StatusMessage { get; init; } = string.Empty;
    }
}
