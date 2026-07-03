using System;

namespace ToolkitGUI.Services
{
    internal static class NavigationService
    {
        public static event Action<string>? NavigateRequested;

        /// <summary>Optional context for the target view (e.g. ProcessAnalyzer filter preset).</summary>
        public static string? PendingContext { get; private set; }

        public static void Request(string section, string? context = null)
        {
            if (string.IsNullOrWhiteSpace(section))
                return;

            var navSection = section;
            var navContext = context;
            var colon = section.IndexOf(':');
            if (colon > 0)
            {
                navSection = section[..colon];
                navContext = section[(colon + 1)..];
            }

            PendingContext = navContext;
            NavigateRequested?.Invoke(navSection);
        }

        public static string? ConsumePendingContext()
        {
            var context = PendingContext;
            PendingContext = null;
            return context;
        }
    }
}
