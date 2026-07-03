using System;
using System.Collections.Generic;

namespace ToolkitGUI.Models
{
    internal sealed class WorkOrderFormData
    {
        public string ClientName { get; set; } = string.Empty;
        public string ClientPhone { get; set; } = string.Empty;
        public string TechnicianNotes { get; set; } = string.Empty;
    }

    internal sealed class WorkOrderListItem
    {
        public string CaseId { get; init; } = string.Empty;
        public string ClientName { get; init; } = string.Empty;
        public string Status { get; init; } = string.Empty;
        public DateTime SortTime { get; init; }
        public string DisplayLabel { get; init; } = string.Empty;
        public string FilePath { get; init; } = string.Empty;
    }

    internal sealed class WorkOrderKeyFinding
    {
        public string Step { get; init; } = string.Empty;
        public string Status { get; init; } = string.Empty;
        public string Detail { get; init; } = string.Empty;
    }

    internal sealed class WorkOrderGuidanceContext
    {
        public string LastSymptomId { get; init; } = string.Empty;
        public string LastHealthPreset { get; init; } = string.Empty;
        public string UpdatedAt { get; init; } = string.Empty;
    }

    internal sealed class WorkOrderRunDetail
    {
        public string WorkflowName { get; init; } = string.Empty;
        public string CompletedAt { get; init; } = string.Empty;
        public string OverallHealth { get; init; } = string.Empty;
        public string Status { get; init; } = string.Empty;
        public string Summary { get; init; } = string.Empty;
        public string EventKind { get; init; } = "Workflow";
        public string DisplayLabel { get; init; } = string.Empty;
        public string ReportJson { get; init; } = string.Empty;
        public string ReportHtml { get; init; } = string.Empty;
        public string ReportPdf { get; init; } = string.Empty;
        public string SourceArtifact { get; init; } = string.Empty;
        public IReadOnlyList<WorkOrderKeyFinding> KeyFindings { get; init; } = Array.Empty<WorkOrderKeyFinding>();

        public string TimelineLabel => !string.IsNullOrWhiteSpace(DisplayLabel) ? DisplayLabel : WorkflowName;
        public bool ShowEventKindChip => !string.Equals(EventKind, "Workflow", StringComparison.OrdinalIgnoreCase);
        public bool HasOpenableReport => !string.IsNullOrWhiteSpace(ReportPdf) && System.IO.File.Exists(ReportPdf);
        public bool HasOpenableLinks => HasOpenableReport;
    }

    internal sealed class WorkOrderDetail
    {
        public string CaseId { get; init; } = string.Empty;
        public string Status { get; init; } = string.Empty;
        public string ClientName { get; init; } = string.Empty;
        public string ClientPhone { get; init; } = string.Empty;
        public string TechnicianNotes { get; init; } = string.Empty;
        public string CreatedAt { get; init; } = string.Empty;
        public string ClosedAt { get; init; } = string.Empty;
        public string FinalReportPdf { get; init; } = string.Empty;
        public WorkOrderGuidanceContext? GuidanceContext { get; init; }
        public IReadOnlyList<WorkOrderRunDetail> Runs { get; init; } = Array.Empty<WorkOrderRunDetail>();

        public bool HasFinalReportPdf =>
            !string.IsNullOrWhiteSpace(FinalReportPdf) && System.IO.File.Exists(FinalReportPdf);
    }

    internal sealed class WorkOrderTimelineEntry
    {
        public string CompletedAt { get; init; } = string.Empty;
        public string DisplayLabel { get; init; } = string.Empty;
        public string WorkflowName { get; init; } = string.Empty;
        public string EventKind { get; init; } = "Workflow";
        public string OverallHealth { get; init; } = string.Empty;
        public string ReportJson { get; init; } = string.Empty;
        public string ReportHtml { get; init; } = string.Empty;
        public string ReportPdf { get; init; } = string.Empty;
        public string SourceArtifact { get; init; } = string.Empty;

        public string TimelineLabel => !string.IsNullOrWhiteSpace(DisplayLabel) ? DisplayLabel : WorkflowName;
        public bool HasOpenableReport => !string.IsNullOrWhiteSpace(ReportPdf) && System.IO.File.Exists(ReportPdf);
    }
}
