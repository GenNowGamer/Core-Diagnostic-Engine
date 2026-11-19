using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Text;
using CdeRecovery.Core.Models;

namespace CdeRecovery.Core.FileSystems
{
    public static class NtfsMftRecordParser
    {
        public const uint FileRecordMagic = 0x454C4946u; // "FILE"
        public const uint AttrStandardInformation = 0x10u;
        public const uint AttrAttributeList = 0x20u;
        public const uint AttrFileName = 0x30u;
        public const uint AttrData = 0x80u;
        public const uint AttrEndMarker = 0xFFFFFFFFu;

        /// <summary>
        /// Validates and restores the NTFS Multi-Sector Update Sequence Array (USA) fixup values across 512-byte strides.
        /// </summary>
        public static bool ApplyMultiSectorFixup(Span<byte> recordBuffer, out bool hasTornWriteWarning)
        {
            hasTornWriteWarning = false;
            if (recordBuffer.Length < 48)
                return false;

            uint magic = BinaryPrimitives.ReadUInt32LittleEndian(recordBuffer.Slice(0, 4));
            if (magic != FileRecordMagic)
                return false;

            ushort usaOffset = BinaryPrimitives.ReadUInt16LittleEndian(recordBuffer.Slice(4, 2));
            ushort usaCount = BinaryPrimitives.ReadUInt16LittleEndian(recordBuffer.Slice(6, 2));

            if (usaOffset < 40 || usaCount < 2 || usaOffset + (usaCount * 2) > recordBuffer.Length)
                return false;

            ushort expectedUsn = BinaryPrimitives.ReadUInt16LittleEndian(recordBuffer.Slice(usaOffset, 2));
            if (expectedUsn == 0)
            {
                // Uninitialized USN (e.g. minimal synthetic record without sector tail stamping)
                return true;
            }

            int sectorCount = usaCount - 1;
            for (int i = 0; i < sectorCount; i++)
            {
                int tailOffset = ((i + 1) * 512) - 2;
                if (tailOffset + 2 > recordBuffer.Length)
                    break;

                ushort actualTailUsn = BinaryPrimitives.ReadUInt16LittleEndian(recordBuffer.Slice(tailOffset, 2));
                if (actualTailUsn != expectedUsn)
                {
                    hasTornWriteWarning = true;
                }
                else
                {
                    ushort originalBytes = BinaryPrimitives.ReadUInt16LittleEndian(recordBuffer.Slice(usaOffset + ((i + 1) * 2), 2));
                    BinaryPrimitives.WriteUInt16LittleEndian(recordBuffer.Slice(tailOffset, 2), originalBytes);
                }
            }

            return true;
        }

        /// <summary>
        /// Decodes an NTFS non-resident compressed Runlist byte stream into VCN/LCN cluster extents.
        /// </summary>
        public static List<NtfsDataRun> DecodeDataRuns(ReadOnlySpan<byte> runlistBytes)
        {
            var runs = new List<NtfsDataRun>();
            int pos = 0;
            long currentVcn = 0;
            long currentLcn = 0;

            while (pos < runlistBytes.Length)
            {
                byte header = runlistBytes[pos];
                if (header == 0x00)
                    break;

                int lengthSize = header & 0x0F;
                int offsetSize = (header >> 4) & 0x0F;
                pos++;

                if (lengthSize <= 0 || lengthSize > 8 || offsetSize > 8 || pos + lengthSize + offsetSize > runlistBytes.Length)
                    break;

                long clusterCount = ReadUnsignedVariableInt(runlistBytes.Slice(pos, lengthSize));
                pos += lengthSize;

                if (clusterCount <= 0)
                    break;

                if (offsetSize == 0)
                {
                    // Sparse cluster run
                    runs.Add(new NtfsDataRun
                    {
                        VcnStart = currentVcn,
                        ClusterCount = clusterCount,
                        LcnStart = -1,
                        IsSparse = true
                    });
                }
                else
                {
                    long lcnDelta = ReadSignedVariableInt(runlistBytes.Slice(pos, offsetSize));
                    pos += offsetSize;
                    currentLcn += lcnDelta;

                    runs.Add(new NtfsDataRun
                    {
                        VcnStart = currentVcn,
                        ClusterCount = clusterCount,
                        LcnStart = currentLcn,
                        IsSparse = false
                    });
                }

                currentVcn += clusterCount;
            }

            return runs;
        }

