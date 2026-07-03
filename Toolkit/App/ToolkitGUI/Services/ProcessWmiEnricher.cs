using System;
using System.Collections.Generic;
using System.Globalization;
using System.Management;
using ToolkitGUI.Models;

namespace ToolkitGUI.Services
{
    internal static class ProcessWmiEnricher
    {
        internal sealed class WmiProcessInfo
        {
            public string CommandLine { get; init; } = string.Empty;
            public int ParentPid { get; init; }
            public int SessionId { get; init; }
            public string StartTime { get; init; } = string.Empty;
        }

        internal static Dictionary<int, WmiProcessInfo> QueryAll()
        {
            var map = new Dictionary<int, WmiProcessInfo>();
            try
            {
                using var searcher = new ManagementObjectSearcher(
                    "SELECT ProcessId, CommandLine, ParentProcessId, SessionId, CreationDate FROM Win32_Process");
                using var results = searcher.Get();
                foreach (ManagementObject mo in results)
                {
                    using (mo)
                    {
                        var pid = ToInt(mo["ProcessId"]);
                        if (pid <= 0)
                            continue;

                        map[pid] = new WmiProcessInfo
                        {
                            CommandLine = mo["CommandLine"]?.ToString() ?? string.Empty,
                            ParentPid = ToInt(mo["ParentProcessId"]),
                            SessionId = ToInt(mo["SessionId"]),
                            StartTime = FormatCreationDate(mo["CreationDate"])
                        };
                    }
                }
            }
            catch
            {
                // WMI unavailable — caller keeps JSON values.
            }

            return map;
        }

        internal static WmiProcessInfo? QueryOne(int pid)
        {
            if (pid <= 0)
                return null;

            try
            {
                using var searcher = new ManagementObjectSearcher(
                    $"SELECT ProcessId, CommandLine, ParentProcessId, SessionId, CreationDate FROM Win32_Process WHERE ProcessId = {pid}");
                using var results = searcher.Get();
                foreach (ManagementObject mo in results)
                {
                    using (mo)
                    {
                        return new WmiProcessInfo
                        {
                            CommandLine = mo["CommandLine"]?.ToString() ?? string.Empty,
                            ParentPid = ToInt(mo["ParentProcessId"]),
                            SessionId = ToInt(mo["SessionId"]),
                            StartTime = FormatCreationDate(mo["CreationDate"])
                        };
                    }
                }
            }
            catch
            {
                // ignore
            }

            return null;
        }

        internal static void ApplyToEntry(ProcessEntry entry, WmiProcessInfo info)
        {
            if (!string.IsNullOrWhiteSpace(info.CommandLine))
                entry.CommandLine = info.CommandLine;
            if (info.ParentPid != 0)
                entry.ParentPid = info.ParentPid;
            if (info.SessionId != 0)
                entry.SessionId = info.SessionId;
            if (!string.IsNullOrWhiteSpace(info.StartTime))
                entry.StartTime = info.StartTime;
        }

        internal static void ApplyToDetail(ProcessDetail detail, WmiProcessInfo info)
        {
            if (!string.IsNullOrWhiteSpace(info.CommandLine))
                detail.StartupCommandLine = info.CommandLine;
            if (info.ParentPid != 0)
                detail.ParentPid = info.ParentPid;
            if (info.SessionId != 0)
                detail.SessionId = info.SessionId;
            if (!string.IsNullOrWhiteSpace(info.StartTime))
                detail.StartTime = info.StartTime;
        }

        private static int ToInt(object? value)
        {
            if (value == null)
                return 0;
            try
            {
                return Convert.ToInt32(value, CultureInfo.InvariantCulture);
            }
            catch
            {
                return 0;
            }
        }

        private static string FormatCreationDate(object? value)
        {
            if (value == null)
                return string.Empty;

            try
            {
                if (value is DateTime dt)
                    return dt.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);

                if (DateTime.TryParse(value.ToString(), CultureInfo.InvariantCulture,
                        DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed))
                    return parsed.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
            }
            catch
            {
                // ignore
            }

            return string.Empty;
        }
    }
}
