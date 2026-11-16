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

                return await NtfsFileRecoveryEngine.ScanRecoverableFilesAsync(
                    source,
                    partition,
                    includeDeleted,
                    maxRecords,
                    progress,
                    cancellationToken).ConfigureAwait(false);
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

            return (jsonPath, File.Exists(pdfPath) ? pdfPath : string.Empty);
        }
    }
}