        public sealed class NtfsAttributeListExtensionRef
        {
            public long StartingVcn { get; init; }
            public long MftRecordNumber { get; init; }
        }

        public sealed class NtfsParsedMftRecordResult
        {
            public RecoverableFileItem? Item { get; init; }
            public byte[]? AttributeListResidentBytes { get; init; }
            public List<NtfsDataRun>? AttributeListNonResidentRuns { get; init; }
            public long AttributeListRealSize { get; init; }
        }

        public static RecoverableFileItem? TryParseFileRecord(
            ReadOnlySpan<byte> rawRecord,
            long mftRecordNumber,
            long partitionStartOffset,
            int clusterSizeBytes)
        {
            return TryParseFileRecordDetailed(rawRecord, mftRecordNumber, partitionStartOffset, clusterSizeBytes)?.Item;
        }

        public static NtfsParsedMftRecordResult? TryParseFileRecordDetailed(
            ReadOnlySpan<byte> rawRecord,
            long mftRecordNumber,
            long partitionStartOffset,
            int clusterSizeBytes)
        {
            if (rawRecord.Length < 48)
                return null;

            uint magic = BinaryPrimitives.ReadUInt32LittleEndian(rawRecord.Slice(0, 4));
            if (magic != FileRecordMagic)
                return null;

            byte[] working = rawRecord.ToArray();
            if (!ApplyMultiSectorFixup(working, out bool hasTornWriteWarning))
                return null;

            ushort seqNumber = BinaryPrimitives.ReadUInt16LittleEndian(working.AsSpan(0x10, 2));
            ushort firstAttrOffset = BinaryPrimitives.ReadUInt16LittleEndian(working.AsSpan(0x14, 2));
            ushort flags = BinaryPrimitives.ReadUInt16LittleEndian(working.AsSpan(0x16, 2));
            ulong baseRecordRef = BinaryPrimitives.ReadUInt64LittleEndian(working.AsSpan(0x20, 8));

            // Skip extension MFT records that point to another base record
            if ((baseRecordRef & 0x0000FFFFFFFFFFFFUL) != 0)
                return null;

            bool inUse = (flags & 0x0001) != 0;
            bool isDirectory = (flags & 0x0002) != 0;
            bool isDeleted = !inUse;

            if (firstAttrOffset < 40 || firstAttrOffset >= working.Length)
                return null;

            string bestFileName = string.Empty;
            byte bestNamespace = 0xFF;
            long parentMftRecord = 5; // Default to Root '.' (Record 5)
            DateTime modifiedUtc = DateTime.UtcNow;
            long fnSize = 0;

            bool hasDataAttr = false;
            bool isResidentData = false;
            bool isCompressed = false;
            bool isEncrypted = false;
            int compressionUnitClusters = 16;
            long dataRealSize = 0;
            long dataAllocSize = 0;
            byte[] residentBytes = Array.Empty<byte>();
            var dataRuns = new List<NtfsDataRun>();

            bool hasAttributeList = false;
            byte[]? attrListResidentBytes = null;
            List<NtfsDataRun>? attrListNonResidentRuns = null;
            long attrListRealSize = 0;

            int pos = firstAttrOffset;
            while (pos > 0 && pos + 16 <= working.Length)
            {
                uint attrType = BinaryPrimitives.ReadUInt32LittleEndian(working.AsSpan(pos, 4));
                if (attrType == AttrEndMarker || attrType == 0)
                    break;

                uint attrLen = BinaryPrimitives.ReadUInt32LittleEndian(working.AsSpan(pos + 4, 4));
                if (attrLen < 16 || pos + (int)attrLen > working.Length)
                    break;

                byte nonResident = working[pos + 8];
                byte attrNameLen = working[pos + 9];

                if (attrType == AttrStandardInformation && nonResident == 0 && pos + 24 <= working.Length)
                {
                    uint valLen = BinaryPrimitives.ReadUInt32LittleEndian(working.AsSpan(pos + 16, 4));
                    ushort valOff = BinaryPrimitives.ReadUInt16LittleEndian(working.AsSpan(pos + 20, 2));
                    if (valLen >= 16 && pos + valOff + 16 <= working.Length)
                    {
                        long fileTime = BinaryPrimitives.ReadInt64LittleEndian(working.AsSpan(pos + valOff + 8, 8));
                        if (fileTime > 0)
                        {
                            try { modifiedUtc = DateTime.FromFileTimeUtc(fileTime); } catch { }
                        }
                    }
                    if (valLen >= 36 && pos + valOff + 36 <= working.Length)
                    {
                        uint fileAttrs = BinaryPrimitives.ReadUInt32LittleEndian(working.AsSpan(pos + valOff + 32, 4));
                        // Note: Do not set isCompressed from $STANDARD_INFORMATION FILE_ATTRIBUTE_COMPRESSED (0x0800),
                        // because files in a compressed directory can carry that attribute even when their unnamed
                        // $DATA stream is stored uncompressed (or resident). Actual LZNT1 stream compression is
                        // governed by the $DATA attribute header flag (0x0001) and non-resident compression unit.
                        if ((fileAttrs & 0x4000u) != 0) isEncrypted = true;
                    }
                }
                else if (attrType == AttrAttributeList)
                {
                    hasAttributeList = true;
                    if (nonResident == 0 && pos + 24 <= working.Length)
                    {
                        uint valLen = BinaryPrimitives.ReadUInt32LittleEndian(working.AsSpan(pos + 16, 4));
                        ushort valOff = BinaryPrimitives.ReadUInt16LittleEndian(working.AsSpan(pos + 20, 2));
                        if (pos + valOff + (int)valLen <= working.Length)
                        {
                            attrListResidentBytes = working.AsSpan(pos + valOff, (int)valLen).ToArray();
                            attrListRealSize = valLen;
                        }
                    }
                    else if (nonResident == 1 && pos + 64 <= working.Length)
                    {
                        ushort runOff = BinaryPrimitives.ReadUInt16LittleEndian(working.AsSpan(pos + 0x20, 2));
                        attrListRealSize = BinaryPrimitives.ReadInt64LittleEndian(working.AsSpan(pos + 0x30, 8));
                        if (runOff >= 0x40 && runOff < attrLen)
                        {
                            attrListNonResidentRuns = DecodeDataRuns(working.AsSpan(pos + runOff, (int)attrLen - runOff));
                        }
                    }
                }
                else if (attrType == AttrFileName && nonResident == 0 && pos + 24 <= working.Length)
                {
                    uint valLen = BinaryPrimitives.ReadUInt32LittleEndian(working.AsSpan(pos + 16, 4));
                    ushort valOff = BinaryPrimitives.ReadUInt16LittleEndian(working.AsSpan(pos + 20, 2));
                    if (valLen >= 0x42 && pos + valOff + (int)valLen <= working.Length)
                    {
                        var body = working.AsSpan(pos + valOff, (int)valLen);
                        ulong parentRef = BinaryPrimitives.ReadUInt64LittleEndian(body.Slice(0, 8));
                        long parentIdx = (long)(parentRef & 0x0000FFFFFFFFFFFFUL);
                        long modTime = BinaryPrimitives.ReadInt64LittleEndian(body.Slice(0x10, 8));
                        long realSz = BinaryPrimitives.ReadInt64LittleEndian(body.Slice(0x30, 8));
                        byte nameChars = body[0x40];
                        byte nameSpace = body[0x41];

                        if (0x42 + (nameChars * 2) <= body.Length)
                        {
                            string candidateName = Encoding.Unicode.GetString(body.Slice(0x42, nameChars * 2));
                            // Prefer Win32 (1), Win32+DOS (3), or POSIX (0) over DOS 8.3 (2)
                            if (string.IsNullOrEmpty(bestFileName) || (bestNamespace == 2 && nameSpace != 2))
                            {
                                bestFileName = candidateName;
                                bestNamespace = nameSpace;
                                parentMftRecord = parentIdx;
                                fnSize = realSz;
                                if (modTime > 0 && modifiedUtc == DateTime.UtcNow)
                                {
                                    try { modifiedUtc = DateTime.FromFileTimeUtc(modTime); } catch { }
                                }
                            }
                        }
                    }
                }
                else if (attrType == AttrData && attrNameLen == 0) // Default unnamed $DATA stream
                {
                    hasDataAttr = true;
                    ushort attrFlags = pos + 14 <= working.Length
                        ? BinaryPrimitives.ReadUInt16LittleEndian(working.AsSpan(pos + 12, 2))
                        : (ushort)0;
                    if ((attrFlags & 0x4000) != 0) isEncrypted = true;

                    if (nonResident == 0 && pos + 24 <= working.Length)
                    {
                        uint valLen = BinaryPrimitives.ReadUInt32LittleEndian(working.AsSpan(pos + 16, 4));
                        ushort valOff = BinaryPrimitives.ReadUInt16LittleEndian(working.AsSpan(pos + 20, 2));
                        if (pos + valOff + (int)valLen <= working.Length)
                        {
                            isResidentData = true;
                            dataRealSize = valLen;
                            dataAllocSize = valLen;
                            residentBytes = working.AsSpan(pos + valOff, (int)valLen).ToArray();
                        }
                    }
                    else if (nonResident == 1 && pos + 64 <= working.Length)
                    {
                        isResidentData = false;
                        ushort runOff = BinaryPrimitives.ReadUInt16LittleEndian(working.AsSpan(pos + 0x20, 2));
                        ushort compUnitExp = BinaryPrimitives.ReadUInt16LittleEndian(working.AsSpan(pos + 0x22, 2));
                        if (compUnitExp > 0 && compUnitExp < 16)
                        {
                            compressionUnitClusters = 1 << compUnitExp;
                            if ((attrFlags & 0x0001) != 0) isCompressed = true;
                        }
                        else if ((attrFlags & 0x0001) != 0)
                        {
                            isCompressed = true;
                        }
                        dataAllocSize = BinaryPrimitives.ReadInt64LittleEndian(working.AsSpan(pos + 0x28, 8));
                        dataRealSize = BinaryPrimitives.ReadInt64LittleEndian(working.AsSpan(pos + 0x30, 8));
                        if (runOff >= 0x40 && runOff < attrLen)
                        {
                            var runSlice = working.AsSpan(pos + runOff, (int)attrLen - runOff);
                            dataRuns.AddRange(DecodeDataRuns(runSlice));
                        }
                    }
                }

                pos += (int)attrLen;
            }

            if (string.IsNullOrWhiteSpace(bestFileName))
                return null;

            if (!isDirectory && !hasDataAttr && !hasAttributeList)
                return null;

            var item = new RecoverableFileItem
            {
                MftRecordNumber = mftRecordNumber,
                SequenceNumber = seqNumber,
                ParentMftRecordNumber = parentMftRecord,
                FileName = bestFileName,
                ReconstructedPath = bestFileName,
                SizeBytes = isDirectory ? 0 : (hasDataAttr ? dataRealSize : fnSize),
                AllocatedSizeBytes = isDirectory ? 0 : dataAllocSize,
                IsDirectory = isDirectory,
                IsDeleted = isDeleted,
                IsResident = isResidentData,
                IsCompressed = isCompressed,
                IsEncrypted = isEncrypted,
                CompressionUnitClusters = compressionUnitClusters,
                HasTornWriteWarning = hasTornWriteWarning,
                ModifiedUtc = modifiedUtc,
                PartitionStartOffset = partitionStartOffset,
                ClusterSizeBytes = clusterSizeBytes,
                ResidentData = residentBytes,
                DataRuns = dataRuns
            };

            return new NtfsParsedMftRecordResult
            {
                Item = item,
                AttributeListResidentBytes = attrListResidentBytes,
                AttributeListNonResidentRuns = attrListNonResidentRuns,
                AttributeListRealSize = attrListRealSize
            };
        }

