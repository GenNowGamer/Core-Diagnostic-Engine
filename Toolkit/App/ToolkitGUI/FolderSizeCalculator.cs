using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace ToolkitGUI
{
    internal static class FolderSizeCalculator
    {
        private const int ProgressByteThreshold = 256 * 1024;
        private static readonly TimeSpan ProgressInterval = TimeSpan.FromMilliseconds(120);

        public static Task<long> CalculateAsync(
            string rootPath,
            IProgress<long> progress,
            CancellationToken cancellationToken)
        {
            return Task.Run(() => Calculate(rootPath, progress, cancellationToken), cancellationToken);
        }

        private static long Calculate(
            string rootPath,
            IProgress<long> progress,
            CancellationToken cancellationToken)
        {
            long total = 0;
            long lastReported = -1;
            var lastReportTime = DateTime.MinValue;
            var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var stack = new Stack<string>();
            stack.Push(rootPath);

            while (stack.Count > 0)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var current = stack.Pop();

                string normalized;
                try
                {
                    normalized = Path.GetFullPath(current);
                }
                catch
                {
                    continue;
                }

                if (!visited.Add(normalized))
                    continue;

                try
                {
                    foreach (var filePath in Directory.EnumerateFiles(current))
                    {
                        cancellationToken.ThrowIfCancellationRequested();
                        try
                        {
                            total += new FileInfo(filePath).Length;
                            lastReported = ReportIfNeeded(progress, total, lastReported, ref lastReportTime);
                        }
                        catch
                        {
                            // Skip unreadable files.
                        }
                    }
                }
                catch
                {
                    // Skip unreadable directories.
                }

                try
                {
                    foreach (var dirPath in Directory.EnumerateDirectories(current))
                    {
                        cancellationToken.ThrowIfCancellationRequested();
                        try
                        {
                            if ((new DirectoryInfo(dirPath).Attributes & FileAttributes.ReparsePoint) != 0)
                                continue;
                        }
                        catch
                        {
                            continue;
                        }

                        stack.Push(dirPath);
                    }
                }
                catch
                {
                    // Skip unreadable branches.
                }
            }

            progress.Report(total);
            return total;
        }

        private static long ReportIfNeeded(
            IProgress<long> progress,
            long total,
            long lastReported,
            ref DateTime lastReportTime)
        {
            var now = DateTime.UtcNow;
            if (total == lastReported)
                return lastReported;

            if (lastReported >= 0 &&
                total - lastReported < ProgressByteThreshold &&
                now - lastReportTime < ProgressInterval)
            {
                return lastReported;
            }

            progress.Report(total);
            lastReportTime = now;
            return total;
        }
    }
}
