using System.Text.Json;

if (args.Length == 0)
{
    Console.Error.WriteLine("Usage: CdeCpuSimdCli probe | run <Mmx|Sse|Sse2|Sse3|Ssse3|Sse41|Sse42>");
    return 2;
}

if (string.Equals(args[0], "probe", StringComparison.OrdinalIgnoreCase))
{
    var payload = new { isStubEngine = CpuSimdEngine.IsStubEngine };
    Console.WriteLine(JsonSerializer.Serialize(payload));
    return 0;
}

if (string.Equals(args[0], "run", StringComparison.OrdinalIgnoreCase) && args.Length >= 2)
{
    var ok = args[1] switch
    {
        "Mmx" => CpuSimdEngine.RunMmxTest(),
        "Sse" => CpuSimdEngine.RunSseTest(),
        "Sse2" => CpuSimdEngine.RunSse2Test(),
        "Sse3" => CpuSimdEngine.RunSse3Test(),
        "Ssse3" => CpuSimdEngine.RunSsse3Test(),
        "Sse41" => CpuSimdEngine.RunSse41Test(),
        "Sse42" => CpuSimdEngine.RunSse42Test(),
        _ => false
    };

    return ok ? 0 : 1;
}

Console.Error.WriteLine("Unknown command.");
return 2;
