using System;
using System.Buffers.Binary;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using CdeRecovery.Core.Partitioning;
using Microsoft.Win32.SafeHandles;

namespace CdeRecovery.Core.Imaging
{
    public enum DiskFixtureScenario
    {
        HealthyGptNtfs,
        DamagedPrimaryGpt_ValidBackupGpt,
        DamagedBackupGpt_ValidPrimaryGpt,
        DamagedNtfsPrimaryVbr_ValidBackupVbr,
        SeverelyDamagedNtfsMft,
        WipedPartitionTable_LostNtfsPartition,
        MalformedMbrSignature_S20,
        ProtectiveMbrMismatch_S21,
        BitLockerEncryptedPartition
    }

    public static class DiskFixtureBuilder
    {
        private const uint FSCTL_SET_SPARSE = 0x000900C4;

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(
            SafeFileHandle hDevice,
            uint dwIoControlCode,
            IntPtr lpInBuffer,
            uint nInBufferSize,
            IntPtr lpOutBuffer,
            uint nOutBufferSize,
            out uint lpBytesReturned,
            IntPtr lpOverlapped);

        /// <summary>
        /// Creates a realistic binary disk image fixture (uses NTFS sparse files when capacity > 64 MiB so even a 10 TB test fixture takes &lt; 1 MB on disk).
        /// </summary>
        public static void CreateFixtureImage(
            string outputPath,
            DiskFixtureScenario scenario,
            long capacityBytes = 64L * 1024 * 1024,
            int logicalSectorSize = 512,
            string volumeLabel = "Friend10TBData")
        {
            if (logicalSectorSize != 512 && logicalSectorSize != 4096)
                throw new ArgumentOutOfRangeException(nameof(logicalSectorSize));

            long totalSectors = capacityBytes / logicalSectorSize;
            if (totalSectors < 4096)
                throw new ArgumentOutOfRangeException(nameof(capacityBytes), "Capacity must be at least 4096 sectors.");

            string fullPath = Path.GetFullPath(outputPath);
            Directory.CreateDirectory(Path.GetDirectoryName(fullPath)!);

            using var fs = new FileStream(fullPath, FileMode.Create, FileAccess.ReadWrite, FileShare.Read);
            if (capacityBytes > 64L * 1024 * 1024)
            {
                // Mark file sparse on NTFS so 10 TB logical size uses almost zero physical disk blocks
                DeviceIoControl(fs.SafeFileHandle, FSCTL_SET_SPARSE, IntPtr.Zero, 0, IntPtr.Zero, 0, out _, IntPtr.Zero);
            }
            fs.SetLength(capacityBytes);

            ulong partFirstLba = (ulong)((1024L * 1024L) / logicalSectorSize); // 1 MiB aligned (LBA 2048 @ 512B, LBA 256 @ 4Kn)
            int entriesSectors = (128 * 128 + logicalSectorSize - 1) / logicalSectorSize;
            ulong partLastLba = (ulong)totalSectors - (ulong)entriesSectors - 2UL;
            long partSectors = (long)(partLastLba - partFirstLba + 1);
            long partStartOffset = (long)partFirstLba * logicalSectorSize;
            long partSizeBytes = partSectors * logicalSectorSize;

            Guid diskGuid = new("11223344-5566-7788-99AA-BBCCDDEEFF00");
            Guid partGuid = new("A1B2C3D4-E5F6-4789-ABCD-0123456789AB");

            var (primHdr, primHdrOff, primEnt, primEntOff, bakHdr, bakHdrOff, bakEnt, bakEntOff) =
                GptAnalyzer.BuildGptForDiscoveredPartition(
                    diskGuid,
                    GptAnalyzer.GuidMsftBasicData,
                    partGuid,
                    partFirstLba,
                    partLastLba,
                    volumeLabel,
                    logicalSectorSize,
                    totalSectors);

            byte[] mbrSector = MbrAnalyzer.BuildProtectiveMbrSector(totalSectors, logicalSectorSize);

            if (scenario == DiskFixtureScenario.MalformedMbrSignature_S20)
            {
                mbrSector[510] = 0x00;
                mbrSector[511] = 0x00;
            }
            else if (scenario == DiskFixtureScenario.ProtectiveMbrMismatch_S21)
            {
                // Corrupt Protective MBR start LBA to 63 instead of 1
                BinaryPrimitives.WriteUInt32LittleEndian(mbrSector.AsSpan(446 + 8, 4), 63u);
            }

            if (scenario != DiskFixtureScenario.WipedPartitionTable_LostNtfsPartition)
            {
                // Write Sector 0
                fs.Seek(0, SeekOrigin.Begin);
                fs.Write(mbrSector);

                // Write Primary GPT unless scenario corrupts it
                if (scenario == DiskFixtureScenario.DamagedPrimaryGpt_ValidBackupGpt)
                {
                    byte[] corruptedPrim = (byte[])primHdr.Clone();
                    // Corrupt signature & CRC
                    corruptedPrim[0] = (byte)'X';
                    corruptedPrim[1] = (byte)'X';
                    fs.Seek(primHdrOff, SeekOrigin.Begin);
                    fs.Write(corruptedPrim);
                    // Zero out primary entries
                    fs.Seek(primEntOff, SeekOrigin.Begin);
                    fs.Write(new byte[primEnt.Length]);
                }
                else
                {
                    fs.Seek(primHdrOff, SeekOrigin.Begin);
                    fs.Write(primHdr);
                    fs.Seek(primEntOff, SeekOrigin.Begin);
                    fs.Write(primEnt);
                }

                // Write Backup GPT unless scenario corrupts it
                if (scenario == DiskFixtureScenario.DamagedBackupGpt_ValidPrimaryGpt)
                {
                    byte[] corruptedBak = (byte[])bakHdr.Clone();
                    corruptedBak[16] ^= 0xFF; // flip CRC byte
                    fs.Seek(bakEntOff, SeekOrigin.Begin);
                    fs.Write(new byte[bakEnt.Length]);
                    fs.Seek(bakHdrOff, SeekOrigin.Begin);
                    fs.Write(corruptedBak);
                }
                else
                {
                    fs.Seek(bakEntOff, SeekOrigin.Begin);
                    fs.Write(bakEnt);
                    fs.Seek(bakHdrOff, SeekOrigin.Begin);
                    fs.Write(bakHdr);
                }
            }

            // Build NTFS volume inside the partition (partStartOffset .. partStartOffset + partSizeBytes)
            int sectorsPerCluster = logicalSectorSize == 512 ? 8 : 1; // 4096-byte clusters
            int clusterSize = logicalSectorSize * sectorsPerCluster;
            long mftCluster = 4;
            long mftMirrCluster = 16;

            byte[] ntfsVbr = BuildNtfsBootSector(
                logicalSectorSize,
                sectorsPerCluster,
                totalVolumeSectors: partSectors - 1,
                mftCluster: mftCluster,
                mftMirrCluster: mftMirrCluster,
                serialNumber: 0x107B_DA7A_2026_1116UL,
                isBitLocker: scenario == DiskFixtureScenario.BitLockerEncryptedPartition);

            long primaryVbrOffset = partStartOffset;
            long backupVbrOffset = partStartOffset + partSizeBytes - logicalSectorSize;

            if (scenario == DiskFixtureScenario.DamagedNtfsPrimaryVbr_ValidBackupVbr)
            {
                byte[] badVbr = new byte[logicalSectorSize];
                fs.Seek(primaryVbrOffset, SeekOrigin.Begin);
                fs.Write(badVbr);
            }
            else
            {
                fs.Seek(primaryVbrOffset, SeekOrigin.Begin);
                fs.Write(ntfsVbr);
            }

            // Write Backup VBR at last sector of partition
            fs.Seek(backupVbrOffset, SeekOrigin.Begin);
            fs.Write(ntfsVbr);

            // Write $MFT Record 0..3 and $MFTMirr Record 0
            long mftByteOffset = partStartOffset + (mftCluster * clusterSize);
            long mftMirrByteOffset = partStartOffset + (mftMirrCluster * clusterSize);

            if (scenario == DiskFixtureScenario.SeverelyDamagedNtfsMft)
            {
                // Corrupt both $MFT and $MFTMirr
                fs.Seek(mftByteOffset, SeekOrigin.Begin);
                fs.Write(Encoding.ASCII.GetBytes("CORRUPT_MFT_HEADER"));
                fs.Seek(mftMirrByteOffset, SeekOrigin.Begin);
                fs.Write(Encoding.ASCII.GetBytes("CORRUPT_MIRR_HEADER"));
            }
            else if (scenario != DiskFixtureScenario.BitLockerEncryptedPartition)
            {
                byte[] mftRec0 = BuildNtfsMftRecord("$MFT", isVolumeRecord: false, volumeLabel: string.Empty);
                byte[] mftRec3 = BuildNtfsMftRecord("$Volume", isVolumeRecord: true, volumeLabel: volumeLabel);

                fs.Seek(mftByteOffset, SeekOrigin.Begin);
                fs.Write(mftRec0);
                fs.Seek(mftByteOffset + (3 * 1024), SeekOrigin.Begin);
                fs.Write(mftRec3);

                fs.Seek(mftMirrByteOffset, SeekOrigin.Begin);
                fs.Write(mftRec0);

                // Populate sample recoverable user directory and files in $MFT (Records 5, 32..37)
                WriteSampleRecoverableFiles(fs, partStartOffset, mftByteOffset, clusterSize);
            }

            fs.Flush(true);
        }

