using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace CdeSmart
{
    public class SmartAttr
    {
        public int Id;
        public string Name;
        public int Current;
        public int Worst;
        public int Threshold;
        public long Raw;
        public string Status;
    }

    public class SmartDrive
    {
        public int Index;
        public string Model;
        public string Serial;
        public string Bus;
        public string Protocol;
        public double SizeGB;
        public string Overall;
        public int TemperatureC;
        public bool Supported;
        public string Note;
        public List<SmartAttr> Attributes = new List<SmartAttr>();
    }

    public static class Reader
    {
        const uint GENERIC_READ = 0x80000000;
        const uint GENERIC_WRITE = 0x40000000;
        const uint FILE_SHARE_READ = 0x1;
        const uint FILE_SHARE_WRITE = 0x2;
        const uint OPEN_EXISTING = 3;
        static readonly IntPtr INVALID_HANDLE = new IntPtr(-1);

        const uint IOCTL_STORAGE_QUERY_PROPERTY = 0x002D1400;
        const uint IOCTL_ATA_PASS_THROUGH = 0x0004D02C;
        const uint IOCTL_DISK_GET_LENGTH_INFO = 0x0007405C;
        // CTL_CODE(IOCTL_STORAGE_BASE, 0x04F0, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS)
        const uint IOCTL_STORAGE_PROTOCOL_COMMAND = 0x002DD3C0;

        const uint STORAGE_PROTOCOL_STRUCTURE_VERSION = 1;
        const uint STORAGE_PROTOCOL_COMMAND_FLAG_ADAPTER_REQUEST = 0x80000000;
        const uint STORAGE_PROTOCOL_COMMAND_LENGTH_NVME = 64;
        const uint STORAGE_PROTOCOL_SPECIFIC_NVME_ADMIN_COMMAND = 1;
        const uint ProtocolTypeNvme = 3;

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess,
            uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition,
            uint dwFlagsAndAttributes, IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool DeviceIoControl(IntPtr hDevice, uint dwIoControlCode,
            byte[] lpInBuffer, uint nInBufferSize, byte[] lpOutBuffer, uint nOutBufferSize,
            out uint lpBytesReturned, IntPtr lpOverlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool CloseHandle(IntPtr hObject);

        static string ReadAsciiZ(byte[] buf, int offset)
        {
            if (offset <= 0 || offset >= buf.Length) return "";
            int end = offset;
            while (end < buf.Length && buf[end] != 0) end++;
            string s = System.Text.Encoding.ASCII.GetString(buf, offset, end - offset);
            return s.Trim();
        }

        static long ReadLE(byte[] buf, int offset, int count)
        {
            long v = 0;
            for (int i = 0; i < count && (offset + i) < buf.Length; i++)
                v |= ((long)buf[offset + i]) << (8 * i);
            return v;
        }

        static string BusName(int bt)
        {
            switch (bt)
            {
                case 1: return "SCSI";
                case 2: return "ATAPI";
                case 3: return "ATA";
                case 4: return "1394";
                case 6: return "Fibre";
                case 7: return "USB";
                case 8: return "RAID";
                case 9: return "iSCSI";
                case 10: return "SAS";
                case 11: return "SATA";
                case 12: return "SD";
                case 13: return "MMC";
                case 14: return "Virtual";
                case 17: return "NVMe";
                case 19: return "UFS";
                default: return "Unknown(" + bt + ")";
            }
        }

        static string AttrName(int id)
        {
            switch (id)
            {
                case 1: return "Raw Read Error Rate";
                case 2: return "Throughput Performance";
                case 3: return "Spin-Up Time";
                case 4: return "Start/Stop Count";
                case 5: return "Reallocated Sectors Count";
                case 7: return "Seek Error Rate";
                case 8: return "Seek Time Performance";
                case 9: return "Power-On Hours";
                case 10: return "Spin Retry Count";
                case 11: return "Recalibration Retries";
                case 12: return "Power Cycle Count";
                case 13: return "Soft Read Error Rate";
                case 170: return "Available Reserved Space";
                case 171: return "SSD Program Fail Count";
                case 172: return "SSD Erase Fail Count";
                case 173: return "SSD Wear Leveling Count";
                case 174: return "Unexpected Power Loss Count";
                case 175: return "Program Fail Count (Chip)";
                case 177: return "Wear Leveling Count";
                case 179: return "Used Reserved Block Count Total";
                case 180: return "Unused Reserved Block Count";
                case 181: return "Program Fail Count Total";
                case 182: return "Erase Fail Count";
                case 183: return "SATA Downshift Error Count";
                case 184: return "End-to-End Error";
                case 187: return "Reported Uncorrectable Errors";
                case 188: return "Command Timeout";
                case 189: return "High Fly Writes";
                case 190: return "Airflow Temperature";
                case 191: return "G-Sense Error Rate";
                case 192: return "Power-Off Retract Count";
                case 193: return "Load Cycle Count";
                case 194: return "Temperature";
                case 195: return "Hardware ECC Recovered";
                case 196: return "Reallocation Event Count";
                case 197: return "Current Pending Sector Count";
                case 198: return "Uncorrectable Sector Count";
                case 199: return "UDMA CRC Error Count";
                case 200: return "Multi-Zone Error Rate";
                case 201: return "Soft Read Error Rate";
                case 202: return "Data Address Mark Errors";
                case 231: return "SSD Life Left / Temperature";
                case 233: return "Media Wearout / Power-On Hours";
                case 234: return "Thermal Throttle Status";
                case 241: return "Total LBAs Written";
                case 242: return "Total LBAs Read";
                case 249: return "NAND Writes (1GiB)";
                default: return "Attribute " + id;
            }
        }

        // ATA media-failure predictors (Backblaze/Seagate-style): nonzero raw → Overall Warn.
        static bool IsMediaFailureAta(int id)
        {
            return id == 5 || id == 10 || id == 184 || id == 187 ||
                   id == 196 || id == 197 || id == 198;
        }

        // Interface/transport counters: often cabling/controller noise (esp. 199 CRC),
        // not platter failure — attribute Info only unless count is extreme.
        static bool IsInterconnectAta(int id)
        {
            return id == 188 || id == 199;
        }

        public static List<SmartDrive> ReadAll()
        {
            List<SmartDrive> drives = new List<SmartDrive>();
            for (int i = 0; i < 32; i++)
            {
                string path = "\\\\.\\PhysicalDrive" + i;
                IntPtr h = CreateFileW(path, GENERIC_READ | GENERIC_WRITE,
                    FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
                bool rw = (h != INVALID_HANDLE);
                if (!rw)
                {
                    int err = Marshal.GetLastWin32Error();
                    if (err == 2 || err == 3) continue; // no such drive
                    // try read-only handle for descriptor only
                    h = CreateFileW(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE,
                        IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
                    if (h == INVALID_HANDLE) continue;
                }

                SmartDrive d = new SmartDrive();
                d.Index = i;
                d.TemperatureC = -1;
                d.Overall = "Unknown";
                d.Supported = false;
                d.Note = "";

                try
                {
                    int busType = 0;
                    GetDescriptor(h, d, out busType);
                    GetSize(h, d);
                    d.Bus = BusName(busType);

                    if (busType == 17) // NVMe
                    {
                        d.Protocol = "NVMe";
                        ReadNvme(h, d);
                    }
                    else if (busType == 3 || busType == 11 || busType == 2) // ATA / SATA / ATAPI
                    {
                        d.Protocol = "ATA";
                        if (rw) ReadAta(h, d);
                        else { d.Note = "Access denied - run elevated for SMART"; }
                    }
                    else if (busType == 7) // USB bridge - best effort SAT
                    {
                        d.Protocol = "USB/SAT";
                        if (rw)
                        {
                            ReadAta(h, d);
                            if (d.Attributes.Count == 0)
                            {
                                d.Supported = false;
                                d.Overall = "Unknown";
                                d.Note = "SMART unavailable (USB bridge does not pass ATA commands)";
                            }
                        }
                        else { d.Note = "Access denied - run elevated for SMART"; }
                    }
                    else
                    {
                        d.Protocol = d.Bus;
                        d.Supported = false;
                        d.Overall = "Unknown";
                        d.Note = "SMART unavailable (RAID/VMD or unsupported controller)";
                    }
                }
                catch (Exception ex)
                {
                    d.Note = "Read error: " + ex.Message;
                }
                finally
                {
                    CloseHandle(h);
                }

                if (string.IsNullOrEmpty(d.Model)) d.Model = path;
                drives.Add(d);
            }
            return drives;
        }

        static void GetDescriptor(IntPtr h, SmartDrive d, out int busType)
        {
            busType = 0;
            byte[] inbuf = new byte[12];
            // STORAGE_PROPERTY_QUERY: PropertyId=StorageDeviceProperty(0), QueryType=Standard(0)
            // (already zeroed)
            byte[] outbuf = new byte[1024];
            uint ret;
            if (!DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, inbuf, (uint)inbuf.Length,
                outbuf, (uint)outbuf.Length, out ret, IntPtr.Zero))
                return;

            // STORAGE_DEVICE_DESCRIPTOR offsets
            int vendorOff = (int)ReadLE(outbuf, 12, 4);
            int productOff = (int)ReadLE(outbuf, 16, 4);
            int serialOff = (int)ReadLE(outbuf, 24, 4);
            busType = (int)ReadLE(outbuf, 28, 4);

            string vendor = ReadAsciiZ(outbuf, vendorOff);
            string product = ReadAsciiZ(outbuf, productOff);
            string serial = ReadAsciiZ(outbuf, serialOff);
            string model = (vendor + " " + product).Trim();
            if (string.IsNullOrEmpty(model)) model = product;
            d.Model = model;
            d.Serial = serial;
        }

        static void GetSize(IntPtr h, SmartDrive d)
        {
            byte[] outbuf = new byte[8];
            uint ret;
            if (DeviceIoControl(h, IOCTL_DISK_GET_LENGTH_INFO, null, 0,
                outbuf, (uint)outbuf.Length, out ret, IntPtr.Zero))
            {
                long bytes = ReadLE(outbuf, 0, 8);
                d.SizeGB = Math.Round(bytes / 1000000000.0, 1);
            }
        }

        // --- ATA / SATA path ---
        static void ReadAta(IntPtr h, SmartDrive d)
        {
            byte[] data = AtaSmartCmd(h, 0xD0); // SMART READ DATA
            if (data == null) return;
            byte[] thr = AtaSmartCmd(h, 0xD1); // SMART READ THRESHOLDS

            Dictionary<int, int> thresholds = new Dictionary<int, int>();
            if (thr != null)
            {
                for (int e = 0; e < 30; e++)
                {
                    int off = 2 + e * 12;
                    int id = thr[off];
                    if (id == 0) continue;
                    thresholds[id] = thr[off + 1];
                }
            }

            bool anyWarn = false;
            bool anyFail = false;
            for (int e = 0; e < 30; e++)
            {
                int off = 2 + e * 12;
                int id = data[off];
                if (id == 0) continue;
                SmartAttr a = new SmartAttr();
                a.Id = id;
                a.Name = AttrName(id);
                a.Current = data[off + 3];
                a.Worst = data[off + 4];
                a.Raw = ReadLE(data, off + 5, 6);
                a.Threshold = thresholds.ContainsKey(id) ? thresholds[id] : -1;

                string st = "OK";
                if (a.Threshold > 0 && a.Current <= a.Threshold) { st = "Fail"; anyFail = true; }
                else if (IsMediaFailureAta(id) && a.Raw > 0) { st = "Warn"; anyWarn = true; }
                else if (IsInterconnectAta(id) && a.Raw > 0)
                {
                    // CRC/timeouts: treat modest counts as interconnect noise (Info);
                    // very high 199 still elevates Overall Warn.
                    if (id == 199 && a.Raw >= 100) { st = "Warn"; anyWarn = true; }
                    else if (id == 188 && a.Raw >= 50) { st = "Warn"; anyWarn = true; }
                    else { st = "Info"; }
                }
                a.Status = st;
                d.Attributes.Add(a);

                if (id == 194 || (id == 190 && d.TemperatureC < 0))
                    d.TemperatureC = (int)(a.Raw & 0xFF);
            }

            d.Supported = d.Attributes.Count > 0;

            // SMART RETURN STATUS (0xDA) - authoritative predicted-fail flag
            int predict = AtaReturnStatus(h);
            if (predict == 1) { anyFail = true; }

            if (!d.Supported) d.Overall = "Unknown";
            else if (anyFail) d.Overall = "Fail";
            else if (anyWarn) d.Overall = "Warn";
            else d.Overall = "Pass";
        }

        static byte[] AtaSmartCmd(IntPtr h, byte feature)
        {
            int hdr = (IntPtr.Size == 8) ? 48 : 40;
            int dataOff = hdr;
            int total = hdr + 512;
            byte[] buf = new byte[total];

            // ATA_PASS_THROUGH_EX header
            WriteU16(buf, 0, (ushort)hdr);          // Length
            WriteU16(buf, 2, 0x0003);               // AtaFlags = DRDY_REQUIRED | DATA_IN
            WriteU32(buf, 8, 512);                   // DataTransferLength
            WriteU32(buf, 12, 10);                   // TimeOutValue (s)
            int dboOff = (IntPtr.Size == 8) ? 24 : 20;
            if (IntPtr.Size == 8) WriteU64(buf, dboOff, (ulong)dataOff);
            else WriteU32(buf, dboOff, (uint)dataOff);

            // CurrentTaskFile is last 8 bytes of header
            int tf = hdr - 8;
            buf[tf + 0] = feature;   // Features
            buf[tf + 1] = 1;         // SectorCount
            buf[tf + 2] = 0;         // LBA Low
            buf[tf + 3] = 0x4F;      // LBA Mid (SMART signature)
            buf[tf + 4] = 0xC2;      // LBA High (SMART signature)
            buf[tf + 5] = 0;         // Device
            buf[tf + 6] = 0xB0;      // Command = SMART

            uint ret;
            if (!DeviceIoControl(h, IOCTL_ATA_PASS_THROUGH, buf, (uint)total, buf, (uint)total, out ret, IntPtr.Zero))
                return null;

            byte[] data = new byte[512];
            Array.Copy(buf, dataOff, data, 0, 512);
            return data;
        }

        // returns 1 = failing predicted, 0 = ok, -1 = unknown
        static int AtaReturnStatus(IntPtr h)
        {
            int hdr = (IntPtr.Size == 8) ? 48 : 40;
            byte[] buf = new byte[hdr];
            WriteU16(buf, 0, (ushort)hdr);   // Length
            WriteU16(buf, 2, 0x0001);        // AtaFlags = DRDY_REQUIRED (no data)
            WriteU32(buf, 8, 0);             // DataTransferLength
            WriteU32(buf, 12, 10);           // TimeOutValue
            int tf = hdr - 8;
            buf[tf + 0] = 0xDA;   // Features = RETURN STATUS
            buf[tf + 1] = 0;
            buf[tf + 2] = 0;
            buf[tf + 3] = 0x4F;
            buf[tf + 4] = 0xC2;
            buf[tf + 5] = 0;
            buf[tf + 6] = 0xB0;

            uint ret;
            if (!DeviceIoControl(h, IOCTL_ATA_PASS_THROUGH, buf, (uint)hdr, buf, (uint)hdr, out ret, IntPtr.Zero))
                return -1;

            byte mid = buf[tf + 3];
            byte high = buf[tf + 4];
            if (mid == 0x2C && high == 0xF4) return 1;   // threshold exceeded
            if (mid == 0x4F && high == 0xC2) return 0;   // healthy
            return -1;
        }

        // --- NVMe path ---
        static void ReadNvme(IntPtr h, SmartDrive d)
        {
            int spdSize = 40;
            int hdr = 8; // STORAGE_PROPERTY_QUERY header (PropertyId + QueryType)
            int logSize = 512;
            int total = hdr + spdSize + logSize;
            byte[] buf = new byte[total];

            // STORAGE_PROPERTY_QUERY
            WriteU32(buf, 0, 50); // StorageDeviceProtocolSpecificProperty
            WriteU32(buf, 4, 0);  // PropertyStandardQuery

            // STORAGE_PROTOCOL_SPECIFIC_DATA @ offset 8
            int p = hdr;
            WriteU32(buf, p + 0, 3);        // ProtocolType = NVMe
            WriteU32(buf, p + 4, 2);        // DataType = NVMeDataTypeLogPage
            WriteU32(buf, p + 8, 0x02);     // ProtocolDataRequestValue = SMART/Health log
            WriteU32(buf, p + 12, 0);             // SubValue
            WriteU32(buf, p + 16, (uint)spdSize); // ProtocolDataOffset (from start of SPD)
            WriteU32(buf, p + 20, (uint)logSize); // ProtocolDataLength

            uint ret;
            if (!DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, buf, (uint)total, buf, (uint)total, out ret, IntPtr.Zero))
            {
                d.Supported = false;
                d.Overall = "Unknown";
                d.Note = "NVMe SMART query failed";
                return;
            }

            // Output: STORAGE_PROTOCOL_DATA_DESCRIPTOR (Version+Size = 8) + SPD(40) + data
            int dataOff = 8 + spdSize;
            // honor returned ProtocolDataOffset if present (at SPD+16 -> 8+16=24)
            int retOff = (int)ReadLE(buf, 8 + 16, 4);
            if (retOff > 0) dataOff = 8 + retOff;
            if (dataOff + 192 > buf.Length) dataOff = 8 + spdSize;

            int crit = buf[dataOff + 0];
            int tempK = (int)ReadLE(buf, dataOff + 1, 2);
            int spare = buf[dataOff + 3];
            int spareThr = buf[dataOff + 4];
            int pctUsed = buf[dataOff + 5];
            long powerCycles = ReadLE(buf, dataOff + 112, 8);
            long powerOnHours = ReadLE(buf, dataOff + 128, 8);
            long unsafeShut = ReadLE(buf, dataOff + 144, 8);
            long mediaErrors = ReadLE(buf, dataOff + 160, 8);
            long errLogEntries = ReadLE(buf, dataOff + 176, 8);
            long unitsRead = ReadLE(buf, dataOff + 32, 8);
            long unitsWritten = ReadLE(buf, dataOff + 48, 8);

            d.TemperatureC = (tempK > 0) ? (tempK - 273) : -1;
            d.Supported = true;

            bool warn = false, fail = false;

            AddNvme(d, 1, "Critical Warning", crit, (crit != 0) ? "Fail" : "OK");
            if (crit != 0) fail = true;

            string tempStatus = "OK";
            // NVMe often runs warmer under load; 70C single snapshot is noisy.
            if (d.TemperatureC >= 0 && d.TemperatureC > 80) { tempStatus = "Warn"; warn = true; }
            AddNvme(d, 2, "Composite Temperature (C)", d.TemperatureC, tempStatus);

            string spareStatus = "OK";
            if (spareThr > 0 && spare <= spareThr) { spareStatus = "Fail"; fail = true; }
            else if (spareThr > 0 && spare <= spareThr + 10) { spareStatus = "Warn"; warn = true; }
            AddNvme(d, 3, "Available Spare (%)", spare, spareStatus);
            AddNvme(d, 4, "Available Spare Threshold (%)", spareThr, "OK");

            string usedStatus = "OK";
            if (pctUsed >= 100) { usedStatus = "Warn"; warn = true; }
            else if (pctUsed >= 95) { usedStatus = "Warn"; warn = true; }
            AddNvme(d, 5, "Percentage Used (%)", pctUsed, usedStatus);

            AddNvme(d, 12, "Power Cycle Count", powerCycles, "OK");
            AddNvme(d, 9, "Power-On Hours", powerOnHours, "OK");
            AddNvme(d, 174, "Unsafe Shutdowns", unsafeShut, "OK");

            // Sticky media error counters: small historical counts are Info; larger elevate Warn.
            string mediaStatus = "OK";
            if (mediaErrors >= 10) { mediaStatus = "Warn"; warn = true; }
            else if (mediaErrors > 0) { mediaStatus = "Info"; }
            AddNvme(d, 198, "Media & Data Integrity Errors", mediaErrors, mediaStatus);
            AddNvme(d, 199, "Error Log Entries", errLogEntries, "OK");

            // Data units are reported in 1000 * 512 byte units -> convert to GB
            long gbRead = (long)Math.Round(unitsRead * 1000.0 * 512.0 / 1000000000.0);
            long gbWritten = (long)Math.Round(unitsWritten * 1000.0 * 512.0 / 1000000000.0);
            AddNvme(d, 242, "Total Data Read (GB)", gbRead, "OK");
            AddNvme(d, 241, "Total Data Written (GB)", gbWritten, "OK");

            if (fail) d.Overall = "Fail";
            else if (warn) d.Overall = "Warn";
            else d.Overall = "Pass";
        }

        static void AddNvme(SmartDrive d, int id, string name, long raw, string status)
        {
            SmartAttr a = new SmartAttr();
            a.Id = id;
            a.Name = name;
            a.Current = -1;
            a.Worst = -1;
            a.Threshold = -1;
            a.Raw = raw;
            a.Status = status;
            d.Attributes.Add(a);
        }

        public static SmartDrive GetDriveByIndex(int index)
        {
            foreach (var d in ReadAll())
            {
                if (d.Index == index) return d;
            }
            return null;
        }

        public static string RunShortSelfTest(int driveIndex, int timeoutSeconds)
        {
            string path = "\\\\.\\PhysicalDrive" + driveIndex;
            IntPtr h = CreateFileW(path, GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
            if (h == INVALID_HANDLE)
            {
                int err = Marshal.GetLastWin32Error();
                if (err == 5) return "Warn: Access denied - run elevated";
                return "Warn: Cannot open " + path;
            }

            try
            {
                SmartDrive probe = new SmartDrive();
                int busType = 0;
                GetDescriptor(h, probe, out busType);

                if (busType == 17)
                    return RunNvmeShortSelfTest(h, timeoutSeconds);
                if (busType == 3 || busType == 11 || busType == 2 || busType == 7)
                    return RunAtaShortSelfTest(h, timeoutSeconds);
                return "Skipped: Self-test not supported for bus type " + busType;
            }
            finally
            {
                CloseHandle(h);
            }
        }

        static string RunAtaShortSelfTest(IntPtr h, int timeoutSeconds)
        {
            int hdr = (IntPtr.Size == 8) ? 48 : 40;
            byte[] buf = new byte[hdr];
            WriteU16(buf, 0, (ushort)hdr);
            WriteU16(buf, 2, 0x0001);
            WriteU32(buf, 8, 0);
            WriteU32(buf, 12, (uint)Math.Max(30, timeoutSeconds));
            int tf = hdr - 8;
            buf[tf + 0] = 0xD4;
            buf[tf + 1] = 0x01;
            buf[tf + 2] = 0;
            buf[tf + 3] = 0x4F;
            buf[tf + 4] = 0xC2;
            buf[tf + 5] = 0;
            buf[tf + 6] = 0xB0;

            uint ret;
            if (!DeviceIoControl(h, IOCTL_ATA_PASS_THROUGH, buf, (uint)hdr, buf, (uint)hdr, out ret, IntPtr.Zero))
                return "Skipped: ATA self-test command rejected";

            DateTime deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
            while (DateTime.UtcNow < deadline)
            {
                System.Threading.Thread.Sleep(5000);
                int status = AtaReturnStatus(h);
                if (status == 1) return "Failed: SMART RETURN STATUS threshold exceeded after self-test";
                if (status == 0) return "Passed: ATA short self-test completed";
            }
            return "Failed: ATA short self-test timed out after " + timeoutSeconds + "s";
        }

        static string RunNvmeShortSelfTest(IntPtr h, int timeoutSeconds)
        {
            // Issue NVMe Device Self-Test (admin opcode 0x14, STC=1 short) via
            // IOCTL_STORAGE_PROTOCOL_COMMAND, then poll Device Self-test log page 0x06.
            // See: https://learn.microsoft.com/en-us/windows/win32/fileio/working-with-nvme-devices
            const int cmdHdrSize = 84; // sizeof(STORAGE_PROTOCOL_COMMAND) excl. Command[] (common Win10 layout)
            const int nvmeCmdSize = 64;
            int total = cmdHdrSize + nvmeCmdSize;
            byte[] buf = new byte[total];

            WriteU32(buf, 0, STORAGE_PROTOCOL_STRUCTURE_VERSION); // Version
            WriteU32(buf, 4, (uint)cmdHdrSize);                  // Length
            WriteU32(buf, 8, ProtocolTypeNvme);                  // ProtocolType
            WriteU32(buf, 12, STORAGE_PROTOCOL_COMMAND_FLAG_ADAPTER_REQUEST); // Flags
            // ReturnStatus @16, ErrorCode @20
            WriteU32(buf, 24, STORAGE_PROTOCOL_COMMAND_LENGTH_NVME); // CommandLength
            WriteU32(buf, 40, (uint)Math.Max(30, timeoutSeconds));  // TimeOutValue
            WriteU32(buf, 56, STORAGE_PROTOCOL_SPECIFIC_NVME_ADMIN_COMMAND); // CommandSpecific

            int cmdOff = cmdHdrSize;
            // NVMe admin command DWORDs
            WriteU32(buf, cmdOff + 0, 0x14);                 // CDW0 OPC = Device Self-Test
            WriteU32(buf, cmdOff + 4, 0xFFFFFFFF);           // CDW1 NSID = all namespaces
            WriteU32(buf, cmdOff + 40, 0x1);                 // CDW10 STC = 1 (short)

            uint ret;
            if (!DeviceIoControl(h, IOCTL_STORAGE_PROTOCOL_COMMAND, buf, (uint)total, buf, (uint)total, out ret, IntPtr.Zero))
            {
                int err = Marshal.GetLastWin32Error();
                return "Skipped: NVMe self-test command rejected (Win32 " + err + ")";
            }

            uint returnStatus = (uint)ReadLE(buf, 16, 4);
            // STORAGE_PROTOCOL_STATUS_SUCCESS = 0; PENDING = 3 (varies by header)
            if (returnStatus != 0 && returnStatus != 1 && returnStatus != 3)
            {
                return "Skipped: NVMe self-test protocol status " + returnStatus;
            }

            bool started = true;
            DateTime deadline = DateTime.UtcNow.AddSeconds(Math.Max(30, timeoutSeconds));
            while (DateTime.UtcNow < deadline)
            {
                System.Threading.Thread.Sleep(3000);
                int dst = ReadNvmeSelfTestLogStatus(h);
                if (dst == 0) return "Passed: NVMe short self-test completed";
                if (dst == 1) return "Failed: NVMe short self-test reported failure";
                if (dst == 2) return "Warn: NVMe self-test started but completion status unavailable";
                // dst == -1 still in progress / unknown
            }

            if (started)
                return "Warn: NVMe self-test started but completion status unavailable";
            return "Failed: NVMe short self-test timed out after " + timeoutSeconds + "s";
        }

        /// <summary>
        /// Reads NVMe Device Self-test log page (0x06).
        /// Returns 0=pass/complete-ok, 1=fail, 2=log unavailable after start, -1=in progress/unknown.
        /// </summary>
        static int ReadNvmeSelfTestLogStatus(IntPtr h)
        {
            int spdSize = 40;
            int hdr = 8;
            int logSize = 564; // DST log is typically 564 bytes
            int total = hdr + spdSize + logSize;
            byte[] qbuf = new byte[total];

            WriteU32(qbuf, 0, 50); // StorageDeviceProtocolSpecificProperty
            WriteU32(qbuf, 4, 0);  // PropertyStandardQuery

            int p = hdr;
            WriteU32(qbuf, p + 0, 3);              // ProtocolType = NVMe
            WriteU32(qbuf, p + 4, 2);              // DataType = NVMeDataTypeLogPage
            WriteU32(qbuf, p + 8, 0x06);           // Log page = Device Self-test
            WriteU32(qbuf, p + 12, 0);
            WriteU32(qbuf, p + 16, (uint)spdSize);
            WriteU32(qbuf, p + 20, (uint)logSize);

            uint ret;
            if (!DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, qbuf, (uint)total, qbuf, (uint)total, out ret, IntPtr.Zero))
                return 2;

            int dataOff = 8 + spdSize;
            int retOff = (int)ReadLE(qbuf, 8 + 16, 4);
            if (retOff > 0) dataOff = 8 + retOff;
            if (dataOff + 8 > qbuf.Length) return 2;

            int currentOp = qbuf[dataOff + 0] & 0x0F;
            // 0 = no DST in progress
            if (currentOp != 0) return -1;

            // Newest result entry starts at offset 4 (NVMe DST log layout)
            int newestResult = qbuf[dataOff + 4] & 0x0F;
            // 0h = Entry unused / no result yet after idle can mean never run — treat as unavailable once
            // 1h = Operation completed without error
            // 2h = Operation aborted by DST command
            // 3h..Fh = various failures / aborted
            if (newestResult == 1) return 0;
            if (newestResult == 0) return -1; // still waiting for result population
            if (newestResult == 2) return 2;  // aborted — soft
            return 1;
        }

        static void WriteU16(byte[] b, int o, ushort v)
        {
            b[o] = (byte)(v & 0xFF);
            b[o + 1] = (byte)((v >> 8) & 0xFF);
        }
        static void WriteU32(byte[] b, int o, uint v)
        {
            b[o] = (byte)(v & 0xFF);
            b[o + 1] = (byte)((v >> 8) & 0xFF);
            b[o + 2] = (byte)((v >> 16) & 0xFF);
            b[o + 3] = (byte)((v >> 24) & 0xFF);
        }
        static void WriteU64(byte[] b, int o, ulong v)
        {
            for (int i = 0; i < 8; i++) b[o + i] = (byte)((v >> (8 * i)) & 0xFF);
        }
    }
}