        public static List<NtfsAttributeListExtensionRef> ParseAttributeListDataExtensions(ReadOnlySpan<byte> attrListBytes)
        {
            var list = new List<NtfsAttributeListExtensionRef>();
            int pos = 0;
            while (pos + 24 <= attrListBytes.Length)
            {
                uint attrType = BinaryPrimitives.ReadUInt32LittleEndian(attrListBytes.Slice(pos, 4));
                ushort recLen = BinaryPrimitives.ReadUInt16LittleEndian(attrListBytes.Slice(pos + 4, 2));
                if (recLen < 24 || pos + recLen > attrListBytes.Length)
                    break;

                byte nameLen = attrListBytes[pos + 6];
                long startingVcn = BinaryPrimitives.ReadInt64LittleEndian(attrListBytes.Slice(pos + 8, 8));
                ulong baseFileRef = BinaryPrimitives.ReadUInt64LittleEndian(attrListBytes.Slice(pos + 16, 8));
                long extMftRecord = (long)(baseFileRef & 0x0000FFFFFFFFFFFFUL);

                if (attrType == AttrData && nameLen == 0 && extMftRecord > 0)
                {
                    list.Add(new NtfsAttributeListExtensionRef
                    {
                        StartingVcn = startingVcn,
                        MftRecordNumber = extMftRecord
                    });
                }

                pos += recLen;
            }
            return list;
        }

