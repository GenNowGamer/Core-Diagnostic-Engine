using System;
using System.Buffers.Binary;
using System.IO;

namespace CdeRecovery.Core.FileSystems
{
    /// <summary>
    /// Standard NTFS LZNT1 decompression for compressed $DATA compression units.
    /// </summary>
    public static class NtfsLznt1Decompressor
    {
        public const int ChunkMaxUncompressedBytes = 4096;

        /// <summary>
        /// Decompresses a single NTFS LZNT1 compressed unit (up to compressionUnitBytes).
        /// </summary>
        public static byte[] DecompressUnit(ReadOnlySpan<byte> compressedUnit, int maxOutputBytes)
        {
            if (compressedUnit.IsEmpty || maxOutputBytes <= 0)
                return Array.Empty<byte>();

            using var output = new MemoryStream(Math.Min(maxOutputBytes, 65536));
            byte[] chunkBuffer = new byte[ChunkMaxUncompressedBytes];
            int inPos = 0;

            while (inPos + 2 <= compressedUnit.Length && output.Length < maxOutputBytes)
            {
                ushort header = BinaryPrimitives.ReadUInt16LittleEndian(compressedUnit.Slice(inPos, 2));
                inPos += 2;
                if (header == 0)
                    break;

                int chunkSize = (header & 0x0FFF) + 1;
                bool isCompressed = (header & 0x8000) != 0;

                int available = Math.Min(chunkSize, compressedUnit.Length - inPos);
                if (available <= 0)
                    break;

                if (!isCompressed)
                {
                    int toWrite = Math.Min(available, maxOutputBytes - (int)output.Length);
                    output.Write(compressedUnit.Slice(inPos, toWrite));
                    inPos += available;
                    continue;
                }

                int chunkEnd = inPos + available;
                int outPos = 0;

                while (inPos < chunkEnd && outPos < ChunkMaxUncompressedBytes)
                {
                    byte flags = compressedUnit[inPos++];
                    for (int bit = 0; bit < 8 && inPos < chunkEnd && outPos < ChunkMaxUncompressedBytes; bit++)
                    {
                        if ((flags & (1 << bit)) == 0)
                        {
                            chunkBuffer[outPos++] = compressedUnit[inPos++];
                        }
                        else
                        {
                            if (inPos + 2 > chunkEnd)
                            {
                                inPos = chunkEnd;
                                break;
                            }

                            ushort tuple = BinaryPrimitives.ReadUInt16LittleEndian(compressedUnit.Slice(inPos, 2));
                            inPos += 2;

                            int shift = 12;
                            int threshold = 0x10;
                            while (outPos > threshold)
                            {
                                threshold <<= 1;
                                shift--;
                            }

                            int lengthMask = (1 << shift) - 1;
                            int length = (tuple & lengthMask) + 3;
                            int offset = (tuple >> shift) + 1;

                            if (offset <= 0 || offset > outPos)
                            {
                                // Corrupt back-reference; zero-fill safely rather than crashing
                                int safeLen = Math.Min(length, ChunkMaxUncompressedBytes - outPos);
                                Array.Clear(chunkBuffer, outPos, safeLen);
                                outPos += safeLen;
                                continue;
                            }

                            for (int k = 0; k < length && outPos < ChunkMaxUncompressedBytes; k++)
                            {
                                chunkBuffer[outPos] = chunkBuffer[outPos - offset];
                                outPos++;
                            }
                        }
                    }
                }

                inPos = chunkEnd;
                int writeCount = Math.Min(outPos, maxOutputBytes - (int)output.Length);
                if (writeCount > 0)
                    output.Write(chunkBuffer, 0, writeCount);
            }

            return output.ToArray();
        }
    }
}
