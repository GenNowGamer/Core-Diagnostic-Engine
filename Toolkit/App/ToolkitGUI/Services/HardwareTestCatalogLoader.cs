using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using ToolkitGUI.Models;

namespace ToolkitGUI.Services
{
    internal static class HardwareTestCatalogLoader
    {
        private static readonly JsonSerializerOptions JsonOpts = new()
        {
            PropertyNameCaseInsensitive = true
        };

        private static readonly string[] FallbackCpu =
        {
            "Level 2 Cache Test", "Register Test", "MMX Test",
            "SSE Test", "SSE2 Test", "SSE3 Test", "SSSE3 Test",
            "SSE4.1 Test", "SSE4.2 Test", "Math Register Test",
            "Prime Number Generation Test", "Floating Point Unit Test"
        };

        private static readonly string[] FallbackMemory =
        {
            "Address Test", "Auxiliary Pattern Test", "Bit High Test",
            "Bit Low Test", "Checkerboard Test", "Modulo20 Test",
            "Moving Inversion Test", "Nibble Move Test",
            "Walking Ones Left Test", "Walking Ones Right Test"
        };

        private static readonly string[] FallbackStorage =
        {
            "SMART Thresholds Test", "SMART Status Test",
            "Targeted Read Test", "Linear Read Test",
            "Linear Read Test (2)", "SMART Short Self Test"
        };

        internal static string[] GetDisplayNames(string category, string profile)
        {
            var catalog = TryLoadCatalog();
            if (catalog?.Tests == null || catalog.Tests.Count == 0)
            {
                return category switch
                {
                    "CPU" => FallbackCpu,
                    "Memory" => FallbackMemory,
                    "HardDrive" => FallbackStorage,
                    _ => Array.Empty<string>()
                };
            }

            var useExtended = profile.Equals("Extended", StringComparison.OrdinalIgnoreCase);
            return catalog.Tests
                .Where(t => string.Equals(t.Category, category, StringComparison.OrdinalIgnoreCase))
                .Where(t => useExtended ? t.Profiles?.Extended == true : t.Profiles?.Quick == true)
                .OrderBy(t => t.Order)
                .Select(t => t.DisplayName ?? t.Id ?? string.Empty)
                .Where(n => !string.IsNullOrWhiteSpace(n))
                .ToArray();
        }

        internal static int GetHardwareSubTestCount(string profile)
        {
            var cpu = GetDisplayNames("CPU", profile).Length;
            var mem = GetDisplayNames("Memory", profile).Length;
            var stor = GetDisplayNames("HardDrive", profile).Length;
            return cpu + mem + stor;
        }

        internal static int GetStorageSubTestCount(string profile) =>
            GetDisplayNames("HardDrive", profile).Length;

        internal static HardwareTestCatalogDto? TryLoadCatalog() => LoadCatalog();

        internal static string? TryGetDisplayNameById(string catalogId)
        {
            var catalog = LoadCatalog();
            var match = catalog?.Tests?.FirstOrDefault(t =>
                string.Equals(t.Id, catalogId, StringComparison.OrdinalIgnoreCase));
            return match?.DisplayName ?? match?.Id;
        }

        internal static IReadOnlyList<(string Id, string DisplayName)> GetTestsForCategory(string category, string profile)
        {
            var catalog = LoadCatalog();
            if (catalog?.Tests == null || catalog.Tests.Count == 0)
            {
                var fallback = category switch
                {
                    "CPU" => FallbackCpu,
                    "Memory" => FallbackMemory,
                    "HardDrive" => FallbackStorage,
                    _ => Array.Empty<string>()
                };
                return fallback.Select((name, i) => ($"fallback_{category}_{i}", name)).ToList();
            }

            var useExtended = profile.Equals("Extended", StringComparison.OrdinalIgnoreCase);
            return catalog.Tests
                .Where(t => string.Equals(t.Category, category, StringComparison.OrdinalIgnoreCase))
                .Where(t => useExtended ? t.Profiles?.Extended == true : t.Profiles?.Quick == true)
                .OrderBy(t => t.Order)
                .Select(t => (t.Id ?? string.Empty, t.DisplayName ?? t.Id ?? string.Empty))
                .Where(t => !string.IsNullOrWhiteSpace(t.Item2))
                .ToList();
        }

        private static HardwareTestCatalogDto? LoadCatalog()
        {
            try
            {
                var path = ToolkitPaths.GetHardwareTestCatalogPath();
                if (!File.Exists(path))
                    return null;
                var json = File.ReadAllText(path);
                return JsonSerializer.Deserialize<HardwareTestCatalogDto>(json, JsonOpts);
            }
            catch
            {
                return null;
            }
        }
    }
}
