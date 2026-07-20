using System;
using System.Globalization;

namespace ToolkitGUI.Services
{
    /// <summary>
    /// Formats work-order ISO timestamps for technician-facing UI/PDF display.
    /// Storage remains round-trip ISO ("o"); only presentation is friendly.
    /// </summary>
    public static class WorkOrderTimestampFormatter
    {
        public const string DisplayFormat = "MMM d, yyyy h:mm tt";

        public static string Format(string? raw, string emptyDisplay = "")
        {
            if (string.IsNullOrWhiteSpace(raw))
                return emptyDisplay;

            if (DateTimeOffset.TryParse(
                    raw,
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.RoundtripKind,
                    out var dto))
            {
                return dto.ToLocalTime().ToString(DisplayFormat, CultureInfo.CurrentCulture);
            }

            if (DateTime.TryParse(
                    raw,
                    CultureInfo.CurrentCulture,
                    DateTimeStyles.AssumeLocal | DateTimeStyles.AllowWhiteSpaces,
                    out var dt))
            {
                return dt.ToLocalTime().ToString(DisplayFormat, CultureInfo.CurrentCulture);
            }

            return raw.Trim();
        }
    }
}
