using System.Diagnostics;
using System.ComponentModel;
using System.Runtime.InteropServices;

internal static class Program
{
    private const string ElevatedRetryArg = "--elevated-launch";
    private const uint MbOk = 0x00000000;
    private const uint MbIconError = 0x00000010;

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

    private static int Fail(string message)
    {
        MessageBoxW(IntPtr.Zero, message, "CDE Launcher", MbOk | MbIconError);
        return 1;
    }

    private static int Main(string[] args)
    {
        var isElevatedRetry = args.Any(a => string.Equals(a, ElevatedRetryArg, StringComparison.OrdinalIgnoreCase));

        var launcherPath = Process.GetCurrentProcess().MainModule?.FileName;
        if (string.IsNullOrWhiteSpace(launcherPath))
        {
            return Fail("Could not determine launcher path.");
        }

        var cdeRoot = Path.GetDirectoryName(launcherPath);
        if (string.IsNullOrWhiteSpace(cdeRoot))
        {
            return Fail("Could not determine CDE root.");
        }

        cdeRoot = cdeRoot.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var toolkitExe = Path.Combine(cdeRoot, "CDE", "ToolkitGUI", "bin", "Release", "net8.0-windows", "ToolkitGUI.exe");

        if (!File.Exists(toolkitExe))
        {
            return Fail($"ToolkitGUI.exe not found.\n\nExpected:\n{toolkitExe}\n\nMake sure the CDE folder structure is intact.");
        }

        var psi = new ProcessStartInfo
        {
            FileName = toolkitExe,
            UseShellExecute = false,
            WorkingDirectory = Path.GetDirectoryName(toolkitExe) ?? cdeRoot
        };

        psi.Environment["TOOLKIT_ROOT"] = cdeRoot;

        try
        {
            Process.Start(psi);
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode == 740)
        {
            if (isElevatedRetry)
            {
                return Fail("ToolkitGUI.exe requires elevation and launch still failed after elevation retry.");
            }

            // Relaunch this launcher elevated, then it will spawn ToolkitGUI with TOOLKIT_ROOT.
            var elevatedLauncher = new ProcessStartInfo
            {
                FileName = launcherPath,
                Arguments = ElevatedRetryArg,
                WorkingDirectory = cdeRoot,
                UseShellExecute = true,
                Verb = "runas"
            };

            try
            {
                Process.Start(elevatedLauncher);
            }
            catch (Exception retryEx)
            {
                return Fail($"Failed to launch elevated ToolkitGUI.exe.\n\n{retryEx.Message}");
            }
        }
        catch (Exception ex)
        {
            return Fail($"Failed to launch ToolkitGUI.exe.\n\n{ex.Message}");
        }

        return 0;
    }
}
