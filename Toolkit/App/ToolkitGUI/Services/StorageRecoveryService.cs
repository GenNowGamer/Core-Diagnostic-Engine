using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using CdeRecovery.Core.Devices;
using CdeRecovery.Core.Evidence;
using CdeRecovery.Core.Imaging;
using CdeRecovery.Core.Models;
using CdeRecovery.Core.Recovery;
using ToolkitGUI.Models;
using ToolkitGUI.ViewModels;

namespace ToolkitGUI.Services
{
    public static class StorageRecoveryService
    {
        public static string GetDefaultSnapshotRoot()
        {
            string dataRoot = ReportPathHelper.GetWorkflowDataRoot();
            string parent = Path.GetDirectoryName(dataRoot) ?? dataRoot;
            string snapRoot = Path.Combine(parent, "StorageSnapshots");
            Directory.CreateDirectory(snapRoot);
            return snapRoot;
        }

        public static string GetDefaultFixturesRoot()
        {
            string dataRoot = ReportPathHelper.GetWorkflowDataRoot();
            string parent = Path.GetDirectoryName(dataRoot) ?? dataRoot;
            string fixRoot = Path.Combine(parent, "StorageFixtures");
            Directory.CreateDirectory(fixRoot);
            return fixRoot;
        }

        public static List<StorageTargetChoice> DiscoverPhysicalDiskTargets()
        {
            var list = new List<StorageTargetChoice>();
            var disks = PhysicalDiskReader.EnumeratePhysicalDisks();
            foreach (var d in disks)
            {
                string sysTag = (d.IsSystemDisk || d.IsBootDisk) ? " [SYSTEM DISK - Read-Only]" : string.Empty;
                string letters = d.MountedDriveLetters.Count > 0 ? $" ({string.Join(", ", d.MountedDriveLetters)})" : string.Empty;
                list.Add(new StorageTargetChoice
                {
                    DisplayTitle = $"Disk {d.DiskNumber} · {d.FriendlyName} · {d.DisplayCapacity}{letters}{sysTag}",
                    Subtitle = $"{d.BusType} · {d.WindowsReportedPartitionStyle} · {d.LogicalSectorSize}B logical / {d.PhysicalSectorSize}B physical · S.M.A.R.T.: {d.SmartHealthStatus}",
                    IsDiskImage = false,
                    Device = d
                });
            }
            return list;
        }

        public static StorageTargetChoice CreateImageTargetChoice(string imagePath, int logicalSectorSize = 512)
        {
            using var reader = new DiskImageReader(imagePath, logicalSectorSize, logicalSectorSize);
            return new StorageTargetChoice
            {
                DisplayTitle = $"[Image] {Path.GetFileName(imagePath)} · {reader.Identity.DisplayCapacity}",
                Subtitle = $"Disk Image · {reader.LogicalSectorSize}B sectors · {imagePath}",
                IsDiskImage = true,
                ImagePath = Path.GetFullPath(imagePath),
                Device = reader.Identity
            };
        }

        public static async Task<StorageRecoveryAssessment> InspectTargetAsync(
            StorageTargetChoice target,
            CancellationToken cancellationToken = default)
        {
            ArgumentNullException.ThrowIfNull(target);
            return await Task.Run(async () =>
            {
                using IReadOnlyBlockSource source = target.IsDiskImage
                    ? new DiskImageReader(target.ImagePath, target.Device.LogicalSectorSize > 0 ? target.Device.LogicalSectorSize : 512)
                    : new PhysicalDiskReader(target.Device);

                return await StorageRecoveryEngine.InspectAsync(source, cancellationToken).ConfigureAwait(false);
            }, cancellationToken).ConfigureAwait(false);
        }

