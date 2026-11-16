using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace CdeRecovery.Core.Devices
{
    public sealed class DiskImageReader : IReadOnlyBlockSource
    {
        private readonly FileStream _stream;
        private readonly List<SectorReadError> _readErrors = new();
        private readonly List<(long Start, long End, string Message)> _simulatedErrorRanges = new();
        private bool _disposed;

        public StorageDeviceIdentity Identity { get; }
        public long Length => Identity.CapacityBytes;
        public int LogicalSectorSize => Identity.LogicalSectorSize;
        public int PhysicalSectorSize => Identity.PhysicalSectorSize;
        public IReadOnlyList<SectorReadError> ReadErrors => _readErrors;

        public DiskImageReader(
            string imagePath,
            int logicalSectorSize = 512,
            int physicalSectorSize = 512,
            string? friendlyName = null,
            string smartHealthStatus = "Healthy")
        {
            if (string.IsNullOrWhiteSpace(imagePath))
                throw new ArgumentException("Image path is required.", nameof(imagePath));
            if (logicalSectorSize != 512 && logicalSectorSize != 4096)
                throw new ArgumentOutOfRangeException(nameof(logicalSectorSize), "Logical sector size must be 512 or 4096.");

            var fullPath = Path.GetFullPath(imagePath);
            if (!File.Exists(fullPath))
                throw new FileNotFoundException("Disk image file not found.", fullPath);

            // Strictly read-only handle
            _stream = new FileStream(
                fullPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite,
                bufferSize: Math.Max(4096, logicalSectorSize * 8),
                useAsync: true);

            Identity = new StorageDeviceIdentity
            {
                DiskNumber = -1,
                DevicePath = fullPath,
                FriendlyName = string.IsNullOrWhiteSpace(friendlyName) ? Path.GetFileName(fullPath) : friendlyName,
                Model = "CDE Virtual Disk Image",
                SerialNumber = $"IMG-{Path.GetFileNameWithoutExtension(fullPath)}",
                BusType = "File Image",
                CapacityBytes = _stream.Length,
                LogicalSectorSize = logicalSectorSize,
                PhysicalSectorSize = Math.Max(logicalSectorSize, physicalSectorSize),
                IsSystemDisk = false,
                IsBootDisk = false,
                IsRemovable = false,
                IsDiskImage = true,
                WindowsReportedPartitionStyle = "Image",
                SmartHealthStatus = smartHealthStatus
            };
        }

        public void AddSimulatedErrorRange(long startOffset, long length, string message = "Simulated CRC / bad sector I/O error")
        {
            _simulatedErrorRanges.Add((startOffset, startOffset + length, message));
        }

        public async Task<int> ReadAtAsync(
            long offset,
            Memory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (offset < 0)
                throw new ArgumentOutOfRangeException(nameof(offset), "Offset cannot be negative.");
            if (buffer.Length == 0)
                return 0;
            if (offset >= Length)
                return 0;

            long endOffset = offset + buffer.Length;
            foreach (var sim in _simulatedErrorRanges)
            {
                if (offset < sim.End && endOffset > sim.Start)
                {
                    var err = new SectorReadError
                    {
                        ByteOffset = offset,
                        ByteLength = buffer.Length,
                        StartLba = LogicalSectorSize > 0 ? offset / LogicalSectorSize : 0,
                        RegionDescription = $"Offset 0x{offset:X}",
                        ErrorMessage = sim.Message,
                        Win32ErrorCode = 23 // ERROR_CRC
                    };
                    _readErrors.Add(err);
                    throw new IOException(sim.Message);
                }
            }

            try
            {
                int maxRead = (int)Math.Min(buffer.Length, Length - offset);
                int totalRead = 0;
                _stream.Seek(offset, SeekOrigin.Begin);
                while (totalRead < maxRead)
                {
                    int read = await _stream.ReadAsync(
                        buffer.Slice(totalRead, maxRead - totalRead),
                        cancellationToken).ConfigureAwait(false);
                    if (read == 0)
                        break;
                    totalRead += read;
                }
                return totalRead;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _readErrors.Add(new SectorReadError
                {
                    ByteOffset = offset,
                    ByteLength = buffer.Length,
                    StartLba = LogicalSectorSize > 0 ? offset / LogicalSectorSize : 0,
                    RegionDescription = $"Offset 0x{offset:X}",
                    ErrorMessage = ex.Message,
                    Win32ErrorCode = ex.HResult & 0xFFFF
                });
                throw;
            }
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            _stream.Dispose();
        }
    }
}
