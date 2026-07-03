using System;
using System.Collections.Generic;
using System.Linq;
using System.Management;

namespace ToolkitGUI.Services
{
    /// <summary>
    /// Mirrors <c>PhysicalDiskCatalog.psm1</c> — excludes removable media from hardware storage testing.
    /// </summary>
    internal static class PhysicalDiskCatalogHelper
    {
        private const string StorageWmiNamespace = @"root\Microsoft\Windows\Storage";

        public static bool IsRemovableMediaDisk(string? mediaType, bool isRemovableFromStorage)
        {
            if (isRemovableFromStorage)
                return true;

            if (!string.IsNullOrWhiteSpace(mediaType) &&
                mediaType.IndexOf("Removable", StringComparison.OrdinalIgnoreCase) >= 0)
                return true;

            return false;
        }

        public static IReadOnlyDictionary<int, bool> GetRemovableMediaDiskMap()
        {
            var map = new Dictionary<int, bool>();
            try
            {
                using var searcher = new ManagementObjectSearcher(
                    StorageWmiNamespace,
                    "SELECT Number, IsRemovable FROM MSFT_Disk");
                foreach (var obj in searcher.Get().Cast<ManagementObject>())
                {
                    var number = Convert.ToInt32(obj["Number"] ?? -1);
                    if (number < 0)
                        continue;

                    var isRemovable = obj["IsRemovable"] is bool b && b;
                    if (isRemovable)
                        map[number] = true;
                }
            }
            catch
            {
                // Storage WMI unavailable — fall back to Win32 MediaType only.
            }

            return map;
        }

        public static List<(int Index, string Title)> GetTestableDriveSlots()
        {
            var slots = new List<(int Index, string Title)>();
            var removableMap = GetRemovableMediaDiskMap();

            try
            {
                using var searcher = new ManagementObjectSearcher(
                    "SELECT Index, Model, Size, MediaType FROM Win32_DiskDrive");
                foreach (var obj in searcher.Get().Cast<ManagementObject>()
                             .OrderBy(d => Convert.ToInt32(d["Index"] ?? 0)))
                {
                    var index = Convert.ToInt32(obj["Index"] ?? 0);
                    var mediaType = obj["MediaType"]?.ToString();
                    var isRemovableFromStorage = removableMap.ContainsKey(index);

                    if (IsRemovableMediaDisk(mediaType, isRemovableFromStorage))
                        continue;

                    var model = (obj["Model"]?.ToString() ?? "Unknown Model").Trim();
                    var sizeBytes = Convert.ToUInt64(obj["Size"] ?? 0UL);
                    var sizeGb = Math.Round(sizeBytes / 1_073_741_824.0, 1);
                    slots.Add((index, $"Drive {index}: {model} ({sizeGb} GB)"));
                }
            }
            catch
            {
                // Fall back to a single placeholder row when WMI is unavailable.
            }

            if (slots.Count == 0)
                slots.Add((0, "Drive 0: Unknown"));

            return slots;
        }
    }
}
