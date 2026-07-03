using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.Win32;

namespace ToolkitGUI.Services
{
    /// <summary>
    /// Borderless WPF windows (WindowStyle=None) overflow the monitor when maximized unless
    /// WM_GETMINMAXINFO is handled. WinPE display hand-off makes this especially visible.
    /// </summary>
    internal static class BorderlessWindowHelper
    {
        private const int WmGetMinMaxInfo = 0x0024;
        private const int MonitorDefaultToNearest = 0x00000002;
        private const double AbsoluteMinWidth = 640;
        private const double AbsoluteMinHeight = 480;

        public static void Enable(Window window)
        {
            if (window == null)
                throw new ArgumentNullException(nameof(window));

            window.SourceInitialized += (_, _) =>
            {
                var source = (HwndSource?)PresentationSource.FromVisual(window);
                source?.AddHook(WndProc);
            };
        }

        public static Rect GetWorkAreaDips(Window window)
        {
            var hwnd = new WindowInteropHelper(window).Handle;
            if (hwnd == IntPtr.Zero)
                return SystemParameters.WorkArea;

            var monitor = MonitorFromWindow(hwnd, MonitorDefaultToNearest);
            if (monitor == IntPtr.Zero)
                return SystemParameters.WorkArea;

            var monitorInfo = new MonitorInfo { cbSize = Marshal.SizeOf<MonitorInfo>() };
            if (!GetMonitorInfo(monitor, ref monitorInfo))
                return SystemParameters.WorkArea;

            return PhysicalRectToDips(window, ToRect(monitorInfo.rcWork));
        }

        /// <summary>
        /// Sizes the main shell on first show. Clamps design defaults and minimums to the monitor work area.
        /// </summary>
        public static void ApplyShellStartup(
            Window window,
            double designWidth,
            double designHeight,
            double designMinWidth,
            double designMinHeight,
            bool fillWorkArea)
        {
            var area = GetWorkAreaDips(window);
            const double margin = 12;
            var maxWidth = Math.Max(AbsoluteMinWidth, area.Width - margin * 2);
            var maxHeight = Math.Max(AbsoluteMinHeight, area.Height - margin * 2);

            window.MinWidth = Math.Min(designMinWidth, maxWidth);
            window.MinHeight = Math.Min(designMinHeight, maxHeight);
            window.MinWidth = Math.Max(window.MinWidth, Math.Min(AbsoluteMinWidth, maxWidth));
            window.MinHeight = Math.Max(window.MinHeight, Math.Min(AbsoluteMinHeight, maxHeight));

            if (fillWorkArea)
            {
                FillWorkArea(window, margin);
                return;
            }

            var width = Math.Min(designWidth, maxWidth);
            var height = Math.Min(designHeight, maxHeight);
            width = Math.Max(width, window.MinWidth);
            height = Math.Max(height, window.MinHeight);
            width = Math.Min(width, maxWidth);
            height = Math.Min(height, maxHeight);

            window.WindowState = WindowState.Normal;
            window.Width = width;
            window.Height = height;
            window.Left = area.Left + Math.Max(margin, (area.Width - width) / 2);
            window.Top = area.Top + Math.Max(margin, (area.Height - height) / 2);
        }

        /// <summary>
        /// Fits the window to the current monitor work area without using WindowState.Maximized.
        /// </summary>
        public static void FillWorkArea(Window window, double margin = 0)
        {
            var area = GetWorkAreaDips(window);
            var maxWidth = Math.Max(AbsoluteMinWidth, area.Width - margin * 2);
            var maxHeight = Math.Max(AbsoluteMinHeight, area.Height - margin * 2);

            ClampMinimumSize(window, maxWidth, maxHeight);

            window.WindowState = WindowState.Normal;
            window.Left = area.Left + margin;
            window.Top = area.Top + margin;
            window.Width = maxWidth;
            window.Height = maxHeight;
        }

        /// <summary>
        /// Corrects windows that were maximized before the HWND hook was active or no longer fit the monitor.
        /// </summary>
        public static void EnsureWithinWorkArea(Window window, double margin = 12)
        {
            var area = GetWorkAreaDips(window);
            var maxWidth = Math.Max(AbsoluteMinWidth, area.Width - margin * 2);
            var maxHeight = Math.Max(AbsoluteMinHeight, area.Height - margin * 2);
            ClampMinimumSize(window, maxWidth, maxHeight);

            var right = window.Left + window.ActualWidth;
            var bottom = window.Top + window.ActualHeight;
            var overflow =
                window.Left < area.Left - 0.5 ||
                window.Top < area.Top - 0.5 ||
                right > area.Right + 0.5 ||
                bottom > area.Bottom + 0.5 ||
                window.ActualWidth > maxWidth + 0.5 ||
                window.ActualHeight > maxHeight + 0.5;

            if (!overflow && window.WindowState != WindowState.Maximized)
                return;

            window.WindowState = WindowState.Normal;
            window.Width = Math.Min(Math.Max(window.MinWidth, window.Width), maxWidth);
            window.Height = Math.Min(Math.Max(window.MinHeight, window.Height), maxHeight);
            window.Left = Math.Max(area.Left + margin, Math.Min(window.Left, area.Right - window.Width - margin));
            window.Top = Math.Max(area.Top + margin, Math.Min(window.Top, area.Bottom - window.Height - margin));
        }

