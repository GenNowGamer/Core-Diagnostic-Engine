using System;
using System.Numerics;

// Fallback SIMD checks for Windows PowerShell 5.1 (netfx Add-Type). PS7 loads CpuSimdEngine.cs instead.
public static class CpuSimdEngine
{
    public static bool IsStubEngine { get { return false; } }

    public static bool RunMmxTest() { return RunVectorFloatTest(); }

    public static bool RunSseTest() { return RunVectorFloatTest(); }

    public static bool RunSse2Test() { return RunVectorDoubleTest(); }

    public static bool RunSse3Test() { return RunVectorDoubleTest(); }

    public static bool RunSsse3Test() { return RunVectorIntTest(); }

    public static bool RunSse41Test() { return RunVectorUIntTest(); }

    public static bool RunSse42Test() { return RunVectorUIntTest(); }

    private static bool RunVectorFloatTest()
    {
        if (!Vector.IsHardwareAccelerated) return false;
        var a = new Vector<float>(1f);
        var b = a + a;
        return Math.Abs(b[0] - 2f) < 1e-5f;
    }

    private static bool RunVectorDoubleTest()
    {
        if (!Vector.IsHardwareAccelerated) return false;
        var a = new Vector<double>(1.0);
        var b = a + a;
        return Math.Abs(b[0] - 2.0) < 1e-12;
    }

    private static bool RunVectorIntTest()
    {
        if (!Vector.IsHardwareAccelerated) return false;
        var a = new Vector<int>(new int[] { -1, 2, -3, 4 });
        var b = Vector.Abs(a);
        return b[0] == 1 && b[1] == 2;
    }

    private static bool RunVectorUIntTest()
    {
        if (!Vector.IsHardwareAccelerated) return false;
        var a = new Vector<uint>(new uint[] { 1, 2, 3, 4 });
        var b = Vector.Max(a, a);
        return b[0] == 1u;
    }
}
