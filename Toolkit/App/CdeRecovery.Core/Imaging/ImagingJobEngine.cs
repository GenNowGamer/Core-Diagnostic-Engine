using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using CdeRecovery.Core.Devices;
using CdeRecovery.Core.Evidence;
using CdeRecovery.Core.Models;
using Microsoft.Win32.SafeHandles;

namespace CdeRecovery.Core.Imaging
{
    public static class ImagingJobEngine
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

        public static string GetMapFilePath(string outputImagePath) =>
            Path.GetFullPath(outputImagePath) + ".cdemap";

        public static async Task<ImagingJobManifest> RunOrResumeImagingJobAsync(
            IReadOnlyBlockSource source,
            string outputImagePath,
            long sourceStartOffset = 0,
            long lengthBytes = 0,
            bool scrapeFailedBlocks = true,
            bool useSparseOutput = true,
            int copyBlockSizeBytes = 256 * 1024,
            string targetScopeLabel = "Whole Disk",
            IProgress<ImagingProgressReport>? progress = null,
            CancellationToken cancellationToken = default)
        {
            ArgumentNullException.ThrowIfNull(source);
            if (string.IsNullOrWhiteSpace(outputImagePath))
                throw new ArgumentException("Output image path is required.", nameof(outputImagePath));

            MetadataSnapshotService.ValidateDestinationNotOnSource(source.Identity, outputImagePath);

            string fullImgPath = Path.GetFullPath(outputImagePath);
            string mapPath = GetMapFilePath(fullImgPath);
            Directory.CreateDirectory(Path.GetDirectoryName(fullImgPath)!);

            long totalToCopy = lengthBytes > 0
                ? Math.Min(lengthBytes, source.Length - sourceStartOffset)
                : source.Length - sourceStartOffset;

            if (sourceStartOffset < 0 || totalToCopy <= 0)
                throw new ArgumentOutOfRangeException(nameof(lengthBytes), "Invalid imaging byte range.");

            int scrapeSectorSize = Math.Max(4096, Math.Max(source.LogicalSectorSize, source.PhysicalSectorSize));
            int blockSize = Math.Max(scrapeSectorSize, (copyBlockSizeBytes / scrapeSectorSize) * scrapeSectorSize);

            ImagingJobManifest manifest;
            if (File.Exists(mapPath) && File.Exists(fullImgPath))
            {
                string existingJson = await File.ReadAllTextAsync(mapPath, cancellationToken).ConfigureAwait(false);
                manifest = JsonSerializer.Deserialize<ImagingJobManifest>(existingJson, new JsonSerializerOptions
                {
                    PropertyNameCaseInsensitive = true
                }) ?? throw new InvalidDataException("Invalid .cdemap file.");

                if (manifest.SourceStartOffset != sourceStartOffset || manifest.TotalBytesToCopy != totalToCopy)
                {
                    throw new InvalidOperationException(
                        $"Existing mapfile ({Path.GetFileName(mapPath)}) was created for range 0x{manifest.SourceStartOffset:X}+0x{manifest.TotalBytesToCopy:X}, which does not match requested range 0x{sourceStartOffset:X}+0x{totalToCopy:X}.");
                }
            }
            else
            {
                manifest = new ImagingJobManifest
                {
                    SchemaVersion = 1,
                    JobId = $"CDEIMG_{DateTime.UtcNow:yyyyMMdd_HHmmss}",
                    CreatedAtUtc = DateTime.UtcNow,
                    UpdatedAtUtc = DateTime.UtcNow,
                    SourceIdentity = source.Identity,
                    OutputImagePath = fullImgPath,
                    MapFilePath = mapPath,
                    TargetScopeLabel = string.IsNullOrWhiteSpace(targetScopeLabel) ? "Whole Disk" : targetScopeLabel,
                    SourceStartOffset = sourceStartOffset,
                    TotalBytesToCopy = totalToCopy,
                    CopyBlockSizeBytes = blockSize,
                    ScrapeSectorSizeBytes = scrapeSectorSize,
                    CurrentPhase = "Copying",
                    Extents = new List<ImagingMapExtent>
                    {
                        new ImagingMapExtent
                        {
                            Offset = 0,
                            Length = totalToCopy,
                            State = ImagingBlockState.NonTried
                        }
                    }
                };
            }

            await using var imgStream = new FileStream(fullImgPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.Read, 65536, useAsync: true);
            if (useSparseOutput)
            {
                try
                {
                    DeviceIoControl(imgStream.SafeFileHandle, FSCTL_SET_SPARSE, IntPtr.Zero, 0, IntPtr.Zero, 0, out _, IntPtr.Zero);
                }
                catch { }
            }
            if (imgStream.Length != totalToCopy)
            {
                imgStream.SetLength(totalToCopy);
            }

            byte[] buffer = new byte[blockSize];
            int blocksSinceSave = 0;
            int consecutiveDeviceErrors = 0;

            try
            {
                // ═══ PHASE 1: FAST BLOCK COPYING PASS ═══
                manifest.CurrentPhase = "Copying";
                var nonTriedSnapshot = manifest.Extents
                    .Where(e => e.State == ImagingBlockState.NonTried)
                    .Select(e => (e.Offset, e.Length))
                    .ToList();

                foreach (var (extStart, extLen) in nonTriedSnapshot)
                {
                    long relPos = extStart;
                    long relEnd = extStart + extLen;

                    while (relPos < relEnd)
                    {
                        cancellationToken.ThrowIfCancellationRequested();

                        int chunkLen = (int)Math.Min(blockSize, relEnd - relPos);
                        long sourceOffset = sourceStartOffset + relPos;

                        try
                        {
                            int read = await source.ReadAtAsync(sourceOffset, buffer.AsMemory(0, chunkLen), cancellationToken).ConfigureAwait(false);
                            consecutiveDeviceErrors = 0;

                            if (read > 0)
                            {
                                if (!useSparseOutput || HasNonZeroBytes(buffer, read))
                                {
                                    imgStream.Seek(relPos, SeekOrigin.Begin);
                                    await imgStream.WriteAsync(buffer.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
                                }

                                UpdateExtentRange(manifest, relPos, read, ImagingBlockState.Finished);
                            }
                            else
                            {
                                UpdateExtentRange(manifest, relPos, chunkLen, ImagingBlockState.FailedBlock);
                            }
                        }
                        catch (Exception ex) when (ex is not OperationCanceledException)
                        {
                            UpdateExtentRange(manifest, relPos, chunkLen, ImagingBlockState.FailedBlock);

                            if (ex is Win32Exception w32 && (w32.NativeErrorCode == 1117 || w32.NativeErrorCode == 1167 || w32.NativeErrorCode == 55))
                            {
                                consecutiveDeviceErrors++;
                                if (consecutiveDeviceErrors >= 3)
                                {
                                    manifest.CurrentPhase = "AbortedDeviceDisconnected";
                                    manifest.LastStatusMessage = $"Paused at offset 0x{sourceOffset:X}: Source device reported repeated I/O disconnection (Win32 error {w32.NativeErrorCode}). Reconnect drive and resume.";
                                    await SaveManifestAsync(manifest, mapPath, imgStream, CancellationToken.None).ConfigureAwait(false);
                                    return manifest;
                                }
                            }
                        }

                        relPos += chunkLen;
                        blocksSinceSave++;

                        RecalculateTotals(manifest);
                        progress?.Report(new ImagingProgressReport
                        {
                            Phase = "Phase 1: Fast Block Copy",
                            CurrentOffset = relPos,
                            TotalBytes = totalToCopy,
                            BytesRescued = manifest.BytesRescued,
                            BytesBad = manifest.BytesBad,
                            BadRangeCount = manifest.Extents.Count(e => e.State is ImagingBlockState.FailedBlock or ImagingBlockState.BadSector),
                            StatusMessage = $"Copying @ 0x{sourceOffset:X} ({manifest.BytesRescued / (1024 * 1024)} MB rescued)"
                        });

                        if (blocksSinceSave >= 16)
                        {
                            blocksSinceSave = 0;
                            await SaveManifestAsync(manifest, mapPath, imgStream, cancellationToken).ConfigureAwait(false);
                        }
                    }
                }

                // ═══ PHASE 2: 4K SECTOR SCRAPING PASS ON FAILED BLOCKS ═══
                if (scrapeFailedBlocks)
                {
                    manifest.CurrentPhase = "Scraping";
                    var failedSnapshot = manifest.Extents
                        .Where(e => e.State == ImagingBlockState.FailedBlock)
                        .Select(e => (e.Offset, e.Length))
                        .ToList();

                    byte[] secBuf = new byte[scrapeSectorSize];
                    foreach (var (fStart, fLen) in failedSnapshot)
                    {
                        long relPos = fStart;
                        long relEnd = fStart + fLen;

                        while (relPos < relEnd)
                        {
                            cancellationToken.ThrowIfCancellationRequested();

                            int secLen = (int)Math.Min(scrapeSectorSize, relEnd - relPos);
                            long sourceOffset = sourceStartOffset + relPos;

                            try
                            {
                                int read = await source.ReadAtAsync(sourceOffset, secBuf.AsMemory(0, secLen), cancellationToken).ConfigureAwait(false);
                                if (read > 0)
                                {
                                    imgStream.Seek(relPos, SeekOrigin.Begin);
                                    await imgStream.WriteAsync(secBuf.AsMemory(0, read), cancellationToken).ConfigureAwait(false);
                                    UpdateExtentRange(manifest, relPos, read, ImagingBlockState.Finished);
                                }
                                else
                                {
                                    UpdateExtentRange(manifest, relPos, secLen, ImagingBlockState.BadSector);
                                }
                            }
                            catch (Exception ex) when (ex is not OperationCanceledException)
                            {
                                UpdateExtentRange(manifest, relPos, secLen, ImagingBlockState.BadSector);
                            }

                            relPos += secLen;
                            RecalculateTotals(manifest);
                            progress?.Report(new ImagingProgressReport
                            {
                                Phase = "Phase 2: Sector Scraping",
                                CurrentOffset = relPos,
                                TotalBytes = totalToCopy,
                                BytesRescued = manifest.BytesRescued,
                                BytesBad = manifest.BytesBad,
                                BadRangeCount = manifest.Extents.Count(e => e.State == ImagingBlockState.BadSector),
                                StatusMessage = $"Scraping failed block @ 0x{sourceOffset:X} ({manifest.BytesBad} bytes confirmed bad)"
                            });
                        }

                        await SaveManifestAsync(manifest, mapPath, imgStream, cancellationToken).ConfigureAwait(false);
                    }
                }

                RecalculateTotals(manifest);
                manifest.CurrentPhase = "Completed";
                manifest.LastStatusMessage = $"Imaging completed: {manifest.BytesRescued:N0} bytes rescued, {manifest.BytesBad:N0} bytes unreadable.";
                await SaveManifestAsync(manifest, mapPath, imgStream, CancellationToken.None).ConfigureAwait(false);
                return manifest;
            }
            catch (OperationCanceledException)
            {
                RecalculateTotals(manifest);
                manifest.CurrentPhase = "Paused";
                manifest.LastStatusMessage = $"Imaging paused at {manifest.BytesRescued:N0} / {manifest.TotalBytesToCopy:N0} bytes. Click Resume to continue from mapfile.";
                await SaveManifestAsync(manifest, mapPath, imgStream, CancellationToken.None).ConfigureAwait(false);
                throw;
            }
        }

        private static void UpdateExtentRange(ImagingJobManifest manifest, long start, long length, ImagingBlockState newState)
        {
            long end = start + length;
            var updated = new List<ImagingMapExtent>(manifest.Extents.Count + 2);

            foreach (var ext in manifest.Extents)
            {
                long extStart = ext.Offset;
                long extEnd = ext.Offset + ext.Length;

                if (extEnd <= start || extStart >= end)
                {
                    updated.Add(ext);
                    continue;
                }

                if (extStart < start)
                {
                    updated.Add(new ImagingMapExtent
                    {
                        Offset = extStart,
                        Length = start - extStart,
                        State = ext.State
                    });
                }

                long overlapStart = Math.Max(extStart, start);
                long overlapEnd = Math.Min(extEnd, end);
                updated.Add(new ImagingMapExtent
                {
                    Offset = overlapStart,
                    Length = overlapEnd - overlapStart,
                    State = newState
                });

                if (extEnd > end)
                {
                    updated.Add(new ImagingMapExtent
                    {
                        Offset = end,
                        Length = extEnd - end,
                        State = ext.State
                    });
                }
            }

            // Coalesce adjacent extents with identical state
            var merged = new List<ImagingMapExtent>(updated.Count);
            foreach (var item in updated.OrderBy(e => e.Offset))
            {
                if (item.Length <= 0) continue;
                if (merged.Count > 0 && merged[^1].State == item.State && merged[^1].Offset + merged[^1].Length == item.Offset)
                {
                    merged[^1].Length += item.Length;
                }
                else
                {
                    merged.Add(item);
                }
            }

            manifest.Extents = merged;
        }

        private static void RecalculateTotals(ImagingJobManifest manifest)
        {
            manifest.BytesRescued = manifest.Extents
                .Where(e => e.State == ImagingBlockState.Finished)
                .Sum(e => e.Length);
            manifest.BytesBad = manifest.Extents
                .Where(e => e.State is ImagingBlockState.FailedBlock or ImagingBlockState.BadSector)
                .Sum(e => e.Length);
            manifest.UpdatedAtUtc = DateTime.UtcNow;
        }

        private static bool HasNonZeroBytes(byte[] buffer, int length) =>
            buffer.AsSpan(0, length).ContainsAnyExcept((byte)0);

        private static async Task SaveManifestAsync(
            ImagingJobManifest manifest,
            string mapPath,
            FileStream imgStream,
            CancellationToken cancellationToken)
        {
            await imgStream.FlushAsync(cancellationToken).ConfigureAwait(false);
            string json = JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true });
            await File.WriteAllTextAsync(mapPath, json, cancellationToken).ConfigureAwait(false);
        }
    }
}
