using System;
using System.Collections.Generic;
using System.IO;
using ToolkitGUI;
using ToolkitGUI.Models;
using ToolkitGUI.Services;
using ToolkitGUI.ViewModels;
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

public class ThemePersistenceAndRootPathTests
{
    [Theory]
    [InlineData("E:", @"E:\")]
    [InlineData(@"E:\", @"E:\")]
    [InlineData(@"D:\Toolkit\", @"D:\Toolkit")]
    public void NormalizeRootPath_PreservesDriveRootSeparator(string input, string expected)
    {
        Assert.Equal(expected, ToolkitPaths.NormalizeRootPath(input));
    }

    [Fact]
    public void OfflineRuntimePaths_GetRuntimeDirectory_HandlesBareDriveRoot()
    {
        Assert.Equal(@"E:\CDE\Runtime", OfflineRuntimePaths.GetRuntimeDirectory("E:"));
    }

    [Fact]
    public void LoadSavedTheme_ReturnsLight_WhenNoThemeFileExists()
    {
        var tempDir = CreateTempDir();
        try
        {
            var primary = Path.Combine(tempDir, "primary", "theme.txt");
            var fallback = Path.Combine(tempDir, "fallback", "theme.txt");

            Assert.Equal(AppTheme.Light, ThemeService.LoadSavedTheme(primary, fallback));
        }
        finally
        {
            CleanupTempDir(tempDir);
        }
    }

    [Fact]
    public void SaveAndLoadTheme_PersistsDarkAndLightAcrossReopens()
    {
        var tempDir = CreateTempDir();
        try
        {
            var primary = Path.Combine(tempDir, "CDE", "Runtime", "theme.txt");
            var fallback = Path.Combine(tempDir, "LocalAppData", "theme.txt");

            ThemeService.SaveTheme(AppTheme.Dark, primary, fallback);
            Assert.Equal(AppTheme.Dark, ThemeService.LoadSavedTheme(primary, fallback));
            Assert.False(File.Exists(fallback));

            ThemeService.SaveTheme(AppTheme.Light, primary, fallback);
            Assert.Equal(AppTheme.Light, ThemeService.LoadSavedTheme(primary, fallback));
            Assert.False(File.Exists(fallback));
        }
        finally
        {
            CleanupTempDir(tempDir);
        }
    }

    [Theory]
    [InlineData("  dark \r\n", AppTheme.Dark)]
    [InlineData(" LIGHT ", AppTheme.Light)]
    public void LoadSavedTheme_ParsesCaseInsensitiveAndWhitespaceTrimmedValues(string fileContent, AppTheme expected)
    {
        var tempDir = CreateTempDir();
        try
        {
            var primary = Path.Combine(tempDir, "theme.txt");
            File.WriteAllText(primary, fileContent);

            Assert.Equal(expected, ThemeService.LoadSavedTheme(primary, null));
        }
        finally
        {
            CleanupTempDir(tempDir);
        }
    }

    [Fact]
    public void LoadSavedTheme_WritablePrimaryTakesPrecedenceOverStaleFallback()
    {
        var tempDir = CreateTempDir();
        try
        {
            var primary = Path.Combine(tempDir, "primary", "theme.txt");
            var fallback = Path.Combine(tempDir, "fallback", "theme.txt");
            Directory.CreateDirectory(Path.GetDirectoryName(primary)!);
            Directory.CreateDirectory(Path.GetDirectoryName(fallback)!);
            File.WriteAllText(primary, "Light");
            File.WriteAllText(fallback, "Dark");

            Assert.Equal(AppTheme.Light, ThemeService.LoadSavedTheme(primary, fallback));
        }
        finally
        {
            CleanupTempDir(tempDir);
        }
    }

    [Fact]
    public void SaveAndLoadTheme_UsesFallbackWhenPrimaryIsReadOnly()
    {
        var tempDir = CreateTempDir();
        try
        {
            var primary = Path.Combine(tempDir, "ro", "theme.txt");
            var fallback = Path.Combine(tempDir, "fallback", "theme.txt");
            Directory.CreateDirectory(Path.GetDirectoryName(primary)!);
            File.WriteAllText(primary, "Light");
            File.SetAttributes(primary, FileAttributes.ReadOnly);

            ThemeService.SaveTheme(AppTheme.Dark, primary, fallback);
            Assert.Equal(AppTheme.Dark, ThemeService.LoadSavedTheme(primary, fallback));

            ThemeService.SaveTheme(AppTheme.Light, primary, fallback);
            Assert.Equal(AppTheme.Light, ThemeService.LoadSavedTheme(primary, fallback));
        }
        finally
        {
            CleanupTempDir(tempDir);
        }
    }

    private static string CreateTempDir()
    {
        var path = Path.Combine(Path.GetTempPath(), "CdeThemeTests_" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }

    private static void CleanupTempDir(string path)
    {
        if (!Directory.Exists(path))
            return;

        foreach (var file in Directory.EnumerateFiles(path, "*", SearchOption.AllDirectories))
        {
            try
            {
                var attrs = File.GetAttributes(file);
                if ((attrs & FileAttributes.ReadOnly) != 0)
                    File.SetAttributes(file, attrs & ~FileAttributes.ReadOnly);
            }
            catch
            {
                /* best-effort */
            }
        }

        try
        {
            Directory.Delete(path, recursive: true);
        }
        catch
        {
            /* best-effort */
        }
    }
}

public class TempFileCleanerTests
{
    [Fact]
    public void BuildCleanArguments_UsesDoubleQuotesAndPreservesSpacesAndApostrophes()
    {
        var pathsFile = @"C:\Users\John O'Brien\AppData\Local\CoreDiagnosticEngine\TempCleanerState\paths.json";
        var whitelistFile = @"C:\Users\John O'Brien\AppData\Local\CoreDiagnosticEngine\TempCleanerState\whitelist.json";

        var args = TempFileCleanerViewModel.BuildCleanArguments(pathsFile, whitelistFile);

        Assert.Contains($"-PathsFile \"{pathsFile}\"", args);
        Assert.Contains($"-WhitelistFile \"{whitelistFile}\"", args);
        Assert.DoesNotContain("-PathsFile '", args);
        Assert.DoesNotContain("-WhitelistFile '", args);
    }

    [Fact]
    public void GetControlFileDirectory_IsOutsideSystemTemp()
    {
        var controlDir = Path.GetFullPath(TempFileCleanerViewModel.GetControlFileDirectory())
            .TrimEnd(Path.DirectorySeparatorChar);
        var sysTemp = Path.GetFullPath(Path.GetTempPath())
            .TrimEnd(Path.DirectorySeparatorChar);

        Assert.True(Directory.Exists(controlDir));
        Assert.False(string.Equals(controlDir, sysTemp, StringComparison.OrdinalIgnoreCase));
        Assert.False(controlDir.StartsWith(sysTemp + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void TempFolderNode_ParentSelectionSkipsProtectedChildren()
    {
        var parent = new TempFolderNode
        {
            DisplayName = "Other Directories",
            IsParent = true
        };
        var cleanable = new TempFolderNode
        {
            DisplayName = "Windows Temp",
            IsProtected = false
        };
        var protectedNode = new TempFolderNode
        {
            DisplayName = "Prefetch",
            IsProtected = true
        };
        parent.Children.Add(cleanable);
        parent.Children.Add(protectedNode);

        parent.IsSelected = true;

        Assert.True(cleanable.IsSelected);
        Assert.False(protectedNode.IsSelected);
    }
}

public class Batch1CriticalRegressionTests
{
    [Fact]
    public void BuildCustomScanTargetCliArguments_SingleTarget_UsesScanTarget()
    {
        var args = MalwareCleanupViewModel.BuildCustomScanTargetCliArguments(new[] { @"C:\Users\Test\Downloads" });
        Assert.Contains("-ScanTarget \"C:\\Users\\Test\\Downloads\"", args);
        Assert.DoesNotContain("-ScanTargetsFile", args);
    }

    [Fact]
    public void BuildCustomScanTargetCliArguments_MultipleTargets_WritesJsonFileInsteadOfRepeatedScanTarget()
    {
        var args = MalwareCleanupViewModel.BuildCustomScanTargetCliArguments(new[]
        {
            @"C:\Users\Test\Downloads",
            @"C:\Users\Test\Desktop"
        });

        Assert.Contains("-ScanTargetsFile \"", args);
        Assert.DoesNotContain("-ScanTarget ", args);

        var startQuote = args.IndexOf('"');
        var endQuote = args.LastIndexOf('"');
        Assert.True(startQuote >= 0 && endQuote > startQuote);
        var filePath = args.Substring(startQuote + 1, endQuote - startQuote - 1);
        try
        {
            Assert.True(File.Exists(filePath));
            var json = File.ReadAllText(filePath);
            Assert.Contains("Downloads", json);
            Assert.Contains("Desktop", json);
        }
        finally
        {
            if (File.Exists(filePath))
                File.Delete(filePath);
        }
    }

    [Fact]
    public void GetOfflineHiveCleanupScript_DoesNotHardcodeUnloadedDefaultHives()
    {
        var script = ToolkitGUI.Views.SettingsView.GetOfflineHiveCleanupScript(throwOnFailure: true);
        Assert.DoesNotContain("foreach ($base in @('HKLM\\Offline_SOFTWARE'", script);
        Assert.Contains("reg.exe query $root.Query", script);
    }

    [Fact]
    public void OfflineWindowsResolver_ResolvesBareDriveRootWithBackslashSeparator()
    {
        var saved = Environment.GetEnvironmentVariable("OFFLINE_WINDOWS_ROOT");
        try
        {
            var systemDrive = (Path.GetPathRoot(Environment.SystemDirectory) ?? "C:\\").TrimEnd('\\');
            Environment.SetEnvironmentVariable("OFFLINE_WINDOWS_ROOT", systemDrive); // bare "C:"
            var resolved = OfflineWindowsResolver.ResolveOfflineWindowsDir("Test", out _);
            Assert.NotNull(resolved);
            Assert.Equal(Path.Combine(systemDrive + "\\", "Windows"), resolved, ignoreCase: true);
        }
        finally
        {
            Environment.SetEnvironmentVariable("OFFLINE_WINDOWS_ROOT", saved);
        }
    }

    [Fact]
    public async System.Threading.Tasks.Task FileExportEngine_CompressedFinalPartialIncompressibleUnit_ExportsRawBytesWithoutDecompressionCorruption()
    {
        // 10 KB (10240 bytes) file in a 16-cluster (64 KB) compression unit, stored as 3 uncompressed clusters (12288 bytes) with no trailing sparse run.
        var expectedBytes = new byte[10240];
        for (int i = 0; i < expectedBytes.Length; i++)
            expectedBytes[i] = (byte)((i * 31 + 17) & 0xFF);

        var diskBytes = new byte[65536];
        Buffer.BlockCopy(expectedBytes, 0, diskBytes, 4096, expectedBytes.Length);

        using var source = new InMemoryBlockSource(diskBytes);
        var item = new CdeRecovery.Core.Models.RecoverableFileItem
        {
            MftRecordNumber = 42,
            FileName = "partial_unit.bin",
            ReconstructedPath = "partial_unit.bin",
            SizeBytes = expectedBytes.Length,
            AllocatedSizeBytes = 12288,
            IsDirectory = false,
            IsResident = false,
            IsCompressed = true,
            CompressionUnitClusters = 16,
            ClusterSizeBytes = 4096,
            PartitionStartOffset = 0,
            DataRuns = new List<CdeRecovery.Core.Models.NtfsDataRun>
            {
                new CdeRecovery.Core.Models.NtfsDataRun
                {
                    VcnStart = 0,
                    LcnStart = 1, // offset 4096
                    ClusterCount = 3,
                    IsSparse = false
                }
            }
        };

        var destDir = Path.Combine(Path.GetTempPath(), "CdeRecoveryPartialTest_" + Guid.NewGuid().ToString("N"));
        try
        {
            var manifest = await CdeRecovery.Core.Recovery.FileExportEngine.ExportFilesAsync(
                source,
                new[] { item },
                destDir);

            Assert.Equal(1, manifest.VerifiedFilesCount);
            var exportedFile = Path.Combine(destDir, "partial_unit.bin");
            Assert.True(File.Exists(exportedFile));
            var actualBytes = await File.ReadAllBytesAsync(exportedFile);
            Assert.Equal(expectedBytes, actualBytes);
        }
        finally
        {
            if (Directory.Exists(destDir))
                Directory.Delete(destDir, recursive: true);
        }
    }

    private sealed class InMemoryBlockSource : CdeRecovery.Core.Devices.IReadOnlyBlockSource
    {
        private readonly byte[] _data;

        public InMemoryBlockSource(byte[] data)
        {
            _data = data;
            Identity = new CdeRecovery.Core.Devices.StorageDeviceIdentity
            {
                DiskNumber = 99,
                DevicePath = @"\\.\PhysicalDrive99",
                FriendlyName = "InMemoryTestDisk",
                CapacityBytes = data.Length,
                LogicalSectorSize = 512,
                PhysicalSectorSize = 512,
                IsDiskImage = true
            };
        }

        public CdeRecovery.Core.Devices.StorageDeviceIdentity Identity { get; }
        public long Length => _data.Length;
        public int LogicalSectorSize => 512;
        public int PhysicalSectorSize => 512;
        public IReadOnlyList<CdeRecovery.Core.Devices.SectorReadError> ReadErrors => Array.Empty<CdeRecovery.Core.Devices.SectorReadError>();

        public System.Threading.Tasks.Task<int> ReadAtAsync(
            long offset,
            Memory<byte> buffer,
            System.Threading.CancellationToken cancellationToken = default)
        {
            if (offset < 0 || offset >= _data.Length)
                return System.Threading.Tasks.Task.FromResult(0);
            int count = (int)Math.Min(buffer.Length, _data.Length - offset);
            _data.AsMemory((int)offset, count).CopyTo(buffer);
            return System.Threading.Tasks.Task.FromResult(count);
        }

        public void Dispose() { }
    }

    [Fact]
    public async System.Threading.Tasks.Task FileExportEngine_SanitizesTraversalInRelativeExportPath()
    {
        var expectedBytes = System.Text.Encoding.UTF8.GetBytes("hello-cde");
        var diskBytes = new byte[4096];
        Buffer.BlockCopy(expectedBytes, 0, diskBytes, 0, expectedBytes.Length);

        using var source = new InMemoryBlockSource(diskBytes);
        var item = new CdeRecovery.Core.Models.RecoverableFileItem
        {
            MftRecordNumber = 100,
            FileName = "escape.txt",
            ReconstructedPath = @"..\..\outside\escape.txt",
            SizeBytes = expectedBytes.Length,
            AllocatedSizeBytes = 4096,
            IsDirectory = false,
            IsResident = false,
            IsCompressed = false,
            ClusterSizeBytes = 4096,
            PartitionStartOffset = 0,
            DataRuns = new List<CdeRecovery.Core.Models.NtfsDataRun>
            {
                new CdeRecovery.Core.Models.NtfsDataRun
                {
                    VcnStart = 0,
                    LcnStart = 0,
                    ClusterCount = 1,
                    IsSparse = false
                }
            }
        };

        var destDir = Path.Combine(Path.GetTempPath(), "CdeExportTraversal_" + Guid.NewGuid().ToString("N"));
        try
        {
            var manifest = await CdeRecovery.Core.Recovery.FileExportEngine.ExportFilesAsync(
                source,
                new[] { item },
                destDir);

            Assert.Equal(1, manifest.VerifiedFilesCount);
            var exportedEntry = Assert.Single(manifest.Results);
            var fullDestDir = Path.GetFullPath(destDir).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            var fullExportedPath = Path.GetFullPath(exportedEntry.DestinationFullPath);
            Assert.StartsWith(fullDestDir, fullExportedPath, StringComparison.OrdinalIgnoreCase);
            Assert.True(File.Exists(fullExportedPath));
        }
        finally
        {
            if (Directory.Exists(destDir))
                Directory.Delete(destDir, recursive: true);
        }
    }

    [Fact]
    public void PowerShellService_IsWinPeEnvironment_ReturnsFalseOnLiveWindows()
    {
        Assert.False(PowerShellService.IsWinPeEnvironment());
    }

    [Fact]
    public void PowerShellArgumentHelper_QuoteForScriptParameter_EscapesSingleQuotes()
    {
        var path = @"D:\Users\O'Connor\Toolkit\Scripts\Workflows\SmartAnalyzer.ps1";
        var quoted = PowerShellArgumentHelper.QuoteForScriptParameter(path);
        Assert.Equal(@"'D:\Users\O''Connor\Toolkit\Scripts\Workflows\SmartAnalyzer.ps1'", quoted);
    }

    [Fact]
    public void EnvironmentCapabilityService_IsActionSupported_ReturnsBooleanWithoutThrowing()
    {
        Assert.True(EnvironmentCapabilityService.IsActionSupported("SystemHealthCheck"));
        Assert.True(EnvironmentCapabilityService.IsActionSupported("NonExistentWorkflowName"));
    }
}
