using System;
using System.Collections.Generic;
using System.IO;

namespace ToolkitGUI
{
    internal sealed class RuntimeConfigContext
    {
        public static RuntimeConfigContext Current { get; private set; } = new();

        public string Language { get; init; } = "en-US";
        public string Skin { get; init; } = "CDE";
        public bool ShowSplash { get; init; } = false;
        public string LogLevel { get; init; } = "Info";

        public static RuntimeConfigContext Load(string? toolkitRoot)
        {
            var defaults = new RuntimeConfigContext();
            if (string.IsNullOrWhiteSpace(toolkitRoot))
            {
                Current = defaults;
                return defaults;
            }

            var cfgPath = Path.Combine(toolkitRoot, "Config", "global.ini");
            if (!File.Exists(cfgPath))
            {
                Current = defaults;
                return defaults;
            }

            var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var rawLine in File.ReadAllLines(cfgPath))
            {
                var line = rawLine.Trim();
                if (line.Length == 0 || line.StartsWith(";", StringComparison.Ordinal) || line.StartsWith("#", StringComparison.Ordinal))
                    continue;
                if (line.StartsWith("[", StringComparison.Ordinal) && line.EndsWith("]", StringComparison.Ordinal))
                    continue;

                var idx = line.IndexOf('=');
                if (idx <= 0)
                    continue;

                var key = line[..idx].Trim();
                var value = line[(idx + 1)..].Trim();
                if (key.Length > 0)
                    map[key] = value;
            }

            var loaded = new RuntimeConfigContext
            {
                Language = map.TryGetValue("Language", out var language) && language.Length > 0 ? language : defaults.Language,
                Skin = map.TryGetValue("Skin", out var skin) && skin.Length > 0 ? skin : defaults.Skin,
                ShowSplash = ParseBool(map, "ShowSplash", defaults.ShowSplash),
                LogLevel = map.TryGetValue("LogLevel", out var logLevel) && logLevel.Length > 0 ? logLevel : defaults.LogLevel
            };

            Current = loaded;
            return loaded;
        }

        private static bool ParseBool(IReadOnlyDictionary<string, string> map, string key, bool fallback)
        {
            if (!map.TryGetValue(key, out var value))
                return fallback;
            return bool.TryParse(value, out var parsed) ? parsed : fallback;
        }
    }
}
