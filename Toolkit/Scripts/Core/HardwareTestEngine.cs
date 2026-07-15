using System;
using System.Collections.Generic;
using System.Threading.Tasks;

/// <summary>
/// Cooperative cancel for in-process hardware stress loops.
/// Host stop already kills the PowerShell process tree (PowerShellService process.Kill);
/// this flag is best-effort when the engine runs in-process and something sets Requested.
/// SMART short self-tests have no abort API in CdeSmart.Reader — stop relies on process kill.
/// </summary>
public static class CdeHardwareCancel
{
    public static volatile bool Requested;

    public static void Reset()
    {
        Requested = false;
    }

    public static void Request()
    {
        Requested = true;
    }
}

public static class HardwareTestEngine
{
    public static int RegisterIterations = 25000000;
    public static int CacheSizeBytes = 32 * 1024 * 1024;
    public static int CachePasses = 3;
    public static int PrimeLimit = 50000;
    public static int ExpectedPrimeCount = 5133;
    public static int FpuLoops = 75000;
    public static int MemoryPatternPasses = 2;
    public static int MemoryBlockCount = 2;
    public static int CpuStressSeconds = 20;
    private static byte[] MovingInversionPatterns = new byte[] { 0x00, 0xFF };

    public static void SetMovingInversionPatterns(byte[] patterns)
    {
        if (patterns == null || patterns.Length == 0)
            MovingInversionPatterns = new byte[] { 0x00, 0xFF };
        else
            MovingInversionPatterns = patterns;
    }

    public static bool RunRegisterTest()
    {
        int iters = RegisterIterations;
        bool ok = true;
        Parallel.For(0, Environment.ProcessorCount, _ =>
        {
            long accumulator = 0;
            for (int i = 0; i < iters; i++)
            {
                accumulator += i * 3 - (i >> 1);
                accumulator ^= (accumulator << 2);
            }
            long verify = 0;
            for (int i = 0; i < iters; i++)
            {
                verify += i * 3 - (i >> 1);
                verify ^= (verify << 2);
            }
            if (accumulator != verify) ok = false;
        });
        return ok;
    }

    public static bool RunCacheTest()
    {
        int size = CacheSizeBytes;
        byte[] data = new byte[size];
        var rng = new Random(42);
        rng.NextBytes(data);

        for (int pass = 0; pass < CachePasses; pass++)
        {
            long sumSequential = 0;
            Parallel.For(0, size, i => { sumSequential += data[i]; });

            long sumStrided = 0;
            for (int i = 0; i < size; i += 64)
                sumStrided += data[i];

            if (sumSequential == 0 || sumStrided == 0)
                return false;
        }
        return true;
    }

    public static bool RunMathRegisterTest()
    {
        double sqrtTwo = Math.Sqrt(2.0);
        if (Math.Abs(sqrtTwo - 1.4142135623730951) > 1e-12) return false;
        double divResult = 1.0 / 3.0;
        if (Math.Abs(divResult - 0.3333333333333333) > 1e-14) return false;
        double piApprox = Math.Acos(-1.0);
        if (Math.Abs(piApprox - 3.141592653589793) > 1e-12) return false;
        double euler = Math.Exp(1.0);
        if (Math.Abs(euler - 2.718281828459045) > 1e-12) return false;
        return true;
    }

    public static bool RunPrimeGenerationTest()
    {
        int limit = PrimeLimit;
        bool passed = true;
        Parallel.For(0, Environment.ProcessorCount, _ =>
        {
            if (!passed) return;
            bool[] sieve = new bool[limit + 1];
            for (int i = 2; i <= limit; i++) sieve[i] = true;
            for (int p = 2; (long)p * p <= limit; p++)
            {
                if (!sieve[p]) continue;
                for (int m = p * p; m <= limit; m += p)
                    sieve[m] = false;
            }
            int count = 0;
            for (int i = 2; i <= limit; i++)
                if (sieve[i]) count++;
            if (count != ExpectedPrimeCount)
                passed = false;
        });
        return passed;
    }

