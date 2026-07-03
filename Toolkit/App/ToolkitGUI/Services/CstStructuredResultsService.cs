using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ToolkitGUI.Services
{
    /// <summary>
    /// Loads final CST findings for operator-facing structured results (actionable types only).
    /// </summary>
    internal static class CstStructuredResultsService
    {
        private static readonly Regex CstArtifactPathRegex = new(
            @"Result Artifact\s*:\s*(?<path>.+)",
            RegexOptions.Compiled | RegexOptions.IgnoreCase);

        private static readonly HashSet<string> ActionableFindingTypes = new(StringComparer.OrdinalIgnoreCase)
        {
            "Malware",
            "Virus",
            "PUP",
            "PUM"
        };

        public const string NoActionableFindingsMessage =
            "No actionable malware or unwanted-program findings in this scan.";

        public const double WeakHeuristicConfidenceCutoff = 0.55;

        public static bool ShouldShowSuppressedAuditFinding(string? detector, double confidence)
        {
            if (string.Equals(detector, "PathHeuristic", StringComparison.OrdinalIgnoreCase)
                && confidence < WeakHeuristicConfidenceCutoff)
            {
                return false;
            }

            return true;
        }

        public static string? ResolveArtifactPathFromStepOutput(string? output)
        {
            if (string.IsNullOrWhiteSpace(output))
            {
                return null;
            }

            var match = CstArtifactPathRegex.Match(output);
            if (!match.Success)
            {
                return null;
            }

            return match.Groups["path"].Value.Trim();
        }

        public static bool IsActionableFindingType(string? type)
        {
            return !string.IsNullOrWhiteSpace(type)
                && ActionableFindingTypes.Contains(type.Trim());
        }

        public static IReadOnlyList<CstStructuredFinding> LoadActionableFindings(string artifactPath)
        {
            return LoadFindings(artifactPath, actionableOnly: true);
        }

        public static IReadOnlyList<CstStructuredFinding> LoadAllFindings(string artifactPath)
        {
            return LoadFindings(artifactPath, actionableOnly: false);
        }

        public static CstScanMetadata? LoadScanMetadata(string artifactPath)
        {
            if (string.IsNullOrWhiteSpace(artifactPath) || !File.Exists(artifactPath))
                return null;

            try
            {
                var artifact = JsonSerializer.Deserialize<CstScanArtifactDocument>(
                    File.ReadAllText(artifactPath),
                    new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
                if (artifact == null)
                    return null;

                return new CstScanMetadata
                {
                    ArtifactPath = artifactPath,
                    ScanMode = artifact.ScanMode ?? artifact.ScanConfiguration?.Mode ?? string.Empty,
                    DetectionScope = artifact.ScanConfiguration?.DetectionScope ?? string.Empty,
                    ItemsScanned = artifact.Summary?.ItemsScanned ?? 0,
                    ThreatCount = artifact.Summary?.ThreatCount ?? 0,
                    WarningCount = artifact.Summary?.WarningCount ?? 0,
                    GeneratedAt = artifact.GeneratedAt ?? string.Empty
                };
            }
            catch
            {
                return null;
            }
        }

        private static IReadOnlyList<CstStructuredFinding> LoadFindings(string artifactPath, bool actionableOnly)
        {
            if (string.IsNullOrWhiteSpace(artifactPath) || !File.Exists(artifactPath))
            {
                return Array.Empty<CstStructuredFinding>();
            }

            try
            {
                var artifact = JsonSerializer.Deserialize<CstScanArtifactDocument>(
                    File.ReadAllText(artifactPath),
                    new JsonSerializerOptions { PropertyNameCaseInsensitive = true });

                var findings = new List<CstStructuredFindingDocument>();
                if (artifact?.Findings != null)
                    findings.AddRange(artifact.Findings);
                if (!actionableOnly && artifact?.SuppressedAuditFindings != null)
                    findings.AddRange(artifact.SuppressedAuditFindings);

                return findings
                    .Where(f => !actionableOnly || IsActionableFindingType(f.Type))
                    .Where(f => actionableOnly || ShouldShowSuppressedAuditFinding(f.Detector, f.Confidence))
                    .Select(f => new CstStructuredFinding
                    {
                        Type = f.Type ?? string.Empty,
                        Severity = f.Severity ?? string.Empty,
                        Name = f.Name ?? string.Empty,
                        Location = f.Location ?? string.Empty,
                        Evidence = f.Evidence ?? string.Empty,
                        Detector = f.Detector ?? string.Empty,
                        Confidence = f.Confidence
                    })
                    .OrderByDescending(f => SeverityRank(f.Severity))
                    .ThenBy(f => f.Name, StringComparer.OrdinalIgnoreCase)
                    .ToList();
            }
            catch
            {
                return Array.Empty<CstStructuredFinding>();
            }
        }

        private static int SeverityRank(string? severity)
        {
            return (severity ?? string.Empty).Trim().ToUpperInvariant() switch
            {
                "CRITICAL" => 5,
                "HIGH" => 4,
                "MEDIUM" => 3,
                "LOW" => 2,
                _ => 1
            };
        }

        internal sealed class CstScanArtifactDocument
        {
            public string? ScanMode { get; set; }
            public string? GeneratedAt { get; set; }
            public List<CstStructuredFindingDocument> Findings { get; set; } = new();
            public List<CstStructuredFindingDocument>? SuppressedAuditFindings { get; set; }
            public CstScanConfigurationDocument? ScanConfiguration { get; set; }
            public CstScanSummaryDocument? Summary { get; set; }
        }

        internal sealed class CstScanConfigurationDocument
        {
            public string? Mode { get; set; }
            public string? DetectionScope { get; set; }
        }

        internal sealed class CstScanSummaryDocument
        {
            public int ItemsScanned { get; set; }
            public int ThreatCount { get; set; }
            public int WarningCount { get; set; }
        }

        internal sealed class CstStructuredFindingDocument
        {
            public string? Type { get; set; }
            public string? Severity { get; set; }
            public string? Name { get; set; }
            public string? Location { get; set; }
            public string? Evidence { get; set; }
            public string? Detector { get; set; }
            public double Confidence { get; set; }
        }
    }

    internal sealed class CstStructuredFinding
    {
        public string Type { get; init; } = string.Empty;
        public string Severity { get; init; } = string.Empty;
        public string Name { get; init; } = string.Empty;
        public string Location { get; init; } = string.Empty;
        public string Evidence { get; init; } = string.Empty;
        public string Detector { get; init; } = string.Empty;
        public double Confidence { get; init; }
    }

    internal sealed class CstScanMetadata
    {
        public string ArtifactPath { get; init; } = string.Empty;
        public string ScanMode { get; init; } = string.Empty;
        public string DetectionScope { get; init; } = string.Empty;
        public int ItemsScanned { get; init; }
        public int ThreatCount { get; init; }
        public int WarningCount { get; init; }
        public string GeneratedAt { get; init; } = string.Empty;
    }
}
