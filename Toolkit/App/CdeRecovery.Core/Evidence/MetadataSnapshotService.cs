using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using CdeRecovery.Core.Devices;
using CdeRecovery.Core.Models;

namespace CdeRecovery.Core.Evidence
{
    public static class MetadataSnapshotService
    {
        public static void ValidateDestinationNotOnSource(StorageDeviceIdentity source, string destinationPath)
        {
            if (string.IsNullOrWhiteSpace(destinationPath))
                throw new ArgumentException("Snapshot destination path is required.", nameof(destinationPath));

            var fullDest = Path.GetFullPath(destinationPath);
            if (source.IsDiskImage && !string.IsNullOrWhiteSpace(source.DevicePath))
            {
                var fullSource = Path.GetFullPath(source.DevicePath);
                if (string.Equals(fullDest, fullSource, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Destination path cannot overwrite the source disk image.");
            }

            var destRoot = Path.GetPathRoot(fullDest)?.TrimEnd('\\') ?? string.Empty;
            if (!string.IsNullOrWhiteSpace(destRoot) && source.MountedDriveLetters.Count > 0)
            {
                foreach (var letter in source.MountedDriveLetters)
                {
                    var clean = letter.Trim().TrimEnd('\\');
                    if (!clean.EndsWith(':')) clean += ":";
                    if (string.Equals(destRoot, clean, StringComparison.OrdinalIgnoreCase))
                    {
                        throw new InvalidOperationException(
                            $"Safety violation: Snapshot destination ({destRoot}) is mounted on the source disk (Disk {source.DiskNumber}). Choose a separate healthy drive.");
                    }
                }
            }
        }

        public static async Task<MetadataSnapshotManifest> CaptureSnapshotAsync(
            IReadOnlyBlockSource source,
            StorageRecoveryAssessment? assessment,
            string baseOutputDirectory,
            CancellationToken cancellationToken = default)
        {
            ArgumentNullException.ThrowIfNull(source);
            ValidateDestinationNotOnSource(source.Identity, baseOutputDirectory);

            int sectorSize = Math.Max(512, source.LogicalSectorSize);
            long totalSectors = source.Length / sectorSize;
            string timestamp = DateTime.UtcNow.ToString("yyyyMMdd_HHmmss_fff");
            string diskTag = source.Identity.IsDiskImage
                ? Path.GetFileNameWithoutExtension(source.Identity.DevicePath)
                : $"Disk{source.Identity.DiskNumber}";
            string snapshotId = $"CDESNAP_{diskTag}_{timestamp}";
            string snapshotDir = Path.Combine(Path.GetFullPath(baseOutputDirectory), snapshotId);
            Directory.CreateDirectory(snapshotDir);

            var regions = new List<MetadataSnapshotRegion>();

            async Task TryCaptureRegionAsync(string regionId, string description, long byteOffset, int byteLength)
            {
                if (byteOffset < 0 || byteLength <= 0 || byteOffset + byteLength > source.Length)
                    return;

                byte[] buffer = new byte[byteLength];
                try
                {
                    int read = await source.ReadAtAsync(byteOffset, buffer, cancellationToken).ConfigureAwait(false);
                    if (read <= 0) return;
                    if (read < byteLength)
                        Array.Resize(ref buffer, read);

                    string fileName = $"{regionId}_0x{byteOffset:X}.bin";
                    string filePath = Path.Combine(snapshotDir, fileName);
                    await File.WriteAllBytesAsync(filePath, buffer, cancellationToken).ConfigureAwait(false);

                    string sha256 = ComputeSha256Hex(buffer);
                    regions.Add(new MetadataSnapshotRegion
                    {
                        RegionId = regionId,
                        Description = description,
                        ByteOffset = byteOffset,
                        ByteLength = buffer.Length,
                        StartLba = byteOffset / sectorSize,
                        FileName = fileName,
                        Sha256 = sha256
                    });
                }
                catch
                {
                    // Skip unreadable region in snapshot, recorded in assessment read errors
                }
            }

            // 1. LBA 0 (MBR / Protective MBR)
            await TryCaptureRegionAsync("LBA0_MBR", "Sector 0 (MBR / Protective MBR)", 0, sectorSize).ConfigureAwait(false);

            // 2. Primary GPT (LBA 1 + 16 KiB entries)
            int gptEntriesBytes = 128 * 128; // 16,384 bytes
            int gptRegionBytes = sectorSize + gptEntriesBytes;
            if (totalSectors >= 68)
            {
                await TryCaptureRegionAsync("GPT_Primary", "Primary GPT Header + Partition Entry Array", sectorSize, gptRegionBytes).ConfigureAwait(false);

                if (source.Identity.IsDiskImage)
                {
                    long backupStartOffset = source.Length - gptRegionBytes;
                    await TryCaptureRegionAsync("GPT_Backup", "Backup GPT Partition Entry Array + Header", backupStartOffset, gptRegionBytes).ConfigureAwait(false);
                }
            }

            // 3. Partition Boot Sectors & $MFT headers from assessment
            if (assessment != null)
            {
                foreach (var fs in assessment.FileSystems)
                {
                    await TryCaptureRegionAsync(
                        $"Part{fs.PartitionIndex}_PrimaryVBR",
                        $"Partition {fs.PartitionIndex} ({fs.PartitionName}) Primary Boot Sector",
                        fs.PartitionStartOffset,
                        sectorSize).ConfigureAwait(false);

                    if (source.Identity.IsDiskImage && fs.BackupBootSectorOffset > fs.PartitionStartOffset)
                    {
                        await TryCaptureRegionAsync(
                            $"Part{fs.PartitionIndex}_BackupVBR",
                            $"Partition {fs.PartitionIndex} ({fs.PartitionName}) Backup Boot Sector",
                            fs.BackupBootSectorOffset,
                            sectorSize).ConfigureAwait(false);
                    }

                    if (fs.NtfsMftByteOffset > fs.PartitionStartOffset && fs.NtfsFileRecordSizeBytes > 0)
                    {
                        await TryCaptureRegionAsync(
                            $"Part{fs.PartitionIndex}_MFT0",
                            $"Partition {fs.PartitionIndex} $MFT Records 0-3",
                            fs.NtfsMftByteOffset,
                            fs.NtfsFileRecordSizeBytes * 4).ConfigureAwait(false);
                    }
                }
            }

            var manifest = new MetadataSnapshotManifest
            {
                SchemaVersion = 1,
                SnapshotId = snapshotId,
                CapturedAtUtc = DateTime.UtcNow,
                SourceIdentity = source.Identity,
                SnapshotDirectory = snapshotDir,
                Regions = regions
            };

            string manifestPath = Path.Combine(snapshotDir, "manifest.json");
            var json = JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true });
            await File.WriteAllTextAsync(manifestPath, json, cancellationToken).ConfigureAwait(false);

            return manifest;
        }