        public static async Task<MetadataSnapshotManifest> CaptureSnapshotAsync(
            StorageTargetChoice target,
            StorageRecoveryAssessment? assessment,
            string? outputDirectory = null,
            CancellationToken cancellationToken = default)
        {
            string outDir = string.IsNullOrWhiteSpace(outputDirectory) ? GetDefaultSnapshotRoot() : outputDirectory;
            return await Task.Run(async () =>
            {
                using IReadOnlyBlockSource source = target.IsDiskImage
                    ? new DiskImageReader(target.ImagePath, target.Device.LogicalSectorSize > 0 ? target.Device.LogicalSectorSize : 512)
                    : new PhysicalDiskReader(target.Device);

                return await MetadataSnapshotService.CaptureSnapshotAsync(source, assessment, outDir, cancellationToken).ConfigureAwait(false);
            }, cancellationToken).ConfigureAwait(false);
        }

        public static async Task<RepairResult> ExecuteRepairOnImageAsync(
            VerifiedRepairPlan plan,
            string imagePath,
            string? snapshotDirectory = null,
            CancellationToken cancellationToken = default)
        {
            string snapDir = string.IsNullOrWhiteSpace(snapshotDirectory) ? GetDefaultSnapshotRoot() : snapshotDirectory;
            var executor = new RepairExecutor();
            return await Task.Run(
                () => executor.ApplyToImageAsync(plan, imagePath, snapDir, cancellationToken),
                cancellationToken).ConfigureAwait(false);
        }

        public static async Task<RepairResult> ExecuteRepairOnPhysicalDiskInPlaceAsync(
            VerifiedRepairPlan plan,
            PhysicalDiskRepairAuthorization authorization,
            CancellationToken cancellationToken = default)
        {
            var executor = new RepairExecutor();
            return await Task.Run(
                () => executor.ApplyToPhysicalDiskInPlaceAsync(plan, authorization, cancellationToken),
                cancellationToken).ConfigureAwait(false);
        }

        public static async Task<List<RecoverableFileItem>> ScanRecoverableFilesAsync(
            StorageTargetChoice target,
            FileSystemAnalysisResult partition,
            bool includeDeleted = false,
            int maxRecords = 8192,
            IProgress<string>? progress = null,
            CancellationToken cancellationToken = default)
        {
            ArgumentNullException.ThrowIfNull(target);
            ArgumentNullException.ThrowIfNull(partition);

            return await Task.Run(async () =>
            {
                using IReadOnlyBlockSource source = target.IsDiskImage
                    ? new DiskImageReader(target.ImagePath, target.Device.LogicalSectorSize > 0 ? target.Device.LogicalSectorSize : 512)
                    : new PhysicalDiskReader(target.Device);

                if (string.Equals(partition.DetectedFileSystem, "FAT32", StringComparison.OrdinalIgnoreCase))
                {
                    return await Fat32FileRecoveryEngine.ScanRecoverableFilesAsync(
                        source,
                        partition,
                        includeDeleted,
                        maxRecords,
                        progress,
                        cancellationToken).ConfigureAwait(false);
                }

                if (string.Equals(partition.DetectedFileSystem, "exFAT", StringComparison.OrdinalIgnoreCase))
                {
                    return await ExFatFileRecoveryEngine.ScanRecoverableFilesAsync(
                        source,
                        partition,
                        includeDeleted,
                        maxRecords,
                        progress,
                        cancellationToken).ConfigureAwait(false);
                }

                if (string.Equals(partition.DetectedFileSystem, "NTFS", StringComparison.OrdinalIgnoreCase))
                {
                    return await NtfsFileRecoveryEngine.ScanRecoverableFilesAsync(
                        source,
                        partition,
                        includeDeleted,
                        maxRecords,
                        progress,
                        cancellationToken).ConfigureAwait(false);
                }

                if (partition.DetectedFileSystem?.Contains("BitLocker", StringComparison.OrdinalIgnoreCase) == true)
                    throw new InvalidOperationException("Partition is BitLocker-encrypted. Unlock the BitLocker volume before scanning for recoverable files.");

                throw new NotSupportedException($"File recovery scan is not supported for filesystem '{partition.DetectedFileSystem ?? "Unknown"}'. Supported filesystems: NTFS, FAT32, exFAT.");
            }, cancellationToken).ConfigureAwait(false);
        }

