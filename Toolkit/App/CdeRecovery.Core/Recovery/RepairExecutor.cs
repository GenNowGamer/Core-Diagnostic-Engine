using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using CdeRecovery.Core.Devices;
using CdeRecovery.Core.Evidence;
using CdeRecovery.Core.Models;
using Microsoft.Win32.SafeHandles;

namespace CdeRecovery.Core.Recovery
{
    public interface IRecoveryRepairExecutor
    {
        Task<RepairResult> ApplyToImageAsync(
            VerifiedRepairPlan plan,
            string imagePath,
            string snapshotOutputDirectory,
            CancellationToken cancellationToken = default);

        Task<RepairResult> ApplyToPhysicalDiskInPlaceAsync(
            VerifiedRepairPlan plan,
            PhysicalDiskRepairAuthorization authorization,
            CancellationToken cancellationToken = default);
    }

    public sealed class RepairExecutor : IRecoveryRepairExecutor
    {
        private const uint GENERIC_READ = 0x80000000;
        private const uint GENERIC_WRITE = 0x40000000;
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_FLAG_WRITE_THROUGH = 0x80000000;
        private const uint IOCTL_DISK_UPDATE_PROPERTIES = 0x00070140;
        private const uint FSCTL_LOCK_VOLUME = 0x00090018;
        private const uint FSCTL_DISMOUNT_VOLUME = 0x00090020;

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
        private static extern bool WriteFile(
            SafeFileHandle hFile,
            byte[] lpBuffer,
            uint nNumberOfBytesToWrite,
            out uint lpNumberOfBytesWritten,
            IntPtr lpOverlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool FlushFileBuffers(SafeFileHandle hFile);

        public async Task<RepairResult> ApplyToImageAsync(
            VerifiedRepairPlan plan,
            string imagePath,
            string snapshotOutputDirectory,
            CancellationToken cancellationToken = default)
        {
            ArgumentNullException.ThrowIfNull(plan);
            var audit = new List<string>();

            if (!plan.IsExecutable || plan.Patches.Count == 0)
            {
                return new RepairResult
                {
                    Succeeded = false,
                    PlanId = plan.PlanId,
                    TargetDescription = imagePath,
                    SummaryMessage = "Repair plan is not executable or contains no byte patches.",
                    AuditLogEntries = audit
                };
            }

            string fullImagePath = Path.GetFullPath(imagePath);
            if (!File.Exists(fullImagePath))
                throw new FileNotFoundException("Target disk image not found.", fullImagePath);

            MetadataSnapshotService.ValidateDestinationNotOnSource(plan.SourceIdentity, snapshotOutputDirectory);

            // 1. Re-verify identity and original bytes via read-only reader first, and capture pre-repair snapshot
            string manifestPath;
            using (var reader = new DiskImageReader(fullImagePath, plan.SourceIdentity.LogicalSectorSize, plan.SourceIdentity.PhysicalSectorSize))
            {
                if (!reader.Identity.MatchesIdentity(plan.SourceIdentity))
                {
                    return new RepairResult
                    {
                        Succeeded = false,
                        PlanId = plan.PlanId,
                        TargetDescription = fullImagePath,
                        SummaryMessage = "Rejected: Target disk image identity or capacity does not match the analyzed source.",
                        AuditLogEntries = audit
                    };
                }

                // Verify expected original bytes (stale plan check)
                foreach (var patch in plan.Patches)
                {
                    byte[] current = new byte[patch.ByteLength];
                    int read = await reader.ReadAtAsync(patch.TargetByteOffset, current, cancellationToken).ConfigureAwait(false);
                    string actualSha = MetadataSnapshotService.ComputeSha256Hex(current.AsSpan(0, read));
                    if (!string.Equals(actualSha, patch.ExpectedOriginalSha256, StringComparison.OrdinalIgnoreCase))
                    {
                        audit.Add($"[REJECTED] Stale repair plan: region '{patch.RegionName}' at 0x{patch.TargetByteOffset:X} has changed since scan (Expected SHA256={patch.ExpectedOriginalSha256}, Actual={actualSha}).");
                        return new RepairResult
                        {
                            Succeeded = false,
                            PlanId = plan.PlanId,
                            TargetDescription = fullImagePath,
                            SummaryMessage = $"Stale repair plan rejected: bytes in '{patch.RegionName}' changed since diagnostic scan.",
                            AuditLogEntries = audit
                        };
                    }
                }

                var snap = await MetadataSnapshotService.CaptureSnapshotAsync(reader, null, snapshotOutputDirectory, cancellationToken, plan.Patches).ConfigureAwait(false);
                manifestPath = Path.Combine(snap.SnapshotDirectory, "manifest.json");
                audit.Add($"[SNAPSHOT] Captured pre-repair binary metadata snapshot: {manifestPath}");
            }

            // 2. Apply patches to disk image
            await using (var writeStream = new FileStream(fullImagePath, FileMode.Open, FileAccess.ReadWrite, FileShare.Read, 4096, useAsync: true))
            {
                foreach (var patch in plan.Patches)
                {
                    writeStream.Seek(patch.TargetByteOffset, SeekOrigin.Begin);
                    await writeStream.WriteAsync(patch.ReplacementBytes, cancellationToken).ConfigureAwait(false);
                    audit.Add($"[WRITE] Applied {patch.ByteLength} bytes to '{patch.RegionName}' at 0x{patch.TargetByteOffset:X} (LBA {patch.StartLba}) -> SHA256 {patch.ReplacementSha256}");
                }
                await writeStream.FlushAsync(cancellationToken).ConfigureAwait(false);
            }

            // 3. Post-write verification
            bool allVerified = true;
            using (var postReader = new DiskImageReader(fullImagePath, plan.SourceIdentity.LogicalSectorSize, plan.SourceIdentity.PhysicalSectorSize))
            {
                foreach (var patch in plan.Patches)
                {
                    byte[] check = new byte[patch.ByteLength];
                    int read = await postReader.ReadAtAsync(patch.TargetByteOffset, check, cancellationToken).ConfigureAwait(false);
                    string checkSha = MetadataSnapshotService.ComputeSha256Hex(check.AsSpan(0, read));
                    if (!string.Equals(checkSha, patch.ReplacementSha256, StringComparison.OrdinalIgnoreCase))
                    {
                        allVerified = false;
                        audit.Add($"[VERIFY FAIL] Post-write verification failed for '{patch.RegionName}' at 0x{patch.TargetByteOffset:X}.");
                    }
                    else
                    {
                        audit.Add($"[VERIFY PASS] Re-read '{patch.RegionName}' at 0x{patch.TargetByteOffset:X}: SHA256 matches {checkSha}.");
                    }
                }
            }

            return new RepairResult
            {
                Succeeded = allVerified,
                PlanId = plan.PlanId,
                TargetDescription = fullImagePath,
                WasPhysicalDiskInPlace = false,
                PreRepairSnapshotManifestPath = manifestPath,
                PostWriteVerificationPassed = allVerified,
                SummaryMessage = allVerified
                    ? $"Successfully applied '{plan.Title}' to image and verified {plan.Patches.Count} region(s)."
                    : "Write completed but post-write hash verification failed on one or more regions.",
                AuditLogEntries = audit
            };
        }

        public async Task<RepairResult> ApplyToPhysicalDiskInPlaceAsync(
            VerifiedRepairPlan plan,
            PhysicalDiskRepairAuthorization authorization,
            CancellationToken cancellationToken = default)
        {
            ArgumentNullException.ThrowIfNull(plan);
            ArgumentNullException.ThrowIfNull(authorization);
            var audit = new List<string>();

            if (!plan.IsExecutable || plan.Patches.Count == 0)
            {
                return new RepairResult
                {
                    Succeeded = false,
                    PlanId = plan.PlanId,
                    TargetDescription = plan.SourceIdentity.DevicePath,
                    WasPhysicalDiskInPlace = true,
                    SummaryMessage = "Repair plan is not executable.",
                    AuditLogEntries = audit
                };
            }

            if (plan.SourceIdentity.IsDiskImage || plan.SourceIdentity.DiskNumber < 0)
            {
                return new RepairResult
                {
                    Succeeded = false,
                    PlanId = plan.PlanId,
                    TargetDescription = plan.SourceIdentity.DevicePath,
                    WasPhysicalDiskInPlace = true,
                    SummaryMessage = "Plan source is not a physical disk.",
                    AuditLogEntries = audit
                };
            }

            if (plan.SourceIdentity.IsSystemDisk || plan.SourceIdentity.IsBootDisk)
            {
                return new RepairResult
                {
                    Succeeded = false,
                    PlanId = plan.PlanId,
                    TargetDescription = plan.SourceIdentity.DevicePath,
                    WasPhysicalDiskInPlace = true,
                    SummaryMessage = "Safety Block: Automatic in-place partition/metadata repair is forbidden on the running System/Boot disk.",
                    AuditLogEntries = audit
                };
            }

            string expectedPhrase = $"REPAIR DISK {plan.SourceIdentity.DiskNumber}";
            if (!authorization.OperatorConfirmedInPlaceWrite
                || !string.Equals(authorization.OperatorConfirmationPhrase?.Trim(), expectedPhrase, StringComparison.OrdinalIgnoreCase))
            {
                return new RepairResult
                {
                    Succeeded = false,
                    PlanId = plan.PlanId,
                    TargetDescription = plan.SourceIdentity.DevicePath,
                    WasPhysicalDiskInPlace = true,
                    SummaryMessage = $"Operator authorization failed. Expected confirmation phrase: '{expectedPhrase}'.",
                    AuditLogEntries = audit
                };
            }

            if (string.IsNullOrWhiteSpace(authorization.MandatorySnapshotDirectory))
            {
                return new RepairResult
                {
                    Succeeded = false,
                    PlanId = plan.PlanId,
                    TargetDescription = plan.SourceIdentity.DevicePath,
                    WasPhysicalDiskInPlace = true,
                    SummaryMessage = "A separate snapshot directory is required before in-place physical disk repair.",
                    AuditLogEntries = audit
                };
            }

            MetadataSnapshotService.ValidateDestinationNotOnSource(plan.SourceIdentity, authorization.MandatorySnapshotDirectory);

            // 1. Re-enumerate live physical disks to verify DiskNumber has not shifted after USB reconnect!
            var liveDisks = PhysicalDiskReader.EnumeratePhysicalDisks();
            var liveMatch = liveDisks.FirstOrDefault(d => d.DiskNumber == plan.SourceIdentity.DiskNumber);
            if (liveMatch == null || !liveMatch.MatchesIdentity(plan.SourceIdentity))
            {
                return new RepairResult
                {
                    Succeeded = false,
                    PlanId = plan.PlanId,
                    TargetDescription = plan.SourceIdentity.DevicePath,
                    WasPhysicalDiskInPlace = true,
                    SummaryMessage = $"Safety Block: PhysicalDrive{plan.SourceIdentity.DiskNumber} device identity (Serial/Model/Capacity) no longer matches the scanned drive. Re-run Diagnostics before repairing.",
                    AuditLogEntries = audit
                };
            }

            // 2. Verify original bytes via read-only PhysicalDiskReader and capture mandatory pre-repair snapshot
            string manifestPath;
            using (var reader = new PhysicalDiskReader(liveMatch))
            {
                if (!reader.Identity.MatchesIdentity(plan.SourceIdentity))
                {
                    return new RepairResult
                    {
                        Succeeded = false,
                        PlanId = plan.PlanId,
                        TargetDescription = plan.SourceIdentity.DevicePath,
                        WasPhysicalDiskInPlace = true,
                        SummaryMessage = "Safety Block: Raw geometry does not match the scanned source identity.",
                        AuditLogEntries = audit
                    };
                }

                foreach (var patch in plan.Patches)
                {
                    if (patch.TargetByteOffset % reader.LogicalSectorSize != 0 || patch.ByteLength % reader.LogicalSectorSize != 0)
                    {
                        return new RepairResult
                        {
                            Succeeded = false,
                            PlanId = plan.PlanId,
                            TargetDescription = plan.SourceIdentity.DevicePath,
                            WasPhysicalDiskInPlace = true,
                            SummaryMessage = $"Patch '{patch.RegionName}' is not aligned to {reader.LogicalSectorSize}-byte logical sector boundary.",
                            AuditLogEntries = audit
                        };
                    }

                    byte[] current = new byte[patch.ByteLength];
                    int read = await reader.ReadAtAsync(patch.TargetByteOffset, current, cancellationToken).ConfigureAwait(false);
                    string actualSha = MetadataSnapshotService.ComputeSha256Hex(current.AsSpan(0, read));
                    if (!string.Equals(actualSha, patch.ExpectedOriginalSha256, StringComparison.OrdinalIgnoreCase))
                    {
                        audit.Add($"[REJECTED] Stale plan: region '{patch.RegionName}' on PhysicalDrive{plan.SourceIdentity.DiskNumber} changed since scan.");
                        return new RepairResult
                        {
                            Succeeded = false,
                            PlanId = plan.PlanId,
                            TargetDescription = plan.SourceIdentity.DevicePath,
                            WasPhysicalDiskInPlace = true,
                            SummaryMessage = $"Stale repair plan rejected: bytes in '{patch.RegionName}' changed since diagnostic scan.",
                            AuditLogEntries = audit
                        };
                    }
                }

                var snap = await MetadataSnapshotService.CaptureSnapshotAsync(reader, null, authorization.MandatorySnapshotDirectory, cancellationToken, plan.Patches).ConfigureAwait(false);
                manifestPath = Path.Combine(snap.SnapshotDirectory, "manifest.json");
                var (snapValid, _, snapMsg) = await MetadataSnapshotService.VerifySnapshotAsync(manifestPath, cancellationToken).ConfigureAwait(false);
                if (!snapValid)
                {
                    return new RepairResult
                    {
                        Succeeded = false,
                        PlanId = plan.PlanId,
                        TargetDescription = plan.SourceIdentity.DevicePath,
                        WasPhysicalDiskInPlace = true,
                        SummaryMessage = $"Pre-repair metadata snapshot verification failed: {snapMsg}. Aborting write.",
                        AuditLogEntries = audit
                    };
                }
                audit.Add($"[SNAPSHOT VERIFIED] Saved mandatory rollback snapshot: {manifestPath}");
            }

            // 3. Lock/dismount any mounted volumes on this disk so Windows permits raw sector writes, then open PhysicalDriveN.
            var lockedVolumeHandles = LockAndDismountVolumes(liveMatch.MountedDriveLetters, audit);
            try
            {
                using (var writeHandle = CreateFileW(
                    plan.SourceIdentity.DevicePath,
                    GENERIC_READ | GENERIC_WRITE,
                    FILE_SHARE_READ | FILE_SHARE_WRITE,
                    IntPtr.Zero,
                    OPEN_EXISTING,
                    FILE_FLAG_WRITE_THROUGH,
                    IntPtr.Zero))
                {
                    if (writeHandle.IsInvalid)
                    {
                        int err = Marshal.GetLastWin32Error();
                        throw new Win32Exception(err, $"Failed to open {plan.SourceIdentity.DevicePath} for authorized metadata write (Win32 error {err}). Ensure CDE is running as Administrator and no volume locks are held.");
                    }

                    foreach (var patch in plan.Patches)
                    {
                        if (!SetFilePointerEx(writeHandle, patch.TargetByteOffset, out _, 0 /* FILE_BEGIN */))
                        {
                            int err = Marshal.GetLastWin32Error();
                            throw new Win32Exception(err, $"SetFilePointerEx failed at 0x{patch.TargetByteOffset:X} (Win32 error {err}).");
                        }

                        if (!WriteFile(writeHandle, patch.ReplacementBytes, (uint)patch.ReplacementBytes.Length, out uint written, IntPtr.Zero)
                            || written != (uint)patch.ReplacementBytes.Length)
                        {
                            int err = Marshal.GetLastWin32Error();
                            throw new Win32Exception(err, $"WriteFile failed at 0x{patch.TargetByteOffset:X} (Win32 error {err}).");
                        }

                        audit.Add($"[PHYSICAL WRITE] Wrote {patch.ByteLength} bytes to {plan.SourceIdentity.DevicePath} '{patch.RegionName}' at 0x{patch.TargetByteOffset:X} (LBA {patch.StartLba}).");
                    }
                    FlushFileBuffers(writeHandle);

                    // Notify Windows kernel to re-read partition table
                    DeviceIoControl(writeHandle, IOCTL_DISK_UPDATE_PROPERTIES, IntPtr.Zero, 0, IntPtr.Zero, 0, out _, IntPtr.Zero);
                    audit.Add("[IOCTL] Sent IOCTL_DISK_UPDATE_PROPERTIES to refresh Windows partition table cache.");
                }
            }
            finally
            {
                foreach (var volHandle in lockedVolumeHandles)
                {
                    volHandle.Dispose();
                }
            }

            // 4. Post-write verification
            bool verified = true;
            using (var postReader = new PhysicalDiskReader(liveMatch))
            {
                foreach (var patch in plan.Patches)
                {
                    byte[] check = new byte[patch.ByteLength];
                    int read = await postReader.ReadAtAsync(patch.TargetByteOffset, check, cancellationToken).ConfigureAwait(false);
                    string checkSha = MetadataSnapshotService.ComputeSha256Hex(check.AsSpan(0, read));
                    if (!string.Equals(checkSha, patch.ReplacementSha256, StringComparison.OrdinalIgnoreCase))
                    {
                        verified = false;
                        audit.Add($"[VERIFY FAIL] Physical sector re-read mismatch on '{patch.RegionName}' at 0x{patch.TargetByteOffset:X}.");
                    }
                    else
                    {
                        audit.Add($"[VERIFY PASS] Physical sector re-read verified for '{patch.RegionName}' (SHA256 {checkSha}).");
                    }
                }
            }

            return new RepairResult
            {
                Succeeded = verified,
                PlanId = plan.PlanId,
                TargetDescription = plan.SourceIdentity.DevicePath,
                WasPhysicalDiskInPlace = true,
                PreRepairSnapshotManifestPath = manifestPath,
                PostWriteVerificationPassed = verified,
                SummaryMessage = verified
                    ? $"In-place repair '{plan.Title}' succeeded on {plan.SourceIdentity.DevicePath} and passed post-write sector verification."
                    : "In-place write completed, but post-write sector verification reported a mismatch.",
                AuditLogEntries = audit
            };
        }

        private static List<SafeFileHandle> LockAndDismountVolumes(IEnumerable<string>? mountedDriveLetters, List<string> audit)
        {
            var handles = new List<SafeFileHandle>();
            if (mountedDriveLetters == null)
                return handles;

            foreach (var rawLetter in mountedDriveLetters)
            {
                string trimmed = (rawLetter ?? string.Empty).Trim().TrimEnd('\\');
                if (string.IsNullOrEmpty(trimmed))
                    continue;
                if (!trimmed.EndsWith(":", StringComparison.Ordinal))
                    trimmed += ":";

                string volPath = $@"\\.\{trimmed}";
                var volHandle = CreateFileW(
                    volPath,
                    GENERIC_READ | GENERIC_WRITE,
                    FILE_SHARE_READ | FILE_SHARE_WRITE,
                    IntPtr.Zero,
                    OPEN_EXISTING,
                    0,
                    IntPtr.Zero);

                if (volHandle.IsInvalid)
                {
                    volHandle.Dispose();
                    audit.Add($"[VOLUME] Could not open {volPath} for lock/dismount (Win32 {Marshal.GetLastWin32Error()}); proceeding with raw disk write.");
                    continue;
                }

                bool locked = DeviceIoControl(volHandle, FSCTL_LOCK_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out _, IntPtr.Zero);
                bool dismounted = DeviceIoControl(volHandle, FSCTL_DISMOUNT_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out _, IntPtr.Zero);
                audit.Add($"[VOLUME] {volPath}: lock={locked}, dismount={dismounted}");
                handles.Add(volHandle);
            }

            return handles;
        }
    }
}