        public static async Task<(bool IsValid, MetadataSnapshotManifest? Manifest, string Message)> VerifySnapshotAsync(
            string manifestOrDirectoryPath,
            CancellationToken cancellationToken = default)
        {
            string manifestPath = Directory.Exists(manifestOrDirectoryPath)
                ? Path.Combine(manifestOrDirectoryPath, "manifest.json")
                : manifestOrDirectoryPath;

            if (!File.Exists(manifestPath))
                return (false, null, $"Snapshot manifest not found: {manifestPath}");

            string dir = Path.GetDirectoryName(manifestPath) ?? string.Empty;
            var json = await File.ReadAllTextAsync(manifestPath, cancellationToken).ConfigureAwait(false);
            var manifest = JsonSerializer.Deserialize<MetadataSnapshotManifest>(json, new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true
            });

            if (manifest == null || manifest.Regions.Count == 0)
                return (false, manifest, "Manifest is empty or invalid.");

            foreach (var region in manifest.Regions)
            {
                string binPath = Path.Combine(dir, region.FileName);
                if (!File.Exists(binPath))
                    return (false, manifest, $"Missing region payload file: {region.FileName}");

                byte[] bytes = await File.ReadAllBytesAsync(binPath, cancellationToken).ConfigureAwait(false);
                if (bytes.Length != region.ByteLength)
                    return (false, manifest, $"Length mismatch in {region.FileName} (expected {region.ByteLength}, actual {bytes.Length}).");

                string actualHash = ComputeSha256Hex(bytes);
                if (!string.Equals(actualHash, region.Sha256, StringComparison.OrdinalIgnoreCase))
                    return (false, manifest, $"SHA-256 mismatch in {region.FileName}.");
            }

            return (true, manifest, $"Verified {manifest.Regions.Count} binary metadata region(s) in {manifest.SnapshotId}.");
        }

        public static string ComputeSha256Hex(ReadOnlySpan<byte> data)
        {
            Span<byte> hash = stackalloc byte[32];
            SHA256.HashData(data, hash);
            return Convert.ToHexString(hash);
        }

        public static string FormatHexPreview(ReadOnlySpan<byte> data, int maxBytes = 64)
        {
            int len = Math.Min(data.Length, maxBytes);
            if (len == 0) return "(empty)";
            var slice = data.Slice(0, len);
            var hex = Convert.ToHexString(slice);
            // Insert spaces every 2 chars
            var parts = new List<string>(len);
            for (int i = 0; i < hex.Length; i += 2)
                parts.Add(hex.Substring(i, 2));
            return string.Join(" ", parts) + (data.Length > maxBytes ? " ..." : string.Empty);
        }
    }
}
