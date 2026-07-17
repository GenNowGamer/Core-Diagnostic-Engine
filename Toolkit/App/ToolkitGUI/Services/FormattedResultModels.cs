using System.Collections.Generic;

namespace ToolkitGUI.Services
{
    internal enum FormattedItemStatus
    {
        Ok,
        Review,
        Warning,
        Fail,
        Info,
        Neutral
    }

    internal sealed class FormattedResultItem
    {
        public FormattedItemStatus Status { get; init; } = FormattedItemStatus.Neutral;
        public string StatusLabel { get; init; } = string.Empty;
        public string Title { get; init; } = string.Empty;
        public string? Subtitle { get; init; }
        public string? Location { get; init; }
        public string? Path { get; init; }
        public string? Notes { get; init; }
        /// <summary>When true, render as a single compact row instead of a full card.</summary>
        public bool Compact { get; init; }

        public string? Impact { get; init; }
        public string? SeverityLabel { get; init; }
        public int? Confidence { get; init; }
        public IReadOnlyList<string> Evidence { get; init; } = new List<string>();
        public IReadOnlyList<string> Recommendations { get; init; } = new List<string>();
        public bool IsStructuredFinding { get; init; }
    }

    internal sealed class FormattedResultSection
    {
        public string Title { get; init; } = string.Empty;
        public IReadOnlyList<FormattedResultItem> Items { get; init; } = new List<FormattedResultItem>();
        public IReadOnlyList<string> Lines { get; init; } = new List<string>();
        /// <summary>Prefer compact item rows (e.g. verified startup entries).</summary>
        public bool UseCompactItems { get; init; }
        /// <summary>Start collapsed (e.g. verified list when review items exist).</summary>
        public bool StartsCollapsed { get; init; }
    }

    internal sealed class FormattedWorkflowOutput
    {
        public string Overview { get; init; } = string.Empty;
        public IReadOnlyList<FormattedResultSection> Sections { get; init; } = new List<FormattedResultSection>();
        public IReadOnlyList<FormattedResultItem> AllItems { get; init; } = new List<FormattedResultItem>();
    }
}
