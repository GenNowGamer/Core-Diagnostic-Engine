using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Media;

namespace ToolkitGUI.Services
{
    public enum AppTheme
    {
        Light,
        Dark
    }

    public static class ThemeService
    {
        private static readonly IReadOnlyDictionary<string, Color> LightPalette = new Dictionary<string, Color>(StringComparer.Ordinal)
        {
            ["BackgroundDarkBrush"] = Color.FromRgb(0xEE, 0xF2, 0xF7),
            ["BackgroundMidBrush"] = Color.FromRgb(0xFF, 0xFF, 0xFF),
            ["BackgroundLightBrush"] = Color.FromRgb(0xE2, 0xE8, 0xF2),
            ["AccentBlueBrush"] = Color.FromRgb(0x00, 0x78, 0xD4),
            ["AccentGreenBrush"] = Color.FromRgb(0x0D, 0x7A, 0x3E),
            ["AccentRedBrush"] = Color.FromRgb(0xC4, 0x2B, 0x1C),
            ["AccentYellowBrush"] = Color.FromRgb(0x92, 0x68, 0x00),
            ["TextPrimaryBrush"] = Color.FromRgb(0x1A, 0x28, 0x40),
            ["TextSecondaryBrush"] = Color.FromRgb(0x5A, 0x6B, 0x80),
            ["BorderBrush"] = Color.FromRgb(0xD0, 0xD6, 0xE0),
            ["ActionButtonHoverBrush"] = Color.FromRgb(0x00, 0x5F, 0xA3),
            ["ActionButtonDisabledBgBrush"] = Color.FromRgb(0xC8, 0xD0, 0xDC),

            // Semantic surfaces & status text
            ["SurfaceCardAltBrush"] = Color.FromRgb(0xFA, 0xFB, 0xFD),
            ["SurfaceGridRowBrush"] = Color.FromRgb(0xFF, 0xFF, 0xFF),
            ["SurfaceGridAltRowBrush"] = Color.FromRgb(0xF8, 0xFA, 0xFC),
            ["SurfaceGridSelectedBrush"] = Color.FromRgb(0xE3, 0xF0, 0xFB),
            ["SurfaceHoverBrush"] = Color.FromRgb(0xEE, 0xF3, 0xF8),
            ["SurfaceWarningBrush"] = Color.FromRgb(0xFF, 0xF4, 0xE5),
            ["SurfaceDangerRowBrush"] = Color.FromRgb(0xFE, 0xE2, 0xE2),
            ["SurfaceSuccessRowBrush"] = Color.FromRgb(0xE8, 0xF5, 0xE9),
            ["SurfaceInfoBannerBrush"] = Color.FromRgb(0xF0, 0xF6, 0xFF),
            ["SurfaceInfoBannerBorderBrush"] = Color.FromRgb(0xB4, 0xD2, 0xF5),
            ["SurfaceWarnBannerBrush"] = Color.FromRgb(0xFF, 0xF8, 0xE6),
            ["SurfaceWarnBannerBorderBrush"] = Color.FromRgb(0xE6, 0xC3, 0x6A),
            ["SurfaceHeaderBandBrush"] = Color.FromRgb(0xD6, 0xE4, 0xF0),
            ["SurfaceRunningRowBrush"] = Color.FromRgb(0xE8, 0xF4, 0xFC),
            ["LoadingOverlayBrush"] = Color.FromArgb(0xB3, 0xFF, 0xFF, 0xFF),
            ["TextWarningBrush"] = Color.FromRgb(0x92, 0x68, 0x00),
            ["TextWarningDarkBrush"] = Color.FromRgb(0x6B, 0x4D, 0x00),
            ["TextDangerBrush"] = Color.FromRgb(0xC6, 0x28, 0x28),
            ["TextSuccessBrush"] = Color.FromRgb(0x0D, 0x7A, 0x3E),
            ["TextInfoBrush"] = Color.FromRgb(0x15, 0x65, 0xC0),
            ["TextOnNeutralBrush"] = Color.FromRgb(0x1A, 0x1A, 0x1A)
        };

