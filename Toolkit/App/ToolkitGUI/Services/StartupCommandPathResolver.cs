using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace ToolkitGUI.Services
{
    /// <summary>
    /// Resolves a startup/service command line to a concrete file path for Explorer / CST.
    /// Prefers -File script targets when the host is an interpreter (powershell, cmd, wscript, etc.).
    /// </summary>
    internal static class StartupCommandPathResolver
    {
        private static readonly Regex QuotedPathRegex = new(
            "\"(?<path>[^\"]+)\"",
            RegexOptions.Compiled);

        private static readonly Regex FileSwitchRegex = new(
            @"(?i)(?:^|\s)(?:-File|/File|-f)\s+(?:""(?<q>[^""]+)""|(?<u>\S+))",
            RegexOptions.Compiled);

        private static readonly Regex AbsoluteExeRegex = new(
            @"^(?<exe>[A-Za-z]:\\.+?\.(?:exe|dll|com|bat|cmd|scr|msi|sys|ps1|vbs|js|wsf|lnk))\b",
            RegexOptions.IgnoreCase | RegexOptions.Compiled);

        public static string? TryResolveExistingFile(string? commandOrPath)
        {
            var all = CollectExistingFiles(commandOrPath);
            return all.Count > 0 ? all[0] : null;
        }

        /// <summary>
        /// Collects all existing leaf paths for a startup command: payload first, then host, then other quoted paths.
        /// </summary>
        public static IReadOnlyList<string> CollectExistingFiles(string? commandOrPath)
        {
            var results = new List<string>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (string.IsNullOrWhiteSpace(commandOrPath))
                return results;

            var raw = commandOrPath.Trim();
            if (raw.Equals("(missing or empty)", StringComparison.OrdinalIgnoreCase))
                return results;

            void Add(string? path)
            {
                if (string.IsNullOrWhiteSpace(path))
                    return;
                var normalized = TryNormalizeExistingLeaf(path);
                if (normalized != null && seen.Add(normalized))
                    results.Add(normalized);
            }

            // Prefer script/payload after interpreter switches.
            Add(TryExtractFileSwitchTarget(raw));

            if (raw.StartsWith('"'))
            {
                var parts = raw.Split('"');
                if (parts.Length >= 2)
                    Add(parts[1]);
            }

            Add(raw);

            var (exe, args) = SplitCommandLine(raw);
            var resolvedExe = TryNormalizeExistingLeaf(exe);
            if (resolvedExe != null)
            {
                if (IsInterpreter(resolvedExe) && !string.IsNullOrWhiteSpace(args))
                    Add(TryExtractPayloadFromArguments(args));
                Add(resolvedExe);
            }
            else if (!string.IsNullOrWhiteSpace(exe) && exe.IndexOfAny(new[] { '\\', '/' }) < 0)
            {
                var onPath = FindOnPath(exe);
                if (onPath != null)
                {
                    if (IsInterpreter(onPath) && !string.IsNullOrWhiteSpace(args))
                        Add(TryExtractPayloadFromArguments(args));
                    Add(onPath);
                }
            }

            foreach (Match match in QuotedPathRegex.Matches(raw))
                Add(match.Groups["path"].Value);

            // Re-order: non-interpreter payloads first.
            return results
                .OrderBy(p => IsInterpreter(p) ? 1 : 0)
                .ThenBy(p => p, StringComparer.OrdinalIgnoreCase)
                .ToList();
        }

        private static string? TryExtractFileSwitchTarget(string command)
        {
            var match = FileSwitchRegex.Match(command);
            if (!match.Success)
                return null;

            if (match.Groups["q"].Success)
                return match.Groups["q"].Value;
            if (match.Groups["u"].Success)
                return match.Groups["u"].Value.TrimEnd(',', ';');
            return null;
        }

        private static string? TryExtractPayloadFromArguments(string args)
        {
            var fileSwitch = TryExtractFileSwitchTarget(args);
            if (!string.IsNullOrWhiteSpace(fileSwitch))
            {
                var resolved = TryNormalizeExistingLeaf(fileSwitch);
                if (resolved != null)
                    return resolved;
            }

            foreach (Match match in QuotedPathRegex.Matches(args))
            {
                var candidate = TryNormalizeExistingLeaf(match.Groups["path"].Value);
                if (candidate != null)
                    return candidate;
            }

            return null;
        }

        private static (string Exe, string Args) SplitCommandLine(string command)
        {
            var trimmed = command.Trim();
            if (trimmed.StartsWith('"'))
            {
                var parts = trimmed.Split('"');
                if (parts.Length >= 2)
                {
                    var exe = parts[1].TrimEnd(',');
                    var args = parts.Length >= 3
                        ? string.Join("\"", parts, 2, parts.Length - 2).Trim()
                        : string.Empty;
                    return (exe, args);
                }
            }

            var abs = AbsoluteExeRegex.Match(trimmed);
            if (abs.Success)
            {
                var exe = abs.Groups["exe"].Value;
                var args = trimmed.Length > exe.Length ? trimmed.Substring(exe.Length).Trim() : string.Empty;
                return (exe, args);
            }

            var space = trimmed.IndexOf(' ');
            if (space < 0)
                return (trimmed.TrimEnd(','), string.Empty);

            return (trimmed.Substring(0, space).TrimEnd(','), trimmed.Substring(space + 1).Trim());
        }

        private static string? TryNormalizeExistingLeaf(string? path)
        {
            if (string.IsNullOrWhiteSpace(path))
                return null;

            var expanded = Environment.ExpandEnvironmentVariables(path.Trim().Trim('"'));
            if (string.IsNullOrWhiteSpace(expanded))
                return null;

            try
            {
                if (File.Exists(expanded))
                    return Path.GetFullPath(expanded);

                // .lnk: return the shortcut itself so Explorer can select it;
                // CST can still scan the .lnk if needed.
                if (expanded.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase) && File.Exists(expanded))
                    return Path.GetFullPath(expanded);
            }
            catch
            {
                // ignore invalid path characters
            }

            return null;
        }

        private static bool IsInterpreter(string path)
        {
            var name = Path.GetFileNameWithoutExtension(path);
            return name.Equals("powershell", StringComparison.OrdinalIgnoreCase)
                || name.Equals("pwsh", StringComparison.OrdinalIgnoreCase)
                || name.Equals("cmd", StringComparison.OrdinalIgnoreCase)
                || name.Equals("wscript", StringComparison.OrdinalIgnoreCase)
                || name.Equals("cscript", StringComparison.OrdinalIgnoreCase)
                || name.Equals("mshta", StringComparison.OrdinalIgnoreCase)
                || name.Equals("rundll32", StringComparison.OrdinalIgnoreCase);
        }

        private static string? FindOnPath(string exeName)
        {
            var lookup = exeName.IndexOf('.') >= 0 ? exeName : exeName + ".exe";
            var pathEnv = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
            foreach (var dir in pathEnv.Split(';', StringSplitOptions.RemoveEmptyEntries))
            {
                try
                {
                    var candidate = Path.Combine(dir.Trim(), lookup);
                    if (File.Exists(candidate))
                        return Path.GetFullPath(candidate);
                }
                catch
                {
                    // skip bad PATH entries
                }
            }

            return null;
        }
    }
}
