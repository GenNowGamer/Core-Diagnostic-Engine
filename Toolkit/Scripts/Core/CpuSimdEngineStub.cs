using System;

// Minimal stub when Vector intrinsics cannot be compiled (Windows PowerShell 5.1 netfx csc).
public static class CpuSimdEngine
{
    public static bool IsStubEngine { get { return true; } }

    public static bool RunMmxTest() { return Environment.Is64BitOperatingSystem; }

    public static bool RunSseTest() { return Environment.Is64BitOperatingSystem; }

    public static bool RunSse2Test() { return Environment.Is64BitOperatingSystem; }

    public static bool RunSse3Test() { return Environment.Is64BitOperatingSystem; }

    public static bool RunSsse3Test() { return Environment.Is64BitOperatingSystem; }

    public static bool RunSse41Test() { return Environment.Is64BitOperatingSystem; }

    public static bool RunSse42Test() { return Environment.Is64BitOperatingSystem; }
}