        private static readonly IReadOnlyDictionary<string, Color> DarkPalette = new Dictionary<string, Color>(StringComparer.Ordinal)
        {
            ["BackgroundDarkBrush"] = Color.FromRgb(0x11, 0x16, 0x1E),
            ["BackgroundMidBrush"] = Color.FromRgb(0x1A, 0x22, 0x2D),
            ["BackgroundLightBrush"] = Color.FromRgb(0x24, 0x2E, 0x3D),
            ["AccentBlueBrush"] = Color.FromRgb(0x38, 0x98, 0xEC),
            ["AccentGreenBrush"] = Color.FromRgb(0x2E, 0xA0, 0x43),
            ["AccentRedBrush"] = Color.FromRgb(0xE5, 0x53, 0x4B),
            ["AccentYellowBrush"] = Color.FromRgb(0xD2, 0x99, 0x22),
            ["TextPrimaryBrush"] = Color.FromRgb(0xE6, 0xED, 0xF5),
            ["TextSecondaryBrush"] = Color.FromRgb(0x9F, 0xB0, 0xC4),
            ["BorderBrush"] = Color.FromRgb(0x31, 0x3E, 0x50),
            ["ActionButtonHoverBrush"] = Color.FromRgb(0x2A, 0x82, 0xD2),
            ["ActionButtonDisabledBgBrush"] = Color.FromRgb(0x2D, 0x37, 0x46),

            // Semantic surfaces & status text (high contrast on dark surfaces)
            ["SurfaceCardAltBrush"] = Color.FromRgb(0x20, 0x29, 0x36),
            ["SurfaceGridRowBrush"] = Color.FromRgb(0x1A, 0x22, 0x2D),
            ["SurfaceGridAltRowBrush"] = Color.FromRgb(0x20, 0x29, 0x36),
            ["SurfaceGridSelectedBrush"] = Color.FromRgb(0x22, 0x3A, 0x58),
            ["SurfaceHoverBrush"] = Color.FromRgb(0x28, 0x33, 0x44),
            ["SurfaceWarningBrush"] = Color.FromRgb(0x3A, 0x2B, 0x16),
            ["SurfaceDangerRowBrush"] = Color.FromRgb(0x3D, 0x1F, 0x24),
            ["SurfaceSuccessRowBrush"] = Color.FromRgb(0x17, 0x2E, 0x20),
            ["SurfaceInfoBannerBrush"] = Color.FromRgb(0x1A, 0x2E, 0x44),
            ["SurfaceInfoBannerBorderBrush"] = Color.FromRgb(0x2E, 0x55, 0x80),
            ["SurfaceWarnBannerBrush"] = Color.FromRgb(0x38, 0x2A, 0x14),
            ["SurfaceWarnBannerBorderBrush"] = Color.FromRgb(0x7A, 0x5B, 0x22),
            ["SurfaceHeaderBandBrush"] = Color.FromRgb(0x24, 0x32, 0x44),
            ["SurfaceRunningRowBrush"] = Color.FromRgb(0x1B, 0x33, 0x4D),
            ["LoadingOverlayBrush"] = Color.FromArgb(0xB3, 0x0F, 0x14, 0x1C),
            ["TextWarningBrush"] = Color.FromRgb(0xE5, 0xB8, 0x4B),
            ["TextWarningDarkBrush"] = Color.FromRgb(0xF0, 0xCB, 0x6E),
            ["TextDangerBrush"] = Color.FromRgb(0xF4, 0x70, 0x67),
            ["TextSuccessBrush"] = Color.FromRgb(0x3F, 0xB9, 0x50),
            ["TextInfoBrush"] = Color.FromRgb(0x58, 0xA6, 0xFF),
            ["TextOnNeutralBrush"] = Color.FromRgb(0xE6, 0xED, 0xF5)
        };

        private static readonly UTF8Encoding Utf8NoBom = new(encoderShouldEmitUTF8Identifier: false);

        public static AppTheme CurrentTheme { get; private set; } = AppTheme.Light;

        public static event EventHandler<AppTheme>? ThemeChanged;

        private static string GetThemeConfigPath()
            => Path.Combine(ToolkitPaths.GetToolkitRoot(), "CDE", "Runtime", "theme.txt");

        private static string? TryGetThemeConfigPath()
        {
            try
            {
                return GetThemeConfigPath();
            }
            catch
            {
                return null;
            }
        }

        private static string? GetFallbackThemeConfigPath()
        {
            try
            {
                var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                if (string.IsNullOrWhiteSpace(localAppData))
                    return null;

                return Path.Combine(localAppData, "CoreDiagnosticEngine", "theme.txt");
            }
            catch
            {
                return null;
            }
        }

