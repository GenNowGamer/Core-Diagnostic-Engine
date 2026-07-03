using System;
using System.Diagnostics.Eventing.Reader;
using System.Management;

namespace ToolkitGUI.ViewModels
{
    internal static class BootUptimeHelper
    {
        private static readonly object CacheLock = new();
        private static DateTime? _bootLocal;

        public static string FormatUptime(TimeSpan span) =>
            $"{(int)span.TotalDays}d {span.Hours}h {span.Minutes}m";

        public static string GetBannerUptimeDisplay()
        {
            var uptime = FormatUptime(DateTime.Now - GetBootLocalTime());
            return $"Uptime: {uptime}";
        }

        private static DateTime GetBootLocalTime()
        {
            lock (CacheLock)
            {
                if (_bootLocal.HasValue)
                {
                    return _bootLocal.Value;
                }

                if (TryGetLatestEventTime(12, "Microsoft-Windows-Kernel-General", out var eventBoot)
                    || TryGetLatestEventTime(6005, null, out eventBoot)
                    || TryGetWmiLastBoot(out eventBoot))
                {
                    _bootLocal = eventBoot;
                    return _bootLocal.Value;
                }

                _bootLocal = DateTime.Now;
                return _bootLocal.Value;
            }
        }

        private static bool TryGetLatestEventTime(int eventId, string? providerName, out DateTime localTime)
        {
            localTime = default;
            try
            {
                var xpath = providerName is null
                    ? $"*[System[EventID={eventId}]]"
                    : $"*[System[Provider[@Name='{providerName}'] and EventID={eventId}]]";

                var query = new EventLogQuery("System", PathType.LogName, xpath)
                {
                    ReverseDirection = true
                };

                using var reader = new EventLogReader(query);
                using var record = reader.ReadEvent();
                if (record?.TimeCreated is null)
                {
                    return false;
                }

                localTime = record.TimeCreated.Value;
                return true;
            }
            catch
            {
                return false;
            }
        }

        private static bool TryGetWmiLastBoot(out DateTime localBoot)
        {
            localBoot = default;
            try
            {
                using var searcher = new ManagementObjectSearcher(
                    "SELECT LastBootUpTime FROM Win32_OperatingSystem");
                foreach (ManagementObject obj in searcher.Get())
                {
                    var raw = obj["LastBootUpTime"]?.ToString();
                    if (string.IsNullOrWhiteSpace(raw))
                    {
                        continue;
                    }

                    localBoot = ManagementDateTimeConverter.ToDateTime(raw);
                    return true;
                }
            }
            catch
            {
                // Best-effort only.
            }

            return false;
        }
    }
}
