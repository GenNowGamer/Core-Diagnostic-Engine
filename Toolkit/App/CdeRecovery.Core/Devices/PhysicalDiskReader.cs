using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Management;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace CdeRecovery.Core.Devices
{
    public sealed class PhysicalDiskReader : IReadOnlyBlockSource
    {
        private const uint GENERIC_READ = 0x80000000;
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;

        private const uint IOCTL_DISK_GET_DRIVE_GEOMETRY_EX = 0x000700A0;
        private const uint IOCTL_DISK_GET_LENGTH_INFO = 0x0007405C;
        private const uint IOCTL_STORAGE_QUERY_PROPERTY = 0x002D1400;

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern SafeFileHandle CreateFileW(
            string lpFileName,
            uint dwDesiredAccess,
            uint dwShareMode,
            IntPtr lpSecurityAttributes,
            uint dwCreationDisposition,
            uint dwFlagsAndAttributes,
            IntPtr hTemplateFile);

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

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFilePointerEx(
            SafeFileHandle hFile,
            long liDistanceToMove,
            out long lpNewFilePointer,
            uint dwMoveMethod);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool ReadFile(
            SafeFileHandle hFile,
            byte[] lpBuffer,
            uint nNumberOfBytesToRead,
            out uint lpNumberOfBytesRead,
            IntPtr lpOverlapped);

        [StructLayout(LayoutKind.Sequential)]
        private struct DISK_GEOMETRY
        {
            public long Cylinders;
            public int MediaType;
            public uint TracksPerCylinder;
            public uint SectorsPerTrack;
            public uint BytesPerSector;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct DISK_GEOMETRY_EX
        {
            public DISK_GEOMETRY Geometry;
            public long DiskSize;
            public byte Data;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct GET_LENGTH_INFORMATION
        {
            public long Length;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct STORAGE_PROPERTY_QUERY
        {
            public int PropertyId;
            public int QueryType;
            public byte AdditionalParameters;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct STORAGE_ACCESS_ALIGNMENT_DESCRIPTOR
        {
            public uint Version;
            public uint Size;
            public uint BytesPerCacheLine;
            public uint BytesOffsetForCacheAlignment;
            public uint BytesPerLogicalSector;
            public uint BytesPerPhysicalSector;
            public uint BytesOffsetForSectorAlignment;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct STORAGE_ADAPTER_DESCRIPTOR
        {
            public uint Version;
            public uint Size;
            public uint MaximumTransferLength;
            public uint MaximumPhysicalPages;
            public uint AlignmentMask;
            public byte AdapterUsesPio;
            public byte AdapterScansDown;
            public byte CommandQueueing;
            public byte AcceleratedTransfer;
            public byte BusType;
            public ushort BusMajorVersion;
            public ushort BusMinorVersion;
        }

        private readonly SafeFileHandle _handle;
        private readonly List<SectorReadError> _readErrors = new();
        private readonly SemaphoreSlim _ioLock = new(1, 1);
        private readonly int _maxTransferBytes;
        private bool _disposed;

        public StorageDeviceIdentity Identity { get; }
        public long Length => Identity.CapacityBytes;
        public int LogicalSectorSize => Identity.LogicalSectorSize;
        public int PhysicalSectorSize => Identity.PhysicalSectorSize;
        public int MaxTransferBytes => _maxTransferBytes;
        public IReadOnlyList<SectorReadError> ReadErrors => _readErrors;

        public PhysicalDiskReader(StorageDeviceIdentity baseIdentity)
        {
            ArgumentNullException.ThrowIfNull(baseIdentity);
            if (baseIdentity.DiskNumber < 0)
                throw new ArgumentOutOfRangeException(nameof(baseIdentity), "Physical disk number must be >= 0.");

            string devicePath = string.IsNullOrWhiteSpace(baseIdentity.DevicePath)
                ? $@"\\.\PhysicalDrive{baseIdentity.DiskNumber}"
                : baseIdentity.DevicePath;

            // Strictly GENERIC_READ only - never request write access in diagnostic reader
            _handle = CreateFileW(
                devicePath,
                GENERIC_READ,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                IntPtr.Zero,
                OPEN_EXISTING,
                FILE_ATTRIBUTE_NORMAL,
                IntPtr.Zero);

            if (_handle.IsInvalid)
            {
                int err = Marshal.GetLastWin32Error();
                throw new Win32Exception(err, $"Unable to open {devicePath} for read-only inspection (Win32 error {err}). Run CDE as Administrator.");
            }

            var (diskSize, logicalSector, physicalSector, maxTransfer) = QueryGeometry(_handle, baseIdentity);
            _maxTransferBytes = maxTransfer;

            Identity = new StorageDeviceIdentity
            {
                DiskNumber = baseIdentity.DiskNumber,
                DevicePath = devicePath,
                FriendlyName = baseIdentity.FriendlyName,
                Model = baseIdentity.Model,
                SerialNumber = baseIdentity.SerialNumber,
                BusType = baseIdentity.BusType,
                CapacityBytes = diskSize > 0 ? diskSize : baseIdentity.CapacityBytes,
                LogicalSectorSize = logicalSector > 0 ? logicalSector : 512,
                PhysicalSectorSize = physicalSector > 0 ? physicalSector : Math.Max(logicalSector, 512),
                IsSystemDisk = baseIdentity.IsSystemDisk,
                IsBootDisk = baseIdentity.IsBootDisk,
                IsRemovable = baseIdentity.IsRemovable,
                IsDiskImage = false,
                WindowsReportedPartitionStyle = baseIdentity.WindowsReportedPartitionStyle,
                SmartHealthStatus = baseIdentity.SmartHealthStatus,
                MountedDriveLetters = new List<string>(baseIdentity.MountedDriveLetters)
            };
        }

        private static (long DiskSize, int LogicalSector, int PhysicalSector, int MaxTransferBytes) QueryGeometry(
            SafeFileHandle handle,
            StorageDeviceIdentity fallback)
        {
            long diskSize = fallback.CapacityBytes;
            int logical = fallback.LogicalSectorSize > 0 ? fallback.LogicalSectorSize : 512;
            int physical = fallback.PhysicalSectorSize > 0 ? fallback.PhysicalSectorSize : logical;
            int maxTransfer = 256 * 1024; // Safe 256 KiB default for USB / UAS bridges

            int geoSize = Marshal.SizeOf<DISK_GEOMETRY_EX>() + 64;
            IntPtr geoPtr = Marshal.AllocHGlobal(geoSize);
            try
            {
                if (DeviceIoControl(
                    handle,
                    IOCTL_DISK_GET_DRIVE_GEOMETRY_EX,
                    IntPtr.Zero,
                    0,
                    geoPtr,
                    (uint)geoSize,
                    out _,
                    IntPtr.Zero))
                {
                    var geo = Marshal.PtrToStructure<DISK_GEOMETRY_EX>(geoPtr);
                    if (geo.DiskSize > 0)
                        diskSize = geo.DiskSize;
                    if (geo.Geometry.BytesPerSector is 512 or 4096)
                        logical = (int)geo.Geometry.BytesPerSector;
                }
            }
            finally
            {
                Marshal.FreeHGlobal(geoPtr);
            }

            // Prefer exact IOCTL_DISK_GET_LENGTH_INFO when supported
            int lenSize = Marshal.SizeOf<GET_LENGTH_INFORMATION>();
            IntPtr lenPtr = Marshal.AllocHGlobal(lenSize);
            try
            {
                if (DeviceIoControl(
                    handle,
                    IOCTL_DISK_GET_LENGTH_INFO,
                    IntPtr.Zero,
                    0,
                    lenPtr,
                    (uint)lenSize,
                    out _,
                    IntPtr.Zero))
                {
                    var lenInfo = Marshal.PtrToStructure<GET_LENGTH_INFORMATION>(lenPtr);
                    if (lenInfo.Length > 0)
                        diskSize = lenInfo.Length;
                }
            }
            finally
            {
                Marshal.FreeHGlobal(lenPtr);
            }

            int querySize = Marshal.SizeOf<STORAGE_PROPERTY_QUERY>();
            int alignSize = Marshal.SizeOf<STORAGE_ACCESS_ALIGNMENT_DESCRIPTOR>();
            IntPtr queryPtr = Marshal.AllocHGlobal(querySize);
            IntPtr alignPtr = Marshal.AllocHGlobal(alignSize);
            try
            {
                var query = new STORAGE_PROPERTY_QUERY
                {
                    PropertyId = 6, // StorageAccessAlignmentProperty
                    QueryType = 0   // PropertyStandardQuery
                };
                Marshal.StructureToPtr(query, queryPtr, false);

                if (DeviceIoControl(
                    handle,
                    IOCTL_STORAGE_QUERY_PROPERTY,
                    queryPtr,
                    (uint)querySize,
                    alignPtr,
                    (uint)alignSize,
                    out _,
                    IntPtr.Zero))
                {
                    var align = Marshal.PtrToStructure<STORAGE_ACCESS_ALIGNMENT_DESCRIPTOR>(alignPtr);
                    if (align.BytesPerLogicalSector is 512 or 4096)
                        logical = (int)align.BytesPerLogicalSector;
                    if (align.BytesPerPhysicalSector >= (uint)logical)
                        physical = (int)align.BytesPerPhysicalSector;
                }
            }
            finally
            {
                Marshal.FreeHGlobal(queryPtr);
                Marshal.FreeHGlobal(alignPtr);
            }

            int adapterSize = Marshal.SizeOf<STORAGE_ADAPTER_DESCRIPTOR>() + 64;
            IntPtr adapterPtr = Marshal.AllocHGlobal(adapterSize);
            IntPtr qAdapterPtr = Marshal.AllocHGlobal(querySize);
            try
            {
                var qAdapter = new STORAGE_PROPERTY_QUERY
                {
                    PropertyId = 1, // StorageAdapterProperty
                    QueryType = 0   // PropertyStandardQuery
                };
                Marshal.StructureToPtr(qAdapter, qAdapterPtr, false);

                if (DeviceIoControl(
                    handle,
                    IOCTL_STORAGE_QUERY_PROPERTY,
                    qAdapterPtr,
                    (uint)querySize,
                    adapterPtr,
                    (uint)adapterSize,
                    out _,
                    IntPtr.Zero))
                {
                    var adapter = Marshal.PtrToStructure<STORAGE_ADAPTER_DESCRIPTOR>(adapterPtr);
                    if (adapter.MaximumTransferLength >= 65536)
                    {
                        // Clamp between 64 KiB and 256 KiB (USB-safe ceiling)
                        int rawLimit = (int)Math.Min(adapter.MaximumTransferLength, 262144u);
                        maxTransfer = (rawLimit / 4096) * 4096;
                    }
                }
            }
            finally
            {
                Marshal.FreeHGlobal(adapterPtr);
                Marshal.FreeHGlobal(qAdapterPtr);
            }

            return (diskSize, logical, physical, maxTransfer);
        }

        public async Task<int> ReadAtAsync(
            long offset,
            Memory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (offset < 0)
                throw new ArgumentOutOfRangeException(nameof(offset));
            if (buffer.Length == 0 || offset >= Length)
                return 0;

            await _ioLock.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                // Always align physical disk reads to at least 4096 bytes (8 x 512B sectors)
                // so 512e/4Kn USB UAS bridges never receive unaligned 512-byte reads even when WMI reports 512B.
                int logicalSize = LogicalSectorSize > 0 ? LogicalSectorSize : 512;
                int alignUnit = Math.Max(4096, Math.Max(logicalSize, PhysicalSectorSize > 0 ? PhysicalSectorSize : logicalSize));

                long alignedStart = (offset / alignUnit) * alignUnit;
                int leadingBytes = (int)(offset - alignedStart);
                long requiredBytes = leadingBytes + buffer.Length;
                int alignedLength = (int)(((requiredBytes + alignUnit - 1) / alignUnit) * alignUnit);

                if (Length > 0 && alignedStart + alignedLength > Length)
                {
                    // If the 4K-aligned window reaches the end of the disk, step back alignedStart to Length - alignUnit when possible
                    if (Length >= alignUnit && buffer.Length <= alignUnit && offset >= Length - alignUnit)
                    {
                        alignedStart = ((Length - alignUnit) / logicalSize) * logicalSize;
                        leadingBytes = (int)(offset - alignedStart);
                        alignedLength = (int)(((leadingBytes + buffer.Length + logicalSize - 1) / logicalSize) * logicalSize);
                    }
                    else
                    {
                        long maxAvailable = Length - alignedStart;
                        alignedLength = (int)((maxAvailable / logicalSize) * logicalSize);
                    }
                    if (alignedLength <= leadingBytes)
                        return 0;
                }

                byte[] alignedBuffer = new byte[alignedLength];
                int chunkLimit = Math.Max(alignUnit, _maxTransferBytes);
                int totalBytesRead = 0;

                while (totalBytesRead < alignedLength)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    long chunkOffset = alignedStart + totalBytesRead;
                    int chunkLen = Math.Min(chunkLimit, alignedLength - totalBytesRead);

                    if (!SetFilePointerEx(_handle, chunkOffset, out _, 0 /* FILE_BEGIN */))
                    {
                        int win32Err = Marshal.GetLastWin32Error();
                        throw new Win32Exception(win32Err, $"SetFilePointerEx failed at offset 0x{chunkOffset:X} (Win32 error {win32Err}).");
                    }

                    byte[] chunkBuf = totalBytesRead == 0 && chunkLen == alignedLength
                        ? alignedBuffer
                        : new byte[chunkLen];

                    if (!ReadFile(_handle, chunkBuf, (uint)chunkLen, out uint bytesRead, IntPtr.Zero))
                    {
                        int win32Err = Marshal.GetLastWin32Error();
                        throw new Win32Exception(win32Err, $"ReadFile failed at offset 0x{chunkOffset:X} length {chunkLen} (Win32 error {win32Err}).");
                    }

                    if (bytesRead == 0)
                        break;

                    if (!ReferenceEquals(chunkBuf, alignedBuffer))
                    {
                        Buffer.BlockCopy(chunkBuf, 0, alignedBuffer, totalBytesRead, (int)bytesRead);
                    }

                    totalBytesRead += (int)bytesRead;
                    if (bytesRead < (uint)chunkLen)
                        break;
                }

                if (totalBytesRead <= leadingBytes)
                    return 0;

                int copyLen = Math.Min(buffer.Length, totalBytesRead - leadingBytes);
                alignedBuffer.AsMemory(leadingBytes, copyLen).CopyTo(buffer);
                return copyLen;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _readErrors.Add(new SectorReadError
                {
                    ByteOffset = offset,
                    ByteLength = buffer.Length,
                    StartLba = LogicalSectorSize > 0 ? offset / LogicalSectorSize : 0,
                    RegionDescription = $"PhysicalDrive{Identity.DiskNumber} @ 0x{offset:X}",
                    ErrorMessage = ex.Message,
                    Win32ErrorCode = Marshal.GetLastWin32Error()
                });
                throw;
            }
            finally
            {
                _ioLock.Release();
            }
        }

        public static List<StorageDeviceIdentity> EnumeratePhysicalDisks()
        {
            var results = new List<StorageDeviceIdentity>();
            var systemDrive = (Environment.GetEnvironmentVariable("SystemDrive") ?? "C:").TrimEnd('\\');

            try
            {
                using var searcher = new ManagementObjectSearcher(
                    "SELECT Index, Model, Caption, SerialNumber, InterfaceType, Size, BytesPerSector, MediaType, Partitions FROM Win32_DiskDrive");
                foreach (ManagementObject disk in searcher.Get())
                {
                    int index = Convert.ToInt32(disk["Index"] ?? -1);
                    if (index < 0) continue;

                    string model = (disk["Model"]?.ToString() ?? disk["Caption"]?.ToString() ?? $"Disk {index}").Trim();
                    string serial = (disk["SerialNumber"]?.ToString() ?? string.Empty).Trim();
                    string busType = (disk["InterfaceType"]?.ToString() ?? "Unknown").Trim();
                    string mediaType = (disk["MediaType"]?.ToString() ?? string.Empty).Trim();
                    long size = disk["Size"] != null ? Convert.ToInt64(disk["Size"]) : 0L;
                    int sectorSize = disk["BytesPerSector"] != null ? Convert.ToInt32(disk["BytesPerSector"]) : 512;
                    if (sectorSize != 512 && sectorSize != 4096) sectorSize = 512;

                    var mountedLetters = new List<string>();
                    bool isSystem = false;
                    try
                    {
                        foreach (ManagementObject part in disk.GetRelated("Win32_DiskPartition"))
                        {
                            foreach (ManagementObject logical in part.GetRelated("Win32_LogicalDisk"))
                            {
                                string devId = logical["DeviceID"]?.ToString() ?? string.Empty;
                                if (!string.IsNullOrWhiteSpace(devId))
                                {
                                    mountedLetters.Add(devId);
                                    if (string.Equals(devId, systemDrive, StringComparison.OrdinalIgnoreCase))
                                        isSystem = true;
                                }
                            }
                        }
                    }
                    catch
                    {
                        // Partition association may fail on RAW or corrupt disks - that is expected.
                    }

                    results.Add(new StorageDeviceIdentity
                    {
                        DiskNumber = index,
                        DevicePath = $@"\\.\PhysicalDrive{index}",
                        FriendlyName = model,
                        Model = model,
                        SerialNumber = serial,
                        BusType = busType,
                        CapacityBytes = size,
                        LogicalSectorSize = sectorSize,
                        PhysicalSectorSize = sectorSize,
                        IsSystemDisk = isSystem,
                        IsBootDisk = isSystem,
                        IsRemovable = mediaType.Contains("Removable", StringComparison.OrdinalIgnoreCase)
                                      || busType.Equals("USB", StringComparison.OrdinalIgnoreCase),
                        IsDiskImage = false,
                        WindowsReportedPartitionStyle = "Unknown",
                        SmartHealthStatus = "Unknown",
                        MountedDriveLetters = mountedLetters
                    });
                }
            }
            catch
            {
                // Fallback if WMI unavailable
            }

            // Enrich from MSFT_Disk (Storage WMI namespace) if available
            try
            {
                var scope = new ManagementScope(@"\\.\root\Microsoft\Windows\Storage");
                scope.Connect();
                using var searcher = new ManagementObjectSearcher(
                    scope,
                    new ObjectQuery("SELECT Number, FriendlyName, SerialNumber, Size, LogicalSectorSize, PhysicalSectorSize, PartitionStyle, IsSystem, IsBoot, HealthStatus, BusType FROM MSFT_Disk"));
                foreach (ManagementObject msft in searcher.Get())
                {
                    int number = Convert.ToInt32(msft["Number"] ?? -1);
                    if (number < 0) continue;

                    int partStyleCode = msft["PartitionStyle"] != null ? Convert.ToInt32(msft["PartitionStyle"]) : 0;
                    string partStyle = partStyleCode switch
                    {
                        1 => "MBR",
                        2 => "GPT",
                        _ => "RAW"
                    };

                    int healthCode = msft["HealthStatus"] != null ? Convert.ToInt32(msft["HealthStatus"]) : -1;
                    string health = healthCode switch
                    {
                        0 => "Healthy",
                        1 => "Warning",
                        2 => "Critical",
                        _ => "Unknown"
                    };

                    int busCode = msft["BusType"] != null ? Convert.ToInt32(msft["BusType"]) : 0;
                    string busName = busCode switch
                    {
                        7 => "USB",
                        11 => "SATA",
                        17 => "NVMe",
                        8 => "RAID",
                        10 => "SAS",
                        _ => string.Empty
                    };

                    int existingIdx = results.FindIndex(r => r.DiskNumber == number);
                    var prev = existingIdx >= 0 ? results[existingIdx] : null;

                    int logicalSec = msft["LogicalSectorSize"] != null ? Convert.ToInt32(msft["LogicalSectorSize"]) : (prev?.LogicalSectorSize ?? 512);
                    int physSec = msft["PhysicalSectorSize"] != null ? Convert.ToInt32(msft["PhysicalSectorSize"]) : Math.Max(logicalSec, prev?.PhysicalSectorSize ?? 512);
                    long cap = msft["Size"] != null ? Convert.ToInt64(msft["Size"]) : (prev?.CapacityBytes ?? 0);
                    string friendly = (msft["FriendlyName"]?.ToString() ?? prev?.FriendlyName ?? $"Disk {number}").Trim();
                    string serial = (msft["SerialNumber"]?.ToString() ?? prev?.SerialNumber ?? string.Empty).Trim();
                    bool isSys = (msft["IsSystem"] != null && Convert.ToBoolean(msft["IsSystem"])) || (prev?.IsSystemDisk ?? false);
                    bool isBoot = (msft["IsBoot"] != null && Convert.ToBoolean(msft["IsBoot"])) || (prev?.IsBootDisk ?? false);

                    var updated = new StorageDeviceIdentity
                    {
                        DiskNumber = number,
                        DevicePath = $@"\\.\PhysicalDrive{number}",
                        FriendlyName = friendly,
                        Model = prev?.Model ?? friendly,
                        SerialNumber = serial,
                        BusType = !string.IsNullOrWhiteSpace(busName) ? busName : (prev?.BusType ?? "Unknown"),
                        CapacityBytes = cap,
                        LogicalSectorSize = logicalSec is 512 or 4096 ? logicalSec : 512,
                        PhysicalSectorSize = physSec >= logicalSec ? physSec : logicalSec,
                        IsSystemDisk = isSys,
                        IsBootDisk = isBoot,
                        IsRemovable = (prev?.IsRemovable ?? false) || busName == "USB",
                        IsDiskImage = false,
                        WindowsReportedPartitionStyle = partStyle,
                        SmartHealthStatus = health,
                        MountedDriveLetters = prev?.MountedDriveLetters ?? new List<string>()
                    };

                    if (existingIdx >= 0)
                        results[existingIdx] = updated;
                    else
                        results.Add(updated);
                }
            }
            catch
            {
                // Storage WMI optional
            }

            return results.OrderBy(r => r.DiskNumber).ToList();
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            _handle.Dispose();
            _ioLock.Dispose();
        }
    }
}
