using System;

namespace ToolkitGUI.Services
{
    internal static class CstScanProgressHelper
    {
        private const double ScanWindowMinimum = 10.0;
        private const double ScanWindowMaximum = 95.0;

        internal static double ResolveDisplayPercent(
            string? phase,
            int scanned,
            int progressTotal,
            double? overallPercent,
            double percent)
        {
            var phaseUpper = (phase ?? string.Empty).Trim().ToUpperInvariant();
            if (phaseUpper is "TARGETPREP" or "ENUMERATING" or "COMPLETED")
                return overallPercent ?? percent;

            if (progressTotal > 0 && scanned >= 0)
            {
                var fileRatio = Math.Min(1.0, scanned / (double)progressTotal);
                return ScanWindowMinimum + (fileRatio * (ScanWindowMaximum - ScanWindowMinimum));
            }

            return overallPercent ?? percent;
        }
    }
}
