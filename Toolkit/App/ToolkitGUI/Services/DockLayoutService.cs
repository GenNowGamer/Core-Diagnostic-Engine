using System.IO;
using System.Linq;
using AvalonDock;
using AvalonDock.Layout;

namespace ToolkitGUI.Services
{
    internal static class DockLayoutService
    {
        public static void ApplyEnvironmentPreset(DockingManager manager)
        {
            if (manager?.Layout == null)
                return;

            var detailPane = manager.Layout
                .Descendents()
                .OfType<LayoutAnchorable>()
                .FirstOrDefault(a => a.CanHide);

            if (detailPane == null)
                return;

            if (IsWinPe())
            {
                detailPane.IsVisible = true;
                detailPane.IsSelected = false;
                detailPane.Parent?.Children
                    .OfType<LayoutAnchorable>()
                    .ToList()
                    .ForEach(a => a.IsActive = false);
                return;
            }

            detailPane.IsVisible = true;
            detailPane.IsSelected = true;
        }

        private static bool IsWinPe() =>
            Directory.Exists(@"X:\Windows\System32");
    }
}
