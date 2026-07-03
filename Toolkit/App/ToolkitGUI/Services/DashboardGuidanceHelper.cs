using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;

namespace ToolkitGUI.Services
{
    internal sealed class SymptomFlowFollowUp
    {
        public string Target { get; init; } = string.Empty;
        public string Label { get; init; } = string.Empty;
    }

    internal sealed class SymptomFlowDefinition
    {
        public string Id { get; init; } = string.Empty;
        public string Label { get; init; } = string.Empty;
        public string Summary { get; init; } = string.Empty;
        public string HealthPreset { get; init; } = string.Empty;
        public IReadOnlyList<string> Keywords { get; init; } = Array.Empty<string>();
        public IReadOnlyList<SymptomFlowFollowUp> FollowUps { get; init; } = Array.Empty<SymptomFlowFollowUp>();
    }

    internal static class DashboardGuidanceHelper
    {
        private static readonly JsonSerializerOptions JsonOpts = new() { PropertyNameCaseInsensitive = true };

        public static IReadOnlyList<SymptomFlowDefinition> LoadSymptomFlows()
        {
            var path = ToolkitPaths.GetSymptomFlowsPath();
            if (!File.Exists(path))
                return Array.Empty<SymptomFlowDefinition>();

            try
            {
                var root = JsonSerializer.Deserialize<SymptomFlowsFileDto>(File.ReadAllText(path), JsonOpts);
                if (root?.Flows == null || root.Flows.Count == 0)
                    return Array.Empty<SymptomFlowDefinition>();

                var list = new List<SymptomFlowDefinition>();
                foreach (var flow in root.Flows)
                {
                    var followUps = new List<SymptomFlowFollowUp>();
                    if (flow.FollowUps != null)
                    {
                        foreach (var item in flow.FollowUps)
                        {
                            if (string.IsNullOrWhiteSpace(item.Target))
                                continue;
                            followUps.Add(new SymptomFlowFollowUp
                            {
                                Target = item.Target.Trim(),
                                Label = string.IsNullOrWhiteSpace(item.Label) ? item.Target.Trim() : item.Label.Trim()
                            });
                        }
                    }

                    list.Add(new SymptomFlowDefinition
                    {
                        Id = flow.Id ?? string.Empty,
                        Label = flow.Label ?? flow.Id ?? string.Empty,
                        Summary = flow.Summary ?? string.Empty,
                        HealthPreset = flow.HealthPreset ?? string.Empty,
                        Keywords = flow.Keywords?
                            .Where(k => !string.IsNullOrWhiteSpace(k))
                            .Select(k => k.Trim())
                            .ToList() ?? new List<string>(),
                        FollowUps = followUps
                    });
                }

                return list;
            }
            catch
            {
                return Array.Empty<SymptomFlowDefinition>();
            }
        }

        public static string GetEnvironmentModeLabel()
        {
            if (!IsWinPeRuntime())
                return "Windows (live system)";

            if (IsOfflineOsLoaded())
                return "WinPE (offline OS loaded)";

            return "WinPE (live environment)";
        }

        public static string GetBootGuidanceText()
        {
            if (!IsWinPeRuntime())
                return "Launch CDE as administrator on the live system, or boot from USB WinPE for offline repair.";

            if (IsOfflineOsLoaded())
                return "Offline OS is loaded. Use Disk & Boot Repair, OS Repair, or Startup Manager against the customer hive.";

            return "For a PC that will not boot into Windows, use WinPE menu option 2 (Offline OS) or run CHU from the rEFInd menu first.";
        }

        public static SymptomFlowDefinition? InferSymptomFlowFromNotes(
            IReadOnlyList<SymptomFlowDefinition> flows,
            string? notes)
        {
            if (flows.Count == 0 || string.IsNullOrWhiteSpace(notes))
                return null;

            var trimmed = notes.Trim();
            foreach (var flow in flows)
            {
                if (trimmed.Equals(flow.Label, StringComparison.OrdinalIgnoreCase) ||
                    trimmed.Equals(flow.Id, StringComparison.OrdinalIgnoreCase))
                {
                    return flow;
                }
            }

            foreach (var flow in flows)
            {
                if (trimmed.Contains(flow.Label, StringComparison.OrdinalIgnoreCase))
                    return flow;
            }

            var compactNotes = CompactNormalize(trimmed);
            if (compactNotes.Length == 0)
                return null;

            SymptomFlowDefinition? bestFlow = null;
            var bestScore = 0;
            var bestKeywordHits = 0;

            foreach (var flow in flows)
            {
                var score = 0;
                var keywordHits = 0;

                foreach (var keyword in flow.Keywords)
                {
                    var compactKeyword = CompactNormalize(keyword);
                    if (compactKeyword.Length == 0)
                        continue;

                    if (!ContainsNormalizedKeyword(compactNotes, compactKeyword))
                        continue;

                    keywordHits++;
                    score += Math.Max(2, compactKeyword.Length / 2);
                }

                foreach (var token in TokenizeForSummaryMatch(flow.Summary))
                {
                    if (token.Length < 4)
                        continue;

                    if (compactNotes.Contains(token, StringComparison.Ordinal))
                        score += 1;
                }

                if (score > bestScore || (score == bestScore && score > 0 && keywordHits > bestKeywordHits))
                {
                    bestScore = score;
                    bestKeywordHits = keywordHits;
                    bestFlow = flow;
                }
            }

            return bestScore >= 2 ? bestFlow : null;
        }

        private static bool ContainsNormalizedKeyword(string compactNotes, string compactKeyword)
        {
            if (compactKeyword.Length == 0)
                return false;

            if (compactNotes.Contains(compactKeyword, StringComparison.Ordinal))
                return true;

            if (compactKeyword.Length < 4)
                return false;

            var stem = compactKeyword.TrimEnd('s');
            return stem.Length >= 4 && compactNotes.Contains(stem, StringComparison.Ordinal);
        }

        private static IEnumerable<string> TokenizeForSummaryMatch(string text)
        {
            foreach (var part in text.Split(new[] { ' ', ',', '.', ';', ':', '-', '(', ')' },
                         StringSplitOptions.RemoveEmptyEntries))
            {
                var token = CompactNormalize(part);
                if (token.Length > 0)
                    yield return token;
            }
        }

        private static string CompactNormalize(string text)
        {
            var sb = new StringBuilder(text.Length);
            foreach (var c in text.ToLowerInvariant())
            {
                if (char.IsLetterOrDigit(c))
                    sb.Append(c);
            }

            return sb.ToString();
        }

        private static bool IsWinPeRuntime() => Directory.Exists(@"X:\Windows\System32");

        private static bool IsOfflineOsLoaded()
        {
            return string.Equals(
                Environment.GetEnvironmentVariable("OFFLINE_REGISTRY_LOADED"),
                "1",
                StringComparison.OrdinalIgnoreCase);
        }

        private sealed class SymptomFlowsFileDto
        {
            public List<SymptomFlowDto>? Flows { get; set; }
        }

        private sealed class SymptomFlowDto
        {
            public string? Id { get; set; }
            public string? Label { get; set; }
            public string? Summary { get; set; }
            public string? HealthPreset { get; set; }
            public List<string>? Keywords { get; set; }
            public List<SymptomFlowFollowUpDto>? FollowUps { get; set; }
        }

        private sealed class SymptomFlowFollowUpDto
        {
            public string? Target { get; set; }
            public string? Label { get; set; }
        }
    }
}
