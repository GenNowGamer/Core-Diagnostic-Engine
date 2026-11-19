using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using CdeRecovery.Core.Devices;
using CdeRecovery.Core.Models;

namespace CdeRecovery.Core.Recovery
{
    public static class ExFatFileRecoveryEngine
    {
        public static async Task<List<RecoverableFileItem>> ScanRecoverableFilesAsync(
            IReadOnlyBlockSource source,
            FileSystemAnalysisResult partition,
            bool includeDeleted = false,
            int maxFiles = 50000,
            IProgress<string>? progress = null,
            CancellationToken cancellationToken = default)
        {
            ArgumentNullException.ThrowIfNull(source);
            ArgumentNullException.ThrowIfNull(partition);

            int sectorSize = Math.Max(512, source.LogicalSectorSize);
            byte[] vbr = new byte[Math.Max(512, sectorSize)];
            await source.ReadAtAsync(partition.PartitionStartOffset, vbr, cancellationToken).ConfigureAwait(false);

            string oem = Encoding.ASCII.GetString(vbr, 3, 8);
            if (!string.Equals(oem, "EXFAT   ", StringComparison.Ordinal))
            {
                // Fall back to exFAT Backup Boot Sector at sector 12 (or partition.BackupBootSectorOffset)
                long backupVbrOffset = partition.BackupBootSectorOffset > partition.PartitionStartOffset
                    ? partition.BackupBootSectorOffset
                    : partition.PartitionStartOffset + (12L * sectorSize);
                if (backupVbrOffset + vbr.Length <= source.Length)
                {
                    await source.ReadAtAsync(backupVbrOffset, vbr, cancellationToken).ConfigureAwait(false);
                    oem = Encoding.ASCII.GetString(vbr, 3, 8);
                }
            }

            if (!string.Equals(oem, "EXFAT   ", StringComparison.Ordinal))
                throw new InvalidDataException("Invalid exFAT boot sector signature.");

            uint fatOffsetSectors = BinaryPrimitives.ReadUInt32LittleEndian(vbr.AsSpan(0x50, 4));
            uint clusterHeapOffsetSectors = BinaryPrimitives.ReadUInt32LittleEndian(vbr.AsSpan(0x58, 4));
            uint clusterCount = BinaryPrimitives.ReadUInt32LittleEndian(vbr.AsSpan(0x5C, 4));
            uint rootCluster = BinaryPrimitives.ReadUInt32LittleEndian(vbr.AsSpan(0x60, 4));
            int bpsShift = vbr[0x6C];
            int spcShift = vbr[0x6D];

            if (bpsShift < 9 || bpsShift > 12 || spcShift > 25 || rootCluster < 2)
                throw new InvalidDataException("Invalid exFAT geometry.");

            int bps = 1 << bpsShift;
            int spc = 1 << spcShift;
            int clusterSize = bps * spc;
            long fatOffset = partition.PartitionStartOffset + ((long)fatOffsetSectors * bps);
            long clusterHeapOffset = partition.PartitionStartOffset + ((long)clusterHeapOffsetSectors * bps);
            long maxCluster = Math.Max(2, clusterCount + 2L);

            var fatCache = new Dictionary<uint, uint>();
            var files = new List<RecoverableFileItem>();
            var dirQueue = new Queue<(uint Cluster, string PathPrefix, bool NoFatChain, bool ParentDeleted, int MaxClusters)>();
            var visitedDirs = new HashSet<uint>();

            dirQueue.Enqueue((rootCluster, string.Empty, false, false, 512));
            visitedDirs.Add(rootCluster);

            int effectiveLimit = maxFiles <= 0 ? int.MaxValue : maxFiles;

            while (dirQueue.Count > 0 && files.Count < effectiveLimit)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var (dirCluster, prefix, noFatChain, parentDeleted, maxDirClusters) = dirQueue.Dequeue();

                var dirClusters = await ReadClusterChainAsync(
                    source, fatOffset, maxCluster, dirCluster, noFatChain || parentDeleted, maxDirClusters, fatCache, cancellationToken).ConfigureAwait(false);

                if (dirClusters.Count == 0)
                    continue;

                // Read all directory clusters into a contiguous span for multi-entry sets (0x85 + 0xC0 + 0xC1...)
                byte[] dirBytes = new byte[dirClusters.Count * clusterSize];
                int dirBytesLen = 0;
                foreach (uint clus in dirClusters)
                {
                    long clusOffset = clusterHeapOffset + ((long)(clus - 2) * clusterSize);
                    if (clusOffset + clusterSize > source.Length)
                        break;
                    try
                    {
                        int read = await source.ReadAtAsync(clusOffset, dirBytes.AsMemory(dirBytesLen, clusterSize), cancellationToken).ConfigureAwait(false);
                        dirBytesLen += read;
                    }
                    catch (Exception ex) when (ex is not OperationCanceledException)
                    {
                        break;
                    }
                }

                for (int off = 0; off + 32 <= dirBytesLen; off += 32)
                {
                    byte entryType = dirBytes[off];
                    if (entryType == 0x00)
                        break;

                    bool isFileEntry = entryType == 0x85 || entryType == 0x05;
                    if (!isFileEntry)
                        continue;

                    bool isDeleted = entryType == 0x05 || parentDeleted;
                    int secondaryCount = dirBytes[off + 1];
                    if (secondaryCount < 2 || off + ((1 + secondaryCount) * 32) > dirBytesLen)
                        continue;

                    ushort fileAttrs = BinaryPrimitives.ReadUInt16LittleEndian(dirBytes.AsSpan(off + 4, 2));
                    bool isDir = (fileAttrs & 0x10) != 0;
                    DateTime modifiedUtc = DecodeExFatTimestamp(BinaryPrimitives.ReadUInt32LittleEndian(dirBytes.AsSpan(off + 12, 4)));

                    // Expect Stream Extension (0xC0 or 0x40) at off + 32
                    int streamOff = off + 32;
                    byte streamType = dirBytes[streamOff];
                    if (streamType != 0xC0 && streamType != 0x40)
                        continue;

                    byte streamFlags = dirBytes[streamOff + 1];
                    bool childNoFatChain = (streamFlags & 0x02) != 0;
                    int nameLen = dirBytes[streamOff + 3];
                    uint startCluster = BinaryPrimitives.ReadUInt32LittleEndian(dirBytes.AsSpan(streamOff + 20, 4));
                    long dataLength = (long)BinaryPrimitives.ReadUInt64LittleEndian(dirBytes.AsSpan(streamOff + 24, 8));

                    var nameBuilder = new StringBuilder(nameLen);
                    for (int s = 2; s <= secondaryCount; s++)
                    {
                        int fnOff = off + (s * 32);
                        byte fnType = dirBytes[fnOff];
                        if (fnType == 0xC1 || fnType == 0x41)
                        {
                            for (int c = 2; c + 1 < 32 && nameBuilder.Length < nameLen; c += 2)
                            {
                                char ch = (char)BinaryPrimitives.ReadUInt16LittleEndian(dirBytes.AsSpan(fnOff + c, 2));
                                nameBuilder.Append(ch);
                            }
                        }
                    }

                    off += secondaryCount * 32;

                    if (isDeleted && !includeDeleted)
                        continue;

                    string name = nameBuilder.ToString().TrimEnd('\0');
                    if (string.IsNullOrWhiteSpace(name))
                        continue;

                    string relPath = string.IsNullOrEmpty(prefix) ? name : Path.Combine(prefix, name);

                    if (isDir)
                    {
                        if (startCluster >= 2 && startCluster < maxCluster && visitedDirs.Add(startCluster))
                        {
                            int maxDirCap = isDeleted ? Math.Max(4, (2 * 1024 * 1024) / Math.Max(4096, clusterSize)) : 512;
                            int dirClusNeed = dataLength > 0 ? (int)Math.Min(maxDirCap, (dataLength + clusterSize - 1) / clusterSize) : Math.Min(32, maxDirCap);
                            dirQueue.Enqueue((startCluster, relPath, childNoFatChain, isDeleted, dirClusNeed));
                        }
                        continue;
                    }

                    var runs = new List<NtfsDataRun>();
                    if (dataLength > 0 && startCluster >= 2 && startCluster < maxCluster)
                    {
                        int neededClusters = (int)((dataLength + clusterSize - 1) / clusterSize);
                        if (childNoFatChain)
                        {
                            runs.Add(new NtfsDataRun
                            {
                                LcnStart = startCluster - 2,
                                ClusterCount = neededClusters,
                                IsSparse = false
                            });
                        }
                        else
                        {
                            var chain = await ReadClusterChainAsync(
                                source, fatOffset, maxCluster, startCluster, isContiguousFallback: isDeleted, maxClusters: neededClusters, fatCache, cancellationToken).ConfigureAwait(false);
                            runs.AddRange(BuildRunsFromClusters(chain));
                        }
                    }

                    files.Add(new RecoverableFileItem
                    {
                        MftRecordNumber = startCluster,
                        FileName = name,
                        ReconstructedPath = relPath,
                        SizeBytes = dataLength,
                        AllocatedSizeBytes = (long)runs.Sum(r => r.ClusterCount) * clusterSize,
                        IsDirectory = false,
                        IsDeleted = isDeleted,
                        IsResident = false,
                        ModifiedUtc = modifiedUtc,
                        PartitionStartOffset = clusterHeapOffset,
                        ClusterSizeBytes = clusterSize,
                        DataRuns = runs
                    });

                    if (files.Count % 250 == 0)
                        progress?.Report($"Scanned exFAT directory tree — found {files.Count:N0} file(s)...");

                    if (files.Count >= effectiveLimit)
                        break;
                }
            }