        private static void WriteSampleRecoverableFiles(
            FileStream fs,
            long partStartOffset,
            long mftByteOffset,
            int clusterSize)
        {
            // Record 5: Root directory '.'
            byte[] recRoot = BuildUserFileMftRecord(
                fileName: ".",
                parentRecordNumber: 5,
                isDirectory: true,
                isDeleted: false,
                residentData: null,
                nonResidentRunlist: null,
                realFileSize: 0);
            fs.Seek(mftByteOffset + (5L * 1024), SeekOrigin.Begin);
            fs.Write(recRoot);

            // Record 32: Subdirectory 'Documents' (parent = 5)
            byte[] recDocsDir = BuildUserFileMftRecord(
                fileName: "Documents",
                parentRecordNumber: 5,
                isDirectory: true,
                isDeleted: false,
                residentData: null,
                nonResidentRunlist: null,
                realFileSize: 0);
            fs.Seek(mftByteOffset + (32L * 1024), SeekOrigin.Begin);
            fs.Write(recDocsDir);

            // Record 33: Resident file 'readme.txt' (parent = 5)
            byte[] readmeBytes = Encoding.UTF8.GetBytes("Hello from CDE resident NTFS file recovery!");
            byte[] recReadme = BuildUserFileMftRecord(
                fileName: "readme.txt",
                parentRecordNumber: 5,
                isDirectory: false,
                isDeleted: false,
                residentData: readmeBytes,
                nonResidentRunlist: null,
                realFileSize: readmeBytes.Length);
            fs.Seek(mftByteOffset + (33L * 1024), SeekOrigin.Begin);
            fs.Write(recReadme);

            // Record 34: Contiguous non-resident file 'report.csv' at LCN 32 (1 cluster)
            byte[] reportBytes = Encoding.UTF8.GetBytes("ID,Name,Status\n1,Drive10TB,Recovered\n2,Partition,Intact\n");
            // Runlist: 0x11 (1 byte length, 1 byte LCN offset), length=1, LCN=+32 (0x20), end=0x00
            byte[] reportRunlist = new byte[] { 0x11, 0x01, 0x20, 0x00 };
            byte[] recReport = BuildUserFileMftRecord(
                fileName: "report.csv",
                parentRecordNumber: 5,
                isDirectory: false,
                isDeleted: false,
                residentData: null,
                nonResidentRunlist: reportRunlist,
                realFileSize: reportBytes.Length,
                allocatedSize: clusterSize);
            fs.Seek(mftByteOffset + (34L * 1024), SeekOrigin.Begin);
            fs.Write(recReport);
            fs.Seek(partStartOffset + (32L * clusterSize), SeekOrigin.Begin);
            fs.Write(reportBytes);

            // Record 35: Fragmented 2-run non-resident file 'archive.bin' (Run 1: 1 cluster @ LCN 48, Run 2: 1 cluster @ LCN 64 [delta +16])
            int fragTotalBytes = clusterSize + 512;
            byte[] fragPart1 = new byte[clusterSize];
            byte[] fragPart2 = new byte[512];
            Array.Fill(fragPart1, (byte)0xA5);
            Array.Fill(fragPart2, (byte)0x5A);
            // Run 1: header 0x11, len=1, lcn=48 (0x30); Run 2: header 0x11, len=1, lcnDelta=+16 (0x10); end=0x00
            byte[] fragRunlist = new byte[] { 0x11, 0x01, 0x30, 0x11, 0x01, 0x10, 0x00 };
            byte[] recFrag = BuildUserFileMftRecord(
                fileName: "archive.bin",
                parentRecordNumber: 5,
                isDirectory: false,
                isDeleted: false,
                residentData: null,
                nonResidentRunlist: fragRunlist,
                realFileSize: fragTotalBytes,
                allocatedSize: clusterSize * 2L);
            fs.Seek(mftByteOffset + (35L * 1024), SeekOrigin.Begin);
            fs.Write(recFrag);
            fs.Seek(partStartOffset + (48L * clusterSize), SeekOrigin.Begin);
            fs.Write(fragPart1);
            fs.Seek(partStartOffset + (64L * clusterSize), SeekOrigin.Begin);
            fs.Write(fragPart2);

            // Record 36: Deleted resident file 'deleted_notes.txt' (InUse bit cleared)
            byte[] deletedBytes = Encoding.UTF8.GetBytes("Recovered deleted note content!");
            byte[] recDeleted = BuildUserFileMftRecord(
                fileName: "deleted_notes.txt",
                parentRecordNumber: 5,
                isDirectory: false,
                isDeleted: true,
                residentData: deletedBytes,
                nonResidentRunlist: null,
                realFileSize: deletedBytes.Length);
            fs.Seek(mftByteOffset + (36L * 1024), SeekOrigin.Begin);
            fs.Write(recDeleted);

            // Record 37: Resident file 'invoice.pdf' inside 'Documents' (parent = 32)
            byte[] invoiceBytes = Encoding.UTF8.GetBytes("%PDF-1.7 CDE Recovered Invoice #2026");
            byte[] recInvoice = BuildUserFileMftRecord(
                fileName: "invoice.pdf",
                parentRecordNumber: 32,
                isDirectory: false,
                isDeleted: false,
                residentData: invoiceBytes,
                nonResidentRunlist: null,
                realFileSize: invoiceBytes.Length);
            fs.Seek(mftByteOffset + (37L * 1024), SeekOrigin.Begin);
            fs.Write(recInvoice);
        }

