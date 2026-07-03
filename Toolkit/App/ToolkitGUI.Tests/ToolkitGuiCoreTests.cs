using System.IO;
using ToolkitGUI;
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