        public static async Task<FileExportManifest> ExportRecoverableFilesAsync(
            StorageTargetChoice target,
            IReadOnlyList<RecoverableFileItem> files,
            string destinationFolder,
            IProgress<string>? progress = null,
            CancellationToken cancellationToken = default)
        {
            ArgumentNullException.ThrowIfNull(target);
            ArgumentNullException.ThrowIfNull(files);

            return await Task.Run(async () =>
            {
                using IReadOnlyBlockSource source = target.IsDiskImage
                    ? new DiskImageReader(target.ImagePath, target.Device.LogicalSectorSize > 0 ? target.Device.LogicalSectorSize : 512)
                    : new PhysicalDiskReader(target.Device);

                return await FileExportEngine.ExportFilesAsync(
                    source,
                    files,
                    destinationFolder,
                    progress,
                    cancellationToken).ConfigureAwait(false);
            }, cancellationToken).ConfigureAwait(false);
        }

        public static async Task<ImagingJobManifest> RunOrResumeImagingJobAsync(
            StorageTargetChoice target,
            string outputImagePath,
            long sourceStartOffset = 0,
            long lengthBytes = 0,
            bool scrapeFailedBlocks = true,
            string targetScopeLabel = "Whole Disk",
            IProgress<ImagingProgressReport>? progress = null,
            CancellationToken cancellationToken = default)
        {
            ArgumentNullException.ThrowIfNull(target);

            return await Task.Run(async () =>
            {
                using IReadOnlyBlockSource source = target.IsDiskImage
                    ? new DiskImageReader(target.ImagePath, target.Device.LogicalSectorSize > 0 ? target.Device.LogicalSectorSize : 512)
                    : new PhysicalDiskReader(target.Device);

                return await ImagingJobEngine.RunOrResumeImagingJobAsync(
                    source,
                    outputImagePath,
                    sourceStartOffset,
                    lengthBytes,
                    scrapeFailedBlocks,
                    useSparseOutput: true,
                    copyBlockSizeBytes: 256 * 1024,
                    targetScopeLabel: targetScopeLabel,
                    progress: progress,
                    cancellationToken: cancellationToken).ConfigureAwait(false);
            }, cancellationToken).ConfigureAwait(false);
        }