        public static byte[] BuildUserFileMftRecord(
            string fileName,
            long parentRecordNumber,
            bool isDirectory,
            bool isDeleted,
            byte[]? residentData,
            byte[]? nonResidentRunlist,
            long realFileSize,
            long allocatedSize = 0,
            ushort usnValue = 0x1234)
        {
            byte[] rec = new byte[1024];
            BinaryPrimitives.WriteUInt32LittleEndian(rec.AsSpan(0, 4), 0x454C4946u); // "FILE"
            BinaryPrimitives.WriteUInt16LittleEndian(rec.AsSpan(4, 2), 48); // USA offset
            BinaryPrimitives.WriteUInt16LittleEndian(rec.AsSpan(6, 2), 3);  // USA count (USN + 2 sectors)
            BinaryPrimitives.WriteUInt16LittleEndian(rec.AsSpan(0x10, 2), 1); // Sequence number
            BinaryPrimitives.WriteUInt16LittleEndian(rec.AsSpan(0x12, 2), 1); // Hard link count
            BinaryPrimitives.WriteUInt16LittleEndian(rec.AsSpan(0x14, 2), 56); // First attribute offset

            ushort flags = 0;
            if (!isDeleted) flags |= 0x0001; // InUse
            if (isDirectory) flags |= 0x0002; // Directory
            BinaryPrimitives.WriteUInt16LittleEndian(rec.AsSpan(0x16, 2), flags);
            BinaryPrimitives.WriteUInt32LittleEndian(rec.AsSpan(0x1C, 4), 1024); // Allocated record size

            int attrPos = 56;

            // 1. $FILE_NAME (0x30) attribute
            byte[] nameUnicode = Encoding.Unicode.GetBytes(fileName);
            int fnBodyLen = 0x42 + nameUnicode.Length;
            int fnValOffset = 24;
            int fnAttrLen = (fnValOffset + fnBodyLen + 7) & ~7;

            BinaryPrimitives.WriteUInt32LittleEndian(rec.AsSpan(attrPos, 4), 0x30u);
            BinaryPrimitives.WriteUInt32LittleEndian(rec.AsSpan(attrPos + 4, 4), (uint)fnAttrLen);
            rec[attrPos + 8] = 0; // Resident
            BinaryPrimitives.WriteUInt32LittleEndian(rec.AsSpan(attrPos + 16, 4), (uint)fnBodyLen);
            BinaryPrimitives.WriteUInt16LittleEndian(rec.AsSpan(attrPos + 20, 2), (ushort)fnValOffset);

            var fnBody = rec.AsSpan(attrPos + fnValOffset, fnBodyLen);
            ulong parentRef = ((ulong)parentRecordNumber & 0x0000FFFFFFFFFFFFUL) | (1UL << 48);
            BinaryPrimitives.WriteUInt64LittleEndian(fnBody.Slice(0, 8), parentRef);
            long sampleFileTime = new DateTime(2026, 11, 16, 12, 0, 0, DateTimeKind.Utc).ToFileTimeUtc();
            BinaryPrimitives.WriteInt64LittleEndian(fnBody.Slice(0x08, 8), sampleFileTime);
            BinaryPrimitives.WriteInt64LittleEndian(fnBody.Slice(0x10, 8), sampleFileTime);
            BinaryPrimitives.WriteInt64LittleEndian(fnBody.Slice(0x18, 8), sampleFileTime);
            BinaryPrimitives.WriteInt64LittleEndian(fnBody.Slice(0x20, 8), sampleFileTime);
            BinaryPrimitives.WriteInt64LittleEndian(fnBody.Slice(0x28, 8), allocatedSize > 0 ? allocatedSize : realFileSize);
            BinaryPrimitives.WriteInt64LittleEndian(fnBody.Slice(0x30, 8), realFileSize);
            fnBody[0x40] = (byte)fileName.Length;
            fnBody[0x41] = 0x01; // Win32 namespace
            nameUnicode.CopyTo(fnBody.Slice(0x42));

            attrPos += fnAttrLen;

            // 2. $DATA (0x80) attribute for files
            if (!isDirectory)
            {
                if (residentData != null)
                {
                    int dataValOff = 24;
                    int dataAttrLen = (dataValOff + residentData.Length + 7) & ~7;
                    BinaryPrimitives.WriteUInt32LittleEndian(rec.AsSpan(attrPos, 4), 0x80u);
                    BinaryPrimitives.WriteUInt32LittleEndian(rec.AsSpan(attrPos + 4, 4), (uint)dataAttrLen);
                    rec[attrPos + 8] = 0; // Resident
                    BinaryPrimitives.WriteUInt32LittleEndian(rec.AsSpan(attrPos + 16, 4), (uint)residentData.Length);
                    BinaryPrimitives.WriteUInt16LittleEndian(rec.AsSpan(attrPos + 20, 2), (ushort)dataValOff);
                    residentData.CopyTo(rec.AsSpan(attrPos + dataValOff));
                    attrPos += dataAttrLen;
                }
                else if (nonResidentRunlist != null)
                {
                    int runOff = 0x40;
                    int dataAttrLen = (runOff + nonResidentRunlist.Length + 7) & ~7;
                    BinaryPrimitives.WriteUInt32LittleEndian(rec.AsSpan(attrPos, 4), 0x80u);
                    BinaryPrimitives.WriteUInt32LittleEndian(rec.AsSpan(attrPos + 4, 4), (uint)dataAttrLen);
                    rec[attrPos + 8] = 1; // Non-resident
                    BinaryPrimitives.WriteUInt16LittleEndian(rec.AsSpan(attrPos + 0x20, 2), (ushort)runOff);
                    BinaryPrimitives.WriteInt64LittleEndian(rec.AsSpan(attrPos + 0x28, 8), allocatedSize > 0 ? allocatedSize : realFileSize);
                    BinaryPrimitives.WriteInt64LittleEndian(rec.AsSpan(attrPos + 0x30, 8), realFileSize);
                    BinaryPrimitives.WriteInt64LittleEndian(rec.AsSpan(attrPos + 0x38, 8), realFileSize);
                    nonResidentRunlist.CopyTo(rec.AsSpan(attrPos + runOff));
                    attrPos += dataAttrLen;
                }
            }

            // End marker 0xFFFFFFFF
            BinaryPrimitives.WriteUInt32LittleEndian(rec.AsSpan(attrPos, 4), 0xFFFFFFFFu);
            BinaryPrimitives.WriteUInt32LittleEndian(rec.AsSpan(0x18, 4), (uint)(attrPos + 8));

            // Stamp Update Sequence Array (USA) fixup at offset 48 (USN + sector 0 tail + sector 1 tail)
            BinaryPrimitives.WriteUInt16LittleEndian(rec.AsSpan(48, 2), usnValue);
            BinaryPrimitives.WriteUInt16LittleEndian(rec.AsSpan(50, 2), BinaryPrimitives.ReadUInt16LittleEndian(rec.AsSpan(510, 2)));
            BinaryPrimitives.WriteUInt16LittleEndian(rec.AsSpan(52, 2), BinaryPrimitives.ReadUInt16LittleEndian(rec.AsSpan(1022, 2)));
            BinaryPrimitives.WriteUInt16LittleEndian(rec.AsSpan(510, 2), usnValue);
            BinaryPrimitives.WriteUInt16LittleEndian(rec.AsSpan(1022, 2), usnValue);

            return rec;
        }

