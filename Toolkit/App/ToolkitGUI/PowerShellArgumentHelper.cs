using System;

namespace ToolkitGUI
{
    /// <summary>
    /// Formats arguments for powershell.exe -File invocations via ProcessStartInfo.Arguments.
    /// Windows splits on spaces unless values use double quotes; single quotes are not honored.
    /// Drive roots must not be passed as 'E:\' (trailing backslash escapes the closing quote).
    /// </summary>
    internal static class PowerShellArgumentHelper
    {
        internal static string NormalizePathArgument(string? value)
        {
            if (string.IsNullOrWhiteSpace(value))
                return string.Empty;

            var trimmed = value.Trim().Trim('"', '\'');

            if (trimmed.Length >= 2 && trimmed[1] == ':')
            {
                var drive = char.ToUpperInvariant(trimmed[0]);
                if (trimmed.Length == 2 || (trimmed.Length == 3 && (trimmed[2] == '\\' || trimmed[2] == '/')))
                    return $"{drive}:";
            }

            return trimmed.TrimEnd('\\', '/');
        }

        /// <summary>
        /// Single-quoted value embedded inside generated PowerShell script text.
        /// </summary>
        internal static string QuoteForScriptParameter(string value)
        {
            if (value == null)
                return "''";

            return $"'{value.Replace("'", "''", StringComparison.Ordinal)}'";
        }

        /// <summary>
        /// Double-quoted value for powershell.exe -File switch parameters (Windows argv rules).
        /// </summary>
        internal static string QuoteForProcessInvocation(string? value)
        {
            if (string.IsNullOrEmpty(value))
                return "\"\"";

            return "\"" + value.Replace("\"", "\\\"", StringComparison.Ordinal) + "\"";
        }

        /// <summary>
        /// Path passed to a workflow script parameter from ProcessStartInfo.Arguments.
        /// </summary>
        internal static string QuotePathParameterForProcess(string? path)
            => QuoteForProcessInvocation(NormalizePathArgument(path));
    }
}
