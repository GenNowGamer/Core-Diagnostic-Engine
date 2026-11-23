using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace ToolkitGUI.Services
{
    public enum FileOperationKind
    {
        Copy,
        Move,
        Delete
    }

    public enum FileOperationPhase
    {
        Preparing,
        Running,
        Paused,
        Completed,
        Cancelled,
        Failed
    }

    public sealed class FileOperationProgress
    {
        public FileOperationPhase Phase { get; init; }
        public FileOperationKind Kind { get; init; }
        public string CurrentItemName { get; init; } = string.Empty;
        public string CurrentSourcePath { get; init; } = string.Empty;
        public string CurrentDestinationPath { get; init; } = string.Empty;
        public int ItemsCompleted { get; init; }
        public int TotalItems { get; init; }
        public long BytesCompleted { get; init; }
        public long TotalBytes { get; init; }
        public double BytesPerSecond { get; init; }
        public TimeSpan? EstimatedRemaining { get; init; }
        public double PercentComplete { get; init; }
        public string StatusText { get; init; } = string.Empty;
    }

    public sealed class FileOperationResult
    {
        public bool Completed { get; init; }
        public bool WasCancelled { get; init; }
        public int ItemsCompleted { get; init; }
        public int TotalItems { get; init; }
        public long BytesCompleted { get; init; }
        public long TotalBytes { get; init; }
        public string? ErrorMessage { get; init; }
    }

    public sealed class FileOperationPauseToken : IDisposable
    {
        private readonly ManualResetEventSlim _gate = new(initialState: true);
        private readonly object _sync = new();
        private bool _isPaused;
        private Stopwatch? _pauseWatch;
        private long _totalPausedMs;

        public bool IsPaused
        {
            get
            {
                lock (_sync)
                    return _isPaused;
            }
        }

        public TimeSpan TotalPausedDuration
        {
            get
            {
                lock (_sync)
                {
                    var ms = _totalPausedMs;
                    if (_isPaused && _pauseWatch != null)
                        ms += _pauseWatch.ElapsedMilliseconds;
                    return TimeSpan.FromMilliseconds(ms);
                }
            }
        }

        public void Pause()
        {
            lock (_sync)
            {
                if (_isPaused)
                    return;
                _isPaused = true;
                _pauseWatch = Stopwatch.StartNew();
                _gate.Reset();
            }
        }

        public void Resume()
        {
            lock (_sync)
            {
                if (!_isPaused)
                    return;
                _isPaused = false;
                if (_pauseWatch != null)
                {
                    _pauseWatch.Stop();
                    _totalPausedMs += _pauseWatch.ElapsedMilliseconds;
                    _pauseWatch = null;
                }
                _gate.Set();
            }
        }

        public void WaitIfPaused(CancellationToken cancellationToken)
        {
            _gate.Wait(cancellationToken);
        }

        public void Dispose()
        {
            _gate.Dispose();
        }
    }

    public static class FileOperationService
    {
        private const int CopyBufferSize = 1024 * 1024;
        private const int ProgressThrottleMs = 60;

        public static Task<FileOperationResult> ExecuteAsync(
            FileOperationKind kind,
            IReadOnlyList<string> sourcePaths,
            string? targetFolder,
            IProgress<FileOperationProgress>? progress = null,
            FileOperationPauseToken? pauseToken = null,
            CancellationToken cancellationToken = default)
        {
            return Task.Run(
                () => ExecuteCore(kind, sourcePaths, targetFolder, progress, pauseToken, cancellationToken),
                CancellationToken.None);
        }

        private static FileOperationResult ExecuteCore(
            FileOperationKind kind,
            IReadOnlyList<string> sourcePaths,
            string? targetFolder,
            IProgress<FileOperationProgress>? progress,
            FileOperationPauseToken? pauseToken,
            CancellationToken cancellationToken)
        {
            var state = new ExecutionState(kind, targetFolder, progress, pauseToken);

            try
            {
                if (sourcePaths == null || sourcePaths.Count == 0)
                {
                    return new FileOperationResult
                    {
                        Completed = true,
                        ItemsCompleted = 0,
                        TotalItems = 0,
                        BytesCompleted = 0,
                        TotalBytes = 0
                    };
                }

                if ((kind == FileOperationKind.Copy || kind == FileOperationKind.Move) &&
                    string.IsNullOrWhiteSpace(targetFolder))
                {
                    throw new ArgumentException("Target folder is required for copy or move.", nameof(targetFolder));
                }

                state.ReportImmediate(FileOperationPhase.Preparing, "Calculating items and size...");

                var plans = BuildRootPlans(kind, sourcePaths, targetFolder, state, cancellationToken);
                state.ActiveStopwatch.Start();

                state.ReportImmediate(
                    FileOperationPhase.Running,
                    GetVerbRunningText(kind));

                foreach (var plan in plans)
                {
                    WaitAndCheckCancel(state, cancellationToken);
                    ExecuteRootPlan(kind, plan, state, cancellationToken);
                }

                state.ActiveStopwatch.Stop();
                state.ReportImmediate(FileOperationPhase.Completed, GetVerbCompletedText(kind));

                return new FileOperationResult
                {
                    Completed = true,
                    WasCancelled = false,
                    ItemsCompleted = state.ItemsCompleted,
                    TotalItems = state.TotalItems,
                    BytesCompleted = state.BytesCompleted,
                    TotalBytes = state.TotalBytes
                };
            }
            catch (OperationCanceledException)
            {
                state.ActiveStopwatch.Stop();
                state.ReportImmediate(FileOperationPhase.Cancelled, "Operation cancelled.");
                return new FileOperationResult
                {
                    Completed = false,
                    WasCancelled = true,
                    ItemsCompleted = state.ItemsCompleted,
                    TotalItems = state.TotalItems,
                    BytesCompleted = state.BytesCompleted,
                    TotalBytes = state.TotalBytes
                };
            }
            catch (Exception ex)
            {
                state.ActiveStopwatch.Stop();
                state.ReportImmediate(FileOperationPhase.Failed, $"Failed: {ex.Message}");
                return new FileOperationResult
                {
                    Completed = false,
                    WasCancelled = false,
                    ItemsCompleted = state.ItemsCompleted,
                    TotalItems = state.TotalItems,
                    BytesCompleted = state.BytesCompleted,
                    TotalBytes = state.TotalBytes,
                    ErrorMessage = ex.Message
                };
            }
        }

        private static List<RootPlan> BuildRootPlans(
            FileOperationKind kind,
            IReadOnlyList<string> sourcePaths,
            string? targetFolder,
            ExecutionState state,
            CancellationToken cancellationToken)
        {
            var plans = new List<RootPlan>(sourcePaths.Count);

            foreach (var rawSource in sourcePaths)
            {
                WaitAndCheckCancel(state, cancellationToken);

                if (string.IsNullOrWhiteSpace(rawSource))
                    continue;

                var isDirectory = Directory.Exists(rawSource);
                if (!isDirectory && !File.Exists(rawSource))
                    continue;

                var trimmedSource = rawSource.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                var name = Path.GetFileName(trimmedSource);
                if (string.IsNullOrEmpty(name))
                    continue;

                string? destPath = null;
                var isSameVolumeMove = false;

                if (kind == FileOperationKind.Copy || kind == FileOperationKind.Move)
                {
                    var destFolder = targetFolder!;
                    if (isDirectory && IsSameOrSubdirectory(rawSource, destFolder))
                        throw new InvalidOperationException($"Cannot copy or move '{name}' into itself or a subfolder.");

                    if (kind == FileOperationKind.Move && IsSameParentDirectory(rawSource, destFolder))
                        continue;

                    destPath = GetUniquePath(Path.Combine(destFolder, name), isDirectory);
                    isSameVolumeMove = kind == FileOperationKind.Move && IsSameVolume(rawSource, destPath);
                }

                var plan = new RootPlan(rawSource, destPath, name, isDirectory, isSameVolumeMove);
                EnumerateRootPlan(plan, state, cancellationToken);
                plans.Add(plan);
            }

            return plans;
        }

        private static void EnumerateRootPlan(RootPlan plan, ExecutionState state, CancellationToken cancellationToken)
        {
            if (!plan.IsDirectory)
            {
                var length = SafeGetFileLength(plan.SourcePath);
                plan.Files.Add(new FileEntry(plan.SourcePath, string.Empty, length));
                plan.ItemCount = 1;
                plan.ByteCount = length;
                state.TotalItems += 1;
                state.TotalBytes += length;
                state.ReportThrottled(FileOperationPhase.Preparing, plan.Name, plan.SourcePath, plan.DestinationPath ?? string.Empty, "Discovering items...");
                return;
            }

            var rootFull = Path.GetFullPath(plan.SourcePath);
            var dirsToVisit = new Stack<DirectoryInfo>();
            var postOrderDirs = new List<string>();
            dirsToVisit.Push(new DirectoryInfo(rootFull));

            while (dirsToVisit.Count > 0)
            {
                WaitAndCheckCancel(state, cancellationToken);
                var dir = dirsToVisit.Pop();
                var relDir = Path.GetRelativePath(rootFull, dir.FullName);
                if (relDir == ".")
                    relDir = string.Empty;

                plan.DirectoriesTopDown.Add(relDir);
                postOrderDirs.Add(dir.FullName);
                plan.ItemCount++;
                state.TotalItems++;

                if ((dir.Attributes & FileAttributes.ReparsePoint) != 0)
                    continue;

                FileInfo[] files;
                try
                {
                    files = dir.GetFiles();
                }
                catch
                {
                    files = Array.Empty<FileInfo>();
                }

                foreach (var file in files)
                {
                    WaitAndCheckCancel(state, cancellationToken);
                    var relFile = string.IsNullOrEmpty(relDir) ? file.Name : Path.Combine(relDir, file.Name);
                    var len = SafeGetFileLength(file);
                    plan.Files.Add(new FileEntry(file.FullName, relFile, len));
                    plan.ItemCount++;
                    plan.ByteCount += len;
                    state.TotalItems++;
                    state.TotalBytes += len;
                }

                DirectoryInfo[] subDirs;
                try
                {
                    subDirs = dir.GetDirectories();
                }
                catch
                {
                    subDirs = Array.Empty<DirectoryInfo>();
                }

                foreach (var sub in subDirs)
                {
                    if ((sub.Attributes & FileAttributes.ReparsePoint) != 0)
                        continue;
                    dirsToVisit.Push(sub);
                }

                state.ReportThrottled(FileOperationPhase.Preparing, dir.Name, dir.FullName, plan.DestinationPath ?? string.Empty, "Discovering items...");
            }

            postOrderDirs.Reverse();
            plan.DirectoriesBottomUp.AddRange(postOrderDirs);
        }

        private static void ExecuteRootPlan(
            FileOperationKind kind,
            RootPlan plan,
            ExecutionState state,
            CancellationToken cancellationToken)
        {
            switch (kind)
            {
                case FileOperationKind.Delete:
                    ExecuteDeletePlan(plan, state, cancellationToken);
                    break;
                case FileOperationKind.Copy:
                    ExecuteCopyPlan(plan, state, cancellationToken);
                    break;
                case FileOperationKind.Move:
                    ExecuteMovePlan(plan, state, cancellationToken);
                    break;
            }
        }

        private static void ExecuteDeletePlan(RootPlan plan, ExecutionState state, CancellationToken cancellationToken)
        {
            if (!plan.IsDirectory)
            {
                if (plan.Files.Count > 0)
                {
                    var f = plan.Files[0];
                    state.ReportThrottled(FileOperationPhase.Running, Path.GetFileName(f.FullPath), f.FullPath, string.Empty, "Deleting items...");
                    DeleteSingleFile(f.FullPath);
                    state.ItemsCompleted++;
                    state.BytesCompleted += f.Length;
                    state.ReportThrottled(FileOperationPhase.Running, Path.GetFileName(f.FullPath), f.FullPath, string.Empty, "Deleting items...");
                }
                return;
            }

            foreach (var file in plan.Files)
            {
                WaitAndCheckCancel(state, cancellationToken);
                var name = Path.GetFileName(file.FullPath);
                state.ReportThrottled(FileOperationPhase.Running, name, file.FullPath, string.Empty, "Deleting items...");
                DeleteSingleFile(file.FullPath);
                state.ItemsCompleted++;
                state.BytesCompleted += file.Length;
                state.ReportThrottled(FileOperationPhase.Running, name, file.FullPath, string.Empty, "Deleting items...");
            }

            foreach (var dirPath in plan.DirectoriesBottomUp)
            {
                WaitAndCheckCancel(state, cancellationToken);
                var name = Path.GetFileName(dirPath);
                state.ReportThrottled(FileOperationPhase.Running, name, dirPath, string.Empty, "Deleting folders...");
                DeleteSingleDirectory(dirPath);
                state.ItemsCompleted++;
                state.ReportThrottled(FileOperationPhase.Running, name, dirPath, string.Empty, "Deleting folders...");
            }
        }

        private static void ExecuteCopyPlan(RootPlan plan, ExecutionState state, CancellationToken cancellationToken)
        {
            var destRoot = plan.DestinationPath!;

            if (!plan.IsDirectory)
            {
                var f = plan.Files[0];
                CopyFileWithProgress(f.FullPath, destRoot, f.Length, state, cancellationToken);
                state.ItemsCompleted++;
                state.ReportThrottled(FileOperationPhase.Running, plan.Name, f.FullPath, destRoot, "Copying items...");
                return;
            }

            foreach (var relDir in plan.DirectoriesTopDown)
            {
                WaitAndCheckCancel(state, cancellationToken);
                var targetDir = string.IsNullOrEmpty(relDir) ? destRoot : Path.Combine(destRoot, relDir);
                Directory.CreateDirectory(targetDir);
                state.ItemsCompleted++;
                state.ReportThrottled(FileOperationPhase.Running, Path.GetFileName(targetDir), plan.SourcePath, targetDir, "Creating folders...");
            }

            foreach (var file in plan.Files)
            {
                WaitAndCheckCancel(state, cancellationToken);
                var targetFile = Path.Combine(destRoot, file.RelativePath);
                CopyFileWithProgress(file.FullPath, targetFile, file.Length, state, cancellationToken);
                state.ItemsCompleted++;
                state.ReportThrottled(FileOperationPhase.Running, Path.GetFileName(file.FullPath), file.FullPath, targetFile, "Copying items...");
            }
        }

        private static void ExecuteMovePlan(RootPlan plan, ExecutionState state, CancellationToken cancellationToken)
        {
            var destRoot = plan.DestinationPath!;

            if (plan.IsSameVolumeMove)
            {
                state.ReportThrottled(FileOperationPhase.Running, plan.Name, plan.SourcePath, destRoot, "Moving items...");
                if (plan.IsDirectory)
                    Directory.Move(plan.SourcePath, destRoot);
                else
                    File.Move(plan.SourcePath, destRoot);

                state.ItemsCompleted += plan.ItemCount;
                state.BytesCompleted += plan.ByteCount;
                state.ReportThrottled(FileOperationPhase.Running, plan.Name, plan.SourcePath, destRoot, "Moving items...");
                return;
            }

            // Cross-volume move: copy everything first, then delete sources.
            ExecuteCopyPlan(plan, state, cancellationToken);
            WaitAndCheckCancel(state, cancellationToken);

            if (plan.IsDirectory)
            {
                foreach (var file in plan.Files)
                    DeleteSingleFile(file.FullPath);
                foreach (var dirPath in plan.DirectoriesBottomUp)
                    DeleteSingleDirectory(dirPath);
            }
            else
            {
                DeleteSingleFile(plan.SourcePath);
            }
        }

        private static void CopyFileWithProgress(
            string sourcePath,
            string destPath,
            long expectedLength,
            ExecutionState state,
            CancellationToken cancellationToken)
        {
            var fileName = Path.GetFileName(sourcePath);
            var destDir = Path.GetDirectoryName(destPath);
            if (!string.IsNullOrEmpty(destDir))
                Directory.CreateDirectory(destDir);

            var buffer = new byte[CopyBufferSize];
            var copiedForThisFile = 0L;
            var partialCreated = false;

            try
            {
                using var sourceStream = new FileStream(sourcePath, FileMode.Open, FileAccess.Read, FileShare.Read, CopyBufferSize, FileOptions.SequentialScan);
                using var destStream = new FileStream(destPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, CopyBufferSize);
                partialCreated = true;

                int bytesRead;
                while ((bytesRead = sourceStream.Read(buffer, 0, buffer.Length)) > 0)
                {
                    WaitAndCheckCancel(state, cancellationToken);
                    destStream.Write(buffer, 0, bytesRead);
                    copiedForThisFile += bytesRead;
                    state.BytesCompleted += bytesRead;
                    state.ReportThrottled(FileOperationPhase.Running, fileName, sourcePath, destPath, "Copying items...");
                }

                if (copiedForThisFile == 0 && expectedLength == 0)
                    state.ReportThrottled(FileOperationPhase.Running, fileName, sourcePath, destPath, "Copying items...");
            }
            catch (OperationCanceledException)
            {
                if (partialCreated)
                    TryDeletePartialFile(destPath);
                throw;
            }
            catch (Exception ex) when (ex is not IOException)
            {
                if (partialCreated)
                    TryDeletePartialFile(destPath);
                throw new IOException($"Failed to copy '{sourcePath}': {ex.Message}", ex);
            }
        }

        private static void TryDeletePartialFile(string path)
        {
            try
            {
                if (File.Exists(path))
                    File.Delete(path);
            }
            catch
            {
                // Best-effort cleanup of cancelled partial destination file.
            }
        }

        private static void DeleteSingleFile(string path)
        {
            if (!File.Exists(path))
                return;

            try
            {
                var attrs = File.GetAttributes(path);
                if ((attrs & FileAttributes.ReadOnly) != 0)
                    File.SetAttributes(path, attrs & ~FileAttributes.ReadOnly);
            }
            catch
            {
                // Best-effort attribute clear before delete.
            }

            File.Delete(path);
        }

        private static void DeleteSingleDirectory(string path)
        {
            if (!Directory.Exists(path))
                return;

            try
            {
                var attrs = File.GetAttributes(path);
                if ((attrs & FileAttributes.ReadOnly) != 0)
                    File.SetAttributes(path, attrs & ~FileAttributes.ReadOnly);
            }
            catch
            {
                // Best-effort attribute clear before delete.
            }

            Directory.Delete(path, recursive: true);
        }

        private static void WaitAndCheckCancel(ExecutionState state, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();

            if (state.PauseToken != null && state.PauseToken.IsPaused)
            {
                state.ActiveStopwatch.Stop();
                state.ReportImmediate(FileOperationPhase.Paused, "Paused");
                try
                {
                    state.PauseToken.WaitIfPaused(cancellationToken);
                }
                finally
                {
                    if (!cancellationToken.IsCancellationRequested)
                        state.ActiveStopwatch.Start();
                }

                state.ReportImmediate(FileOperationPhase.Running, GetVerbRunningText(state.Kind));
            }
        }

        private static long SafeGetFileLength(string path)
        {
            try
            {
                return new FileInfo(path).Length;
            }
            catch
            {
                return 0;
            }
        }

        private static long SafeGetFileLength(FileInfo info)
        {
            try
            {
                return info.Length;
            }
            catch
            {
                return 0;
            }
        }

        private static string GetVerbRunningText(FileOperationKind kind) => kind switch
        {
            FileOperationKind.Copy => "Copying items...",
            FileOperationKind.Move => "Moving items...",
            FileOperationKind.Delete => "Deleting items...",
            _ => "Processing..."
        };

        private static string GetVerbCompletedText(FileOperationKind kind) => kind switch
        {
            FileOperationKind.Copy => "Copy complete.",
            FileOperationKind.Move => "Move complete.",
            FileOperationKind.Delete => "Delete complete.",
            _ => "Complete."
        };

        internal static bool IsSameOrSubdirectory(string sourceDir, string targetDir)
        {
            try
            {
                var sourceFull = Path.GetFullPath(sourceDir).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                var targetFull = Path.GetFullPath(targetDir).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                if (string.Equals(sourceFull, targetFull, StringComparison.OrdinalIgnoreCase))
                    return true;

                var prefix = sourceFull + Path.DirectorySeparatorChar;
                return targetFull.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        internal static bool IsSameParentDirectory(string sourcePath, string targetDir)
        {
            try
            {
                var sourceFull = Path.GetFullPath(sourcePath).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                var parent = Path.GetDirectoryName(sourceFull)?.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                var targetFull = Path.GetFullPath(targetDir).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                return !string.IsNullOrEmpty(parent) &&
                       string.Equals(parent, targetFull, StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        internal static bool IsSameVolume(string pathA, string pathB)
        {
            try
            {
                var rootA = Path.GetPathRoot(Path.GetFullPath(pathA));
                var rootB = Path.GetPathRoot(Path.GetFullPath(pathB));
                return !string.IsNullOrEmpty(rootA) &&
                       string.Equals(rootA, rootB, StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        internal static string GetUniquePath(string path, bool isDirectory = false)
        {
            if (!File.Exists(path) && !Directory.Exists(path))
                return path;

            var trimmed = path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var directory = Path.GetDirectoryName(trimmed) ?? string.Empty;
            var filename = isDirectory ? Path.GetFileName(trimmed) : Path.GetFileNameWithoutExtension(trimmed);
            var extension = isDirectory ? string.Empty : Path.GetExtension(trimmed);
            var counter = 1;

            string candidate;
            do
            {
                candidate = Path.Combine(directory, $"{filename} ({counter}){extension}");
                counter++;
            } while (File.Exists(candidate) || Directory.Exists(candidate));

            return candidate;
        }

        private sealed class FileEntry
        {
            public string FullPath { get; }
            public string RelativePath { get; }
            public long Length { get; }

            public FileEntry(string fullPath, string relativePath, long length)
            {
                FullPath = fullPath;
                RelativePath = relativePath;
                Length = length;
            }
        }

        private sealed class RootPlan
        {
            public string SourcePath { get; }
            public string? DestinationPath { get; }
            public string Name { get; }
            public bool IsDirectory { get; }
            public bool IsSameVolumeMove { get; }
            public int ItemCount { get; set; }
            public long ByteCount { get; set; }
            public List<string> DirectoriesTopDown { get; } = new();
            public List<string> DirectoriesBottomUp { get; } = new();
            public List<FileEntry> Files { get; } = new();

            public RootPlan(string sourcePath, string? destinationPath, string name, bool isDirectory, bool isSameVolumeMove)
            {
                SourcePath = sourcePath;
                DestinationPath = destinationPath;
                Name = name;
                IsDirectory = isDirectory;
                IsSameVolumeMove = isSameVolumeMove;
            }
        }

        private sealed class ExecutionState
        {
            private readonly IProgress<FileOperationProgress>? _progress;
            private readonly Stopwatch _reportThrottle = Stopwatch.StartNew();
            private string _lastItemName = string.Empty;
            private string _lastSourcePath = string.Empty;
            private string _lastDestPath = string.Empty;

            public FileOperationKind Kind { get; }
            public string? TargetFolder { get; }
            public FileOperationPauseToken? PauseToken { get; }
            public Stopwatch ActiveStopwatch { get; } = new();
            public int ItemsCompleted { get; set; }
            public int TotalItems { get; set; }
            public long BytesCompleted { get; set; }
            public long TotalBytes { get; set; }

            public ExecutionState(
                FileOperationKind kind,
                string? targetFolder,
                IProgress<FileOperationProgress>? progress,
                FileOperationPauseToken? pauseToken)
            {
                Kind = kind;
                TargetFolder = targetFolder;
                _progress = progress;
                PauseToken = pauseToken;
            }

            public void ReportThrottled(
                FileOperationPhase phase,
                string itemName,
                string sourcePath,
                string destPath,
                string statusText)
            {
                _lastItemName = itemName;
                _lastSourcePath = sourcePath;
                _lastDestPath = destPath;

                if (_progress == null || _reportThrottle.ElapsedMilliseconds < ProgressThrottleMs)
                    return;

                _reportThrottle.Restart();
                _progress.Report(BuildSnapshot(phase, itemName, sourcePath, destPath, statusText));
            }

            public void ReportImmediate(FileOperationPhase phase, string statusText)
            {
                if (_progress == null)
                    return;

                _reportThrottle.Restart();
                _progress.Report(BuildSnapshot(phase, _lastItemName, _lastSourcePath, _lastDestPath, statusText));
            }

            private FileOperationProgress BuildSnapshot(
                FileOperationPhase phase,
                string itemName,
                string sourcePath,
                string destPath,
                string statusText)
            {
                var elapsedSec = ActiveStopwatch.Elapsed.TotalSeconds;
                var bps = elapsedSec > 0.05 && BytesCompleted > 0
                    ? BytesCompleted / elapsedSec
                    : 0d;

                TimeSpan? eta = null;
                if (phase == FileOperationPhase.Running && bps > 1 && TotalBytes > BytesCompleted)
                {
                    var remainingSec = (TotalBytes - BytesCompleted) / bps;
                    if (remainingSec is >= 0 and < 86400 * 7)
                        eta = TimeSpan.FromSeconds(remainingSec);
                }

                double percent;
                if (phase == FileOperationPhase.Completed)
                {
                    percent = 100;
                }
                else if (TotalBytes > 0)
                {
                    percent = Math.Clamp((double)BytesCompleted / TotalBytes * 100.0, 0, 100);
                }
                else if (TotalItems > 0)
                {
                    percent = Math.Clamp((double)ItemsCompleted / TotalItems * 100.0, 0, 100);
                }
                else
                {
                    percent = 0;
                }

                return new FileOperationProgress
                {
                    Phase = phase,
                    Kind = Kind,
                    CurrentItemName = itemName,
                    CurrentSourcePath = sourcePath,
                    CurrentDestinationPath = destPath,
                    ItemsCompleted = ItemsCompleted,
                    TotalItems = TotalItems,
                    BytesCompleted = BytesCompleted,
                    TotalBytes = TotalBytes,
                    BytesPerSecond = bps,
                    EstimatedRemaining = eta,
                    PercentComplete = percent,
                    StatusText = statusText
                };
            }
        }
    }
}
