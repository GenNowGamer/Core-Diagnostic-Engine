using System;
using System.Collections.Generic;
using System.IO;

namespace ToolkitGUI.Services
{
    /// <summary>
    /// Helpers for optional removal of files linked to deleted startup persistence
    /// (e.g. ProgramData/AppData droppers left after Run-key Delete).
    /// </summary>
    internal static class StartupTargetFileCleanup
    {
        /// <summary>
        /// True when the path looks user-writable / non-OS and is safe to offer for deletion
        /// after removing the autorun that pointed at it.
        /// </summary>
        public static bool IsRemediableDropPath(string? fullPath)
        {
            if (string.IsNullOrWhiteSpace(fullPath))
                return false;

            string p;
            try
            {
                p = Path.GetFullPath(fullPath).ToLowerInvariant();
            }
            catch
            {
                return false;
            }

            // Never offer OS / install trees (except Windows\Temp).
            if (p.Contains(@"\windows\") && !p.Contains(@"\windows\temp\"))
                return false;
            if (p.Contains(@"\program files\") || p.Contains(@"\program files (x86)\"))
                return false;

            // Microsoft ProgramData products are usually legitimate,
            // except the common Startup folder under Start Menu.
            if (p.Contains(@"\programdata\microsoft\") &&
                !p.Contains(@"\programdata\microsoft\windows\start menu\programs\startup\"))
                return false;

            // Temp / Public / Downloads are always eligible.
            if (p.Contains(@"\temp\")
                || p.Contains(@"\users\public\")
                || p.Contains(@"\downloads\"))
                return true;

            // Explicit AppData Local Temp and Roaming Startup.
            if (p.Contains(@"\appdata\local\temp\")
                || p.Contains(@"\appdata\roaming\microsoft\windows\start menu\programs\startup\"))
                return true;

            // Non-Microsoft ProgramData trees (vendor drop nests).
            if (p.Contains(@"\programdata\"))
                return true;

            // AppData only for known drop-style nests (not Documents/Desktop).
            if (p.Contains(@"\appdata\"))
            {
                return p.Contains(@"\temp\")
                    || p.Contains(@"\startup\")
                    || p.Contains(@"\vendorcache\")
                    || p.Contains(@"\appdata\local\microsoft\windows\start menu");
            }

            // Documents and Desktop are not remediable unless already matched above
            // via Temp/Public (e.g. Users\Public\Documents).
            return false;
        }

        public static bool TryDeleteFileAndEmptyParents(string fullPath, out string detail)
        {
            detail = string.Empty;
            if (string.IsNullOrWhiteSpace(fullPath) || !File.Exists(fullPath))
            {
                detail = "Target file was already gone.";
                return false;
            }

            if (!IsRemediableDropPath(fullPath))
            {
                detail = "Target path is not eligible for automatic removal.";
                return false;
            }

            try
            {
                var file = new FileInfo(Path.GetFullPath(fullPath));
                var parent = file.Directory;
                file.Delete();

                var removedDirs = new List<string>();
                // Remove up to two empty parent dirs under remediable roots (e.g. Runtime + VendorCache).
                for (var i = 0; i < 2 && parent != null; i++)
                {
                    if (!IsRemediableDropPath(parent.FullName))
                        break;

                    parent.Refresh();
                    if (!parent.Exists)
                        break;

                    try
                    {
                        if (parent.GetFileSystemInfos().Length == 0)
                        {
                            var next = parent.Parent;
                            parent.Delete();
                            removedDirs.Add(parent.FullName);
                            parent = next;
                            continue;
                        }
                    }
                    catch
                    {
                        break;
                    }

                    break;
                }

                detail = removedDirs.Count > 0
                    ? $"Removed file and empty folder(s): {string.Join("; ", removedDirs)}"
                    : "Removed target file.";
                return true;
            }
            catch (Exception ex)
            {
                detail = ex.Message;
                return false;
            }
        }
    }
}
