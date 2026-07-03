using System;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using ToolkitGUI.Models;
using ToolkitGUI.ViewModels;

namespace ToolkitGUI.Services
{
    public static class DiskLayoutService
    {
        private static string DiskLayoutModulePath =>
            Path.Combine(ToolkitPaths.GetScriptsRoot(), "Core", "DiskLayout.psm1");

        public static async Task<CdeDiskLayoutDocument?> LoadLayoutAsync(CancellationToken cancellationToken = default)
        {
            var modulePath = DiskLayoutModulePath;
            if (!File.Exists(modulePath))
                return null;

            var command = $"Import-Module '{modulePath.Replace("'", "''")}' -Force; Export-CdeDiskLayoutJson -Compress";
            var (json, error) = await PowerShellService.QueryAsync(command);
            if (string.IsNullOrWhiteSpace(json))
            {
                if (!string.IsNullOrWhiteSpace(error))
                    throw new InvalidOperationException(error.Trim());
                return null;
            }

            try
            {
                return JsonSerializer.Deserialize<CdeDiskLayoutDocument>(json, new JsonSerializerOptions
                {
                    PropertyNameCaseInsensitive = true
                });
            }
            catch (JsonException ex)
            {
                throw new InvalidOperationException($"Failed to parse disk layout JSON: {ex.Message}", ex);
            }
        }
    }
}