        public static (long StartingVcn, long RealSize, long AllocSize, bool IsCompressed, int CompressionUnitClusters, List<NtfsDataRun> Runs)
            ParseExtensionRecordData(ReadOnlySpan<byte> rawRecord)
        {
            var runs = new List<NtfsDataRun>();
            if (rawRecord.Length < 48)
                return (0, 0, 0, false, 16, runs);

            byte[] working = rawRecord.ToArray();
            if (!ApplyMultiSectorFixup(working, out _))
                return (0, 0, 0, false, 16, runs);

            ushort firstAttrOffset = BinaryPrimitives.ReadUInt16LittleEndian(working.AsSpan(20, 2));
            if (firstAttrOffset < 40 || firstAttrOffset >= working.Length)
                return (0, 0, 0, false, 16, runs);

            long bestStartingVcn = 0;
            long realSize = 0;
            long allocSize = 0;
            bool isCompressed = false;
            int compressionUnitClusters = 16;

            int pos = firstAttrOffset;
            while (pos > 0 && pos + 16 <= working.Length)
            {
                uint attrType = BinaryPrimitives.ReadUInt32LittleEndian(working.AsSpan(pos, 4));
                if (attrType == AttrEndMarker || attrType == 0)
                    break;

                uint attrLen = BinaryPrimitives.ReadUInt32LittleEndian(working.AsSpan(pos + 4, 4));
                if (attrLen < 16 || pos + (int)attrLen > working.Length)
                    break;

                byte nonResident = working[pos + 8];
                byte attrNameLen = working[pos + 9];

                if (attrType == AttrData && attrNameLen == 0 && nonResident == 1 && pos + 64 <= working.Length)
                {
                    ushort attrFlags = BinaryPrimitives.ReadUInt16LittleEndian(working.AsSpan(pos + 12, 2));
                    if ((attrFlags & 0x0001) != 0) isCompressed = true;

                    long attrStartVcn = BinaryPrimitives.ReadInt64LittleEndian(working.AsSpan(pos + 0x10, 8));
                    if (runs.Count == 0 || attrStartVcn < bestStartingVcn)
                        bestStartingVcn = attrStartVcn;
                    ushort runOff = BinaryPrimitives.ReadUInt16LittleEndian(working.AsSpan(pos + 0x20, 2));
                    ushort compUnitExp = BinaryPrimitives.ReadUInt16LittleEndian(working.AsSpan(pos + 0x22, 2));
                    if (compUnitExp > 0 && compUnitExp < 16)
                        compressionUnitClusters = 1 << compUnitExp;

                    long extAlloc = BinaryPrimitives.ReadInt64LittleEndian(working.AsSpan(pos + 0x28, 8));
                    long extReal = BinaryPrimitives.ReadInt64LittleEndian(working.AsSpan(pos + 0x30, 8));
                    if (extAlloc > allocSize) allocSize = extAlloc;
                    if (extReal > realSize) realSize = extReal;

                    if (runOff >= 0x40 && runOff < attrLen)
                    {
                        runs.AddRange(DecodeDataRuns(working.AsSpan(pos + runOff, (int)attrLen - runOff)));
                    }
                }

                pos += (int)attrLen;
            }

            return (bestStartingVcn, realSize, allocSize, isCompressed, compressionUnitClusters, runs);
        }

        private static long ReadUnsignedVariableInt(ReadOnlySpan<byte> bytes)
        {
            ulong value = 0;
            for (int i = 0; i < bytes.Length; i++)
            {
                value |= (ulong)bytes[i] << (i * 8);
            }
            return (long)value;
        }

        private static long ReadSignedVariableInt(ReadOnlySpan<byte> bytes)
        {
            long value = 0;
            for (int i = 0; i < bytes.Length; i++)
            {
                value |= (long)bytes[i] << (i * 8);
            }

            // Sign-extend if most significant bit of top byte is set
            if (bytes.Length < 8 && (bytes[bytes.Length - 1] & 0x80) != 0)
            {
                long mask = -1L << (bytes.Length * 8);
                value |= mask;
            }

            return value;
        }
    }
}
