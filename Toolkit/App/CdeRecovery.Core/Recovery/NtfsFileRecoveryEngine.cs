using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using CdeRecovery.Core.Devices;
using CdeRecovery.Core.FileSystems;
using CdeRecovery.Core.Models;

namespace CdeRecovery.Core.Recovery
{
    public static class NtfsFileRecoveryEngine
    {
        public static async Task<List<RecoverableFileItem>> ScanRecoverableFilesAsync(
            IReadOnlyBlockSource source,
            FileSystemAnalysisResult partition,
            bool includeDeleted = false,
            int maxRecords = 4096,
            IProgress<string>? progress = null,
            CancellationToken cancellationToken = default)
        {
            ArgumentNullException.ThrowIfNull(source);
            ArgumentNullException.ThrowIfNull(partition);

            int bps = partition.BytesPerSector > 0 ? partition.BytesPerSector : Math.Max(512, source.LogicalSectorSize);
            int spc = partition.SectorsPerCluster > 0 ? partition.SectorsPerCluster : (bps == 512 ? 8 : 1);
            int clusterSize = bps * spc;
            int recordSize = partition.NtfsFileRecordSizeBytes > 0 ? partition.NtfsFileRecordSizeBytes : 1024;
            long mftOffset = partition.NtfsMftByteOffset;
            long mftMirrOffset = partition.NtfsMftMirrorByteOffset;

            // If geometry wasn't populated, attempt to parse Backup VBR or Primary VBR directly
            if (mftOffset <= partition.PartitionStartOffset)
            {
                byte[] vbrBuf = new byte[Math.Max(512, source.LogicalSectorSize)];
                NtfsAnalyzer.NtfsVbrFields? vbr = null;

                try
                {
                    if (await source.ReadAtAsync(partition.PartitionStartOffset, vbrBuf, cancellationToken).ConfigureAwait(false) >= 512)
                    {
                        var p = NtfsAnalyzer.ParseBootSector(vbrBuf);
                        if (p.IsValid) vbr = p;
                    }
                }
                catch { }

                if (vbr == null && partition.BackupBootSectorOffset > partition.PartitionStartOffset)
                {
                    try
                    {
                        if (await source.ReadAtAsync(partition.BackupBootSectorOffset, vbrBuf, cancellationToken).ConfigureAwait(false) >= 512)
                        {
                            var b = NtfsAnalyzer.ParseBootSector(vbrBuf);
                            if (b.IsValid) vbr = b;
                        }
                    }
                    catch { }
                }

                if (vbr != null)
                {
                    bps = vbr.BytesPerSector;
                    spc = vbr.SectorsPerCluster;
                    clusterSize = bps * spc;
                    recordSize = vbr.FileRecordSizeBytes;
                    mftOffset = partition.PartitionStartOffset + (vbr.MftCluster * clusterSize);
                    mftMirrOffset = partition.PartitionStartOffset + (vbr.MftMirrorCluster * clusterSize);
                }
            }

            if (mftOffset <= partition.PartitionStartOffset || mftOffset >= source.Length)
                throw new InvalidOperationException("Unable to locate a valid NTFS Master File Table ($MFT) offset on this partition.");

            // Check if $MFT Record 0 defines fragmented $MFT runs
            var mftExtents = new List<(long ByteOffset, long RecordCount)>();
            byte[] rec0Buf = new byte[recordSize];
            bool rec0Loaded = false;

            try
            {
                if (await source.ReadAtAsync(mftOffset, rec0Buf, cancellationToken).ConfigureAwait(false) == recordSize)
                {
                    var rec0Item = NtfsMftRecordParser.TryParseFileRecord(rec0Buf, 0, partition.PartitionStartOffset, clusterSize);
                    if (rec0Item != null && !rec0Item.IsResident && rec0Item.DataRuns.Count > 0)
                    {
                        foreach (var run in rec0Item.DataRuns.Where(r => !r.IsSparse && r.LcnStart >= 0))
                        {
                            long runByteOff = partition.PartitionStartOffset + (run.LcnStart * clusterSize);
                            long runRecCount = (run.ClusterCount * clusterSize) / recordSize;
                            if (runRecCount > 0)
                                mftExtents.Add((runByteOff, runRecCount));
                        }
                        rec0Loaded = mftExtents.Count > 0;
                    }
                }
            }
            catch { }

            if (!rec0Loaded && mftMirrOffset > partition.PartitionStartOffset && mftMirrOffset + recordSize <= source.Length)
            {
                try
                {
                    if (await source.ReadAtAsync(mftMirrOffset, rec0Buf, cancellationToken).ConfigureAwait(false) == recordSize)
                    {
                        var mirrItem = NtfsMftRecordParser.TryParseFileRecord(rec0Buf, 0, partition.PartitionStartOffset, clusterSize);
                        if (mirrItem != null && !mirrItem.IsResident && mirrItem.DataRuns.Count > 0)
                        {
                            foreach (var run in mirrItem.DataRuns.Where(r => !r.IsSparse && r.LcnStart >= 0))
                            {
                                long runByteOff = partition.PartitionStartOffset + (run.LcnStart * clusterSize);
                                long runRecCount = (run.ClusterCount * clusterSize) / recordSize;
                                if (runRecCount > 0)
                                    mftExtents.Add((runByteOff, runRecCount));
                            }
                            rec0Loaded = mftExtents.Count > 0;
                        }
                    }
                }
                catch { }
            }

            if (!rec0Loaded)
            {
                long maxPossible = (source.Length - mftOffset) / recordSize;
                mftExtents.Add((mftOffset, Math.Min(maxRecords, maxPossible)));
            }

            var directories = new Dictionary<long, RecoverableFileItem>();
            var files = new List<RecoverableFileItem>();

            // Batch read MFT records in 64 KiB chunks (64 records at a time)
            const int recordsPerBatch = 64;
            int batchByteSize = recordsPerBatch * recordSize;
            byte[] batchBuffer = new byte[batchByteSize];

            long globalRecordIndex = 0;
            int consecutiveEmptyRecords = 0;

            long effectiveMaxRecords = maxRecords <= 0 ? long.MaxValue : maxRecords;
            foreach (var extent in mftExtents)
            {
                long recordsRemainingInExtent = Math.Min(extent.RecordCount, effectiveMaxRecords - globalRecordIndex);
                long currentExtentByteOffset = extent.ByteOffset;

                while (recordsRemainingInExtent > 0 && globalRecordIndex < effectiveMaxRecords)
                {
                    cancellationToken.ThrowIfCancellationRequested();

                    int recordsThisBatch = (int)Math.Min(recordsPerBatch, recordsRemainingInExtent);
                    int bytesToRead = recordsThisBatch * recordSize;
                    if (currentExtentByteOffset + bytesToRead > source.Length)
                        break;

                    int bytesRead = 0;
                    try
                    {
                        bytesRead = await source.ReadAtAsync(currentExtentByteOffset, batchBuffer.AsMemory(0, bytesToRead), cancellationToken).ConfigureAwait(false);
                    }
                    catch (Exception ex) when (ex is not OperationCanceledException)
                    {
                        // If a batch fails due to a bad sector inside $MFT, fall back to individual record reads
                        for (int r = 0; r < recordsThisBatch; r++)
                        {
                            cancellationToken.ThrowIfCancellationRequested();
                            try
                            {
                                await source.ReadAtAsync(
                                    currentExtentByteOffset + (r * recordSize),
                                    batchBuffer.AsMemory(r * recordSize, recordSize),
                                    cancellationToken).ConfigureAwait(false);
                            }
                            catch (Exception innerEx) when (innerEx is not OperationCanceledException)
                            {
                                Array.Clear(batchBuffer, r * recordSize, recordSize);
                            }
                        }
                        bytesRead = bytesToRead;
                    }

                    int actualRecords = bytesRead / recordSize;
                    if (actualRecords <= 0)
                        break;

                    ParseBatchRecords(
                        batchBuffer,
                        actualRecords,
                        recordSize,
                        globalRecordIndex,
                        partition.PartitionStartOffset,
                        clusterSize,
                        includeDeleted,
                        directories,
                        files,
                        ref consecutiveEmptyRecords);

                    globalRecordIndex += actualRecords;
                    recordsRemainingInExtent -= actualRecords;
                    currentExtentByteOffset += actualRecords * recordSize;

                    progress?.Report($"Scanned {globalRecordIndex:N0} $MFT records — found {files.Count:N0} recoverable file(s)...");

                    if (consecutiveEmptyRecords >= 4096 && globalRecordIndex >= 64)
                    {
                        // Reached unallocated tail of $MFT
                        break;
                    }
                }

                if (globalRecordIndex >= effectiveMaxRecords || (consecutiveEmptyRecords >= 4096 && globalRecordIndex >= 64))
                    break;
            }

            // Reconstruct full folder paths by walking ParentMftRecordNumber up to Root (Record 5)
            var resolvedFiles = new List<RecoverableFileItem>(files.Count);
            foreach (var f in files)
            {
                string fullRelPath = ReconstructRelativePath(f, directories);
                resolvedFiles.Add(new RecoverableFileItem
                {
                    MftRecordNumber = f.MftRecordNumber,
                    SequenceNumber = f.SequenceNumber,
                    ParentMftRecordNumber = f.ParentMftRecordNumber,
                    FileName = f.FileName,
                    ReconstructedPath = fullRelPath,
                    SizeBytes = f.SizeBytes,
                    AllocatedSizeBytes = f.AllocatedSizeBytes,
                    IsDirectory = f.IsDirectory,
                    IsDeleted = f.IsDeleted,
                    IsResident = f.IsResident,
                    HasTornWriteWarning = f.HasTornWriteWarning,
                    ModifiedUtc = f.ModifiedUtc,
                    PartitionStartOffset = f.PartitionStartOffset,
                    ClusterSizeBytes = f.ClusterSizeBytes,
                    ResidentData = f.ResidentData,
                    DataRuns = f.DataRuns
                });
            }

            return resolvedFiles
                .OrderBy(f => f.ReconstructedPath, StringComparer.OrdinalIgnoreCase)
                .ToList();
        }

