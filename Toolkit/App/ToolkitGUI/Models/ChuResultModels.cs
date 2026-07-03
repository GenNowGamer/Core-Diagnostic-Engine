using System.Collections.Generic;

namespace ToolkitGUI.Models
{
    /// <summary>One test result entry as stored in a CHU JSON results file.</summary>
    public class ChuTestEntry
    {
        public string Id           { get; set; } = string.Empty;
        public string Category     { get; set; } = string.Empty;
        public string DisplayName  { get; set; } = string.Empty;
        public string Test         { get; set; } = string.Empty;
        public string Status       { get; set; } = string.Empty;
        public int    Errors       { get; set; }
        public string Details      { get; set; } = string.Empty;
        public double DurationSec  { get; set; }
    }

    public class ChuResultCategoryGroup
    {
        public string Category { get; set; } = string.Empty;
        public List<ChuTestEntry> Tests { get; set; } = new();
    }

    /// <summary>The top-level structure of a CoreDiag .json results file.</summary>
    public class ChuResultFile
    {
        public string              RunLabel  { get; set; } = string.Empty;
        public string              Timestamp { get; set; } = string.Empty;
        public List<ChuTestEntry>  Results   { get; set; } = new();
    }
}
