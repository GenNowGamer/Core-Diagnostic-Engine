using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ToolkitGUI.Services
{
    internal static class WorkflowResultFormatter
    {
        private static readonly Regex StartupAuditLineRegex = new(
            @"^\[(?<tag>OK|REVIEW)\]\s*\[(?<location>[^\]]+)\]\s*(?<body>.+)$",
            RegexOptions.Compiled | RegexOptions.IgnoreCase);

        private static readonly Regex CountSummaryRegex = new(
            @"^Total:\s*(?<total>\d+)\s*\|\s*Review:\s*(?<review>\d+)\s*\|\s*OK:\s*(?<ok>\d+)\s*$",
            RegexOptions.Compiled | RegexOptions.IgnoreCase);

        private static readonly Regex GenericCountRegex = new(
            @"^(?<label>[A-Za-z][A-Za-z0-9 /()%-]+):\s*(?<value>.+)$",
            RegexOptions.Compiled);

        private static readonly Regex KeyValueRegex = new(
            @"^(?<label>.+?)\s{2,}:\s*(?<value>.+)$",
            RegexOptions.Compiled);

        private static readonly Regex LooseKeyValueRegex = new(
            @"^(?<label>[^:]+):\s*(?<value>.+)$",
            RegexOptions.Compiled);

        private static readonly Regex ProblemLineRegex = new(
            @"^\[!\]\s*(?<title>.+)$",
            RegexOptions.Compiled);

        private static readonly Regex SectionHeaderRegex = new(
            @"^[A-Z][A-Z0-9 &'()/%-]{2,}$",
            RegexOptions.Compiled);

        private static readonly Regex SeparatorLineRegex = new(
            @"^[=]{3,}$|^[-]{3,}$",
            RegexOptions.Compiled);

        private static readonly Regex TableSeparatorRegex = new(
            @"^[-\s]{8,}$",
            RegexOptions.Compiled);

        private static readonly Regex InternalProtocolRegex = new(
            @"^\[(POSTOP:STARTUP|AUDIT:EVENT|HEALTH:PHASE|HEALTH:RECOMMENDATION)\]",
            RegexOptions.Compiled | RegexOptions.IgnoreCase);

        private static readonly Regex CstSectionUnderlineRegex = new(
            @"^[-=]{3,}$",
            RegexOptions.Compiled);

        private static readonly Regex CstFindingHeaderRegex = new(
            @"^\[(?<type>[^\]]+)\]\s*(?<title>.+)$",
            RegexOptions.Compiled);

        private static readonly Regex GroupBlockHeaderRegex = new(
            @"^(?<kind>ADAPTER|GPU|EXTENSION|STORE|TASK|PROGRAM|DRIVER|DEVICE|SERVICE|INTERFACE|PARTITION|EVENT|ENTRY|HOST|DRIVE|MODULE|CPU|SUMMARY|UNSIGNED|SYSTEM|PROCESSOR|MEMORY|BOARD|UPDATE|GROUP)\s+(?<index>\d+)\s*:\s*(?<name>.+)$",
            RegexOptions.Compiled | RegexOptions.IgnoreCase);

        private static readonly HashSet<string> GroupedHealthCheckSteps = new(StringComparer.OrdinalIgnoreCase)
        {
            "OSVersion",
            "CPULoad",
            "RAM",
            "DiskSpace",
            "Activation",
            "EventLogErrors",
            "SystemInfo",
            "DriverAudit",
            "WindowsUpdateService",
            "NetworkAdapters",
            "GPUInfo",
            "CriticalEvents",
            "InstalledSoftware",
            "Drivers",
            "PnPDevices",
            "Services",
            "NetworkConfig",
            "EventLogs",
            "PartitionTable",
            "AutorunsAudit",
            "HostsFile",
            "BrowserExtensionScan",
            "ScheduledTasksAudit"
        };

        public static FormattedWorkflowOutput Format(string? stepName, string? output)
        {
            if (string.IsNullOrWhiteSpace(output))
            {
                return new FormattedWorkflowOutput
                {
                    Overview = "No additional detail was recorded for this step."
                };
            }

            if (string.Equals(stepName, "StartupAudit", StringComparison.OrdinalIgnoreCase))
            {
                return FormatStartupAudit(output);
            }

            if (string.Equals(stepName, "CoreSecurityTool", StringComparison.OrdinalIgnoreCase)
                || LooksLikeCoreSecurityToolReport(output))
            {
                return FormatCoreSecurityTool(output);
            }

            if (UsesGroupedPropertySections(stepName))
            {
                return FormatGroupBlockOutput(stepName, output);
            }

            return FormatGenericOutput(stepName, output);
        }

        public static bool UsesGroupedPropertySections(string? stepName)
            => !string.IsNullOrWhiteSpace(stepName) && GroupedHealthCheckSteps.Contains(stepName.Trim());

        public static bool UsesDeviceGroupedSections(string? stepName)
            => UsesGroupedPropertySections(stepName);

        public static string BuildOverview(string? stepName, string? output)
            => Format(stepName, output).Overview;

        private static FormattedWorkflowOutput FormatStartupAudit(string output)
        {
            var lines = SplitLines(output);
            var overview = string.Empty;
            var items = new List<FormattedResultItem>();
            var reviewItems = new List<FormattedResultItem>();
            var okItems = new List<FormattedResultItem>();

            foreach (var line in lines)
            {
                if (InternalProtocolRegex.IsMatch(line))
                {
                    continue;
                }

                var countMatch = CountSummaryRegex.Match(line);
                if (countMatch.Success)
                {
                    var total = countMatch.Groups["total"].Value;
                    var review = countMatch.Groups["review"].Value;
                    var ok = countMatch.Groups["ok"].Value;
                    overview = review != "0"
                        ? $"Audited {total} startup entries. {review} need review; {ok} look normal."
                        : $"Audited {total} startup entries. All {ok} entries look normal.";
                    continue;
                }

                if (!TryParseStartupAuditLine(line, out var item))
                {
                    continue;
                }

                if (item.Status == FormattedItemStatus.Review)
                {
                    reviewItems.Add(item);
                }
                else
                {
                    okItems.Add(item);
                }
            }

            items.AddRange(reviewItems);
            items.AddRange(okItems);

            if (string.IsNullOrWhiteSpace(overview))
            {
                overview = reviewItems.Count > 0
                    ? $"{reviewItems.Count} startup entr{(reviewItems.Count == 1 ? "y needs" : "ies need")} review."
                    : items.Count > 0
                        ? $"{items.Count} startup entr{(items.Count == 1 ? "y" : "ies")} audited."
                        : "Startup audit completed.";
            }

            var sections = new List<FormattedResultSection>();
            if (reviewItems.Count > 0)
            {
                sections.Add(new FormattedResultSection
                {
                    Title = "Entries to review",
                    Items = reviewItems
                });
            }

            if (okItems.Count > 0)
            {
                sections.Add(new FormattedResultSection
                {
                    Title = reviewItems.Count > 0 ? "Verified entries" : "Startup entries",
                    Items = okItems
                });
            }

            return new FormattedWorkflowOutput
            {
                Overview = overview,
                Sections = sections,
                AllItems = items
            };
        }

        private static FormattedWorkflowOutput FormatEventLogs(string? stepName, string output)
        {
            var lines = SplitLines(output);
            var items = new List<FormattedResultItem>();
            var prose = new List<string>();

            foreach (var line in lines)
            {
                if (TryParseAuditEventLine(line, out var item))
                {
                    items.Add(item);
                    continue;
                }

                if (!string.IsNullOrWhiteSpace(line)
                    && !InternalProtocolRegex.IsMatch(line))
                {
                    prose.Add(line);
                }
            }

            var overview = items.Count > 0
                ? $"Found {items.Count} distinct error event group{(items.Count == 1 ? string.Empty : "s")} in the last 24 hours."
                : prose.FirstOrDefault() ?? "No critical or error events were found in the last 24 hours.";

            var sections = new List<FormattedResultSection>();
            if (items.Count > 0)
            {
                sections.Add(new FormattedResultSection
                {
                    Title = "Event log errors",
                    Items = items
                });
            }

            if (prose.Count > 0)
            {
                sections.Add(new FormattedResultSection
                {
                    Title = "Summary",
                    Lines = prose
                });
            }

            return new FormattedWorkflowOutput
            {
                Overview = overview,
                Sections = sections,
                AllItems = items
            };
        }

        private static bool LooksLikeCoreSecurityToolReport(string output)
        {
            if (string.IsNullOrWhiteSpace(output))
            {
                return false;
            }

            return output.Contains("CORE SECURITY TOOL", StringComparison.OrdinalIgnoreCase)
                && output.Contains("TOP FINDINGS", StringComparison.OrdinalIgnoreCase);
        }

        private static FormattedWorkflowOutput FormatCoreSecurityTool(string output)
        {
            var lines = SplitLines(output);
            var sections = new List<FormattedResultSection>();
            var allItems = new List<FormattedResultItem>();
            var overviewParts = new List<string>();

            var currentTitle = "Scan summary";
            var currentLines = new List<string>();
            var currentItems = new List<FormattedResultItem>();
            FormattedResultItem? pendingFinding = null;
            var findingDetails = new List<string>();

            void FlushFinding()
            {
                if (pendingFinding == null)
                {
                    return;
                }

                string? path = null;
                var remainingDetails = new List<string>();
                foreach (var detail in findingDetails)
                {
                    if (TryParseKeyValueLine(detail, out var label, out var value)
                        && label.Equals("Location", StringComparison.OrdinalIgnoreCase))
                    {
                        path = value;
                        continue;
                    }

                    remainingDetails.Add(detail);
                }

                var finding = new FormattedResultItem
                {
                    Status = pendingFinding.Status,
                    StatusLabel = pendingFinding.StatusLabel,
                    Title = pendingFinding.Title,
                    Path = path,
                    Notes = remainingDetails.Count > 0 ? string.Join(Environment.NewLine, remainingDetails) : null
                };
                currentItems.Add(finding);
                allItems.Add(finding);
                pendingFinding = null;
                findingDetails.Clear();
            }

            void FlushSection()
            {
                FlushFinding();
                if (currentLines.Count == 0 && currentItems.Count == 0)
                {
                    return;
                }

                sections.Add(new FormattedResultSection
                {
                    Title = currentTitle,
                    Lines = currentLines.ToList(),
                    Items = currentItems.ToList()
                });
                currentLines.Clear();
                currentItems.Clear();
            }

            for (var i = 0; i < lines.Count; i++)
            {
                var line = lines[i];
                if (CstSectionUnderlineRegex.IsMatch(line))
                {
                    continue;
                }

                if (i + 1 < lines.Count
                    && CstSectionUnderlineRegex.IsMatch(lines[i + 1])
                    && !line.Contains(':')
                    && line.Length >= 3)
                {
                    FlushSection();
                    currentTitle = TitleCaseHeader(line);
                    i++;
                    continue;
                }

                var findingMatch = CstFindingHeaderRegex.Match(line);
                if (findingMatch.Success)
                {
                    FlushFinding();
                    var type = findingMatch.Groups["type"].Value.Trim();
                    pendingFinding = new FormattedResultItem
                    {
                        Status = MapCstFindingType(type),
                        StatusLabel = type,
                        Title = findingMatch.Groups["title"].Value.Trim()
                    };
                    continue;
                }

                if (pendingFinding != null && line.StartsWith("  ", StringComparison.Ordinal))
                {
                    findingDetails.Add(line.Trim());
                    continue;
                }

                if (pendingFinding != null)
                {
                    FlushFinding();
                }

                if (TryParseKeyValueLine(line, out var label, out var value))
                {
                    if (overviewParts.Count < 6)
                    {
                        overviewParts.Add($"{label}: {value}");
                    }

                    currentLines.Add(line);
                    continue;
                }

                if (line.StartsWith("CORE SECURITY TOOL", StringComparison.OrdinalIgnoreCase))
                {
                    currentLines.Add(line);
                    continue;
                }

                currentLines.Add(line);
            }

            FlushSection();

            var overview = overviewParts.Count > 0
                ? string.Join(" · ", overviewParts.Take(6))
                : BuildGenericOverview("CoreSecurityTool", sections, allItems);

            return new FormattedWorkflowOutput
            {
                Overview = overview,
                Sections = sections,
                AllItems = allItems
            };
        }

        private static FormattedItemStatus MapCstFindingType(string type)
        {
            if (type.Equals("Malware", StringComparison.OrdinalIgnoreCase))
            {
                return FormattedItemStatus.Fail;
            }

            if (type.Equals("Suspicious", StringComparison.OrdinalIgnoreCase))
            {
                return FormattedItemStatus.Review;
            }

            if (type.Equals("PUP", StringComparison.OrdinalIgnoreCase)
                || type.Equals("PUM", StringComparison.OrdinalIgnoreCase))
            {
                return FormattedItemStatus.Warning;
            }

            return FormattedItemStatus.Info;
        }

        private static FormattedWorkflowOutput FormatGroupBlockOutput(string? stepName, string output)
        {
            var lines = SplitLines(output);
            var sections = new List<FormattedResultSection>();
            var overviewParts = new List<string>();

            string? currentTitle = null;
            var currentLines = new List<string>();

            void Flush()
            {
                if (string.IsNullOrWhiteSpace(currentTitle) || currentLines.Count == 0)
                {
                    currentTitle = null;
                    currentLines.Clear();
                    return;
                }

                sections.Add(new FormattedResultSection
                {
                    Title = currentTitle,
                    Lines = currentLines.ToList()
                });
                currentTitle = null;
                currentLines.Clear();
            }

            foreach (var line in lines)
            {
                if (InternalProtocolRegex.IsMatch(line))
                {
                    continue;
                }

                if (SeparatorLineRegex.IsMatch(line))
                {
                    continue;
                }

                var groupMatch = GroupBlockHeaderRegex.Match(line);
                if (groupMatch.Success)
                {
                    Flush();
                    var index = groupMatch.Groups["index"].Value;
                    var name = groupMatch.Groups["name"].Value.Trim();
                    var kind = groupMatch.Groups["kind"].Value;

                    currentTitle = string.Equals(kind, "GPU", StringComparison.OrdinalIgnoreCase)
                        ? $"GPU {index}: {name}"
                        : name;
                    continue;
                }

                if (SectionHeaderRegex.IsMatch(line) && !line.Contains(':', StringComparison.Ordinal))
                {
                    continue;
                }

                if (line.StartsWith("Recommendation:", StringComparison.OrdinalIgnoreCase))
                {
                    overviewParts.Add(line);
                    continue;
                }

                if (!TryParseLooseKeyValue(line, out var label, out var value))
                {
                    if (currentTitle == null
                        && (line.StartsWith("No ", StringComparison.OrdinalIgnoreCase)
                            || line.StartsWith("Not applicable", StringComparison.OrdinalIgnoreCase)))
                    {
                        overviewParts.Add(line);
                    }

                    continue;
                }

                if (IsGroupScopeSummaryLabel(label))
                {
                    overviewParts.Add($"{label.Trim()}: {value.Trim()}");
                    continue;
                }

                if (currentTitle != null)
                {
                    currentLines.Add($"{label.Trim()}: {value.Trim()}");
                }
            }

            Flush();

            var overview = overviewParts.Count > 0
                ? string.Join(" · ", overviewParts)
                : BuildGroupBlockOverview(stepName, sections.Count);

            return new FormattedWorkflowOutput
            {
                Overview = overview,
                Sections = sections
            };
        }

        private static bool IsGroupScopeSummaryLabel(string label)
        {
            var trimmed = label.Trim();
            if (trimmed.Length == 0)
            {
                return false;
            }

            if (trimmed.StartsWith("Total ", StringComparison.OrdinalIgnoreCase)
                || trimmed.EndsWith(" Found", StringComparison.OrdinalIgnoreCase)
                || trimmed.Contains("in scope", StringComparison.OrdinalIgnoreCase)
                || trimmed.Contains("Events (", StringComparison.OrdinalIgnoreCase)
                || trimmed.StartsWith("Low space warning", StringComparison.OrdinalIgnoreCase)
                || trimmed.StartsWith("Scope", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            return trimmed.Equals("Adapters in scope", StringComparison.OrdinalIgnoreCase)
                || trimmed.Equals("Adapters found", StringComparison.OrdinalIgnoreCase)
                || trimmed.Equals("Extension Stores Found", StringComparison.OrdinalIgnoreCase)
                || trimmed.Equals("Profiles Found", StringComparison.OrdinalIgnoreCase)
                || trimmed.Equals("Installed Extensions", StringComparison.OrdinalIgnoreCase)
                || trimmed.Equals("Custom (Non-Microsoft) Tasks", StringComparison.OrdinalIgnoreCase)
                || trimmed.Equals("Suspicious Tasks", StringComparison.OrdinalIgnoreCase)
                || trimmed.Equals("Auto-Start Stopped", StringComparison.OrdinalIgnoreCase)
                || trimmed.Equals("Currently Stopped", StringComparison.OrdinalIgnoreCase)
                || trimmed.Equals("Devices needing attention", StringComparison.OrdinalIgnoreCase)
                || trimmed.Equals("Present devices excluded from scope", StringComparison.OrdinalIgnoreCase)
                || trimmed.Equals("Signed drivers in scope", StringComparison.OrdinalIgnoreCase)
                || trimmed.Equals("Unsigned drivers", StringComparison.OrdinalIgnoreCase)
                || trimmed.Equals("Error count", StringComparison.OrdinalIgnoreCase)
                || trimmed.Equals("Events captured", StringComparison.OrdinalIgnoreCase)
                || trimmed.Equals("Grouped signatures", StringComparison.OrdinalIgnoreCase)
                || trimmed.Equals("Registry Entries", StringComparison.OrdinalIgnoreCase)
                || trimmed.Equals("Startup Folder Items", StringComparison.OrdinalIgnoreCase)
                || trimmed.Equals("Suspicious Entries", StringComparison.OrdinalIgnoreCase)
                || trimmed.Equals("Hosts File Location", StringComparison.OrdinalIgnoreCase)
                || trimmed.Equals("Non-Default Entries", StringComparison.OrdinalIgnoreCase)
                || trimmed.Equals("File-system drives", StringComparison.OrdinalIgnoreCase)
                || trimmed.Equals("Summary", StringComparison.OrdinalIgnoreCase);
        }

        private static bool TryParseLooseKeyValue(string line, out string label, out string value)
        {
            label = string.Empty;
            value = string.Empty;

            var match = KeyValueRegex.Match(line);
            if (!match.Success)
            {
                match = LooseKeyValueRegex.Match(line);
            }

            if (!match.Success)
            {
                return false;
            }

            label = match.Groups["label"].Value;
            value = match.Groups["value"].Value;
            return true;
        }

        private static string BuildGroupBlockOverview(string? stepName, int sectionCount)
        {
            var title = ResolveStepTitle(stepName);
            if (sectionCount <= 0)
            {
                return $"{title} completed.";
            }

            return sectionCount == 1
                ? $"{title}: 1 item captured."
                : $"{title}: {sectionCount} items captured.";
        }

        private static FormattedWorkflowOutput FormatGenericOutput(string? stepName, string output)
        {
            var lines = SplitLines(output);
            var sections = new List<FormattedResultSection>();
            var allItems = new List<FormattedResultItem>();
            var overviewParts = new List<string>();

            FormattedResultSection? currentSection = null;
            var currentLines = new List<string>();
            var currentItems = new List<FormattedResultItem>();
            var inTable = false;

            void FlushSection()
            {
                if (currentSection == null
                    && currentItems.Count == 0
                    && currentLines.Count == 0)
                {
                    return;
                }

                sections.Add(new FormattedResultSection
                {
                    Title = currentSection?.Title ?? string.Empty,
                    Items = currentItems.ToList(),
                    Lines = currentLines.ToList()
                });
                allItems.AddRange(currentItems);
                currentItems.Clear();
                currentLines.Clear();
                currentSection = null;
                inTable = false;
            }

            for (var i = 0; i < lines.Count; i++)
            {
                var line = lines[i];
                if (string.IsNullOrWhiteSpace(line))
                {
                    continue;
                }

                if (InternalProtocolRegex.IsMatch(line))
                {
                    continue;
                }

                if (SeparatorLineRegex.IsMatch(line))
                {
                    continue;
                }

                if (CountSummaryRegex.IsMatch(line))
                {
                    overviewParts.Add(TranslateCountSummary(line));
                    currentLines.Add(TranslateCountSummary(line));
                    continue;
                }

                if (TryParseStartupAuditLine(line, out var startupItem))
                {
                    currentItems.Add(startupItem);
                    continue;
                }

                var problemMatch = ProblemLineRegex.Match(line);
                if (problemMatch.Success)
                {
                    currentItems.Add(new FormattedResultItem
                    {
                        Status = FormattedItemStatus.Warning,
                        StatusLabel = "Attention",
                        Title = problemMatch.Groups["title"].Value.Trim()
                    });
                    continue;
                }

                if (IsSectionHeader(line, i, lines))
                {
                    FlushSection();
                    currentSection = new FormattedResultSection { Title = TitleCaseHeader(line) };
                    continue;
                }

                if (TryParseKeyValueLine(line, out var label, out var value))
                {
                    currentItems.Add(new FormattedResultItem
                    {
                        Status = FormattedItemStatus.Info,
                        StatusLabel = "Detail",
                        Title = label,
                        Subtitle = value
                    });
                    continue;
                }

                if (i + 1 < lines.Count && TableSeparatorRegex.IsMatch(lines[i + 1]))
                {
                    inTable = true;
                    i++;
                    continue;
                }

                if (inTable)
                {
                    if (TableSeparatorRegex.IsMatch(line))
                    {
                        continue;
                    }

                    var fixedRow = string.Equals(stepName, "InstalledSoftware", StringComparison.OrdinalIgnoreCase)
                        ? ParseInstalledSoftwareTableRow(line)
                        : ParseFixedWidthTableRow(line);
                    if (fixedRow != null)
                    {
                        currentItems.Add(fixedRow);
                        continue;
                    }

                    inTable = false;
                }

                if (GenericCountRegex.IsMatch(line) && line.Length < 120)
                {
                    overviewParts.Add(TranslateGenericCount(line));
                    currentLines.Add(TranslateGenericCount(line));
                    continue;
                }

                currentLines.Add(line);
            }

            FlushSection();

            if (sections.Count == 0 && lines.Count > 0)
            {
                sections.Add(new FormattedResultSection
                {
                    Title = ResolveStepTitle(stepName),
                    Lines = lines.Where(l => !InternalProtocolRegex.IsMatch(l)).ToList()
                });
            }

            var overview = overviewParts.FirstOrDefault()
                ?? BuildGenericOverview(stepName, sections, allItems);

            return new FormattedWorkflowOutput
            {
                Overview = overview,
                Sections = sections,
                AllItems = allItems
            };
        }

        private static bool TryParseStartupAuditLine(string line, out FormattedResultItem item)
        {
            item = new FormattedResultItem();
            var match = StartupAuditLineRegex.Match(line);
            if (!match.Success)
            {
                return false;
            }

            var tag = match.Groups["tag"].Value;
            var location = match.Groups["location"].Value.Trim();
            var body = match.Groups["body"].Value.Trim();

            var lastSep = body.LastIndexOf(" — ", StringComparison.Ordinal);
            if (lastSep < 0)
            {
                lastSep = body.LastIndexOf(" - ", StringComparison.Ordinal);
            }

            string name;
            string riskPart;
            string path;

            if (lastSep < 0)
            {
                name = body;
                riskPart = string.Empty;
                path = string.Empty;
            }
            else
            {
                path = body[(lastSep + 3)..].Trim();
                var rest = body[..lastSep];
                var midSep = rest.IndexOf(" — ", StringComparison.Ordinal);
                if (midSep < 0)
                {
                    midSep = rest.IndexOf(" - ", StringComparison.Ordinal);
                }

                if (midSep < 0)
                {
                    name = rest.Trim();
                    riskPart = string.Empty;
                }
                else
                {
                    name = rest[..midSep].Trim();
                    riskPart = rest[(midSep + 3)..].Trim();
                }
            }

            var risk = riskPart;
            var reasons = string.Empty;
            var paren = riskPart.IndexOf(" (", StringComparison.Ordinal);
            if (paren > 0 && riskPart.EndsWith(')'))
            {
                risk = riskPart[..paren].Trim();
                reasons = riskPart[(paren + 2)..^1].Trim();
            }

            var isReview = tag.Equals("REVIEW", StringComparison.OrdinalIgnoreCase);
            var notes = new List<string>();
            if (!string.IsNullOrWhiteSpace(risk))
            {
                notes.Add($"Trust band: {risk}");
            }

            if (!string.IsNullOrWhiteSpace(reasons))
            {
                notes.Add(reasons);
            }

            item = new FormattedResultItem
            {
                Status = isReview ? FormattedItemStatus.Review : FormattedItemStatus.Ok,
                StatusLabel = isReview ? "Needs review" : "Verified OK",
                Title = name,
                Location = FormatRegistryLocation(location),
                Path = path,
                Notes = notes.Count > 0 ? string.Join(" · ", notes) : null
            };
            return true;
        }

        private static bool TryParseAuditEventLine(string line, out FormattedResultItem item)
        {
            item = new FormattedResultItem();
            var markerIdx = line.IndexOf("[AUDIT:EVENT]", StringComparison.OrdinalIgnoreCase);
            if (markerIdx < 0)
            {
                return false;
            }

            var jsonStart = line.IndexOf('{', markerIdx);
            if (jsonStart < 0)
            {
                return false;
            }

            try
            {
                using var doc = JsonDocument.Parse(line[jsonStart..]);
                var root = doc.RootElement;
                var log = root.TryGetProperty("logName", out var logEl) ? logEl.GetString() ?? "Event" : "Event";
                var source = root.TryGetProperty("source", out var srcEl) ? srcEl.GetString() ?? "Unknown" : "Unknown";
                var eventId = root.TryGetProperty("eventId", out var idEl) && idEl.TryGetInt32(out var id) ? id : 0;
                var message = root.TryGetProperty("message", out var msgEl) ? msgEl.GetString() ?? string.Empty : string.Empty;
                var count = root.TryGetProperty("occurrenceCount", out var countEl) && countEl.TryGetInt32(out var c) ? c : 1;

                var title = eventId > 0 ? $"{log} · {source} (Event {eventId})" : $"{log} · {source}";
                var notes = message;
                if (count > 1)
                {
                    notes = $"{message} ({count} occurrences in the last 24 hours)";
                }

                item = new FormattedResultItem
                {
                    Status = FormattedItemStatus.Fail,
                    StatusLabel = "Error",
                    Title = title,
                    Notes = notes
                };
                return true;
            }
            catch
            {
                return false;
            }
        }

        private static bool IsSectionHeader(string line, int index, IReadOnlyList<string> lines)
        {
            if (!SectionHeaderRegex.IsMatch(line))
            {
                return false;
            }

            if (index + 1 < lines.Count && SeparatorLineRegex.IsMatch(lines[index + 1]))
            {
                return true;
            }

            return line.Length >= 4
                && line == line.ToUpperInvariant()
                && !line.Contains(':')
                && !line.StartsWith('[');
        }

        private static bool TryParseKeyValueLine(string line, out string label, out string value)
        {
            label = string.Empty;
            value = string.Empty;

            var match = KeyValueRegex.Match(line);
            if (!match.Success)
            {
                match = LooseKeyValueRegex.Match(line);
            }

            if (!match.Success)
            {
                return false;
            }

            label = match.Groups["label"].Value.Trim();
            value = match.Groups["value"].Value.Trim();

            if (string.IsNullOrWhiteSpace(label) || string.IsNullOrWhiteSpace(value))
            {
                return false;
            }

            if (label.Length > 80 || value.Length > 500)
            {
                return false;
            }

            if (label.Contains('[') || TableSeparatorRegex.IsMatch(label))
            {
                return false;
            }

            return true;
        }

        private static List<string> SplitFixedWidthColumns(string line)
            => Regex.Split(line.Trim(), @"\s{2,}")
                .Where(p => !string.IsNullOrWhiteSpace(p))
                .ToList();

        private static FormattedResultItem? ParseInstalledSoftwareTableRow(string line)
        {
            if (TableSeparatorRegex.IsMatch(line) || line.Contains(':'))
            {
                return null;
            }

            var columns = SplitFixedWidthColumns(line);
            if (columns.Count < 3)
            {
                return null;
            }

            var title = columns[0].Trim();
            if (string.IsNullOrWhiteSpace(title)
                || string.Equals(title, "Program Name", StringComparison.OrdinalIgnoreCase)
                || title.All(ch => ch == '-'))
            {
                return null;
            }

            var version = columns.Count > 1 ? columns[1].Trim() : string.Empty;
            var publisher = columns.Count > 2 ? columns[2].Trim() : string.Empty;
            string installPath;
            string installedOn;
            if (columns.Count > 5)
            {
                installedOn = columns[^1].Trim();
                installPath = string.Join(" ", columns.Skip(3).Take(columns.Count - 4)).Trim();
            }
            else if (columns.Count == 5)
            {
                installPath = columns[3].Trim();
                installedOn = columns[4].Trim();
            }
            else if (columns.Count == 4)
            {
                installPath = columns[3].Trim();
                installedOn = string.Empty;
            }
            else
            {
                installPath = string.Empty;
                installedOn = string.Empty;
            }

            var subtitleParts = new List<string>();
            if (!string.IsNullOrWhiteSpace(version) && !string.Equals(version, "Unknown", StringComparison.OrdinalIgnoreCase))
            {
                subtitleParts.Add(version);
            }

            if (!string.IsNullOrWhiteSpace(publisher) && !string.Equals(publisher, "Unknown", StringComparison.OrdinalIgnoreCase))
            {
                subtitleParts.Add(publisher);
            }

            string? notes = null;
            if (!string.IsNullOrWhiteSpace(installedOn) && !string.Equals(installedOn, "Unknown", StringComparison.OrdinalIgnoreCase))
            {
                notes = $"Installed on: {installedOn}";
            }

            return new FormattedResultItem
            {
                Status = FormattedItemStatus.Neutral,
                StatusLabel = "Entry",
                Title = title,
                Subtitle = subtitleParts.Count > 0 ? string.Join(" · ", subtitleParts) : null,
                Path = string.IsNullOrWhiteSpace(installPath) || string.Equals(installPath, "Unknown", StringComparison.OrdinalIgnoreCase)
                    ? null
                    : installPath,
                Notes = notes
            };
        }

        private static FormattedResultItem? ParseFixedWidthTableRow(string line)
        {
            if (TableSeparatorRegex.IsMatch(line) || line.Contains(':'))
            {
                return null;
            }

            var columns = SplitFixedWidthColumns(line);
            if (columns.Count < 2)
            {
                return null;
            }

            var trimmed = line.TrimEnd();
            var marker = string.Empty;
            if (trimmed.EndsWith("[!]", StringComparison.Ordinal))
            {
                marker = "Stopped or needs attention";
                columns[^1] = columns[^1].Replace("[!]", string.Empty, StringComparison.Ordinal).Trim();
            }

            var status = string.IsNullOrWhiteSpace(marker)
                ? FormattedItemStatus.Neutral
                : FormattedItemStatus.Warning;
            var statusLabel = string.IsNullOrWhiteSpace(marker) ? "Entry" : "Attention";

            return new FormattedResultItem
            {
                Status = status,
                StatusLabel = statusLabel,
                Title = columns[0],
                Subtitle = string.Join(" · ", columns.Skip(1)),
                Notes = string.IsNullOrWhiteSpace(marker) ? null : marker
            };
        }

        private static string TranslateCountSummary(string line)
        {
            var match = CountSummaryRegex.Match(line);
            if (!match.Success)
            {
                return line;
            }

            return $"Total entries: {match.Groups["total"].Value} · Needs review: {match.Groups["review"].Value} · Verified OK: {match.Groups["ok"].Value}";
        }

        private static string TranslateGenericCount(string line)
        {
            var match = GenericCountRegex.Match(line);
            if (!match.Success)
            {
                return line;
            }

            return $"{match.Groups["label"].Value.Trim()}: {match.Groups["value"].Value.Trim()}";
        }

        private static string BuildGenericOverview(
            string? stepName,
            IReadOnlyList<FormattedResultSection> sections,
            IReadOnlyList<FormattedResultItem> items)
        {
            var reviewCount = items.Count(i => i.Status == FormattedItemStatus.Review || i.Status == FormattedItemStatus.Warning || i.Status == FormattedItemStatus.Fail);
            if (reviewCount > 0)
            {
                return $"{reviewCount} item{(reviewCount == 1 ? string.Empty : "s")} need attention in {ResolveStepTitle(stepName)}.";
            }

            var prose = sections.SelectMany(s => s.Lines).FirstOrDefault();
            if (!string.IsNullOrWhiteSpace(prose))
            {
                return prose.Length > 180 ? prose[..180] + "…" : prose;
            }

            if (items.Count > 0)
            {
                return $"{items.Count} detail record{(items.Count == 1 ? string.Empty : "s")} captured for {ResolveStepTitle(stepName)}.";
            }

            var lineCount = sections.SelectMany(s => s.Lines).Count();
            if (lineCount > 0)
            {
                return $"{ResolveStepTitle(stepName)} completed with {lineCount} detail line{(lineCount == 1 ? string.Empty : "s")}.";
            }

            return $"{ResolveStepTitle(stepName)} completed.";
        }

        private static string ResolveStepTitle(string? stepName)
        {
            if (string.IsNullOrWhiteSpace(stepName))
            {
                return "This check";
            }

            return stepName.Trim() switch
            {
                "SystemInfo" => "System information",
                "InstalledSoftware" => "Installed software",
                "Drivers" => "Driver audit",
                "PnPDevices" => "Plug and Play devices",
                "Services" => "Services audit",
                "StartupAudit" => "Startup entry audit",
                "NetworkConfig" => "Network configuration",
                "EventLogs" => "Event logs",
                "PartitionTable" => "Partition table",
                "NetworkAdapters" => "Network adapters",
                "GPUInfo" => "GPU information",
                "BrowserExtensionScan" => "Browser extensions",
                "ScheduledTasksAudit" => "Scheduled tasks",
                "OSVersion" => "OS version",
                "CPULoad" => "CPU load",
                "RAM" => "Memory",
                "DiskSpace" => "Disk free space",
                "Activation" => "Windows activation",
                "EventLogErrors" => "System event errors",
                "DriverAudit" => "Driver signature audit",
                "WindowsUpdateService" => "Windows Update service",
                "CriticalEvents" => "Critical events",
                "AutorunsAudit" => "Autoruns audit",
                "HostsFile" => "Hosts file check",
                "CoreSecurityTool" => "Security scan",
                _ => Regex.Replace(stepName, "([a-z])([A-Z])", "$1 $2")
            };
        }

        private static string TitleCaseHeader(string header)
            => System.Globalization.CultureInfo.CurrentCulture.TextInfo.ToTitleCase(header.ToLowerInvariant());

        private static string FormatRegistryLocation(string location)
        {
            if (string.IsNullOrWhiteSpace(location))
            {
                return string.Empty;
            }

            return location
                .Replace(@"HKLM\", "Local machine · ", StringComparison.OrdinalIgnoreCase)
                .Replace(@"HKCU\", "Current user · ", StringComparison.OrdinalIgnoreCase)
                .Replace(@"\\", @"\");
        }

        private static List<string> SplitLines(string text)
            => text.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
                .Select(l => l.Trim())
                .Where(l => !string.IsNullOrWhiteSpace(l))
                .ToList();

        public static string BuildPlainText(string? stepName, string? output)
        {
            var formatted = Format(stepName, output);
            var sb = new StringBuilder();
            if (!string.IsNullOrWhiteSpace(formatted.Overview))
            {
                sb.AppendLine(formatted.Overview);
                sb.AppendLine();
            }

            foreach (var section in formatted.Sections)
            {
                if (!string.IsNullOrWhiteSpace(section.Title))
                {
                    sb.AppendLine(section.Title.ToUpperInvariant());
                    sb.AppendLine(new string('─', Math.Min(section.Title.Length, 60)));
                }

                foreach (var item in section.Items)
                {
                    sb.AppendLine($"{item.StatusLabel}: {item.Title}");
                    if (!string.IsNullOrWhiteSpace(item.Location))
                    {
                        sb.AppendLine($"  Location: {item.Location}");
                    }

                    if (!string.IsNullOrWhiteSpace(item.Subtitle))
                    {
                        sb.AppendLine($"  {item.Subtitle}");
                    }

                    if (!string.IsNullOrWhiteSpace(item.Path))
                    {
                        sb.AppendLine($"  Path: {item.Path}");
                    }

                    if (!string.IsNullOrWhiteSpace(item.Notes))
                    {
                        sb.AppendLine($"  Notes: {item.Notes}");
                    }

                    sb.AppendLine();
                }

                foreach (var line in section.Lines)
                {
                    sb.AppendLine(line);
                }

                if (section.Lines.Count > 0)
                {
                    sb.AppendLine();
                }
            }

            return sb.ToString().TrimEnd();
        }
    }
}
