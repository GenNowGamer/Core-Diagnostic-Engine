using System;
using System.Collections.Generic;
using System.Windows.Media;

namespace ToolkitGUI.Models
{
    public sealed class WorkflowExecutionReport
    {
        public string WorkflowName { get; set; } = string.Empty;
        public DateTime StartTime { get; set; }
        public DateTime EndTime { get; set; }
        public double DurationSec { get; set; }
        public string Status { get; set; } = string.Empty;
        public string EnvironmentMode { get; set; } = string.Empty;
        public string? OverallHealth { get; set; }
        public List<WorkflowExecutionStep> Steps { get; set; } = new();
        public List<string> Errors { get; set; } = new();
    }

    public sealed class WorkflowExecutionStep
    {
        public string Name { get; set; } = string.Empty;
        public string Status { get; set; } = string.Empty;
        public string Output { get; set; } = string.Empty;
        public string Detail { get; set; } = string.Empty;
        public string CheckId { get; set; } = string.Empty;
    }

    public sealed class WorkflowExecutionStepViewModel
    {
        public string Name { get; }
        public string Status { get; }
        public string Output { get; }
        public string CheckId { get; }
        public Brush StatusBrush { get; }

        public WorkflowExecutionStepViewModel(WorkflowExecutionStep step)
        {
            Name = string.IsNullOrWhiteSpace(step.Name) ? "Step" : step.Name;
            Status = string.IsNullOrWhiteSpace(step.Status) ? "Unknown" : step.Status;
            Output = !string.IsNullOrWhiteSpace(step.Output)
                ? step.Output
                : (step.Detail ?? string.Empty);
            CheckId = string.IsNullOrWhiteSpace(step.CheckId) ? string.Empty : step.CheckId;
            StatusBrush = Status.ToUpperInvariant() switch
            {
                "PASS" => new SolidColorBrush(Color.FromRgb(0x0D, 0x7A, 0x3E)),
                "COMPLETED" => new SolidColorBrush(Color.FromRgb(0x0D, 0x7A, 0x3E)),
                "WARN" => new SolidColorBrush(Color.FromRgb(0x92, 0x68, 0x00)),
                "FAIL" => new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C)),
                "ERROR" => new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C)),
                "SKIP" => Brushes.Gray,
                "N/A" => Brushes.Gray,
                "NA" => Brushes.Gray,
                _ => new SolidColorBrush(Color.FromRgb(0x00, 0x78, 0xD4))
            };
        }
    }
}
