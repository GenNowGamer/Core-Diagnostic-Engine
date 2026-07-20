using System;

namespace ToolkitGUI.Services
{
    /// <summary>
    /// Evidence-quality classification for System Health findings.
    /// Aligns with NIST SP 800-61 triage (validate/confirm before treating a signal
    /// as confirmed) and keeps Incomplete distinct from Fail/Warn outcomes.
    /// </summary>
    internal static class HealthFindingClassification
    {
        public const string ConfirmedFault = "ConfirmedFault";
        public const string CorroboratedSuspect = "CorroboratedSuspect";
        public const string SingleSignal = "SingleSignal";
        public const string Inventory = "Inventory";
        public const string ExpectedLimitation = "ExpectedLimitation";
        public const string Incomplete = "Incomplete";

        public static string Resolve(
            string? classification,
            string? status,
            string? severity,
            int confidence)
        {
            var explicitValue = (classification ?? string.Empty).Trim();
            if (IsKnown(explicitValue))
            {
                return NormalizeToken(explicitValue);
            }

            var statusNorm = (status ?? string.Empty).Trim();
            var severityNorm = (severity ?? string.Empty).Trim();

            if (statusNorm.Equals("Fail", StringComparison.OrdinalIgnoreCase))
                return ConfirmedFault;

            if (statusNorm.Equals("N/A", StringComparison.OrdinalIgnoreCase)
                || statusNorm.Equals("NA", StringComparison.OrdinalIgnoreCase)
                || statusNorm.Equals("Skip", StringComparison.OrdinalIgnoreCase))
            {
                return Incomplete;
            }

            if (statusNorm.Equals("Pass", StringComparison.OrdinalIgnoreCase)
                || statusNorm.Equals("Info", StringComparison.OrdinalIgnoreCase))
            {
                return Inventory;
            }

            if (statusNorm.Equals("Warn", StringComparison.OrdinalIgnoreCase)
                || statusNorm.Equals("Warning", StringComparison.OrdinalIgnoreCase))
            {
                if (severityNorm.Equals("Critical", StringComparison.OrdinalIgnoreCase))
                    return ConfirmedFault;

                if (severityNorm.Equals("High", StringComparison.OrdinalIgnoreCase) && confidence >= 90)
                    return CorroboratedSuspect;

                return SingleSignal;
            }

            return SingleSignal;
        }

        public static bool RequiresAttention(
            string? classification,
            string? status,
            string? severity = null,
            int confidence = 0)
        {
            var resolved = Resolve(classification, status, severity, confidence);
            if (resolved.Equals(ConfirmedFault, StringComparison.OrdinalIgnoreCase)
                || resolved.Equals(CorroboratedSuspect, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            if (resolved.Equals(SingleSignal, StringComparison.OrdinalIgnoreCase))
            {
                var statusNorm = (status ?? string.Empty).Trim();
                return statusNorm.Equals("Fail", StringComparison.OrdinalIgnoreCase)
                    || statusNorm.Equals("Warn", StringComparison.OrdinalIgnoreCase)
                    || statusNorm.Equals("Warning", StringComparison.OrdinalIgnoreCase);
            }

            return false;
        }

        public static string GetDisplayLabel(string? classification)
        {
            return (classification ?? string.Empty).Trim() switch
            {
                var c when c.Equals(ConfirmedFault, StringComparison.OrdinalIgnoreCase) => "Confirmed fault",
                var c when c.Equals(CorroboratedSuspect, StringComparison.OrdinalIgnoreCase) => "Corroborated suspect",
                var c when c.Equals(SingleSignal, StringComparison.OrdinalIgnoreCase) => "Single signal",
                var c when c.Equals(Inventory, StringComparison.OrdinalIgnoreCase) => "Inventory",
                var c when c.Equals(ExpectedLimitation, StringComparison.OrdinalIgnoreCase) => "Expected limitation",
                var c when c.Equals(Incomplete, StringComparison.OrdinalIgnoreCase) => "Incomplete",
                _ => string.IsNullOrWhiteSpace(classification) ? string.Empty : classification.Trim()
            };
        }

        public static int Rank(string? classification)
        {
            var token = (classification ?? string.Empty).Trim();
            if (!IsKnown(token))
                return 0;

            return NormalizeToken(token) switch
            {
                ConfirmedFault => 6,
                CorroboratedSuspect => 5,
                SingleSignal => 4,
                Incomplete => 3,
                ExpectedLimitation => 2,
                Inventory => 1,
                _ => 0
            };
        }

        private static bool IsKnown(string value) =>
            value.Equals(ConfirmedFault, StringComparison.OrdinalIgnoreCase)
            || value.Equals(CorroboratedSuspect, StringComparison.OrdinalIgnoreCase)
            || value.Equals(SingleSignal, StringComparison.OrdinalIgnoreCase)
            || value.Equals(Inventory, StringComparison.OrdinalIgnoreCase)
            || value.Equals(ExpectedLimitation, StringComparison.OrdinalIgnoreCase)
            || value.Equals(Incomplete, StringComparison.OrdinalIgnoreCase);

        private static string NormalizeToken(string value)
        {
            if (value.Equals(ConfirmedFault, StringComparison.OrdinalIgnoreCase)) return ConfirmedFault;
            if (value.Equals(CorroboratedSuspect, StringComparison.OrdinalIgnoreCase)) return CorroboratedSuspect;
            if (value.Equals(SingleSignal, StringComparison.OrdinalIgnoreCase)) return SingleSignal;
            if (value.Equals(Inventory, StringComparison.OrdinalIgnoreCase)) return Inventory;
            if (value.Equals(ExpectedLimitation, StringComparison.OrdinalIgnoreCase)) return ExpectedLimitation;
            if (value.Equals(Incomplete, StringComparison.OrdinalIgnoreCase)) return Incomplete;
            return value;
        }
    }
}