        private static string ReconstructRelativePath(
            RecoverableFileItem item,
            Dictionary<long, RecoverableFileItem> directories)
        {
            var segments = new List<string> { SanitizePathSegment(item.FileName) };
            var visited = new HashSet<long> { item.MftRecordNumber };

            long currentParent = item.ParentMftRecordNumber;
            int depth = 0;

            while (currentParent != 5 && currentParent > 0 && depth < 32)
            {
                if (!visited.Add(currentParent))
                    break; // Cycle guard

                if (directories.TryGetValue(currentParent, out var parentDir))
                {
                    if (!string.IsNullOrWhiteSpace(parentDir.FileName) && parentDir.FileName != ".")
                    {
                        segments.Add(SanitizePathSegment(parentDir.FileName));
                    }
                    currentParent = parentDir.ParentMftRecordNumber;
                    depth++;
                }
                else
                {
                    segments.Add("_Orphaned_Files");
                    break;
                }
            }

            segments.Reverse();
            return string.Join(Path.DirectorySeparatorChar, segments);
        }

        private static string SanitizePathSegment(string segment)
        {
            if (string.IsNullOrWhiteSpace(segment))
                return "unnamed";

            char[] invalid = Path.GetInvalidFileNameChars();
            var chars = segment.ToCharArray();
            for (int i = 0; i < chars.Length; i++)
            {
                if (Array.IndexOf(invalid, chars[i]) >= 0)
                    chars[i] = '_';
            }
            return new string(chars).Trim();
        }