        public static byte[] BuildNtfsBootSector(
            int bytesPerSector,
            int sectorsPerCluster,
            long totalVolumeSectors,
            long mftCluster,
            long mftMirrCluster,
            ulong serialNumber,
            bool isBitLocker = false)
        {
            byte[] sector = new byte[bytesPerSector];
            sector[0] = 0xEB;
            sector[1] = 0x52;
            sector[2] = 0x90;

            string oem = isBitLocker ? "-FVE-FS-" : "NTFS    ";
            Encoding.ASCII.GetBytes(oem, sector.AsSpan(3, 8));

            BinaryPrimitives.WriteUInt16LittleEndian(sector.AsSpan(11, 2), (ushort)bytesPerSector);
            sector[13] = (byte)sectorsPerCluster;
            sector[21] = 0xF8; // Media descriptor (fixed disk)
            BinaryPrimitives.WriteUInt16LittleEndian(sector.AsSpan(24, 2), 63);
            BinaryPrimitives.WriteUInt16LittleEndian(sector.AsSpan(26, 2), 255);
            BinaryPrimitives.WriteUInt64LittleEndian(sector.AsSpan(40, 8), (ulong)totalVolumeSectors);
            BinaryPrimitives.WriteUInt64LittleEndian(sector.AsSpan(48, 8), (ulong)mftCluster);
            BinaryPrimitives.WriteUInt64LittleEndian(sector.AsSpan(56, 8), (ulong)mftMirrCluster);
            sector[64] = unchecked((byte)-10); // 2^10 = 1024-byte MFT record size
            sector[68] = 1; // Clusters per index buffer
            BinaryPrimitives.WriteUInt64LittleEndian(sector.AsSpan(72, 8), serialNumber);
            BinaryPrimitives.WriteUInt16LittleEndian(sector.AsSpan(510, 2), 0xAA55);
            return sector;
        }

