using System;
using System.Diagnostics;
using System.IO;

namespace ToolkitGUI.Services
{
    /// <summary>
    /// Opens files with the user's default application from a de-elevated shell context.
    /// CDE runs as administrator; direct ShellExecute from an elevated process often starts
    /// the handler without bringing its window to the foreground.
    /// </summary>
    internal static class ShellFileOpenHelper
    {
        public static void OpenWithDefaultApplication(string filePath)
        {
            if (string.IsNullOrWhiteSpace(filePath))
            {
                throw new ArgumentException("A file path is required.", nameof(filePath));
            }

            var fullPath = Path.GetFullPath(filePath);
            if (!File.Exists(fullPath))
            {
                throw new FileNotFoundException("The file could not be found.", fullPath);
            }

            Process.Start(new ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = $"\"{fullPath}\"",
                UseShellExecute = true
            });
        }
    }
}
