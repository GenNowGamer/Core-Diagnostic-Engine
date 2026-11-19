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
    public static class Fat32FileRecoveryEngine
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

            int bps = BinaryPrimitives.ReadUInt16LittleEndian(vbr.AsSpan(0x0B, 2));
            int spc = vbr[0x0D];
            int reservedSectors = BinaryPrimitives.ReadUInt16LittleEndian(vbr.AsSpan(0x0E, 2));
            int numFats = vbr[0x10];
            uint fatSizeSectors = BinaryPrimitives.ReadUInt32LittleEndian(vbr.AsSpan(0x24, 4));
            uint rootCluster = BinaryPrimitives.ReadUInt32LittleEndian(vbr.AsSpan(0x2C, 4));

            if (bps < 512 || spc <= 0 || fatSizeSectors == 0 || rootCluster < 2)
            {
                // Fall back to FAT32 Backup Boot Sector at sector 6 (or partition.BackupBootSectorOffset)
                long backupVbrOffset = partition.BackupBootSectorOffset > partition.PartitionStartOffset
                    ? partition.BackupBootSectorOffset
                    : partition.PartitionStartOffset + (6L * sectorSize);
                if (backupVbrOffset + vbr.Length <= source.Length)
                {
                    await source.ReadAtAsync(backupVbrOffset, vbr, cancellationToken).ConfigureAwait(false);
                    bps = BinaryPrimitives.ReadUInt16LittleEndian(vbr.AsSpan(0x0B, 2));
                    spc = vbr[0x0D];
                    reservedSectors = BinaryPrimitives.ReadUInt16LittleEndian(vbr.AsSpan(0x0E, 2));
                    numFats = vbr[0x10];
                    fatSizeSectors = BinaryPrimitives.ReadUInt32LittleEndian(vbr.AsSpan(0x24, 4));
                    rootCluster = BinaryPrimitives.ReadUInt32LittleEndian(vbr.AsSpan(0x2C, 4));
                }
            }

            if (bps < 512 || spc <= 0 || fatSizeSectors == 0 || rootCluster < 2)
                throw new InvalidDataException("Invalid FAT32 BPB geometry; cannot scan directory tree.");

            int clusterSize = bps * spc;
            long fatOffset = partition.PartitionStartOffset + ((long)reservedSectors * bps);
            long fatByteLength = (long)fatSizeSectors * bps;
            long dataAreaOffset = fatOffset + ((long)numFats * fatByteLength);
            long partBytes = partition.PartitionSizeBytes > 0 ? partition.PartitionSizeBytes : (source.Length - partition.PartitionStartOffset);
            long maxCluster = Math.Max(2, ((partBytes - (dataAreaOffset - partition.PartitionStartOffset)) / clusterSize) + 2);

            var fatCache = new Dictionary<uint, uint>();
            var files = new List<RecoverableFileItem>();
            var dirQueue = new Queue<(uint Cluster, string PathPrefix, bool ParentDeleted)>();
            var visitedDirs = new HashSet<uint>();

            dirQueue.Enqueue((rootCluster, string.Empty, false));
            visitedDirs.Add(rootCluster);

            int effectiveLimit = maxFiles <= 0 ? int.MaxValue : maxFiles;

            while (dirQueue.Count > 0 && files.Count < effectiveLimit)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var (dirCluster, prefix, parentDeleted) = dirQueue.Dequeue();

                var dirClusters = await ReadClusterChainAsync(
                    source, fatOffset, maxCluster, dirCluster, isContiguousFallback: parentDeleted, maxClusters: 512, fatCache, cancellationToken).ConfigureAwait(false);

                if (dirClusters.Count == 0)
                    continue;

                var lfnStack = new Stack<string>();

                foreach (uint clus in dirClusters)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    long clusOffset = dataAreaOffset + ((long)(clus - 2) * clusterSize);
                    if (clusOffset + clusterSize > source.Length)
                        break;

                    byte[] clusBuf = new byte[clusterSize];
                    try
                    {
                        await source.ReadAtAsync(clusOffset, clusBuf, cancellationToken).ConfigureAwait(false);
                    }
                    catch (Exception ex) when (ex is not OperationCanceledException)
                    {
                        lfnStack.Clear();
                        continue;
                    }

                    bool endOfDir = ParseDirectoryCluster(clusBuf, lfnStack, parentDeleted, out var parsedEntries);
                    foreach (var pe in parsedEntries)
                    {
                        if (pe.IsDeleted && !includeDeleted)
                            continue;

                        string relPath = string.IsNullOrEmpty(prefix) ? pe.Name : Path.Combine(prefix, pe.Name);

                        if (pe.IsDir)
                        {
                            if (pe.StartCluster >= 2 && pe.StartCluster < maxCluster && visitedDirs.Add(pe.StartCluster))
                            {
                                dirQueue.Enqueue((pe.StartCluster, relPath, pe.IsDeleted));
                            }
                            continue;
                        }

                        var runs = new List<NtfsDataRun>();
                        if (pe.FileSize > 0 && pe.StartCluster >= 2 && pe.StartCluster < maxCluster)
                        {
                            int neededClusters = (int)((pe.FileSize + clusterSize - 1) / clusterSize);
                            var chain = await ReadClusterChainAsync(
                                source, fatOffset, maxCluster, pe.StartCluster, isContiguousFallback: pe.IsDeleted, maxClusters: neededClusters, fatCache, cancellationToken).ConfigureAwait(false);
                            runs.AddRange(BuildRunsFromClusters(chain));
                        }

                        files.Add(new RecoverableFileItem
                        {
                            MftRecordNumber = pe.StartCluster,
                            FileName = pe.Name,
                            ReconstructedPath = relPath,
                            SizeBytes = pe.FileSize,
                            AllocatedSizeBytes = (long)runs.Sum(r => r.ClusterCount) * clusterSize,
                            IsDirectory = false,
                            IsDeleted = pe.IsDeleted,
                            IsResident = false,
                            ModifiedUtc = pe.ModifiedUtc,
                            PartitionStartOffset = dataAreaOffset,
                            ClusterSizeBytes = clusterSize,
                            DataRuns = runs
                        });

                        if (files.Count % 250 == 0)
                            progress?.Report($"Scanned FAT32 directory tree — found {files.Count:N0} file(s)...");

                        if (files.Count >= effectiveLimit)
                            break;
                    }

                    if (endOfDir || files.Count >= effectiveLimit)
                        break;
                }
            }

            return files.OrderBy(f => f.ReconstructedPath, StringComparer.OrdinalIgnoreCase).ToList();
        }

        private sealed record ParsedFatDirEntry(string Name, bool IsDir, bool IsDeleted, uint StartCluster, long FileSize, DateTime ModifiedUtc);

        private static bool ParseDirectoryCluster(
            byte[] clusBuf,
            Stack<string> lfnStack,
            bool parentDeleted,
            out List<ParsedFatDirEntry> entries)
        {
            entries = new List<ParsedFatDirEntry>();
            for (int off = 0; off + 32 <= clusBuf.Length; off += 32)
            {
                var entry = clusBuf.AsSpan(off, 32);
                byte firstByte = entry[0];
                if (firstByte == 0x00)
                    return true;

                byte attr = entry[0x0B];
                if ((attr & 0x3F) == 0x0F)
                {
                    lfnStack.Push(DecodeLfnPart(entry));
                    continue;
                }

                if ((attr & 0x08) != 0)
                {
                    lfnStack.Clear();
                    continue;
                }

                bool isDeleted = firstByte == 0xE5 || parentDeleted;
                string name = lfnStack.Count > 0
                    ? string.Concat(lfnStack)
                    : DecodeShortName(entry, firstByte == 0xE5);
                lfnStack.Clear();

                if (string.IsNullOrWhiteSpace(name) || name == "." || name == "..")
                    continue;

                bool isDir = (attr & 0x10) != 0;
                uint highClus = BinaryPrimitives.ReadUInt16LittleEndian(entry.Slice(0x14, 2));
                uint lowClus = BinaryPrimitives.ReadUInt16LittleEndian(entry.Slice(0x1A, 2));
                uint startCluster = (highClus << 16) | lowClus;
                long fileSize = BinaryPrimitives.ReadUInt32LittleEndian(entry.Slice(0x1C, 4));
                DateTime modifiedUtc = DecodeDosDateTime(
                    BinaryPrimitives.ReadUInt16LittleEndian(entry.Slice(0x18, 2)),
                    BinaryPrimitives.ReadUInt16LittleEndian(entry.Slice(0x16, 2)));

                entries.Add(new ParsedFatDirEntry(name, isDir, isDeleted, startCluster, fileSize, modifiedUtc));
            }
            return false;
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

            var visited = new HashSet<uint>();
            uint current = startCluster;

            while (current >= 2 && current < maxCluster && chain.Count < maxClusters && visited.Add(current))
            {
                chain.Add(current);
                uint next = await ReadFat32EntryAsync(source, fatOffset, current, fatCache, cancellationToken).ConfigureAwait(false);

                if (next == 0 && isContiguousFallback)
                {
                    // FAT chain cleared on delete; fall back to contiguous cluster assumption
                    while (chain.Count < maxClusters && current + 1 < maxCluster)
                    {
                        current++;
                        chain.Add(current);
                    }
                    break;
                }

                if (next >= 0x0FFFFFF7u || next < 2)
                    break;

                current = next;
            }

            return chain;
        }

        private static async Task<uint> ReadFat32EntryAsync(
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
            int offsetInSector = (int)(entryByteOffset - alignedOffset);

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
                    uint val = BinaryPrimitives.ReadUInt32LittleEndian(sector.AsSpan(i * 4, 4)) & 0x0FFFFFFFu;
                    fatCache[(uint)idx] = val;
                }
                return fatCache.TryGetValue(cluster, out uint resolved) ? resolved : 0x0FFFFFFFu;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                return 0x0FFFFFFFu;
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

        private static string DecodeLfnPart(ReadOnlySpan<byte> entry)
        {
            var sb = new StringBuilder(13);
            ReadUtf16Chars(entry.Slice(0x01, 10), sb);
            ReadUtf16Chars(entry.Slice(0x0E, 12), sb);
            ReadUtf16Chars(entry.Slice(0x1C, 4), sb);
            return sb.ToString();
        }

        private static void ReadUtf16Chars(ReadOnlySpan<byte> bytes, StringBuilder sb)
        {
            for (int i = 0; i + 1 < bytes.Length; i += 2)
            {
                char ch = (char)BinaryPrimitives.ReadUInt16LittleEndian(bytes.Slice(i, 2));
                if (ch == '\0' || ch == '\uFFFF')
                    return;
                sb.Append(ch);
            }
        }

        private static string DecodeShortName(ReadOnlySpan<byte> entry, bool isDeletedFirstByte)
        {
            byte[] nameBytes = entry.Slice(0, 8).ToArray();
            if (isDeletedFirstByte)
                nameBytes[0] = (byte)'_';

            string baseName = Encoding.ASCII.GetString(nameBytes).TrimEnd(' ');
            string ext = Encoding.ASCII.GetString(entry.Slice(8, 3)).TrimEnd(' ');
            return string.IsNullOrEmpty(ext) ? baseName : $"{baseName}.{ext}";
        }

        private static DateTime DecodeDosDateTime(ushort dosDate, ushort dosTime)
        {
            if (dosDate == 0)
                return DateTime.UtcNow;
            try
            {
                int year = ((dosDate >> 9) & 0x7F) + 1980;
                int month = Math.Clamp((dosDate >> 5) & 0x0F, 1, 12);
                int maxDay = DateTime.DaysInMonth(Math.Clamp(year, 1980, 2107), month);
                int day = Math.Clamp(dosDate & 0x1F, 1, maxDay);
                int hour = Math.Clamp((dosTime >> 11) & 0x1F, 0, 23);
                int min = Math.Clamp((dosTime >> 5) & 0x3F, 0, 59);
                int sec = Math.Clamp((dosTime & 0x1F) * 2, 0, 59);
                return new DateTime(year, month, day, hour, min, sec, DateTimeKind.Utc);
            }
            catch
            {
                return DateTime.UtcNow;
            }
        }
    }
}
