using System;
using System.Windows;

namespace ToolkitGUI.Services
{
    /// <summary>
    /// Keeps modal and child windows within the owner or monitor work area on small displays.
    /// </summary>
    internal static class WindowSizingHelper
    {
        private const double Margin = 16;
        private const double AbsoluteMinWidth = 320;
        private const double AbsoluteMinHeight = 240;

        public static void EnableAdaptiveDialog(Window window)
        {
            window.SourceInitialized += (_, _) => Constrain(window);
            if (window.IsLoaded)
                Constrain(window);
        }

        public static void Constrain(Window window)
        {
            if (window.Owner != null)
                ConstrainToOwner(window);
            else
                ConstrainToWorkArea(window);
        }

        private static void ConstrainToOwner(Window window)
        {
            var owner = window.Owner;
            if (owner == null)
            {
                ConstrainToWorkArea(window);
                return;
            }

            var maxWidth = Math.Max(AbsoluteMinWidth, owner.ActualWidth - Margin * 2);
            var maxHeight = Math.Max(AbsoluteMinHeight, owner.ActualHeight - Margin * 2);
            ApplyBounds(window, maxWidth, maxHeight);

            window.Left = owner.Left + Math.Max(Margin, (owner.ActualWidth - window.Width) / 2);
            window.Top = owner.Top + Math.Max(Margin, (owner.ActualHeight - window.Height) / 2);
        }

        private static void ConstrainToWorkArea(Window window)
        {
            var area = BorderlessWindowHelper.GetWorkAreaDips(window);
            var maxWidth = Math.Max(AbsoluteMinWidth, area.Width - Margin * 2);
            var maxHeight = Math.Max(AbsoluteMinHeight, area.Height - Margin * 2);
            ApplyBounds(window, maxWidth, maxHeight);

            window.Left = area.Left + Math.Max(Margin, (area.Width - window.Width) / 2);
            window.Top = area.Top + Math.Max(Margin, (area.Height - window.Height) / 2);
        }

        private static void ApplyBounds(Window window, double maxWidth, double maxHeight)
        {
            window.MaxWidth = maxWidth;
            window.MaxHeight = maxHeight;

            if (window.MinWidth > maxWidth)
                window.MinWidth = Math.Max(AbsoluteMinWidth, maxWidth * 0.9);
            if (window.MinHeight > maxHeight)
                window.MinHeight = Math.Max(AbsoluteMinHeight, maxHeight * 0.9);

            if (double.IsNaN(window.Width) || window.Width <= 0)
                window.Width = Math.Min(maxWidth, window.MaxWidth);
            else
                window.Width = Math.Min(window.Width, maxWidth);

            if (double.IsNaN(window.Height) || window.Height <= 0)
                window.Height = Math.Min(maxHeight, window.MaxHeight);
            else
                window.Height = Math.Min(window.Height, maxHeight);

            window.Width = Math.Max(window.Width, Math.Min(window.MinWidth, maxWidth));
            window.Height = Math.Max(window.Height, Math.Min(window.MinHeight, maxHeight));
            window.Width = Math.Min(window.Width, maxWidth);
            window.Height = Math.Min(window.Height, maxHeight);
        }
    }
}
