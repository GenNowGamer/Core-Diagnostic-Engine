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
    }

    internal sealed class FormattedResultSection
    {
        public string Title { get; init; } = string.Empty;
        public IReadOnlyList<FormattedResultItem> Items { get; init; } = new List<FormattedResultItem>();
        public IReadOnlyList<string> Lines { get; init; } = new List<string>();
    }

    internal sealed class FormattedWorkflowOutput
    {
        public string Overview { get; init; } = string.Empty;
        public IReadOnlyList<FormattedResultSection> Sections { get; init; } = new List<FormattedResultSection>();
        public IReadOnlyList<FormattedResultItem> AllItems { get; init; } = new List<FormattedResultItem>();
    }
}
