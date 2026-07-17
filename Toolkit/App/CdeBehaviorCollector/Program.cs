using System.Diagnostics;
using System.Diagnostics.Eventing.Reader;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Xml.Linq;

var app = new CollectorApplication();
return app.Run(args);

internal sealed class CollectorApplication
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    public int Run(string[] args)
    {
        if (args.Length == 0)
        {
            WriteUsage();
            return 2;
        }

        if (string.Equals(args[0], "probe", StringComparison.OrdinalIgnoreCase))
        {
            var probe = BuildProbe();
            Console.WriteLine(JsonSerializer.Serialize(probe, JsonOptions));
            return 0;
        }

        if (!string.Equals(args[0], "collect", StringComparison.OrdinalIgnoreCase))
        {
            WriteUsage();
            return 2;
        }

        var options = ParseCollectOptions(args.Skip(1).ToArray());
        if (!options.IsValid(out var error))
        {
            Console.Error.WriteLine(error);
            WriteUsage();
            return 2;
        }

        try
        {
            var envelope = Collect(options);
            var directory = Path.GetDirectoryName(options.OutputPath);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            File.WriteAllText(options.OutputPath!, JsonSerializer.Serialize(envelope, JsonOptions));
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                outputPath = options.OutputPath,
                artifactCount = envelope.ArtifactCount,
                channelCount = envelope.Channels.Count,
                sinceUtc = envelope.Options.SinceUtc
            }, JsonOptions));
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
    }

    private static CollectorProbe BuildProbe()
    {
        var channels = new[]
        {
            "Security",
            "System",
            "Microsoft-Windows-Windows Defender/Operational",
            "Microsoft-Windows-PowerShell/Operational",
            "Microsoft-Windows-WMI-Activity/Operational",
            "Microsoft-Windows-Sysmon/Operational"
        };

        var results = channels.Select(channel =>
        {
            try
            {
                var exists = EventLog.Exists(channel);
                return new ChannelProbe(channel, exists, exists ? null : "Channel unavailable");
            }
            catch (Exception ex)
            {
                return new ChannelProbe(channel, false, ex.Message);
            }
        }).ToArray();

        return new CollectorProbe(Environment.MachineName, DateTime.UtcNow, results);
    }

    private static BehaviorEnvelope Collect(CollectOptions options)
    {
        var sinceUtc = DateTime.UtcNow.AddHours(-options.SinceHours);
        var artifacts = new List<BehaviorArtifact>();
        var channelResults = new List<ChannelResult>();

        CollectSecurity4688(sinceUtc, options.MaxEventsPerChannel, artifacts, channelResults);
        CollectSystem7045(sinceUtc, options.MaxEventsPerChannel, artifacts, channelResults);
        CollectSecurity4697(sinceUtc, options.MaxEventsPerChannel, artifacts, channelResults);
        CollectDefender1116(sinceUtc, options.MaxEventsPerChannel, artifacts, channelResults);
        CollectPowerShell4104(sinceUtc, options.MaxEventsPerChannel, artifacts, channelResults);
        CollectWmi5861(sinceUtc, options.MaxEventsPerChannel, artifacts, channelResults);
        CollectOptionalSysmon(sinceUtc, options.MaxEventsPerChannel, artifacts, channelResults);

        return new BehaviorEnvelope(
            Collector: "CdeBehaviorCollector",
            GeneratedUtc: DateTime.UtcNow,
            MachineName: Environment.MachineName,
            Options: new EnvelopeOptions(options.SinceHours, options.MaxEventsPerChannel, sinceUtc),
            ArtifactCount: artifacts.Count,
            Channels: channelResults,
            Artifacts: artifacts);
    }

    private static void CollectSecurity4688(DateTime sinceUtc, int maxEvents, List<BehaviorArtifact> artifacts, List<ChannelResult> channelResults)
    {
        CollectFromLog(
            logName: "Security",
            eventId: 4688,
            logicalChannel: "Security-4688",
            sinceUtc: sinceUtc,
            maxEvents: maxEvents,
            artifacts: artifacts,
            channelResults: channelResults,
            mapEvent: record =>
            {
                var data = GetNamedEventData(record);
                var processPath = FirstNonEmpty(data, "NewProcessName", "ProcessName");
                var commandLine = FirstNonEmpty(data, "ProcessCommandLine", "CommandLine");
                var newProcessId = ParseProcessId(FirstNonEmpty(data, "NewProcessId", "ProcessId"));
                var parentPid = ParseProcessId(FirstNonEmpty(data, "CreatorProcessId", "ParentProcessId"));
                var userSid = FirstNonEmpty(data, "SubjectUserSid", "TargetUserSid");
                var integrity = FirstNonEmpty(data, "MandatoryLabel");
                var riskTags = BuildRiskTags(processPath, commandLine);
                var kind = ResolveArtifactKind(riskTags);

                return new BehaviorArtifact(
                    Kind: kind,
                    Source: "CdeBehaviorCollector",
                    Name: Path.GetFileName(processPath),
                    Path: processPath,
                    TargetPath: null,
                    CommandLine: commandLine,
                    Location: "Security/4688",
                    State: "Observed",
                    ObjectType: kind == "Process" ? "Process" : "Telemetry",
                    Evidence: "Process creation observed via Security event 4688.",
                    EntityType: "Process",
                    Pid: newProcessId,
                    ParentPid: parentPid,
                    SessionId: null,
                    UserSid: userSid,
                    IntegrityLevel: integrity,
                    SignerStatus: null,
                    Publisher: null,
                    Sha256: null,
                    SourceChannel: "Security-4688",
                    EvidenceKind: "ImportedTelemetry",
                    RiskTags: riskTags,
                    ParentEntityId: parentPid.HasValue && parentPid.Value > 0 ? $"process:{parentPid.Value}" : null,
                    EdgeType: parentPid.HasValue && parentPid.Value > 0 ? "created_by" : null,
                    CorrelationStrength: 0.0,
                    ConfidenceDelta: riskTags.Count > 0 ? Math.Min(0.15, 0.04 * riskTags.Count) : 0.0,
                    FirstSeenUtc: record.TimeCreated?.ToUniversalTime(),
                    LastSeenUtc: record.TimeCreated?.ToUniversalTime());
            });
    }

    private static void CollectSystem7045(DateTime sinceUtc, int maxEvents, List<BehaviorArtifact> artifacts, List<ChannelResult> channelResults)
    {
        CollectFromLog(
            logName: "System",
            eventId: 7045,
            logicalChannel: "System-7045",
            sinceUtc: sinceUtc,
            maxEvents: maxEvents,
            artifacts: artifacts,
            channelResults: channelResults,
            mapEvent: record =>
            {
                var data = GetNamedEventData(record);
                var serviceName = FirstNonEmpty(data, "ServiceName");
                var imagePath = FirstNonEmpty(data, "ImagePath", "ServiceFileName");
                var accountName = FirstNonEmpty(data, "AccountName");
                var riskTags = BuildRiskTags(imagePath, imagePath);
                if (!string.IsNullOrWhiteSpace(accountName) && accountName.Contains("LocalSystem", StringComparison.OrdinalIgnoreCase))
                {
                    riskTags.Add("runs_as_localsystem");
                }

                return new BehaviorArtifact(
                    Kind: "Service",
                    Source: "CdeBehaviorCollector",
                    Name: serviceName,
                    Path: imagePath,
                    TargetPath: null,
                    CommandLine: imagePath,
                    Location: "System/7045",
                    State: "Installed",
                    ObjectType: "Persistence",
                    Evidence: "Service installation observed via Service Control Manager event 7045.",
                    EntityType: "Service",
                    Pid: null,
                    ParentPid: null,
                    SessionId: null,
                    UserSid: null,
                    IntegrityLevel: null,
                    SignerStatus: null,
                    Publisher: accountName,
                    Sha256: null,
                    SourceChannel: "System-7045",
                    EvidenceKind: "ImportedTelemetry",
                    RiskTags: riskTags,
                    ParentEntityId: null,
                    EdgeType: "installed_service",
                    CorrelationStrength: 0.1,
                    ConfidenceDelta: riskTags.Count > 0 ? 0.1 : 0.0,
                    FirstSeenUtc: record.TimeCreated?.ToUniversalTime(),
                    LastSeenUtc: record.TimeCreated?.ToUniversalTime());
            });
    }

    private static void CollectSecurity4697(DateTime sinceUtc, int maxEvents, List<BehaviorArtifact> artifacts, List<ChannelResult> channelResults)
    {
        CollectFromLog(
            logName: "Security",
            eventId: 4697,
            logicalChannel: "Security-4697",
            sinceUtc: sinceUtc,
            maxEvents: maxEvents,
            artifacts: artifacts,
            channelResults: channelResults,
            mapEvent: record =>
            {
                var data = GetNamedEventData(record);
                var serviceName = FirstNonEmpty(data, "ServiceName");
                var servicePath = FirstNonEmpty(data, "ServiceFileName", "ImagePath");
                var userSid = FirstNonEmpty(data, "SubjectUserSid");
                var riskTags = BuildRiskTags(servicePath, servicePath);

                return new BehaviorArtifact(
                    Kind: "Service",
                    Source: "CdeBehaviorCollector",
                    Name: serviceName,
                    Path: servicePath,
                    TargetPath: null,
                    CommandLine: servicePath,
                    Location: "Security/4697",
                    State: "Installed",
                    ObjectType: "Persistence",
                    Evidence: "Service installation observed via Security event 4697.",
                    EntityType: "Service",
                    Pid: null,
                    ParentPid: null,
                    SessionId: null,
                    UserSid: userSid,
                    IntegrityLevel: null,
                    SignerStatus: null,
                    Publisher: null,
                    Sha256: null,
                    SourceChannel: "Security-4697",
                    EvidenceKind: "ImportedTelemetry",
                    RiskTags: riskTags,
                    ParentEntityId: null,
                    EdgeType: "installed_service",
                    CorrelationStrength: 0.1,
                    ConfidenceDelta: riskTags.Count > 0 ? 0.1 : 0.0,
                    FirstSeenUtc: record.TimeCreated?.ToUniversalTime(),
                    LastSeenUtc: record.TimeCreated?.ToUniversalTime());
            });
    }

    private static void CollectPowerShell4104(DateTime sinceUtc, int maxEvents, List<BehaviorArtifact> artifacts, List<ChannelResult> channelResults)
    {
        CollectFromLog(
            logName: "Microsoft-Windows-PowerShell/Operational",
            eventId: 4104,
            logicalChannel: "PowerShell-4104",
            sinceUtc: sinceUtc,
            maxEvents: maxEvents,
            artifacts: artifacts,
            channelResults: channelResults,
            mapEvent: record =>
            {
                var data = GetNamedEventData(record);
                var scriptText = FirstNonEmpty(data, "ScriptBlockText", "Message");
                var scriptPath = FirstNonEmpty(data, "Path");
                var riskTags = BuildPowerShellRiskTags(scriptText, scriptPath);
                var name = !string.IsNullOrWhiteSpace(scriptPath) ? Path.GetFileName(scriptPath) : "ScriptBlock";

                return new BehaviorArtifact(
                    Kind: "ScriptBlock",
                    Source: "CdeBehaviorCollector",
                    Name: name,
                    Path: scriptPath,
                    TargetPath: null,
                    CommandLine: Truncate(scriptText, 4096),
                    Location: "PowerShell/4104",
                    State: "Observed",
                    ObjectType: "Telemetry",
                    Evidence: "PowerShell script block observed via PowerShell operational event 4104.",
                    EntityType: "PowerShell",
                    Pid: null,
                    ParentPid: null,
                    SessionId: null,
                    UserSid: null,
                    IntegrityLevel: null,
                    SignerStatus: null,
                    Publisher: null,
                    Sha256: null,
                    SourceChannel: "PowerShell-4104",
                    EvidenceKind: "ImportedTelemetry",
                    RiskTags: riskTags,
                    ParentEntityId: null,
                    EdgeType: null,
                    CorrelationStrength: 0.0,
                    ConfidenceDelta: riskTags.Count > 0 ? 0.1 : 0.0,
                    FirstSeenUtc: record.TimeCreated?.ToUniversalTime(),
                    LastSeenUtc: record.TimeCreated?.ToUniversalTime());
            });
    }

    private static void CollectDefender1116(DateTime sinceUtc, int maxEvents, List<BehaviorArtifact> artifacts, List<ChannelResult> channelResults)
    {
        CollectFromLog(
            logName: "Microsoft-Windows-Windows Defender/Operational",
            eventId: 1116,
            logicalChannel: "Defender-1116",
            sinceUtc: sinceUtc,
            maxEvents: maxEvents,
            artifacts: artifacts,
            channelResults: channelResults,
            mapEvent: record =>
            {
                var data = GetNamedEventData(record);
                var threatName = FirstNonEmpty(data, "Threat Name", "ThreatName", "Name");
                var severityName = FirstNonEmpty(data, "Severity Name", "SeverityName", "Severity");
                var path = FirstNonEmpty(data, "Path", "File Path", "FilePath");
                var processName = FirstNonEmpty(data, "Process Name", "ProcessName");
                var userName = FirstNonEmpty(data, "Detection User", "User", "User Name");
                var message = GetEventMessage(record);

                var riskTags = BuildRiskTags(path, processName);
                riskTags.Add("defender_detected");
                if (!string.IsNullOrWhiteSpace(severityName))
                {
                    riskTags.Add("severity_" + severityName.Trim().Replace(' ', '_').ToLowerInvariant());
                }

                var displayName = !string.IsNullOrWhiteSpace(threatName) ? threatName : "DefenderDetection";
                var evidence = !string.IsNullOrWhiteSpace(message)
                    ? "Windows Defender detection observed via operational event 1116. " + Truncate(message, 1024)
                    : "Windows Defender detection observed via operational event 1116.";

                return new BehaviorArtifact(
                    Kind: "ThreatDetection",
                    Source: "CdeBehaviorCollector",
                    Name: displayName,
                    Path: path,
                    TargetPath: null,
                    CommandLine: processName,
                    Location: "Defender/1116",
                    State: "Detected",
                    ObjectType: "Threat",
                    Evidence: evidence,
                    EntityType: "ThreatDetection",
                    Pid: null,
                    ParentPid: null,
                    SessionId: null,
                    UserSid: userName,
                    IntegrityLevel: null,
                    SignerStatus: null,
                    Publisher: severityName,
                    Sha256: null,
                    SourceChannel: "Defender-1116",
                    EvidenceKind: "ImportedTelemetry",
                    RiskTags: riskTags.Distinct(StringComparer.OrdinalIgnoreCase).ToList(),
                    ParentEntityId: null,
                    EdgeType: "defender_detected",
                    CorrelationStrength: 0.95,
                    ConfidenceDelta: 0.25,
                    FirstSeenUtc: record.TimeCreated?.ToUniversalTime(),
                    LastSeenUtc: record.TimeCreated?.ToUniversalTime());
            });
    }

    private static void CollectWmi5861(DateTime sinceUtc, int maxEvents, List<BehaviorArtifact> artifacts, List<ChannelResult> channelResults)
    {
        CollectFromLog(
            logName: "Microsoft-Windows-WMI-Activity/Operational",
            eventId: 5861,
            logicalChannel: "WMI-5861",
            sinceUtc: sinceUtc,
            maxEvents: maxEvents,
            artifacts: artifacts,
            channelResults: channelResults,
            mapEvent: record =>
            {
                var data = GetNamedEventData(record);
                var consumer = FirstNonEmpty(data, "Consumer", "ConsumerName", "PossibleCause");
                var query = FirstNonEmpty(data, "Query", "QueryText");
                var namespaceName = FirstNonEmpty(data, "NamespaceName", "Namespace");
                var user = FirstNonEmpty(data, "User", "UserName", "ClientMachine");
                var message = GetEventMessage(record);
                var combinedCommand = FirstNonEmpty(
                    new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                    {
                        ["query"] = query,
                        ["message"] = message,
                        ["consumer"] = consumer
                    },
                    "query",
                    "message",
                    "consumer");

                var riskTags = BuildPowerShellRiskTags(combinedCommand, consumer);
                riskTags.Add("wmi_subscription");
                if (!string.IsNullOrWhiteSpace(namespaceName) && namespaceName.Contains("subscription", StringComparison.OrdinalIgnoreCase))
                {
                    riskTags.Add("wmi_persistence_namespace");
                }

                var displayName = !string.IsNullOrWhiteSpace(consumer) ? consumer : "WmiSubscription";
                var evidence = !string.IsNullOrWhiteSpace(message)
                    ? "WMI activity observed via operational event 5861. " + Truncate(message, 1024)
                    : "WMI activity observed via operational event 5861.";

                return new BehaviorArtifact(
                    Kind: "WmiSubscription",
                    Source: "CdeBehaviorCollector",
                    Name: displayName,
                    Path: consumer,
                    TargetPath: null,
                    CommandLine: Truncate(combinedCommand, 4096),
                    Location: string.IsNullOrWhiteSpace(namespaceName) ? "WMI/5861" : namespaceName,
                    State: "Observed",
                    ObjectType: "Persistence",
                    Evidence: evidence,
                    EntityType: "WmiSubscription",
                    Pid: null,
                    ParentPid: null,
                    SessionId: null,
                    UserSid: user,
                    IntegrityLevel: null,
                    SignerStatus: null,
                    Publisher: null,
                    Sha256: null,
                    SourceChannel: "WMI-5861",
                    EvidenceKind: "ImportedTelemetry",
                    RiskTags: riskTags.Distinct(StringComparer.OrdinalIgnoreCase).ToList(),
                    ParentEntityId: null,
                    EdgeType: "wmi_subscription",
                    CorrelationStrength: 0.2,
                    ConfidenceDelta: riskTags.Count > 1 ? 0.12 : 0.05,
                    FirstSeenUtc: record.TimeCreated?.ToUniversalTime(),
                    LastSeenUtc: record.TimeCreated?.ToUniversalTime());
            });
    }

    private static void CollectFromLog(
        string logName,
        int eventId,
        string logicalChannel,
        DateTime sinceUtc,
        int maxEvents,
        List<BehaviorArtifact> artifacts,
        List<ChannelResult> channelResults,
        Func<EventRecord, BehaviorArtifact?> mapEvent)
    {
        var beforeCount = artifacts.Count;
        try
        {
            if (!EventLog.Exists(logName))
            {
                channelResults.Add(new ChannelResult(logicalChannel, "Unavailable", 0, "Event log unavailable."));
                return;
            }

            var query = new EventLogQuery(logName, PathType.LogName, $"*[System[EventID={eventId}]]")
            {
                ReverseDirection = true
            };

            using var reader = new EventLogReader(query);
            for (EventRecord? record = reader.ReadEvent(); record is not null; record = reader.ReadEvent())
            {
                using (record)
                {
                    var created = record.TimeCreated?.ToUniversalTime();
                    if (created.HasValue && created.Value < sinceUtc)
                    {
                        break;
                    }

                    var artifact = mapEvent(record);
                    if (artifact is null)
                    {
                        continue;
                    }

                    artifacts.Add(artifact);
                    if (artifacts.Count - beforeCount >= maxEvents)
                    {
                        break;
                    }
                }
            }

            channelResults.Add(new ChannelResult(logicalChannel, "Collected", artifacts.Count - beforeCount, null));
        }
        catch (EventLogNotFoundException ex)
        {
            channelResults.Add(new ChannelResult(logicalChannel, "Unavailable", 0, ex.Message));
        }
        catch (UnauthorizedAccessException ex)
        {
            channelResults.Add(new ChannelResult(logicalChannel, "AccessDenied", 0, ex.Message));
        }
        catch (Exception ex)
        {
            channelResults.Add(new ChannelResult(logicalChannel, "Error", 0, ex.Message));
        }
    }

    private static Dictionary<string, string> GetNamedEventData(EventRecord record)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var xml = record.ToXml();
        var document = XDocument.Parse(xml);
        XNamespace ns = document.Root?.Name.Namespace ?? XNamespace.None;

        foreach (var data in document.Descendants(ns + "Data"))
        {
            var name = (string?)data.Attribute("Name");
            if (string.IsNullOrWhiteSpace(name))
            {
                continue;
            }

            result[name] = data.Value?.Trim() ?? string.Empty;
        }

        return result;
    }

    private static string FirstNonEmpty(IReadOnlyDictionary<string, string> values, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (values.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value))
            {
                return value.Trim();
            }
        }

        return string.Empty;
    }

    private static string GetEventMessage(EventRecord record)
    {
        try
        {
            return record.FormatDescription() ?? string.Empty;
        }
        catch
        {
            return string.Empty;
        }
    }

    private static int? ParseProcessId(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            return null;
        }

        raw = raw.Trim();
        if (raw.StartsWith("0x", StringComparison.OrdinalIgnoreCase) && int.TryParse(raw[2..], System.Globalization.NumberStyles.HexNumber, null, out var hexValue))
        {
            return hexValue;
        }

        return int.TryParse(raw, out var decimalValue) ? decimalValue : null;
    }

    private static List<string> BuildRiskTags(string? path, string? commandLine)
    {
        var tags = new List<string>();
        var combined = ((path ?? string.Empty) + " " + (commandLine ?? string.Empty)).ToLowerInvariant();

        if (combined.Contains("\\appdata\\") || combined.Contains("\\temp\\") || combined.Contains("\\programdata\\"))
        {
            tags.Add("user_writable_path");
        }

        if (combined.Contains("-enc") || combined.Contains("encodedcommand"))
        {
            tags.Add("encoded_command");
        }

        if (combined.Contains("downloadstring") || combined.Contains("invoke-webrequest") || combined.Contains("bitsadmin") || combined.Contains("certutil"))
        {
            tags.Add("network_stager");
        }

        if (combined.Contains("login data") || combined.Contains("\\cookies") || combined.Contains("web data") ||
            combined.Contains("key4.db") || combined.Contains("logins.json") || combined.Contains("procdump") ||
            combined.Contains("mimikatz") || combined.Contains("lsass.exe") || combined.Contains("\\lsass"))
        {
            tags.Add("credential_store_touch");
            tags.Add("lsass_or_browser_store");
        }

        if ((combined.Contains("vssadmin") && combined.Contains("delete")) ||
            combined.Contains("shadowcopy delete") ||
            (combined.Contains("wbadmin") && combined.Contains("delete")) ||
            (combined.Contains("diskshadow") && combined.Contains("delete")) ||
            combined.Contains("resize shadowstorage") ||
            (combined.Contains("recoveryenabled") && combined.Contains("no")) ||
            (combined.Contains("reagentc") && combined.Contains("disable")))
        {
            tags.Add("t1490_recovery_inhibit");
        }

        if (combined.Contains("virtualallocex") || combined.Contains("writeprocessmemory") ||
            combined.Contains("createremotethread") || combined.Contains("ntcreatethreadex") ||
            combined.Contains("reflectivedll") || combined.Contains("process hollowing"))
        {
            tags.Add("injection_api");
        }

        if (combined.Contains("xmrig") || combined.Contains("stratum+tcp") || combined.Contains("stratum+ssl") ||
            combined.Contains("nicehash") || combined.Contains("ethminer") || combined.Contains("--cuda"))
        {
            tags.Add("miner_cmdline");
        }

        return tags.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    }

    private static string ResolveArtifactKind(IReadOnlyCollection<string> riskTags)
    {
        if (riskTags.Any(t => t.Equals("credential_store_touch", StringComparison.OrdinalIgnoreCase) ||
                              t.Equals("lsass_or_browser_store", StringComparison.OrdinalIgnoreCase)))
        {
            return "CredentialAccess";
        }

        if (riskTags.Any(t => t.Equals("injection_api", StringComparison.OrdinalIgnoreCase) ||
                              t.Equals("remote_thread", StringComparison.OrdinalIgnoreCase) ||
                              t.Equals("process_access", StringComparison.OrdinalIgnoreCase)))
        {
            return "ProcessInjection";
        }

        if (riskTags.Any(t => t.Equals("t1490_recovery_inhibit", StringComparison.OrdinalIgnoreCase)))
        {
            return "RecoveryTamper";
        }

        return "Process";
    }

    private static void CollectOptionalSysmon(DateTime sinceUtc, int maxEvents, List<BehaviorArtifact> artifacts, List<ChannelResult> channelResults)
    {
        const string sysmonLog = "Microsoft-Windows-Sysmon/Operational";
        if (!EventLog.Exists(sysmonLog))
        {
            channelResults.Add(new ChannelResult("Sysmon", "Unavailable", 0, "Sysmon operational log not present; skipped."));
            return;
        }

        CollectFromLog(
            logName: sysmonLog,
            eventId: 8,
            logicalChannel: "Sysmon-8",
            sinceUtc: sinceUtc,
            maxEvents: maxEvents,
            artifacts: artifacts,
            channelResults: channelResults,
            mapEvent: record =>
            {
                var data = GetNamedEventData(record);
                var sourceImage = FirstNonEmpty(data, "SourceImage");
                var targetImage = FirstNonEmpty(data, "TargetImage");
                var sourcePid = ParseProcessId(FirstNonEmpty(data, "SourceProcessId", "SourceProcessGuid"));
                var riskTags = new List<string> { "remote_thread", "injection_api" };
                riskTags.AddRange(BuildRiskTags(sourceImage, targetImage));

                return new BehaviorArtifact(
                    Kind: "ProcessInjection",
                    Source: "CdeBehaviorCollector",
                    Name: Path.GetFileName(sourceImage),
                    Path: sourceImage,
                    TargetPath: targetImage,
                    CommandLine: null,
                    Location: "Sysmon/8",
                    State: "Observed",
                    ObjectType: "Telemetry",
                    Evidence: "CreateRemoteThread observed via Sysmon event 8.",
                    EntityType: "Process",
                    Pid: sourcePid,
                    ParentPid: null,
                    SessionId: null,
                    UserSid: null,
                    IntegrityLevel: null,
                    SignerStatus: null,
                    Publisher: null,
                    Sha256: null,
                    SourceChannel: "Sysmon-8",
                    EvidenceKind: "ImportedTelemetry",
                    RiskTags: riskTags.Distinct(StringComparer.OrdinalIgnoreCase).ToList(),
                    ParentEntityId: null,
                    EdgeType: "remote_thread",
                    CorrelationStrength: 0.25,
                    ConfidenceDelta: 0.12,
                    FirstSeenUtc: record.TimeCreated?.ToUniversalTime(),
                    LastSeenUtc: record.TimeCreated?.ToUniversalTime());
            });

        CollectFromLog(
            logName: sysmonLog,
            eventId: 10,
            logicalChannel: "Sysmon-10",
            sinceUtc: sinceUtc,
            maxEvents: maxEvents,
            artifacts: artifacts,
            channelResults: channelResults,
            mapEvent: record =>
            {
                var data = GetNamedEventData(record);
                var sourceImage = FirstNonEmpty(data, "SourceImage");
                var targetImage = FirstNonEmpty(data, "TargetImage");
                var sourcePid = ParseProcessId(FirstNonEmpty(data, "SourceProcessId"));
                var riskTags = new List<string> { "process_access" };
                if (!string.IsNullOrWhiteSpace(targetImage) &&
                    targetImage.Contains("lsass", StringComparison.OrdinalIgnoreCase))
                {
                    riskTags.Add("lsass_access");
                    riskTags.Add("credential_store_touch");
                }

                riskTags.AddRange(BuildRiskTags(sourceImage, targetImage));
                var kind = ResolveArtifactKind(riskTags);

                return new BehaviorArtifact(
                    Kind: kind,
                    Source: "CdeBehaviorCollector",
                    Name: Path.GetFileName(sourceImage),
                    Path: sourceImage,
                    TargetPath: targetImage,
                    CommandLine: null,
                    Location: "Sysmon/10",
                    State: "Observed",
                    ObjectType: "Telemetry",
                    Evidence: "Process access observed via Sysmon event 10.",
                    EntityType: "Process",
                    Pid: sourcePid,
                    ParentPid: null,
                    SessionId: null,
                    UserSid: null,
                    IntegrityLevel: null,
                    SignerStatus: null,
                    Publisher: null,
                    Sha256: null,
                    SourceChannel: "Sysmon-10",
                    EvidenceKind: "ImportedTelemetry",
                    RiskTags: riskTags.Distinct(StringComparer.OrdinalIgnoreCase).ToList(),
                    ParentEntityId: null,
                    EdgeType: "process_access",
                    CorrelationStrength: 0.2,
                    ConfidenceDelta: 0.1,
                    FirstSeenUtc: record.TimeCreated?.ToUniversalTime(),
                    LastSeenUtc: record.TimeCreated?.ToUniversalTime());
            });
    }

    private static List<string> BuildPowerShellRiskTags(string? scriptText, string? scriptPath)
    {
        var tags = BuildRiskTags(scriptPath, scriptText);
        var lower = (scriptText ?? string.Empty).ToLowerInvariant();

        if (lower.Contains("invoke-expression") || lower.Contains("iex "))
        {
            tags.Add("powershell_iex");
        }

        if (lower.Contains("frombase64string") || lower.Contains("-encodedcommand"))
        {
            tags.Add("powershell_encoded");
        }

        return tags.Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    }

    private static string Truncate(string? value, int maxLength)
    {
        if (string.IsNullOrEmpty(value) || value.Length <= maxLength)
        {
            return value ?? string.Empty;
        }

        return value[..maxLength];
    }

    private static CollectOptions ParseCollectOptions(string[] args)
    {
        var options = new CollectOptions();

        for (var index = 0; index < args.Length; index++)
        {
            var token = args[index];
            if (string.Equals(token, "--output", StringComparison.OrdinalIgnoreCase) && index + 1 < args.Length)
            {
                options.OutputPath = args[++index];
                continue;
            }

            if (string.Equals(token, "--since-hours", StringComparison.OrdinalIgnoreCase) && index + 1 < args.Length && double.TryParse(args[++index], out var sinceHours))
            {
                options.SinceHours = sinceHours;
                continue;
            }

            if (string.Equals(token, "--max-events", StringComparison.OrdinalIgnoreCase) && index + 1 < args.Length && int.TryParse(args[++index], out var maxEvents))
            {
                options.MaxEventsPerChannel = maxEvents;
                continue;
            }
        }

        return options;
    }

    private static void WriteUsage()
    {
        Console.Error.WriteLine("Usage:");
        Console.Error.WriteLine("  CdeBehaviorCollector probe");
        Console.Error.WriteLine("  CdeBehaviorCollector collect --output <path> [--since-hours <n>] [--max-events <n>]");
    }
}

