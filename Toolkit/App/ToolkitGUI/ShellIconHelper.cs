using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace ToolkitGUI
{
    internal static class ShellIconHelper
    {
        private const uint ShgfiIcon = 0x000000100;
        private const uint ShgfiSmallIcon = 0x000000001;
        private const uint ShgfiUseFileAttributes = 0x000000010;
        private const uint FileAttributeDirectory = 0x00000010;
        private const uint FileAttributeNormal = 0x00000080;

        private static readonly Dictionary<string, ImageSource> Cache = new(StringComparer.OrdinalIgnoreCase);

        public static ImageSource GetIcon(string path, bool isDirectory)
        {
            var cacheKey = isDirectory ? "__dir__" : GetExtensionKey(path);
            if (Cache.TryGetValue(cacheKey, out var cached))
                return cached;

            var source = LoadShellIcon(path, isDirectory);
            Cache[cacheKey] = source;
            return source;
        }

        private static ImageSource LoadShellIcon(string path, bool isDirectory)
        {
            if (!string.IsNullOrWhiteSpace(path) &&
                (isDirectory ? Directory.Exists(path) : File.Exists(path)))
            {
                return QueryIcon(path, 0, ShgfiIcon | ShgfiSmallIcon);
            }

            var lookup = isDirectory ? "Folder" : Path.GetExtension(path);
            if (string.IsNullOrEmpty(lookup))
                lookup = ".txt";

            var attributes = isDirectory ? FileAttributeDirectory : FileAttributeNormal;
            return QueryIcon(lookup, attributes, ShgfiIcon | ShgfiSmallIcon | ShgfiUseFileAttributes);
        }

        private static ImageSource QueryIcon(string lookup, uint attributes, uint flags)
        {
            var shfi = new Shfileinfo();
            var result = SHGetFileInfo(
                lookup,
                attributes,
                ref shfi,
                (uint)Marshal.SizeOf<Shfileinfo>(),
                flags);

            if (result == IntPtr.Zero || shfi.hIcon == IntPtr.Zero)
                throw new InvalidOperationException($"Unable to resolve shell icon for '{lookup}'.");

            try
            {
                var source = Imaging.CreateBitmapSourceFromHIcon(
                    shfi.hIcon,
                    Int32Rect.Empty,
                    BitmapSizeOptions.FromWidthAndHeight(16, 16));
                source.Freeze();
                return source;
            }
            finally
            {
                DestroyIcon(shfi.hIcon);
            }
        }

        private static string GetExtensionKey(string path)
        {
            var ext = Path.GetExtension(path);
            return string.IsNullOrEmpty(ext) ? "__file__" : ext;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct Shfileinfo
        {
            public IntPtr hIcon;
            public int iIcon;
            public uint dwAttributes;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string szDisplayName;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)]
            public string szTypeName;
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr SHGetFileInfo(
            string pszPath,
            uint dwFileAttributes,
            ref Shfileinfo psfi,
            uint cbFileInfo,
            uint uFlags);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool DestroyIcon(IntPtr hIcon);
    }
}
