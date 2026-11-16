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

        public static RecoverableFileItem? TryParseFileRecord(
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
            bool isResidentData = true;
            long dataRealSize = 0;
            long dataAllocSize = 0;
            byte[] residentBytes = Array.Empty<byte>();
            var dataRuns = new List<NtfsDataRun>();

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

            if (!isDirectory && !hasDataAttr)
                return null;

            return new RecoverableFileItem
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
                HasTornWriteWarning = hasTornWriteWarning,
                ModifiedUtc = modifiedUtc,
                PartitionStartOffset = partitionStartOffset,
                ClusterSizeBytes = clusterSizeBytes,
                ResidentData = residentBytes,
                DataRuns = dataRuns
            };
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
