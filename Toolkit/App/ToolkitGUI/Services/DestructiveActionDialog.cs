using System.Windows;

namespace ToolkitGUI.Services
{
    /// <summary>
    /// Standard confirmation gate before destructive CDE operations.
    /// </summary>
    internal static class DestructiveActionDialog
    {
        public static bool Confirm(
            string title,
            string summary,
            string impact,
            bool defaultNo = true)
        {
            var message = summary;
            if (!string.IsNullOrWhiteSpace(impact))
            {
                message += "\n\nImpact:\n" + impact;
            }

            message += "\n\nDo you want to continue?";

            var result = MessageBox.Show(
                message,
                title,
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning,
                defaultNo ? MessageBoxResult.No : MessageBoxResult.Yes);

            return result == MessageBoxResult.Yes;
        }
    }
}
