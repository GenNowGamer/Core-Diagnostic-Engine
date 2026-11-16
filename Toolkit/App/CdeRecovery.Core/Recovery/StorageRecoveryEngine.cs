using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using CdeRecovery.Core.Devices;
using CdeRecovery.Core.FileSystems;
using CdeRecovery.Core.Models;
using CdeRecovery.Core.Partitioning;

namespace CdeRecovery.Core.Recovery
{
    public static class StorageRecoveryEngine
    {
        public static async Task<StorageRecoveryAssessment> InspectAsync(
            IReadOnlyBlockSource source,
            CancellationToken cancellationToken = default)
        {
            ArgumentNullException.ThrowIfNull(source);

            var allFindings = new List<StorageDiagnosticFinding>();

            // 1. MBR Analysis (Sector 0)
            var (mbrResult, mbrFindings) = await MbrAnalyzer.AnalyzeAsync(source, cancellationToken).ConfigureAwait(false);
            allFindings.AddRange(mbrFindings);

            GptAnalysisResult gptResult = new() { IsGptCandidate = false, SummaryStatus = "Unreadable (Device I/O Error)" };
            var discovered = new List<DiscoveredPartitionCandidate>();
            var fileSystems = new List<FileSystemAnalysisResult>();

            if (mbrResult.SectorReadSucceeded)
            {
                // 2. GPT Analysis (Primary LBA 1..33 & Backup end-of-disk)
                var (gptRes, gptFindings) = await GptAnalyzer.AnalyzeAsync(source, mbrResult, cancellationToken).ConfigureAwait(false);
                gptResult = gptRes;
                allFindings.AddRange(gptFindings);

                // 3. Partition Discovery (Active + Lost/Unreferenced Partitions)
                var (discRes, discoveryFindings) = await PartitionDiscovery.DiscoverAsync(
                    source, mbrResult, gptResult, cancellationToken).ConfigureAwait(false);
                discovered = discRes;
                allFindings.AddRange(discoveryFindings);

                // 4. File System Integrity Analysis on each Partition
                if (gptResult.IsGptCandidate && gptResult.ActivePartitions.Count > 0)
                {
                    int idx = 1;
                    foreach (var p in gptResult.ActivePartitions)
                    {
                        if (p.PartitionTypeGuid == GptAnalyzer.GuidMsftReserved)
                        {
                            idx++;
                            continue;
                        }

                        var (fsRes, fsFindings) = await Fat32Analyzer.InspectAnyFileSystemAsync(
                            source,
                            idx,
                            string.IsNullOrWhiteSpace(p.Name) ? $"GPT Partition {idx}" : p.Name,
                            p.StartByteOffset,
                            p.SizeBytes,
                            cancellationToken).ConfigureAwait(false);
                        fileSystems.Add(fsRes);
                        allFindings.AddRange(fsFindings);
                        idx++;
                    }
                }
                else
                {
                    int idx = 1;
                    foreach (var m in mbrResult.Entries.Where(e => e.IsAllocated && !e.IsProtectiveGptEntry))
                    {
                        var (fsRes, fsFindings) = await Fat32Analyzer.InspectAnyFileSystemAsync(
                            source,
                            idx,
                            $"MBR Partition {idx} ({m.PartitionTypeName})",
                            m.StartByteOffset,
                            m.SizeBytes,
                            cancellationToken).ConfigureAwait(false);
                        fileSystems.Add(fsRes);
                        allFindings.AddRange(fsFindings);
                        idx++;
                    }
                }

                // Also inspect high-confidence lost partitions if no active partitions exist
                if (fileSystems.Count == 0)
                {
                    int idx = 1;
                    foreach (var lost in discovered.Where(d => !d.InActivePartitionTable))
                    {
                        var (fsRes, fsFindings) = await Fat32Analyzer.InspectAnyFileSystemAsync(
                            source,
                            idx,
                            $"Lost Partition {idx} ({lost.FileSystemType})",
                            lost.StartByteOffset,
                            lost.SizeBytes,
                            cancellationToken).ConfigureAwait(false);
                        fileSystems.Add(fsRes);
                        allFindings.AddRange(fsFindings);
                        idx++;
                    }
                }
            }

            // 5. Guided Repair Planning
            var proposedRepairs = await RecoveryPlanner.GeneratePlansAsync(
                source,
                mbrResult,
                gptResult,
                fileSystems,
                discovered,
                allFindings,
                cancellationToken).ConfigureAwait(false);

            // 6. Compute Badges & Executive Summary
            string hwBadge = source.ReadErrors.Count > 0
                ? $"Read Errors ({source.ReadErrors.Count})"
                : string.IsNullOrWhiteSpace(source.Identity.SmartHealthStatus)
                    ? "Healthy (No Read Errors)"
                    : source.Identity.SmartHealthStatus;

            string ptBadge = !mbrResult.SectorReadSucceeded
                ? "Unreadable (Device I/O Error)"
                : gptResult.IsGptCandidate
                    ? gptResult.SummaryStatus
                    : (mbrResult.HasValidSignature ? "MBR Valid" : "MBR Damaged");

            string fsBadge = !mbrResult.SectorReadSucceeded
                ? "Not Scanned (Device Offline)"
                : fileSystems.Count == 0
                    ? "No Volumes Found"
                    : fileSystems.All(f => f.HealthStatus.StartsWith("Healthy", StringComparison.OrdinalIgnoreCase))
                        ? $"Healthy ({string.Join(", ", fileSystems.Select(f => f.DetectedFileSystem).Distinct())})"
                        : fileSystems.Any(f => f.IsEncryptedBitLocker)
                            ? "BitLocker Encrypted"
                            : fileSystems.FirstOrDefault(f => !f.HealthStatus.StartsWith("Healthy", StringComparison.OrdinalIgnoreCase))?.HealthStatus ?? "Degraded";

            int failCount = allFindings.Count(f => string.Equals(f.Status, "Fail", StringComparison.OrdinalIgnoreCase));
            int warnCount = allFindings.Count(f => string.Equals(f.Status, "Warn", StringComparison.OrdinalIgnoreCase));
            int execRepairs = proposedRepairs.Count(p => p.IsExecutable);

            string overallVerdict = !mbrResult.SectorReadSucceeded
                ? "Device I/O Error — Reconnect Drive"
                : failCount > 0
                    ? (execRepairs > 0 ? "Repairable Corruption Detected" : "Critical Damage — Extract Files")
                    : warnCount > 0
                        ? "Degraded / Warning"
                        : "Healthy";

            string execSummary = !mbrResult.SectorReadSucceeded
                ? $"Could not read Sector 0 (LBA 0) on {source.Identity.FriendlyName} ({source.ReadErrors.FirstOrDefault()?.ErrorMessage ?? "I/O Device Error"}). " +
                  "If this is an external USB drive, its USB bridge may have reset or gone offline. Unplug the USB cable (and power cord if externally powered) for 10 seconds, plug it back in, click 'Refresh Drives', and click 'Inspect Disk' again."
                : BuildExecutiveSummary(source.Identity, ptBadge, fsBadge, proposedRepairs, allFindings);

            return new StorageRecoveryAssessment
            {
                SchemaVersion = 1,
                AssessedAtUtc = DateTime.UtcNow,
                Device = source.Identity,
                ScanMode = "ReadOnlyMetadataScan",
                HardwareHealthBadge = hwBadge,
                PartitionTableBadge = ptBadge,
                FileSystemBadge = fsBadge,
                OverallVerdict = overallVerdict,
                ExecutiveSummary = execSummary,
                Mbr = mbrResult,
                Gpt = gptResult,
                FileSystems = fileSystems,
                DiscoveredPartitions = discovered,
                ReadErrors = source.ReadErrors.ToList(),
                Findings = allFindings,
                ProposedRepairs = proposedRepairs
            };
        }

