using System;
using System.Runtime.Intrinsics;
using System.Runtime.Intrinsics.X86;

public static class CpuSimdEngine
{
    public static bool IsStubEngine => false;

    public static bool RunMmxTest()
    {
        if (!Sse.IsSupported) return false;
        try
        {
            var v = Vector128.Create((byte)1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16);
            var sum = Sse2.Add(v, v);
            return sum.GetElement(0) == 2 && sum.GetElement(15) == 32;
        }
        catch { return false; }
    }

    public static bool RunSseTest()
    {
        if (!Sse.IsSupported) return false;
        var a = Vector128.Create(1.0f, 2.0f, 3.0f, 4.0f);
        var b = Sse.Add(a, a);
        return Math.Abs(b.GetElement(0) - 2.0f) < 1e-5f;
    }

    public static bool RunSse2Test()
    {
        if (!Sse2.IsSupported) return false;
        var a = Vector128.Create(new double[] { 1.0, 2.0, 3.0, 4.0 });
        var b = Sse2.Add(a, a);
        return Math.Abs(b.GetElement(0) - 2.0) < 1e-12;
    }

    public static bool RunSse3Test()
    {
        if (!Sse3.IsSupported) return false;
        var left = Vector128.Create(1.0, 2.0);
        var right = Vector128.Create(3.0, 4.0);
        var result = Sse3.AddSubtract(left, right);
        return Math.Abs(result.GetElement(0) - (-2.0)) < 1e-12 &&
               Math.Abs(result.GetElement(1) - 6.0) < 1e-12;
    }

    public static bool RunSsse3Test()
    {
        if (!Ssse3.IsSupported) return false;
        var a = Vector128.Create((sbyte)1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16);
        var b = Ssse3.Abs(a);
        return b.GetElement(0) == 1 && b.GetElement(1) == 2;
    }

    public static bool RunSse41Test()
    {
        if (!Sse41.IsSupported) return false;
        var a = Vector128.Create((uint)1, 2, 3, 4);
        var b = Sse41.Max(a, a);
        return b.GetElement(0) == 1u;
    }

    public static bool RunSse42Test()
    {
        if (!Sse42.IsSupported) return false;
        var a = Vector128.Create(1L, 0L);
        var b = Vector128.Create(0L, 1L);
        var cmp = Sse42.CompareGreaterThan(a, b);
        return cmp.GetElement(0) != 0;
    }
}