            return files.OrderBy(f => f.ReconstructedPath, StringComparer.OrdinalIgnoreCase).ToList();
        }

        private static async Task<List<uint>> ReadClusterChainAsync(
            IReadOnlyBlockSource source,
            long fatOffset,
            long maxCluster,
            uint startCluster,
            bool isContiguousFallback,
            int maxClusters,
            Dictionary<uint, uint> fatCache,
            CancellationToken cancellationToken)
        {
            var chain = new List<uint>();
            if (startCluster < 2 || startCluster >= maxCluster)
                return chain;

            if (isContiguousFallback)
            {
                for (int i = 0; i < maxClusters && startCluster + i < maxCluster; i++)
                    chain.Add(startCluster + (uint)i);
                return chain;
            }

            var visited = new HashSet<uint>();
            uint current = startCluster;
            while (current >= 2 && current < maxCluster && chain.Count < maxClusters && visited.Add(current))
            {
                chain.Add(current);
                uint next = await ReadFatEntryAsync(source, fatOffset, current, fatCache, cancellationToken).ConfigureAwait(false);
                if (next >= 0xFFFFFFF7u || next < 2)
                    break;
                current = next;
            }

            return chain;
        }

        private static async Task<uint> ReadFatEntryAsync(
            IReadOnlyBlockSource source,
            long fatOffset,
            uint cluster,
            Dictionary<uint, uint> fatCache,
            CancellationToken cancellationToken)
        {
            if (fatCache.TryGetValue(cluster, out uint cached))
                return cached;

            long entryByteOffset = fatOffset + ((long)cluster * 4);
            long sectorSize = Math.Max(512, source.LogicalSectorSize);
            long alignedOffset = (entryByteOffset / sectorSize) * sectorSize;

            byte[] sector = new byte[sectorSize];
            try
            {
                await source.ReadAtAsync(alignedOffset, sector, cancellationToken).ConfigureAwait(false);
                int entriesPerSector = (int)(sectorSize / 4);
                for (int i = 0; i < entriesPerSector; i++)
                {
                    long entryFileOffset = alignedOffset + (i * 4L) - fatOffset;
                    if (entryFileOffset < 0 || (entryFileOffset % 4) != 0)
                        continue;
                    long idx = entryFileOffset / 4;
                    if (idx < 0 || idx > uint.MaxValue)
                        continue;
                    uint val = BinaryPrimitives.ReadUInt32LittleEndian(sector.AsSpan(i * 4, 4));
                    fatCache[(uint)idx] = val;
                }
                return fatCache.TryGetValue(cluster, out uint resolved) ? resolved : 0xFFFFFFFFu;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                return 0xFFFFFFFFu;
            }
        }