        private static void ParseBatchRecords(
            byte[] batchBuffer,
            int actualRecords,
            int recordSize,
            long globalRecordIndex,
            long partitionStartOffset,
            int clusterSize,
            bool includeDeleted,
            Dictionary<long, RecoverableFileItem> directories,
            List<RecoverableFileItem> files,
            ref int consecutiveEmptyRecords)
        {
            for (int i = 0; i < actualRecords; i++)
            {
                long recNum = globalRecordIndex + i;
                ReadOnlySpan<byte> recordSpan = batchBuffer.AsSpan(i * recordSize, recordSize);

                if (IsAllZero(recordSpan))
                {
                    if (recNum >= 24)
                        consecutiveEmptyRecords++;
                    continue;
                }

                consecutiveEmptyRecords = 0;

                // Skip reserved NTFS system metadata records (0..15), except Record 5 (Root '.')
                if (recNum < 16 && recNum != 5)
                    continue;

                var parsed = NtfsMftRecordParser.TryParseFileRecord(
                    recordSpan,
                    recNum,
                    partitionStartOffset,
                    clusterSize);

                if (parsed == null)
                    continue;

                if (parsed.IsDirectory)
                {
                    directories[recNum] = parsed;
                    continue;
                }

                if (parsed.IsDeleted && !includeDeleted)
                    continue;

                if (parsed.FileName.StartsWith('$'))
                    continue;

                files.Add(parsed);
            }
        }

        private static bool IsAllZero(ReadOnlySpan<byte> span)
        {
            return !span.ContainsAnyExcept((byte)0);
        }
    }
}