        public static void Initialize()
        {
            var saved = LoadSavedTheme();
            ApplyTheme(saved);
        }

        public static AppTheme LoadSavedTheme()
        {
            try
            {
                return LoadSavedTheme(TryGetThemeConfigPath() ?? string.Empty, GetFallbackThemeConfigPath());
            }
            catch
            {
                // Fall back to Light theme if runtime config is unreadable.
                return AppTheme.Light;
            }
        }

        internal static AppTheme LoadSavedTheme(string primaryPath, string? fallbackPath)
        {
            if (!string.IsNullOrWhiteSpace(primaryPath) &&
                File.Exists(primaryPath) &&
                CanWriteExistingFile(primaryPath) &&
                TryReadThemeFile(primaryPath, out var primaryTheme))
            {
                return primaryTheme;
            }

            if (!string.IsNullOrWhiteSpace(fallbackPath) &&
                File.Exists(fallbackPath) &&
                TryReadThemeFile(fallbackPath, out var fallbackTheme))
            {
                return fallbackTheme;
            }

            if (!string.IsNullOrWhiteSpace(primaryPath) &&
                File.Exists(primaryPath) &&
                TryReadThemeFile(primaryPath, out var readOnlyPrimaryTheme))
            {
                return readOnlyPrimaryTheme;
            }

            return AppTheme.Light;
        }

        public static void SetTheme(AppTheme theme)
        {
            SaveTheme(theme);
            ApplyTheme(theme);
        }

        private static void SaveTheme(AppTheme theme)
        {
            try
            {
                SaveTheme(theme, TryGetThemeConfigPath() ?? string.Empty, GetFallbackThemeConfigPath());
            }
            catch
            {
                // Best-effort persistence (e.g. read-only media).
            }
        }

        internal static void SaveTheme(AppTheme theme, string primaryPath, string? fallbackPath)
        {
            if (TryWriteThemeFile(primaryPath, theme))
                return;

            TryWriteThemeFile(fallbackPath, theme);
        }

        private static bool TryParseTheme(string? raw, out AppTheme theme)
        {
            var trimmed = raw?.Trim();
            if (string.Equals(trimmed, "Dark", StringComparison.OrdinalIgnoreCase))
            {
                theme = AppTheme.Dark;
                return true;
            }

            if (string.Equals(trimmed, "Light", StringComparison.OrdinalIgnoreCase))
            {
                theme = AppTheme.Light;
                return true;
            }

            theme = AppTheme.Light;
            return false;
        }

        private static bool TryReadThemeFile(string path, out AppTheme theme)
        {
            theme = AppTheme.Light;
            try
            {
                if (!File.Exists(path))
                    return false;

                var text = File.ReadAllText(path);
                return TryParseTheme(text, out theme);
            }
            catch
            {
                return false;
            }
        }

        private static bool CanWriteExistingFile(string path)
        {
            try
            {
                if ((File.GetAttributes(path) & FileAttributes.ReadOnly) != 0)
                    return false;

                using var stream = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite);
                return stream.CanWrite;
            }
            catch
            {
                return false;
            }
        }

        private static bool TryWriteThemeFile(string? path, AppTheme theme)
        {
            if (string.IsNullOrWhiteSpace(path))
                return false;

            try
            {
                var dir = Path.GetDirectoryName(path);
                if (!string.IsNullOrEmpty(dir))
                    Directory.CreateDirectory(dir);

                File.WriteAllText(path, theme == AppTheme.Dark ? "Dark" : "Light", Utf8NoBom);
                return true;
            }
            catch
            {
                return false;
            }
        }

        public static void ApplyTheme(AppTheme theme)
        {
            CurrentTheme = theme;
            var resources = Application.Current?.Resources;
            if (resources == null)
            {
                ThemeChanged?.Invoke(null, theme);
                return;
            }

            var palette = theme == AppTheme.Dark ? DarkPalette : LightPalette;
            foreach (var pair in palette)
            {
                if (resources[pair.Key] is SolidColorBrush existing && !existing.IsFrozen)
                {
                    existing.Color = pair.Value;
                }
                else
                {
                    resources[pair.Key] = new SolidColorBrush(pair.Value);
                }
            }

            ThemeChanged?.Invoke(null, theme);
        }

        public static Brush GetBrush(string key, Brush fallback)
        {
            if (Application.Current?.TryFindResource(key) is Brush brush)
                return brush;
            return fallback;
        }
    }
}