        private static List<NtfsDataRun> BuildRunsFromClusters(List<uint> clusters)
        {
            var runs = new List<NtfsDataRun>();
            if (clusters.Count == 0) return runs;

            long runStart = clusters[0] - 2;
            long runLen = 1;
            for (int i = 1; i < clusters.Count; i++)
            {
                long lcn = clusters[i] - 2;
                if (lcn == runStart + runLen)
                {
                    runLen++;
                }
                else
                {
                    runs.Add(new NtfsDataRun { LcnStart = runStart, ClusterCount = runLen, IsSparse = false });
                    runStart = lcn;
                    runLen = 1;
                }
            }
            runs.Add(new NtfsDataRun { LcnStart = runStart, ClusterCount = runLen, IsSparse = false });
            return runs;
        }

        private static DateTime DecodeExFatTimestamp(uint ts)
        {
            if (ts == 0)
                return DateTime.UtcNow;
            try
            {
                int year = (int)(((ts >> 25) & 0x7F) + 1980);
                int month = (int)Math.Clamp((ts >> 21) & 0x0F, 1, 12);
                int maxDay = DateTime.DaysInMonth(Math.Clamp(year, 1980, 2107), month);
                int day = (int)Math.Clamp((ts >> 16) & 0x1F, 1, maxDay);
                int hour = (int)Math.Clamp((ts >> 11) & 0x1F, 0, 23);
                int min = (int)Math.Clamp((ts >> 5) & 0x3F, 0, 59);
                int sec = (int)Math.Clamp((ts & 0x1F) * 2, 0, 59);
                return new DateTime(year, month, day, hour, min, sec, DateTimeKind.Utc);
            }
            catch
            {
                return DateTime.UtcNow;
            }
        }
    }
}
