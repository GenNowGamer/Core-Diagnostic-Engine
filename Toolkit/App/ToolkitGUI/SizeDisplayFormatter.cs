namespace ToolkitGUI
{
    public static class SizeDisplayFormatter
    {
        public static string FormatBytes(long bytes)
        {
            string[] units = { "B", "KB", "MB", "GB", "TB" };
            double value = bytes < 0 ? 0 : bytes;
            var unit = 0;

            while (value >= 1024 && unit < units.Length - 1)
            {
                value /= 1024;
                unit++;
            }

            var decimals = unit <= 1 ? 0 : 1;
            return $"{value.ToString($"F{decimals}")} {units[unit]}";
        }

        public static string FormatMegabytes(double megabytes)
        {
            if (double.IsNaN(megabytes) || double.IsInfinity(megabytes) || megabytes < 0)
                return "0 MB";

            var bytes = (long)System.Math.Round(megabytes * 1024 * 1024, System.MidpointRounding.AwayFromZero);
            return FormatBytes(bytes);
        }
    }
}