    public static bool RunFpuTest()
    {
        bool ok = true;
        Parallel.For(0, Environment.ProcessorCount, _ =>
        {
            for (int n = 0; n < FpuLoops; n++)
            {
                double sinPi6 = Math.Sin(Math.PI / 6.0);
                if (Math.Abs(sinPi6 - 0.5) > 1e-12) { ok = false; return; }
                double cosPi3 = Math.Cos(Math.PI / 3.0);
                if (Math.Abs(cosPi3 - 0.5) > 1e-12) { ok = false; return; }
                double sqrt144 = Math.Sqrt(144.0);
                if (Math.Abs(sqrt144 - 12.0) > 1e-12) { ok = false; return; }
                double tanPi4 = Math.Tan(Math.PI / 4.0);
                if (Math.Abs(tanPi4 - 1.0) > 1e-12) { ok = false; return; }
                double log1 = Math.Log(Math.E);
                if (Math.Abs(log1 - 1.0) > 1e-12) { ok = false; return; }
            }
        });
        return ok;
    }

    /// <summary>
    /// Timed multi-core soak using verify-able integer/FPU work for CpuStressSeconds.
    /// Checks <see cref="CdeHardwareCancel.Requested"/> each worker chunk (cooperative cancel).
    /// </summary>
    public static string RunCpuStressTest()
    {
        CdeHardwareCancel.Reset();
        int seconds = Math.Max(1, CpuStressSeconds);
        DateTime deadline = DateTime.UtcNow.AddSeconds(seconds);
        bool ok = true;
        bool cancelled = false;
        long iterations = 0;
        object sync = new object();

        Parallel.For(0, Environment.ProcessorCount, _ =>
        {
            long localIters = 0;
            while (DateTime.UtcNow < deadline && ok && !cancelled)
            {
                if (CdeHardwareCancel.Requested)
                {
                    cancelled = true;
                    return;
                }

                long accumulator = 0;
                long verify = 0;
                const int chunk = 50000;
                for (int i = 0; i < chunk; i++)
                {
                    accumulator += i * 3 - (i >> 1);
                    accumulator ^= (accumulator << 2);
                }
                for (int i = 0; i < chunk; i++)
                {
                    verify += i * 3 - (i >> 1);
                    verify ^= (verify << 2);
                }
                if (accumulator != verify)
                {
                    ok = false;
                    return;
                }

                double sinPi6 = Math.Sin(Math.PI / 6.0);
                if (Math.Abs(sinPi6 - 0.5) > 1e-12)
                {
                    ok = false;
                    return;
                }

                localIters++;
            }

            lock (sync) { iterations += localIters; }
        });

        if (cancelled || CdeHardwareCancel.Requested)
            return "Warn: CPU timed stress cancelled";
        if (!ok)
            return "Failed: CPU timed stress verification mismatch";
        return string.Format("Passed: {0}s multi-core soak ({1} worker chunks)", seconds, iterations);
    }

    public static string RunMemoryTest(string testName, int totalSizeMB)
    {
        int blockCount = Math.Max(1, MemoryBlockCount);
        int blockMb = Math.Max(1, totalSizeMB / blockCount);
        string last = string.Empty;
        for (int pass = 0; pass < MemoryPatternPasses; pass++)
        {
            for (int b = 0; b < blockCount; b++)
            {
                last = RunMemoryTestOnce(testName, blockMb);
                if (!last.StartsWith("Passed"))
                    return last;
            }
        }
        return last.StartsWith("Passed")
            ? string.Format("Passed ({0} blocks x {1} MB)", blockCount, blockMb)
            : last;
    }

