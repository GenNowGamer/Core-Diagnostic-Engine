using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using ToolkitGUI.ViewModels;

namespace ToolkitGUI.Services
{
    public sealed class ShadowCopyEntry
    {
        public string Id { get; init; } = string.Empty;
        public string Drive { get; init; } = string.Empty;
        public string InstallDate { get; init; } = string.Empty;
        public string DeviceObject { get; init; } = string.Empty;
        public string VolumeName { get; init; } = string.Empty;
        public string DisplayLabel { get; init; } = string.Empty;
    }

    public static class ShadowCopyBrowseService
    {
        private static string ScriptPath =>
            Path.Combine(ToolkitPaths.GetScriptsRoot(), "Core", "ShadowCopyBrowse.ps1");

        public static bool IsAvailable()
        {
            if (IsWinPeMode())
                return false;

            try
            {
                return !string.Equals(Environment.GetEnvironmentVariable("SystemDrive"), "X:", StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return true;
            }
        }

        public static bool IsShadowBrowsePath(string? path)
        {
            if (string.IsNullOrWhiteSpace(path))
                return false;

            try
            {
                var full = Path.GetFullPath(path);
                var root = Path.Combine(Path.GetTempPath(), "CDE_ShadowBrowse");
                return full.StartsWith(root, StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        public static async Task<(IReadOnlyList<ShadowCopyEntry> Entries, string? Error)> ListAsync()
        {
            if (!IsAvailable())
                return (Array.Empty<ShadowCopyEntry>(), null);

            var script = ScriptPath.Replace("'", "''");
            var (output, error) = await PowerShellService.QueryAsync($"& '{script}' -Action List").ConfigureAwait(false);
            if (!string.IsNullOrWhiteSpace(error) && string.IsNullOrWhiteSpace(output))
                return (Array.Empty<ShadowCopyEntry>(), error.Trim());

            try
            {
                if (string.IsNullOrWhiteSpace(output))
                    return (Array.Empty<ShadowCopyEntry>(), null);

                var entries = new List<ShadowCopyEntry>();
                using var doc = JsonDocument.Parse(output);
                if (doc.RootElement.ValueKind == JsonValueKind.Object
                    && doc.RootElement.TryGetProperty("error", out var errorElement))
                {
                    var message = errorElement.GetString();
                    if (!string.IsNullOrWhiteSpace(message))
                        return (Array.Empty<ShadowCopyEntry>(), message.Trim());
                }

                if (doc.RootElement.ValueKind == JsonValueKind.Array)
                {
                    foreach (var item in doc.RootElement.EnumerateArray())
                        entries.Add(ParseEntry(item));
                }
                else if (doc.RootElement.ValueKind == JsonValueKind.Object)
                {
                    entries.Add(ParseEntry(doc.RootElement));
                }

                return (entries, null);
            }
            catch (Exception ex)
            {
                var detail = string.IsNullOrWhiteSpace(error) ? ex.Message : $"{ex.Message} | {error}";
                return (Array.Empty<ShadowCopyEntry>(), detail);
            }
        }

        public static async Task<(string? MountPath, string? Error)> MountAsync(ShadowCopyEntry entry)
        {
            if (!IsAvailable())
                return (null, "Shadow copy browse is not available in WinPE mode.");

            var script = ScriptPath.Replace("'", "''");
            var id = entry.Id.Replace("'", "''");
            var device = entry.DeviceObject.Replace("'", "''");
            var drive = entry.Drive.Replace("'", "''");
            var command =
                $"& '{script}' -Action Mount -ShadowId '{id}' -DeviceObject '{device}' -Drive '{drive}'";

            var (output, error) = await PowerShellService.QueryAsync(command).ConfigureAwait(false);
            if (!string.IsNullOrWhiteSpace(error) && string.IsNullOrWhiteSpace(output))
                return (null, error.Trim());

            try
            {
                if (string.IsNullOrWhiteSpace(output))
                    return (null, "Mount command returned no output.");

                using var doc = JsonDocument.Parse(output);
                if (doc.RootElement.TryGetProperty("MountPath", out var mountPath))
                {
                    var path = mountPath.GetString();
                    if (!string.IsNullOrWhiteSpace(path) && Directory.Exists(path))
                        return (path, null);
                }

                return (null, string.IsNullOrWhiteSpace(error) ? "Failed to mount shadow copy." : error.Trim());
            }
            catch (Exception ex)
            {
                var detail = string.IsNullOrWhiteSpace(error) ? ex.Message : $"{ex.Message} | {error}";
                return (null, detail);
            }
        }

        private static ShadowCopyEntry ParseEntry(JsonElement item) =>
            new()
            {
                Id = item.TryGetProperty("Id", out var id) ? id.GetString() ?? string.Empty : string.Empty,
                Drive = item.TryGetProperty("Drive", out var drive) ? drive.GetString() ?? string.Empty : string.Empty,
                InstallDate = item.TryGetProperty("InstallDate", out var installDate) ? installDate.GetString() ?? string.Empty : string.Empty,
                DeviceObject = item.TryGetProperty("DeviceObject", out var device) ? device.GetString() ?? string.Empty : string.Empty,
                VolumeName = item.TryGetProperty("VolumeName", out var volume) ? volume.GetString() ?? string.Empty : string.Empty,
                DisplayLabel = item.TryGetProperty("DisplayLabel", out var label) ? label.GetString() ?? string.Empty : string.Empty
            };

        private static bool IsWinPeMode()
        {
            try
            {
                return string.Equals(Environment.GetEnvironmentVariable("SystemDrive"), "X:", StringComparison.OrdinalIgnoreCase)
                    || Environment.GetEnvironmentVariable("WINPE") == "1"
                    || Environment.GetEnvironmentVariable("PEINSTALL") == "1"
                    || Directory.Exists(@"X:\");
            }
            catch
            {
                return false;
            }
        }
    }
}
