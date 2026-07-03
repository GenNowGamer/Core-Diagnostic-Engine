using System;
using System.Collections.Generic;
using System.Linq;
using ToolkitGUI.Models;

namespace ToolkitGUI.Services
{
    internal sealed class ChuResultsRollup
    {
        public int PassCount { get; init; }
        public int WarnCount { get; init; }
        public int FailCount { get; init; }
        public int SkipCount { get; init; }
        public string OverallLabel { get; init; } = "Unknown";
    }

    public sealed class ChuCorrelatedEntry
    {
        public ChuTestEntry Entry { get; init; } = new();
        public string CatalogDisplayName { get; init; } = string.Empty;
        public bool HasCatalogMatch { get; init; }
        public bool ShowDiagRepairLink { get; init; }
        public string HighlightContext { get; init; } = string.Empty;
    }

    internal static class ChuResultsCorrelationHelper
    {
        public static ChuResultsRollup ComputeRollup(IEnumerable<ChuTestEntry> entries)
        {
            var list = entries?.ToList() ?? new List<ChuTestEntry>();
            var pass = 0;
            var warn = 0;
            var fail = 0;
            var skip = 0;

            foreach (var entry in list)
            {
                switch (entry.Status?.ToUpperInvariant())
                {
                    case "PASS":
                        pass++;
                        break;
                    case "WARN":
                    case "ABORTED":
                        warn++;
                        break;
                    case "FAIL":
                        fail++;
                        break;
                    case "SKIP":
                        skip++;
                        break;
                }
            }

            var overall = fail > 0 ? "Critical" : warn > 0 ? "Warning" : pass > 0 ? "Healthy" : "Unknown";
            return new ChuResultsRollup
            {
                PassCount = pass,
                WarnCount = warn,
                FailCount = fail,
                SkipCount = skip,
                OverallLabel = overall
            };
        }

        public static IReadOnlyList<ChuCorrelatedEntry> CorrelateEntries(IEnumerable<ChuTestEntry> entries)
        {
            var catalog = HardwareTestCatalogLoader.TryLoadCatalog();
            var byId = catalog?.Tests?
                .Where(t => !string.IsNullOrWhiteSpace(t.Id))
                .ToDictionary(t => t.Id!, t => t, StringComparer.OrdinalIgnoreCase)
                ?? new Dictionary<string, HardwareTestEntryDto>(StringComparer.OrdinalIgnoreCase);

            return (entries ?? Array.Empty<ChuTestEntry>()).Select(entry =>
            {
                var hasMatch = !string.IsNullOrWhiteSpace(entry.Id) && byId.ContainsKey(entry.Id);
                var displayName = hasMatch
                    ? byId[entry.Id].DisplayName ?? entry.DisplayName
                    : entry.DisplayName;
                var status = entry.Status?.ToUpperInvariant() ?? string.Empty;
                var needsLink = hasMatch && (status is "WARN" or "FAIL" or "ABORTED");
                return new ChuCorrelatedEntry
                {
                    Entry = entry,
                    CatalogDisplayName = displayName ?? entry.Test,
                    HasCatalogMatch = hasMatch,
                    ShowDiagRepairLink = needsLink,
                    HighlightContext = hasMatch ? $"highlight:{entry.Id}" : string.Empty
                };
            }).ToList();
        }
    }
}