internal sealed class CollectOptions
{
    public string? OutputPath { get; set; }
    public double SinceHours { get; set; } = 24;
    public int MaxEventsPerChannel { get; set; } = 64;

    public bool IsValid(out string error)
    {
        if (string.IsNullOrWhiteSpace(OutputPath))
        {
            error = "Missing required --output path.";
            return false;
        }

        if (SinceHours <= 0 || SinceHours > 720)
        {
            error = "--since-hours must be between 0 and 720.";
            return false;
        }

        if (MaxEventsPerChannel <= 0 || MaxEventsPerChannel > 2048)
        {
            error = "--max-events must be between 1 and 2048.";
            return false;
        }

        error = string.Empty;
        return true;
    }
}

internal sealed record CollectorProbe(string MachineName, DateTime GeneratedUtc, IReadOnlyList<ChannelProbe> Channels);

internal sealed record ChannelProbe(string LogName, bool Available, string? Message);

internal sealed record EnvelopeOptions(double SinceHours, int MaxEventsPerChannel, DateTime SinceUtc);

internal sealed record BehaviorEnvelope(
    string Collector,
    DateTime GeneratedUtc,
    string MachineName,
    EnvelopeOptions Options,
    int ArtifactCount,
    IReadOnlyList<ChannelResult> Channels,
    IReadOnlyList<BehaviorArtifact> Artifacts);

internal sealed record ChannelResult(string SourceChannel, string Status, int CollectedArtifacts, string? Message);

internal sealed record BehaviorArtifact(
    string Kind,
    string Source,
    string? Name,
    string? Path,
    string? TargetPath,
    string? CommandLine,
    string? Location,
    string? State,
    string? ObjectType,
    string? Evidence,
    string? EntityType,
    int? Pid,
    int? ParentPid,
    int? SessionId,
    string? UserSid,
    string? IntegrityLevel,
    string? SignerStatus,
    string? Publisher,
    string? Sha256,
    string SourceChannel,
    string EvidenceKind,
    IReadOnlyList<string> RiskTags,
    string? ParentEntityId,
    string? EdgeType,
    double CorrelationStrength,
    double ConfidenceDelta,
    DateTime? FirstSeenUtc,
    DateTime? LastSeenUtc);