    private static string RunMemoryTestOnce(string testIdOrName, int sizeMB)
    {
        int sizeBytes = sizeMB * 1024 * 1024;
        try
        {
            // Dispatch on catalog implementations.windows allowlist ids (displayName accepted as legacy alias).
            switch (NormalizeMemoryImplId(testIdOrName))
            {
                case "AddressTest": return AddressTest(sizeBytes);
                case "AuxPatternTest": return AuxPatternTest(sizeBytes);
                case "BitHighTest": return BitHighTest(sizeBytes);
                case "BitLowTest": return BitLowTest(sizeBytes);
                case "CheckerboardTest": return CheckerboardTest(sizeBytes);
                case "Modulo20Test": return Modulo20Test(sizeBytes);
                case "MovingInversionTest": return MovingInversionTest(sizeBytes);
                case "NibbleMoveTest": return NibbleMoveTest(sizeBytes);
                case "WalkingOnesLeftTest": return WalkingOnesLeftTest(sizeBytes);
                case "WalkingOnesRightTest": return WalkingOnesRightTest(sizeBytes);
                default: return "Failed: Unknown test " + testIdOrName;
            }
        }
        catch (OutOfMemoryException)
        {
            return "Skipped: Insufficient memory to allocate " + sizeMB + " MB";
        }
        catch (Exception ex)
        {
            return "Failed: " + ex.Message;
        }
    }

    private static string NormalizeMemoryImplId(string testIdOrName)
    {
        if (string.IsNullOrWhiteSpace(testIdOrName))
            return string.Empty;

        switch (testIdOrName.Trim())
        {
            case "AddressTest":
            case "Address Test":
                return "AddressTest";
            case "AuxPatternTest":
            case "Auxiliary Pattern Test":
                return "AuxPatternTest";
            case "BitHighTest":
            case "Bit High Test":
                return "BitHighTest";
            case "BitLowTest":
            case "Bit Low Test":
                return "BitLowTest";
            case "CheckerboardTest":
            case "Checkerboard Test":
                return "CheckerboardTest";
            case "Modulo20Test":
            case "Modulo20 Test":
                return "Modulo20Test";
            case "MovingInversionTest":
            case "Moving Inversion Test":
                return "MovingInversionTest";
            case "NibbleMoveTest":
            case "Nibble Move Test":
                return "NibbleMoveTest";
            case "WalkingOnesLeftTest":
            case "Walking Ones Left Test":
                return "WalkingOnesLeftTest";
            case "WalkingOnesRightTest":
            case "Walking Ones Right Test":
                return "WalkingOnesRightTest";
            default:
                return testIdOrName.Trim();
        }
    }

    private static string AddressTest(int size)
    {
        int count = size / 4;
        int[] arr = new int[count];
        for (int i = 0; i < count; i++) arr[i] = i;
        int mismatches = 0;
        for (int i = 0; i < count; i++)
            if (arr[i] != i) mismatches++;
        return mismatches == 0 ? "Passed" : "Failed: " + mismatches + " address mismatches";
    }

    private static string AuxPatternTest(int size)
    {
        byte[] buf = new byte[size];
        uint seed = 0xDEADBEEF;
        for (int i = 0; i < size; i++)
        {
            seed = seed * 1103515245 + 12345;
            buf[i] = (byte)(seed >> 16);
        }
        seed = 0xDEADBEEF;
        int mismatches = 0;
        for (int i = 0; i < size; i++)
        {
            seed = seed * 1103515245 + 12345;
            if (buf[i] != (byte)(seed >> 16)) mismatches++;
        }
        return mismatches == 0 ? "Passed" : "Failed: " + mismatches + " pattern mismatches";
    }

    private static string BitHighTest(int size)
    {
        byte[] buf = new byte[size];
        for (int i = 0; i < size; i++) buf[i] = 0xFF;
        int mismatches = 0;
        for (int i = 0; i < size; i++)
            if (buf[i] != 0xFF) mismatches++;
        return mismatches == 0 ? "Passed" : "Failed: " + mismatches + " bit-high mismatches";
    }

    private static string BitLowTest(int size)
    {
        byte[] buf = new byte[size];
        for (int i = 0; i < size; i++) buf[i] = 0x00;
        int mismatches = 0;
        for (int i = 0; i < size; i++)
            if (buf[i] != 0x00) mismatches++;
        return mismatches == 0 ? "Passed" : "Failed: " + mismatches + " bit-low mismatches";
    }