        public static byte[] BuildNtfsMftRecord(string name, bool isVolumeRecord, string volumeLabel)
        {
            byte[] rec = new byte[1024];
            // "FILE" = 0x454C4946
            BinaryPrimitives.WriteUInt32LittleEndian(rec.AsSpan(0, 4), 0x454C4946u);
            BinaryPrimitives.WriteUInt16LittleEndian(rec.AsSpan(4, 2), 48); // USA offset
            BinaryPrimitives.WriteUInt16LittleEndian(rec.AsSpan(6, 2), 3);  // USA count
            BinaryPrimitives.WriteUInt16LittleEndian(rec.AsSpan(16, 2), 1); // Sequence number
            BinaryPrimitives.WriteUInt16LittleEndian(rec.AsSpan(18, 2), 1); // Hard link count
            BinaryPrimitives.WriteUInt16LittleEndian(rec.AsSpan(20, 2), 56); // First attribute offset
            BinaryPrimitives.WriteUInt16LittleEndian(rec.AsSpan(22, 2), 1); // Flags (InUse)
            BinaryPrimitives.WriteUInt32LittleEndian(rec.AsSpan(24, 4), 256); // Bytes in use
            BinaryPrimitives.WriteUInt32LittleEndian(rec.AsSpan(28, 4), 1024); // Bytes allocated

            int attrPos = 56;
            if (isVolumeRecord && !string.IsNullOrWhiteSpace(volumeLabel))
            {
                // Write a resident $VOLUME_NAME (0x60) attribute
                byte[] labelBytes = Encoding.Unicode.GetBytes(volumeLabel);
                int valOffset = 24;
                int attrLen = (valOffset + labelBytes.Length + 7) & ~7;
                BinaryPrimitives.WriteUInt32LittleEndian(rec.AsSpan(attrPos, 4), 0x60u);
                BinaryPrimitives.WriteUInt32LittleEndian(rec.AsSpan(attrPos + 4, 4), (uint)attrLen);
                rec[attrPos + 8] = 0; // resident
                BinaryPrimitives.WriteUInt32LittleEndian(rec.AsSpan(attrPos + 16, 4), (uint)labelBytes.Length);
                BinaryPrimitives.WriteUInt16LittleEndian(rec.AsSpan(attrPos + 20, 2), (ushort)valOffset);
                labelBytes.CopyTo(rec.AsSpan(attrPos + valOffset));
                attrPos += attrLen;
            }

            // End marker 0xFFFFFFFF
            BinaryPrimitives.WriteUInt32LittleEndian(rec.AsSpan(attrPos, 4), 0xFFFFFFFFu);
            return rec;
        }
    }
}
