using System;
using System.Collections.Generic;
using System.IO;
using WinForms = System.Windows.Forms;

namespace ToolkitGUI.ViewModels
{
    /// <summary>
    /// Resolves the offline Windows installation that OS-repair workflows should
    /// target when ToolkitGUI runs under WinPE. The selection model mirrors the
    /// bootloader repair tools so a workflow never silently falls back to C:\ on
    /// the boot stick. Resolution order:
    ///   1. OFFLINE_WINDOWS_ROOT (exported by WinPE startup from the boot menu).
    ///   2. A single auto-detected Windows installation.
    ///   3. An operator pick when multiple installations exist.
    /// Returns <c>null</c> (with a status reason) when nothing is selectable.
    /// </summary>
    internal static class OfflineWindowsResolver
    {
        internal sealed record WindowsInstallTarget(string DriveRoot, string WindowsDir);

        internal static List<WindowsInstallTarget> ScanWindowsInstalls()
        {
            var results = new List<WindowsInstallTarget>();
            foreach (var drive in DriveInfo.GetDrives())
            {
                try
                {
                    if (!drive.IsReady) continue;
                    var root = drive.RootDirectory.FullName.TrimEnd('\\');
                    if (root.Equals("X:", StringComparison.OrdinalIgnoreCase)) continue;
                    var winDir = Path.Combine(root, "Windows");
                    if (!Directory.Exists(winDir)) continue;
                    results.Add(new WindowsInstallTarget(root, winDir));
                }
                catch { /* skip unreadable drives */ }
            }
            return results;
        }

        internal static WindowsInstallTarget? PickInstallDialog(List<WindowsInstallTarget> targets, string title)
        {
            if (targets.Count == 0) return null;
            if (targets.Count == 1) return targets[0];

            using var form = new WinForms.Form
            {
                Text = title,
                Width = 640,
                Height = 280,
                StartPosition = WinForms.FormStartPosition.CenterScreen,
                FormBorderStyle = WinForms.FormBorderStyle.FixedDialog,
                MinimizeBox = false,
                MaximizeBox = false,
                TopMost = true
            };
            var listBox = new WinForms.ListBox
            {
                Dock = WinForms.DockStyle.Fill,
                Font = new System.Drawing.Font("Segoe UI", 10f)
            };
            foreach (var t in targets)
            {
                listBox.Items.Add($"{t.DriveRoot}  \u2014  {t.WindowsDir}");
            }
            listBox.SelectedIndex = 0;
            var okButton = new WinForms.Button
            {
                Text = "Select",
                DialogResult = WinForms.DialogResult.OK,
                Dock = WinForms.DockStyle.Bottom,
                Height = 36
            };
            form.Controls.Add(listBox);
            form.Controls.Add(okButton);
            form.AcceptButton = okButton;
            return form.ShowDialog() == WinForms.DialogResult.OK ? targets[listBox.SelectedIndex] : null;
        }

        /// <summary>
        /// Resolves the Windows directory to pass to OSRepair.ps1 under WinPE.
        /// Returns <c>null</c> and sets <paramref name="statusOnFailure"/> when the
        /// operator cancels or no installation can be found.
        /// </summary>
        internal static string? ResolveOfflineWindowsDir(string selectionTitle, out string statusOnFailure)
        {
            statusOnFailure = string.Empty;

            var offlineRoot = Environment.GetEnvironmentVariable("OFFLINE_WINDOWS_ROOT");
            if (!string.IsNullOrWhiteSpace(offlineRoot))
            {
                var winDir = Path.Combine(offlineRoot.TrimEnd('\\'), "Windows");
                if (Directory.Exists(winDir)) return winDir;
            }

            var targets = ScanWindowsInstalls();
            if (targets.Count == 0)
            {
                statusOnFailure = "No Windows installation found";
                return null;
            }
            if (targets.Count == 1) return targets[0].WindowsDir;

            var picked = PickInstallDialog(targets, selectionTitle);
            if (picked == null)
            {
                statusOnFailure = "Cancelled";
                return null;
            }
            return picked.WindowsDir;
        }
    }

    /// <summary>
    /// A removable Windows update package on an offline image, as enumerated by
    /// <c>dism /Get-Packages</c> via OSRepair.ps1's ListPackages query mode.
    /// </summary>
    internal sealed record UpdatePackage(string PackageName, string ReleaseType, string InstallTime, string State)
    {
        public string Display => $"{PackageName}   [{ReleaseType}]   {InstallTime}".Trim();
    }

    /// <summary>
    /// WinForms picker that lets the operator choose a single update package to
    /// remove from an offline image (or "revert pending actions only"). Mirrors
    /// <see cref="OfflineWindowsResolver.PickInstallDialog"/>.
    /// </summary>
    internal static class UpdatePackagePicker
    {
        // Sentinel meaning "operator cancelled the dialog".
        internal static readonly UpdatePackage Cancelled = new("\0CANCELLED", "", "", "");
        // Empty PackageName meaning "revert pending actions only, remove nothing".
        private static readonly UpdatePackage RevertOnly = new(string.Empty, string.Empty, string.Empty, string.Empty);

        internal static UpdatePackage Pick(List<UpdatePackage> packages, string title)
        {
            using var form = new WinForms.Form
            {
                Text = title,
                Width = 760,
                Height = 420,
                StartPosition = WinForms.FormStartPosition.CenterScreen,
                FormBorderStyle = WinForms.FormBorderStyle.FixedDialog,
                MinimizeBox = false,
                MaximizeBox = false,
                TopMost = true
            };
            var listBox = new WinForms.ListBox
            {
                Dock = WinForms.DockStyle.Fill,
                Font = new System.Drawing.Font("Consolas", 9f),
                HorizontalScrollbar = true
            };
            listBox.Items.Add("(Revert pending actions only \u2014 remove no package)");
            foreach (var p in packages) listBox.Items.Add(p.Display);
            listBox.SelectedIndex = 0;

            var ok = new WinForms.Button
            {
                Text = "Apply",
                DialogResult = WinForms.DialogResult.OK,
                Dock = WinForms.DockStyle.Bottom,
                Height = 36
            };
            var cancel = new WinForms.Button
            {
                Text = "Cancel",
                DialogResult = WinForms.DialogResult.Cancel,
                Dock = WinForms.DockStyle.Bottom,
                Height = 36
            };
            form.Controls.Add(listBox);
            form.Controls.Add(ok);
            form.Controls.Add(cancel);
            form.AcceptButton = ok;
            form.CancelButton = cancel;

            if (form.ShowDialog() != WinForms.DialogResult.OK) return Cancelled;
            var idx = listBox.SelectedIndex;
            return idx <= 0 ? RevertOnly : packages[idx - 1];
        }
    }
}
