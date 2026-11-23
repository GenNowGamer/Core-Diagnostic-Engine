using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using ToolkitGUI.Services;
using Xunit;

namespace ToolkitGUI.Tests;

public class FileOperationServiceTests : IDisposable
{
    private readonly string _tempRoot;

    public FileOperationServiceTests()
    {
        _tempRoot = Path.Combine(Path.GetTempPath(), "CdeFileOpTests_" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_tempRoot);
    }

    public void Dispose()
    {
        try
        {
            if (Directory.Exists(_tempRoot))
                Directory.Delete(_tempRoot, recursive: true);
        }
        catch
        {
            // Best-effort temp cleanup.
        }
    }

    [Fact]
    public async Task DeleteAsync_RemovesNestedFoldersAndReadOnlyFiles_AndReportsCompletion()
    {
        var folder = Path.Combine(_tempRoot, "DeleteMe");
        var subFolder = Path.Combine(folder, "Sub");
        Directory.CreateDirectory(subFolder);

        var file1 = Path.Combine(folder, "a.txt");
        var file2 = Path.Combine(subFolder, "b.bin");
        await File.WriteAllTextAsync(file1, "hello");
        await File.WriteAllBytesAsync(file2, new byte[2048]);
        File.SetAttributes(file2, FileAttributes.ReadOnly);

        var reports = new List<FileOperationProgress>();
        var progress = new InlineProgress<FileOperationProgress>(p => reports.Add(p));

        var result = await FileOperationService.ExecuteAsync(
            FileOperationKind.Delete,
            new[] { folder },
            targetFolder: null,
            progress: progress);

        Assert.True(result.Completed);
        Assert.False(result.WasCancelled);
        Assert.False(Directory.Exists(folder));
        Assert.Equal(4, result.TotalItems); // DeleteMe, Sub, a.txt, b.bin
        Assert.Equal(result.TotalItems, result.ItemsCompleted);
        Assert.Contains(reports, r => r.Phase == FileOperationPhase.Preparing);
        Assert.Equal(FileOperationPhase.Completed, reports.Last().Phase);
        Assert.Equal(100, reports.Last().PercentComplete);
    }

    [Fact]
    public async Task CopyAsync_CopiesRecursively_HandlesCollisions_AndReportsBytes()
    {
        var sourceDir = Path.Combine(_tempRoot, "Src");
        var nestedDir = Path.Combine(sourceDir, "Nested");
        Directory.CreateDirectory(nestedDir);
        await File.WriteAllBytesAsync(Path.Combine(sourceDir, "one.dat"), new byte[4096]);
        await File.WriteAllBytesAsync(Path.Combine(nestedDir, "two.dat"), new byte[8192]);

        var destRoot = Path.Combine(_tempRoot, "Dest");
        Directory.CreateDirectory(destRoot);
        // Pre-create collision folder "Src" in Dest to verify GetUniquePath creates "Src (1)".
        Directory.CreateDirectory(Path.Combine(destRoot, "Src"));

        var reports = new List<FileOperationProgress>();
        var progress = new InlineProgress<FileOperationProgress>(p => reports.Add(p));

        var result = await FileOperationService.ExecuteAsync(
            FileOperationKind.Copy,
            new[] { sourceDir },
            destRoot,
            progress: progress);

        var expectedTarget = Path.Combine(destRoot, "Src (1)");
        Assert.True(result.Completed);
        Assert.False(result.WasCancelled);
        Assert.True(File.Exists(Path.Combine(expectedTarget, "one.dat")));
        Assert.True(File.Exists(Path.Combine(expectedTarget, "Nested", "two.dat")));
        Assert.Equal(4096 + 8192, result.TotalBytes);
        Assert.Equal(result.TotalBytes, result.BytesCompleted);
        Assert.Equal(FileOperationPhase.Completed, reports.Last().Phase);
    }

    [Fact]
    public async Task MoveAsync_SameVolume_MovesDirectoryAndUpdatesProgress()
    {
        var sourceDir = Path.Combine(_tempRoot, "MoveSrc");
        Directory.CreateDirectory(sourceDir);
        var payload = new byte[1024];
        await File.WriteAllBytesAsync(Path.Combine(sourceDir, "file.bin"), payload);

        var destRoot = Path.Combine(_tempRoot, "MoveDest");
        Directory.CreateDirectory(destRoot);

        var reports = new List<FileOperationProgress>();
        var progress = new InlineProgress<FileOperationProgress>(p => reports.Add(p));

        var result = await FileOperationService.ExecuteAsync(
            FileOperationKind.Move,
            new[] { sourceDir },
            destRoot,
            progress: progress);

        Assert.True(result.Completed);
        Assert.False(result.WasCancelled);
        Assert.False(Directory.Exists(sourceDir));
        Assert.True(File.Exists(Path.Combine(destRoot, "MoveSrc", "file.bin")));
        Assert.Equal(result.TotalItems, result.ItemsCompleted);
        Assert.Equal(1024, result.BytesCompleted);
        Assert.Equal(FileOperationPhase.Completed, reports.Last().Phase);
    }

    [Fact]
    public async Task ExecuteAsync_WhenCancelled_ReturnsWasCancelledTrue()
    {
        var sourceFile = Path.Combine(_tempRoot, "large.bin");
        await File.WriteAllBytesAsync(sourceFile, new byte[1024 * 64]);

        using var cts = new CancellationTokenSource();
        cts.Cancel();

        var result = await FileOperationService.ExecuteAsync(
            FileOperationKind.Copy,
            new[] { sourceFile },
            Path.Combine(_tempRoot, "Out"),
            cancellationToken: cts.Token);

        Assert.False(result.Completed);
        Assert.True(result.WasCancelled);
    }

    [Fact]
    public async Task CopyAsync_IntoSubdirectoryOfSelf_FailsWithErrorMessage()
    {
        var parent = Path.Combine(_tempRoot, "Parent");
        var child = Path.Combine(parent, "Child");
        Directory.CreateDirectory(child);

        var result = await FileOperationService.ExecuteAsync(
            FileOperationKind.Copy,
            new[] { parent },
            child);

        Assert.False(result.Completed);
        Assert.False(result.WasCancelled);
        Assert.False(string.IsNullOrWhiteSpace(result.ErrorMessage));
        Assert.Contains("subfolder", result.ErrorMessage, StringComparison.OrdinalIgnoreCase);
    }

    private sealed class InlineProgress<T> : IProgress<T>
    {
        private readonly Action<T> _handler;

        public InlineProgress(Action<T> handler) => _handler = handler;

        public void Report(T value) => _handler(value);
    }
}