        private static string BuildExecutiveSummary(
            StorageDeviceIdentity dev,
            string ptBadge,
            string fsBadge,
            List<VerifiedRepairPlan> plans,
            List<StorageDiagnosticFinding> findings)
        {
            var execPlans = plans.Where(p => p.IsExecutable).ToList();
            if (execPlans.Count > 0)
            {
                return $"Inspected {dev.FriendlyName} ({dev.DisplayCapacity}, {dev.LogicalSectorSize}B sectors). " +
                       $"Partition Table: {ptBadge}. File System: {fsBadge}. " +
                       $"Generated {execPlans.Count} verified repair plan(s): {string.Join("; ", execPlans.Select(p => p.Title))}.";
            }

            if (plans.Any(p => p.ActionType == "SafetyStop"))
            {
                return $"STOP: Hardware or read errors detected on {dev.FriendlyName}. In-place metadata writes are blocked for safety.";
            }

            if (plans.Any(p => p.ActionType == "GuidanceFileExtraction"))
            {
                return $"Partition table is readable on {dev.FriendlyName}, but file system metadata ($MFT) is severely damaged. " +
                       "In-place partition table repair will not fix this volume — extract files to a separate drive before reformatting.";
            }

            return $"Inspected {dev.FriendlyName} ({dev.DisplayCapacity}, {dev.LogicalSectorSize}B sectors). " +
                   $"Partition Table: {ptBadge}. File System: {fsBadge}. " +
                   $"{findings.Count(f => f.Status == "Pass")} check(s) passed.";
        }
    }
}
