using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using CdeRecovery.Core.Devices;
using CdeRecovery.Core.Evidence;
using CdeRecovery.Core.Models;

namespace CdeRecovery.Core.Recovery
{
    public static class FileExportEngine
    {
        public static async Task<FileExportManifest> ExportFilesAsync(
            IReadOnlyBlockSource source,
            IReadOnlyList<RecoverableFileItem> filesToExport,
            string destinationRootDirectory,
            IProgress<string>? progress = null,
            CancellationToken cancellationToken = default)
        {
            ArgumentNullException.ThrowIfNull(source);
            ArgumentNullException.ThrowIfNull(filesToExport);

            MetadataSnapshotService.ValidateDestinationNotOnSource(source.Identity, destinationRootDirectory);

            string fullDestRoot = Path.GetFullPath(destinationRootDirectory);
            Directory.CreateDirectory(fullDestRoot);

            var results = new List<FileExportItemResult>(filesToExport.Count);
            long totalBytesWritten = 0;
            int sectorSize = Math.Max(512, source.LogicalSectorSize);

            int index = 0;
            foreach (var file in filesToExport.Where(f => !f.IsDirectory))
            {
                cancellationToken.ThrowIfCancellationRequested();
                index++;
                progress?.Report($"Exporting ({index}/{filesToExport.Count}): {file.ReconstructedPath} ({file.DisplaySize})...");

                string relPath = string.IsNullOrWhiteSpace(file.ReconstructedPath) ? file.FileName : file.ReconstructedPath;
                string targetPath = Path.Combine(fullDestRoot, relPath);
                string? parentDir = Path.GetDirectoryName(targetPath);
                if (!string.IsNullOrWhiteSpace(parentDir))
                    Directory.CreateDirectory(parentDir);

                long bytesWrittenForFile = 0;
                int unreadableSectors = 0;
                string errorDetail = string.Empty;

                try
                {
                    using var sha256 = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                    await using (var outStream = new FileStream(targetPath, FileMode.Create, FileAccess.Write, FileShare.None, 65536, useAsync: true))
                    {
                        if (file.IsResident)
                        {
                            int len = (int)Math.Min(file.SizeBytes, file.ResidentData.Length);
                            if (len > 0)
                            {
                                await outStream.WriteAsync(file.ResidentData.AsMemory(0, len), cancellationToken).ConfigureAwait(false);
                                sha256.AppendData(file.ResidentData, 0, len);
                                bytesWrittenForFile = len;
                            }
                        }
                        else
                        {
                            long remainingBytes = file.SizeBytes;
                            int clusterSize = file.ClusterSizeBytes > 0 ? file.ClusterSizeBytes : 4096;
                            const int maxChunkBytes = 256 * 1024;
                            byte[] chunkBuffer = new byte[maxChunkBytes];
                            byte[] zeroSector = new byte[sectorSize];

                            foreach (var run in file.DataRuns)
                            {
                                if (remainingBytes <= 0)
                                    break;

                                long runBytesTotal = run.ClusterCount * clusterSize;
                                long bytesFromThisRun = Math.Min(remainingBytes, runBytesTotal);

                                if (run.IsSparse || run.LcnStart < 0)
                                {
                                    Array.Clear(chunkBuffer, 0, chunkBuffer.Length);
                                    long sparseLeft = bytesFromThisRun;
                                    while (sparseLeft > 0)
                                    {
                                        int writeNow = (int)Math.Min(chunkBuffer.Length, sparseLeft);
                                        await outStream.WriteAsync(chunkBuffer.AsMemory(0, writeNow), cancellationToken).ConfigureAwait(false);
                                        sha256.AppendData(chunkBuffer, 0, writeNow);
                                        sparseLeft -= writeNow;
                                        bytesWrittenForFile += writeNow;
                                    }
                                    remainingBytes -= bytesFromThisRun;
                                    continue;
                                }

                                long diskRunStartOffset = file.PartitionStartOffset + (run.LcnStart * clusterSize);
                                long runOffsetProcessed = 0;

                                while (runOffsetProcessed < bytesFromThisRun)
                                {
                                    cancellationToken.ThrowIfCancellationRequested();

                                    long currentDiskOffset = diskRunStartOffset + runOffsetProcessed;
                                    long bytesNeeded = bytesFromThisRun - runOffsetProcessed;
                                    int alignedReadLen = (int)Math.Min(maxChunkBytes, ((bytesNeeded + sectorSize - 1) / sectorSize) * sectorSize);
                                    int validDataLen = (int)Math.Min(bytesNeeded, alignedReadLen);

                                    try
                                    {
                                        int read = await source.ReadAtAsync(currentDiskOffset, chunkBuffer.AsMemory(0, alignedReadLen), cancellationToken).ConfigureAwait(false);
                                        if (read < validDataLen)
                                        {
                                            Array.Clear(chunkBuffer, read, validDataLen - read);
                                        }

                                        await outStream.WriteAsync(chunkBuffer.AsMemory(0, validDataLen), cancellationToken).ConfigureAwait(false);
                                        sha256.AppendData(chunkBuffer, 0, validDataLen);
                                        bytesWrittenForFile += validDataLen;
                                    }
                                    catch
                                    {
                                        // Bad sector inside chunk: salvage sector-by-sector and zero-fill only unreadable sectors
                                        int chunkProcessed = 0;
                                        while (chunkProcessed < validDataLen)
                                        {
                                            int secValid = Math.Min(sectorSize, validDataLen - chunkProcessed);
                                            long secDiskOffset = currentDiskOffset + chunkProcessed;
                                            try
                                            {
                                                byte[] secBuf = new byte[sectorSize];
                                                int rSec = await source.ReadAtAsync(secDiskOffset, secBuf, cancellationToken).ConfigureAwait(false);
                                                await outStream.WriteAsync(secBuf.AsMemory(0, secValid), cancellationToken).ConfigureAwait(false);
                                                sha256.AppendData(secBuf, 0, secValid);
                                            }
                                            catch (Exception secEx)
                                            {
                                                unreadableSectors++;
                                                if (string.IsNullOrEmpty(errorDetail))
                                                    errorDetail = $"Unreadable sector at 0x{secDiskOffset:X}: {secEx.Message}";

                                                await outStream.WriteAsync(zeroSector.AsMemory(0, secValid), cancellationToken).ConfigureAwait(false);
                                                sha256.AppendData(zeroSector, 0, secValid);
                                            }

                                            chunkProcessed += secValid;
                                            bytesWrittenForFile += secValid;
                                        }
                                    }

                                    runOffsetProcessed += validDataLen;
                                }

                                remainingBytes -= bytesFromThisRun;
                            }
                        }

                        await outStream.FlushAsync(cancellationToken).ConfigureAwait(false);
                    }

                    try
                    {
                        if (file.ModifiedUtc.Year >= 1980 && file.ModifiedUtc.Year <= 2100)
                            File.SetLastWriteTimeUtc(targetPath, file.ModifiedUtc);
                    }
                    catch { }

                    string hashHex = Convert.ToHexString(sha256.GetHashAndReset());
                    string status = unreadableSectors == 0 && !file.HasTornWriteWarning
                        ? "Verified"
                        : "Partial (Unreadable Sectors)";

                    totalBytesWritten += bytesWrittenForFile;
                    results.Add(new FileExportItemResult
                    {
                        MftRecordNumber = file.MftRecordNumber,
                        RelativePath = relPath,
                        DestinationFullPath = targetPath,
                        BytesWritten = bytesWrittenForFile,
                        ExpectedBytes = file.SizeBytes,
                        Status = status,
                        Sha256 = hashHex,
                        UnreadableSectorCount = unreadableSectors,
                        ErrorDetail = errorDetail
                    });
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    results.Add(new FileExportItemResult
                    {
                        MftRecordNumber = file.MftRecordNumber,
                        RelativePath = relPath,
                        DestinationFullPath = targetPath,
                        BytesWritten = bytesWrittenForFile,
                        ExpectedBytes = file.SizeBytes,
                        Status = "Failed",
                        UnreadableSectorCount = unreadableSectors,
                        ErrorDetail = ex.Message
                    });
                }
            }

            string manifestPath = Path.Combine(fullDestRoot, "recovery_export_manifest.json");
            var manifest = new FileExportManifest
            {
                SchemaVersion = 1,
                ExportedAtUtc = DateTime.UtcNow,
                SourceIdentity = source.Identity,
                DestinationRoot = fullDestRoot,
                TotalFilesRequested = filesToExport.Count(f => !f.IsDirectory),
                VerifiedFilesCount = results.Count(r => r.Status == "Verified"),
                PartialFilesCount = results.Count(r => r.Status.StartsWith("Partial", StringComparison.OrdinalIgnoreCase)),
                FailedFilesCount = results.Count(r => r.Status == "Failed"),
                TotalBytesWritten = totalBytesWritten,
                ManifestFilePath = manifestPath,
                Results = results
            };

            string json = JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true });
            await File.WriteAllTextAsync(manifestPath, json, cancellationToken).ConfigureAwait(false);

            return manifest;
        }
    }
}
