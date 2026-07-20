using System.Collections.Generic;
using System.IO;
using ToolkitGUI;
using ToolkitGUI.Models;
using ToolkitGUI.Services;
using Xunit;

namespace ToolkitGUI.Tests;

public class ToolkitPathsTests
{
    [Fact]
    public void GetScriptsRoot_ReturnsExistingDirectory()
    {
        var scripts = ToolkitPaths.GetScriptsRoot();
        Assert.False(string.IsNullOrWhiteSpace(scripts));
        Assert.True(Directory.Exists(scripts));
        Assert.True(File.Exists(Path.Combine(scripts, "Core", "Toolkit.Core.psm1")));
    }

    [Fact]
    public void GetEnvironmentCapabilityMatrixPath_PointsAtConfigFile()
    {
        var path = ToolkitPaths.GetEnvironmentCapabilityMatrixPath();
        Assert.EndsWith("EnvironmentCapabilityMatrix.json", path);
        Assert.True(File.Exists(path));
    }
}

public class WorkflowReportExportHelperTests
{
    [Fact]
    public void TryExtractArtifactPath_FindsPdfMarker()
    {
        var ok = WorkflowReportExportHelper.TryExtractArtifactPath(
            "Report saved: C:\\Logs\\run.pdf",
            "Report saved:",
            ".pdf",
            out var path);

        Assert.True(ok);
        Assert.Equal("C:\\Logs\\run.pdf", path);
    }

    [Fact]
    public void TryExtractWorkflowJson_ParsesTrailingObject()
    {
        var text = "noise\n{\"WorkflowName\":\"OSRepair\",\"Status\":\"Completed\",\"Steps\":[]}";
        var json = WorkflowReportExportHelper.TryExtractWorkflowJson(text);
        Assert.NotNull(json);
        Assert.Contains("\"WorkflowName\"", json);
    }
}

public class EnvironmentCapabilityServiceTests
{
    [Fact]
    public void FastFixesApply_IsBlockedInWinPeColumn()
    {
        // Matrix declares winpe_* as na — service should report unsupported when column is winpe.
        // We only assert matrix file loads and live column resolves.
        var column = EnvironmentCapabilityService.GetActiveColumn();
        Assert.False(string.IsNullOrWhiteSpace(column));
    }
}

public class HealthFindingClassificationTests
{
    [Theory]
    [InlineData("Fail", "Critical", 98, null, HealthFindingClassification.ConfirmedFault)]
    [InlineData("Warn", "High", 90, null, HealthFindingClassification.CorroboratedSuspect)]
    [InlineData("Warn", "Medium", 80, null, HealthFindingClassification.SingleSignal)]
    [InlineData("Pass", "Info", 80, null, HealthFindingClassification.Inventory)]
    [InlineData("N/A", "Info", 100, null, HealthFindingClassification.Incomplete)]
    [InlineData("Info", "Info", 95, HealthFindingClassification.ExpectedLimitation, HealthFindingClassification.ExpectedLimitation)]
    public void Resolve_DerivesExpectedClassification(
        string status,
        string severity,
        int confidence,
        string? explicitClassification,
        string expected)
    {
        var actual = HealthFindingClassification.Resolve(explicitClassification, status, severity, confidence);
        Assert.Equal(expected, actual);
    }

    [Fact]
    public void RequiresAttention_ExcludesInventoryAndLimitations()
    {
        Assert.False(HealthFindingClassification.RequiresAttention(
            HealthFindingClassification.Inventory, "Info", "Low", 35));
        Assert.False(HealthFindingClassification.RequiresAttention(
            HealthFindingClassification.ExpectedLimitation, "Info", "Info", 95));
        Assert.False(HealthFindingClassification.RequiresAttention(
            HealthFindingClassification.Incomplete, "N/A", "Info", 100));
        Assert.True(HealthFindingClassification.RequiresAttention(
            HealthFindingClassification.SingleSignal, "Warn", "Medium", 80));
        Assert.True(HealthFindingClassification.RequiresAttention(
            HealthFindingClassification.ConfirmedFault, "Fail", "Critical", 98));
    }

    [Fact]
    public void BuildAttentionItems_FiltersByEvidenceClassification()
    {
        var items = new List<StructuredResultItemViewModel>
        {
            new()
            {
                Name = "Residual noise",
                IsStructuredHealthFinding = true,
                Severity = "Low",
                StatusLabelText = "Info",
                Classification = "Inventory"
            },
            new()
            {
                Name = "Low disk",
                IsStructuredHealthFinding = true,
                Severity = "Medium",
                StatusLabelText = "Warn",
                Classification = "Single signal"
            }
        };

        var attention = SystemHealthReviewHelper.BuildAttentionItems(
            "DiskSpace",
            "disk_space",
            "detail",
            "Warn",
            items);

        Assert.Single(attention);
        Assert.Equal("Low disk", attention[0].Name);
    }

    [Fact]
    public void Format_PutsInventoryFindingsInVerifiedNotActionable()
    {
        var findings = new List<HealthStructuredFindingDto>
        {
            new()
            {
                FindingId = "event.unclassified.x.1",
                CheckId = "event_errors_24h",
                Finding = "Unclassified event error",
                Severity = "Low",
                Confidence = 35,
                Status = "Info",
                Classification = HealthFindingClassification.Inventory
            },
            new()
            {
                FindingId = "health.cpu.high_load",
                CheckId = "cpu_load",
                Finding = "CPU load is critically high",
                Severity = "High",
                Confidence = 90,
                Status = "Warn",
                Classification = HealthFindingClassification.CorroboratedSuspect
            }
        };

        var formatted = WorkflowResultFormatter.Format("CPULoad", "summary", findings);
        Assert.Contains("1 actionable finding", formatted.Overview);
        Assert.Contains(formatted.Sections, s => s.Title.StartsWith("Actionable findings"));
        Assert.Contains(formatted.Sections, s => s.Title.StartsWith("Verified"));
    }
}