    private static string CheckerboardTest(int size)
    {
        byte[] buf = new byte[size];
        for (int i = 0; i < size; i++)
            buf[i] = (i % 2 == 0) ? (byte)0xAA : (byte)0x55;
        int mismatches = 0;
        for (int i = 0; i < size; i++)
        {
            byte expected = (i % 2 == 0) ? (byte)0xAA : (byte)0x55;
            if (buf[i] != expected) mismatches++;
        }
        return mismatches == 0 ? "Passed" : "Failed: " + mismatches + " checkerboard mismatches";
    }

    /* CHU MemoryTest.c TestModulo20 — MemTest86 Modulo-X stride 20 */
    private static string Modulo20Test(int size)
    {
        byte[] buf = new byte[size];
        const int stride = 20;
        byte pattern = 0xA5;
        byte inv = (byte)~pattern;
        int mismatches = 0;

        for (int offset = 0; offset < stride; offset++)
        {
            for (int i = offset; i < size; i += stride)
                buf[i] = pattern;
            for (int i = 0; i < size; i++)
                if ((i % stride) != offset)
                    buf[i] = inv;
            for (int i = offset; i < size; i += stride)
                if (buf[i] != pattern) mismatches++;
        }
        return mismatches == 0 ? "Passed" : "Failed: " + mismatches + " modulo-20 mismatches";
    }

    private static string MovingInversionTest(int size)
    {
        byte[] buf = new byte[size];
        int mismatches = 0;
        foreach (byte pattern in MovingInversionPatterns)
        {
            byte inv = (byte)~pattern;
            for (int i = 0; i < size; i++) buf[i] = pattern;
            for (int i = 0; i < size; i++)
            {
                if (buf[i] != pattern) mismatches++;
                buf[i] = inv;
            }
            for (int i = 0; i < size; i++)
            {
                if (buf[i] != inv) mismatches++;
                buf[i] = pattern;
            }
            for (int i = size - 1; i >= 0; i--)
            {
                if (buf[i] != pattern) mismatches++;
                buf[i] = inv;
            }
            for (int i = size - 1; i >= 0; i--)
            {
                if (buf[i] != inv) mismatches++;
                buf[i] = pattern;
            }
            for (int i = 0; i < size; i++)
                if (buf[i] != pattern) mismatches++;
        }
        return mismatches == 0 ? "Passed" : "Failed: " + mismatches + " moving-inversion mismatches";
    }

    private static string NibbleMoveTest(int size)
    {
        byte[] buf = new byte[size];
        for (int i = 0; i < size; i++)
        {
            byte val = (byte)(i & 0xFF);
            buf[i] = (byte)(((val & 0x0F) << 4) | ((val & 0xF0) >> 4));
        }
        int mismatches = 0;
        for (int i = 0; i < size; i++)
        {
            byte val = (byte)(i & 0xFF);
            byte expected = (byte)(((val & 0x0F) << 4) | ((val & 0xF0) >> 4));
            if (buf[i] != expected) mismatches++;
        }
        return mismatches == 0 ? "Passed" : "Failed: " + mismatches + " nibble-move mismatches";
    }

    private static string WalkingOnesLeftTest(int size)
    {
        byte[] buf = new byte[size];
        for (int i = 0; i < size; i++)
            buf[i] = (byte)(1 << (i % 8));
        int mismatches = 0;
        for (int i = 0; i < size; i++)
            if (buf[i] != (byte)(1 << (i % 8))) mismatches++;
        return mismatches == 0 ? "Passed" : "Failed: " + mismatches + " walking-ones-left mismatches";
    }

    private static string WalkingOnesRightTest(int size)
    {
        byte[] buf = new byte[size];
        for (int i = 0; i < size; i++)
            buf[i] = (byte)(0x80 >> (i % 8));
        int mismatches = 0;
        for (int i = 0; i < size; i++)
            if (buf[i] != (byte)(0x80 >> (i % 8))) mismatches++;
        return mismatches == 0 ? "Passed" : "Failed: " + mismatches + " walking-ones-right mismatches";
    }
}