        public static async Task<(string JsonPath, string PdfPath)> ExportAssessmentReportAsync(
            StorageRecoveryAssessment assessment,
            IReadOnlyList<string> sessionAuditLog)
        {
            var now = DateTime.Now;
            var steps = new List<WorkflowExecutionStep>();

            foreach (var f in assessment.Findings)
            {
                string detail = $"[{f.Category} | {f.Classification} | {f.Confidence}%] {f.EvidenceSummary}";
                if (!string.IsNullOrWhiteSpace(f.Recommendation))
                    detail += $" Recommendation: {f.Recommendation}";

                steps.Add(new WorkflowExecutionStep
                {
                    Name = f.Title,
                    Status = f.Status,
                    Detail = detail,
                    Output = detail
                });
            }

            if (sessionAuditLog.Count > 0)
            {
                steps.Add(new WorkflowExecutionStep
                {
                    Name = "Recovery Session Audit Trail",
                    Status = "Pass",
                    Detail = string.Join("\n", sessionAuditLog),
                    Output = string.Join("\n", sessionAuditLog)
                });
            }

            string overallHealth = assessment.OverallVerdict.Contains("Healthy", StringComparison.OrdinalIgnoreCase)
                ? "Healthy"
                : assessment.OverallVerdict.Contains("Warning", StringComparison.OrdinalIgnoreCase)
                    ? "Warning"
                    : "Critical";

            var wfReport = new WorkflowExecutionReport
            {
                WorkflowName = "StorageRecovery",
                StartTime = assessment.AssessedAtUtc.ToLocalTime(),
                EndTime = now,
                Status = "Completed",
                EnvironmentMode = Environment.GetEnvironmentVariable("SystemDrive")?.Equals("X:", StringComparison.OrdinalIgnoreCase) == true
                    ? "WinPE"
                    : "Windows",
                OverallHealth = overallHealth,
                Steps = steps
            };

            string baseName = WorkflowReportExportHelper.BuildReportBaseName(wfReport);
            string jsonPath = Path.Combine(ReportPathHelper.GetWorkflowDataRoot(), $"{baseName}.json");
            var json = JsonSerializer.Serialize(assessment, new JsonSerializerOptions { WriteIndented = true });
            await File.WriteAllTextAsync(jsonPath, json).ConfigureAwait(false);

            string pdfPath = ReportPathHelper.GetOperatorPdfPathForInternalJson(jsonPath);
            if (!string.IsNullOrWhiteSpace(pdfPath))
            {
                await Task.Run(() => WorkflowReportPdfService.TryGeneratePdf(wfReport, pdfPath, out _)).ConfigureAwait(false);
            }

            string resolvedPdf = File.Exists(pdfPath) ? pdfPath : string.Empty;
            WorkOrderService.TryRecordWorkflowReport(wfReport, jsonPath, string.IsNullOrWhiteSpace(resolvedPdf) ? null : resolvedPdf);

            return (jsonPath, resolvedPdf);
        }

        public static async Task RecordActivityWorkOrderReportAsync(
            string actionTitle,
            string stepStatus,
            string detail,
            IReadOnlyList<string> sessionAuditLog)
        {
            var now = DateTime.Now;
            var steps = new List<WorkflowExecutionStep>
            {
                new WorkflowExecutionStep
                {
                    Name = actionTitle,
                    Status = stepStatus,
                    Detail = detail,
                    Output = sessionAuditLog.Count > 0 ? $"{detail}\n\n{string.Join("\n", sessionAuditLog)}" : detail
                }
            };

            string overallHealth = string.Equals(stepStatus, "Fail", StringComparison.OrdinalIgnoreCase)
                ? "Critical"
                : string.Equals(stepStatus, "Warn", StringComparison.OrdinalIgnoreCase)
                    ? "Warning"
                    : "Healthy";

            var wfReport = new WorkflowExecutionReport
            {
                WorkflowName = "StorageRecovery",
                StartTime = now,
                EndTime = now,
                Status = string.Equals(stepStatus, "Fail", StringComparison.OrdinalIgnoreCase) ? "Failed" : "Completed",
                EnvironmentMode = Environment.GetEnvironmentVariable("SystemDrive")?.Equals("X:", StringComparison.OrdinalIgnoreCase) == true
                    ? "WinPE"
                    : "Windows",
                OverallHealth = overallHealth,
                Steps = steps
            };

            string baseName = WorkflowReportExportHelper.BuildReportBaseName(wfReport);
            string jsonPath = Path.Combine(ReportPathHelper.GetWorkflowDataRoot(), $"{baseName}.json");
            var json = JsonSerializer.Serialize(wfReport, new JsonSerializerOptions { WriteIndented = true });
            await File.WriteAllTextAsync(jsonPath, json).ConfigureAwait(false);

            string pdfPath = ReportPathHelper.GetOperatorPdfPathForInternalJson(jsonPath);
            if (!string.IsNullOrWhiteSpace(pdfPath))
            {
                await Task.Run(() => WorkflowReportPdfService.TryGeneratePdf(wfReport, pdfPath, out _)).ConfigureAwait(false);
            }

            WorkOrderService.TryRecordWorkflowReport(wfReport, jsonPath, File.Exists(pdfPath) ? pdfPath : null);
        }