        public static void EnableDisplayChangeRelayout(Window window, Action<Window> relayout)
        {
            EventHandler? handler = null;
            handler = (_, _) =>
            {
                if (!window.IsLoaded)
                    return;

                window.Dispatcher.BeginInvoke(() => relayout(window));
            };

            window.Loaded += (_, _) => SystemEvents.DisplaySettingsChanged += handler;
            window.Closed += (_, _) => SystemEvents.DisplaySettingsChanged -= handler;
        }

        private static void ClampMinimumSize(Window window, double maxWidth, double maxHeight)
        {
            if (window.MinWidth > maxWidth)
                window.MinWidth = Math.Max(Math.Min(AbsoluteMinWidth, maxWidth), maxWidth * 0.9);
            if (window.MinHeight > maxHeight)
                window.MinHeight = Math.Max(Math.Min(AbsoluteMinHeight, maxHeight), maxHeight * 0.9);
        }

        private static IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            if (msg != WmGetMinMaxInfo)
                return IntPtr.Zero;

            var window = HwndSource.FromHwnd(hwnd)?.RootVisual as Window;
            if (window?.WindowStyle != WindowStyle.None)
                return IntPtr.Zero;

            var monitor = MonitorFromWindow(hwnd, MonitorDefaultToNearest);
            if (monitor == IntPtr.Zero)
                return IntPtr.Zero;

            var monitorInfo = new MonitorInfo { cbSize = Marshal.SizeOf<MonitorInfo>() };
            if (!GetMonitorInfo(monitor, ref monitorInfo))
                return IntPtr.Zero;

            var mmi = Marshal.PtrToStructure<MinMaxInfo>(lParam);
            var work = ToRect(monitorInfo.rcWork);
            var monitorRect = ToRect(monitorInfo.rcMonitor);

            if (window != null)
            {
                var area = PhysicalRectToDips(window, work);
                var origin = PhysicalRectToDips(window, new Rect(work.Left, work.Top, 0, 0));
                mmi.ptMaxPosition.x = (int)Math.Round(origin.Left);
                mmi.ptMaxPosition.y = (int)Math.Round(origin.Top);
                mmi.ptMaxSize.x = (int)Math.Round(area.Width);
                mmi.ptMaxSize.y = (int)Math.Round(area.Height);
            }
            else
            {
                mmi.ptMaxPosition.x = (int)(work.Left - monitorRect.Left);
                mmi.ptMaxPosition.y = (int)(work.Top - monitorRect.Top);
                mmi.ptMaxSize.x = (int)work.Width;
                mmi.ptMaxSize.y = (int)work.Height;
            }

            Marshal.StructureToPtr(mmi, lParam, true);
            handled = true;
            return IntPtr.Zero;
        }

        private static Rect ToRect(NativeRect rect) =>
            new(rect.Left, rect.Top, rect.Right - rect.Left, rect.Bottom - rect.Top);

        private static Rect PhysicalRectToDips(Window window, Rect physical)
        {
            var source = PresentationSource.FromVisual(window);
            if (source?.CompositionTarget == null)
                return physical;

            var transform = source.CompositionTarget.TransformFromDevice;
            var topLeft = transform.Transform(new Point(physical.Left, physical.Top));
            var bottomRight = transform.Transform(new Point(physical.Right, physical.Bottom));
            return new Rect(topLeft, bottomRight);
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PointStruct
        {
            public int x;
            public int y;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MinMaxInfo
        {
            public PointStruct ptReserved;
            public PointStruct ptMaxSize;
            public PointStruct ptMaxPosition;
            public PointStruct ptMinTrackSize;
            public PointStruct ptMaxTrackSize;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeRect
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        private struct MonitorInfo
        {
            public int cbSize;
            public NativeRect rcMonitor;
            public NativeRect rcWork;
            public int dwFlags;
        }

        [DllImport("user32.dll")]
        private static extern IntPtr MonitorFromWindow(IntPtr hwnd, int dwFlags);

        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetMonitorInfo(IntPtr hMonitor, ref MonitorInfo lpmi);
    }
}