        public sealed class BitLockerStatusInfo
        {
            public bool ToolAvailable { get; init; }
            public string DriveLetter { get; init; } = string.Empty;
            public string KeyProtectorId { get; init; } = string.Empty;
            public bool IsUnlocked { get; init; }
            public string StatusMessage { get; init; } = string.Empty;
        }

        public sealed class BitLockerUnlockResult
        {
            public bool Succeeded { get; init; }
            public string DriveLetter { get; init; } = string.Empty;
            public string Message { get; init; } = string.Empty;
        }

        public static string? NormalizeBitLockerRecoveryKey(string? rawInput)
        {
            if (string.IsNullOrWhiteSpace(rawInput)) return null;
            var digits = new string(rawInput.Where(char.IsDigit).ToArray());
            if (digits.Length != 48) return null;

            var groups = new string[8];
            for (int i = 0; i < 8; i++)
                groups[i] = digits.Substring(i * 6, 6);
            return string.Join("-", groups);
        }

        public static async Task<BitLockerStatusInfo> QueryBitLockerStatusAsync(int diskNumber, int partitionNumber)
        {
            string manageBde = Path.Combine(Environment.SystemDirectory, "manage-bde.exe");
            if (!File.Exists(manageBde))
            {
                return new BitLockerStatusInfo
                {
                    ToolAvailable = false,
                    StatusMessage = "BitLocker unlock tool (manage-bde.exe) is not present in this WinPE image."
                };
            }

            string letter = await GetPartitionDriveLetterAsync(diskNumber, partitionNumber).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(letter))
            {
                return new BitLockerStatusInfo
                {
                    ToolAvailable = true,
                    StatusMessage = "No drive letter assigned yet. Enter your 48-digit recovery key and click Unlock Drive — CDE will assign a drive letter automatically."
                };
            }

            string keyId = await GetBitLockerRecoveryKeyIdAsync(manageBde, letter).ConfigureAwait(false);
            var (_, statusOut, _) = await RunProcessCaptureAsync(manageBde, $"-status {letter}:").ConfigureAwait(false);
            bool unlocked = statusOut.Contains("Lock Status:", StringComparison.OrdinalIgnoreCase)
                && statusOut.Contains("Unlocked", StringComparison.OrdinalIgnoreCase);

            string msg = unlocked
                ? $"Drive {letter}: is already unlocked and accessible."
                : $"Drive {letter}: is locked. Enter the 48-digit recovery key to unlock it.";

            return new BitLockerStatusInfo
            {
                ToolAvailable = true,
                DriveLetter = letter,
                KeyProtectorId = keyId,
                IsUnlocked = unlocked,
                StatusMessage = msg
            };
        }

        public static async Task<BitLockerUnlockResult> UnlockBitLockerPartitionAsync(
            int diskNumber,
            int partitionNumber,
            string rawRecoveryKey)
        {
            string manageBde = Path.Combine(Environment.SystemDirectory, "manage-bde.exe");
            if (!File.Exists(manageBde))
            {
                return new BitLockerUnlockResult
                {
                    Succeeded = false,
                    Message = "BitLocker unlock tool (manage-bde.exe) is not available in this WinPE environment."
                };
            }

            string? formattedKey = NormalizeBitLockerRecoveryKey(rawRecoveryKey);
            if (formattedKey == null)
            {
                return new BitLockerUnlockResult
                {
                    Succeeded = false,
                    Message = "Please enter a valid 48-digit BitLocker recovery key (with or without dashes)."
                };
            }

            string letter = await GetPartitionDriveLetterAsync(diskNumber, partitionNumber).ConfigureAwait(false);
            if (string.IsNullOrWhiteSpace(letter))
            {
                letter = await AssignDriveLetterToPartitionAsync(diskNumber, partitionNumber).ConfigureAwait(false);
                if (string.IsNullOrWhiteSpace(letter))
                {
                    return new BitLockerUnlockResult
                    {
                        Succeeded = false,
                        Message = $"Could not assign a drive letter to Disk {diskNumber}, Partition {partitionNumber}."
                    };
                }
            }

            var (exitCode, stdout, stderr) = await RunProcessCaptureAsync(
                manageBde,
                $"-unlock {letter}: -RecoveryPassword {formattedKey}").ConfigureAwait(false);

            string combined = string.Join(Environment.NewLine, new[] { stdout, stderr }.Where(s => !string.IsNullOrWhiteSpace(s))).Trim();
            if (exitCode == 0)
            {
                return new BitLockerUnlockResult
                {
                    Succeeded = true,
                    DriveLetter = letter,
                    Message = $"Drive {letter}: unlocked successfully! You can now browse or copy files from {letter}:\\."
                };
            }

            return new BitLockerUnlockResult
            {
                Succeeded = false,
                DriveLetter = letter,
                Message = string.IsNullOrWhiteSpace(combined)
                    ? $"manage-bde exited with code {exitCode} while unlocking {letter}:."
                    : combined
            };
        }

        private static async Task<string> GetPartitionDriveLetterAsync(int diskNumber, int partitionNumber)
        {
            string script = $"$p = Get-Partition -DiskNumber {diskNumber} -PartitionNumber {partitionNumber} -ErrorAction SilentlyContinue; if ($p -and $p.DriveLetter) {{ $p.DriveLetter }}";
            var (_, stdout, _) = await RunProcessCaptureAsync("powershell.exe", $"-NoProfile -ExecutionPolicy Bypass -Command \"{script}\"").ConfigureAwait(false);
            string trimmed = stdout.Trim();
            return trimmed.Length == 1 && char.IsLetter(trimmed[0]) ? trimmed.ToUpperInvariant() : string.Empty;
        }

        private static async Task<string> AssignDriveLetterToPartitionAsync(int diskNumber, int partitionNumber)
        {
            string script = $"$p = Get-Partition -DiskNumber {diskNumber} -PartitionNumber {partitionNumber} -ErrorAction Stop; $p | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop; $p2 = Get-Partition -DiskNumber {diskNumber} -PartitionNumber {partitionNumber}; if ($p2.DriveLetter) {{ $p2.DriveLetter }}";
            var (code, stdout, _) = await RunProcessCaptureAsync("powershell.exe", $"-NoProfile -ExecutionPolicy Bypass -Command \"{script}\"").ConfigureAwait(false);
            if (code != 0) return string.Empty;
            string trimmed = stdout.Trim();
            return trimmed.Length == 1 && char.IsLetter(trimmed[0]) ? trimmed.ToUpperInvariant() : string.Empty;
        }

        private static async Task<string> GetBitLockerRecoveryKeyIdAsync(string manageBdePath, string driveLetter)
        {
            var (_, stdout, _) = await RunProcessCaptureAsync(manageBdePath, $"-protectors -get {driveLetter}: -Type RecoveryPassword").ConfigureAwait(false);
            var match = System.Text.RegularExpressions.Regex.Match(stdout, @"\{[0-9A-Fa-f\-]{36}\}");
            return match.Success ? match.Value : string.Empty;
        }

        private static async Task<(int ExitCode, string Stdout, string Stderr)> RunProcessCaptureAsync(string fileName, string arguments)
        {
            return await Task.Run(() =>
            {
                using var proc = new System.Diagnostics.Process
                {
                    StartInfo = new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = fileName,
                        Arguments = arguments,
                        UseShellExecute = false,
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        CreateNoWindow = true
                    }
                };
                proc.Start();
                string stdout = proc.StandardOutput.ReadToEnd();
                string stderr = proc.StandardError.ReadToEnd();
                proc.WaitForExit();
                return (proc.ExitCode, stdout, stderr);
            }).ConfigureAwait(false);
        }
    }
}
